import CodexBalanceCore
import Foundation
import Security
import SwiftUI
import WidgetKit

@MainActor
protocol OpenAIAPICredentialStorage {
  func save(_ value: String) -> Bool
  func read() -> String?
  func remove() -> Bool
}

/// This item belongs solely to the API usage connection. The secret is never
/// included in preferences, widgets, diagnostics, or shared packages.
@MainActor
struct OpenAIAPIKeychain: OpenAIAPICredentialStorage {
  private let service = "dev.codex.balance-dashboard.openai-api-usage"
  private let account = "organization-costs"

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
  }

  func save(_ value: String) -> Bool {
    let data = Data(value.utf8)
    let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if result == errSecSuccess { return true }
    guard result == errSecItemNotFound else { return false }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrLabel as String] = "Codex 脉动 · API 用量"
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  func read() -> String? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func remove() -> Bool {
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }
}

extension Notification.Name {
  static let openAIAPIUsageChanged = Notification.Name("dev.codex.balance-dashboard.api-usage-changed")
}

@MainActor
final class OpenAIAPIUsageStore: ObservableObject {
  static let shared = OpenAIAPIUsageStore()
  @Published private(set) var reading: OpenAIAPICostReading?
  @Published private(set) var grant: OpenAIAPIGrantConfirmation?
  @Published private(set) var grantExpiry: OpenAIAPIGrantExpiry?
  @Published private(set) var expiryNotificationsEnabled: Bool
  @Published private(set) var expiryReminderStatus: APIExpiryReminderStatus = .noDate
  @Published private(set) var isConnected: Bool
  @Published private(set) var isRefreshing = false
  @Published private(set) var message: String
  @Published private(set) var lastAttemptAt: Date?

  private let defaults: UserDefaults
  private let credentials: any OpenAIAPICredentialStorage
  private let reader: OpenAIAPIUsageReader
  private let publishToWidget: Bool
  private let reminderService: any APIExpiryReminderScheduling
  private var timer: Timer?
  private var started = false
  private var generation = 0
  private var retryAt: Date?
  private var reminderGeneration = 0
  private var reminderTask: Task<Void, Never>?

  init(defaults: UserDefaults = PulsePreferences.shared,
       credentials: any OpenAIAPICredentialStorage = OpenAIAPIKeychain(),
       reader: OpenAIAPIUsageReader = OpenAIAPIUsageReader(),
       publishToWidget: Bool = true,
       reminderService: (any APIExpiryReminderScheduling)? = nil) {
    self.defaults = defaults
    self.credentials = credentials
    self.reader = reader
    self.publishToWidget = publishToWidget
    self.reminderService = reminderService ?? (PulsePreferences.isIsolated || !publishToWidget
      ? APIExpiryReminderPreview() as any APIExpiryReminderScheduling
      : APIExpiryReminderService() as any APIExpiryReminderScheduling)
    expiryNotificationsEnabled = defaults.object(forKey: "openAIAPIExpiryNotificationsEnabled") as? Bool ?? true
    let connected = defaults.bool(forKey: "openAIAPIUsageConnected")
    isConnected = connected
    message = connected ? "等待更新" : "未连接 API 用量"
    retryAt = defaults.object(forKey: "openAIAPIUsageRetryAt") as? Date
    if connected, let data = defaults.data(forKey: "openAIAPICostReading"),
       let value = try? JSONDecoder().decode(OpenAIAPICostReading.self, from: data),
       value.costUSD.isFinite, value.isCurrentPeriod(at: Date()) {
      reading = value
    }
    if let data = defaults.data(forKey: "openAIAPIGrantConfirmation"),
       let value = try? JSONDecoder().decode(OpenAIAPIGrantConfirmation.self, from: data),
       OpenAIAPIGrantConfirmation(totalUSD: value.totalUSD, remainingUSD: value.remainingUSD,
                                  checkedAt: value.checkedAt, expiresAt: value.expiresAt) != nil {
      grant = value
    }
    if let data = defaults.data(forKey: "openAIAPIGrantExpiry"),
       let value = try? JSONDecoder().decode(OpenAIAPIGrantExpiry.self, from: data),
       value.expiresAt.timeIntervalSince1970.isFinite, value.confirmedAt.timeIntervalSince1970.isFinite {
      grantExpiry = value
    } else if let grant, let expiry = grant.expiresAt {
      // Upgrade older confirmed grants without deriving a date from spending.
      grantExpiry = OpenAIAPIGrantExpiry(expiresAt: expiry, confirmedAt: grant.checkedAt)
    }
  }

  func start() {
    guard !started else { return }
    started = true
    if isConnected { refresh() }
    let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    synchronizeReminders(requestPermission: false)
    publishChange()
  }

  @discardableResult
  func connect(adminKey: String) async -> Bool {
    let value = adminKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !isRefreshing else {
      message = "请输入管理员密钥"
      return false
    }
    if let retryAt, retryAt > Date() {
      message = "请在 \(retryAt.formatted(date: .omitted, time: .shortened)) 后重试"
      return false
    }
    generation += 1
    let requestGeneration = generation
    isRefreshing = true
    message = "正在验证用量读取权限"
    let result: OpenAIAPICostReading
    do { result = try await reader.fetch(adminKey: value) }
    catch {
      guard generation == requestGeneration else { return false }
      isRefreshing = false
      message = errorMessage(error)
      return false
    }
    guard generation == requestGeneration else { return false }
    isRefreshing = false
    guard credentials.save(value) else {
      message = "无法保存到钥匙串，请重试"
      return false
    }
    // Replacing a connection may change organization. A first connection
    // retains a grant the user already confirmed for their chosen organization.
    let replacingConnection = isConnected
    reading = result
    if replacingConnection { grant = nil; grantExpiry = nil }
    if let data = try? JSONEncoder().encode(result) { defaults.set(data, forKey: "openAIAPICostReading") }
    if replacingConnection {
      defaults.removeObject(forKey: "openAIAPIGrantConfirmation")
      defaults.removeObject(forKey: "openAIAPIGrantExpiry")
      synchronizeReminders(requestPermission: false)
    }
    defaults.set(true, forKey: "openAIAPIUsageConnected")
    isConnected = true
    retryAt = nil
    defaults.removeObject(forKey: "openAIAPIUsageRetryAt")
    message = "已读取 · 数据可能有统计延迟"
    publishChange()
    return true
  }

  func disconnect() {
    guard credentials.remove() else { message = "无法移除钥匙串连接"; return }
    generation += 1
    isRefreshing = false
    defaults.set(false, forKey: "openAIAPIUsageConnected")
    defaults.removeObject(forKey: "openAIAPICostReading")
    defaults.removeObject(forKey: "openAIAPIGrantConfirmation")
    defaults.removeObject(forKey: "openAIAPIGrantExpiry")
    defaults.removeObject(forKey: "openAIAPIUsageRetryAt")
    isConnected = false
    reading = nil
    grant = nil
    grantExpiry = nil
    retryAt = nil
    message = "未连接 API 用量"
    synchronizeReminders(requestPermission: false)
    publishChange()
  }

  func refresh() {
    guard isConnected, !isRefreshing else { return }
    if let retryAt, retryAt > Date() { return }
    guard let key = credentials.read(), !key.isEmpty else {
      message = "请在设置中重新连接 API 用量"
      publishChange()
      return
    }
    isRefreshing = true
    lastAttemptAt = Date()
    let reader = reader
    let requestGeneration = generation
    Task { [weak self] in
      do {
        let result = try await reader.fetch(adminKey: key)
        guard let self, self.generation == requestGeneration else { return }
        self.isRefreshing = false
        guard self.isConnected else { return }
        self.reading = result
        self.retryAt = nil
        self.defaults.removeObject(forKey: "openAIAPIUsageRetryAt")
        if let data = try? JSONEncoder().encode(result) { self.defaults.set(data, forKey: "openAIAPICostReading") }
        self.message = "已读取 · 数据可能有统计延迟"
        self.publishChange()
      } catch {
        guard let self, self.generation == requestGeneration else { return }
        self.isRefreshing = false
        guard self.isConnected else { return }
        self.message = self.errorMessage(error)
        self.publishChange()
      }
    }
  }

  func confirmGrant(total: Double, remaining: Double, expiresAt: Date?) -> Bool {
    guard let value = OpenAIAPIGrantConfirmation(totalUSD: total, remainingUSD: remaining,
                                                  checkedAt: Date(), expiresAt: expiresAt ?? grantExpiry?.expiresAt),
          let data = try? JSONEncoder().encode(value) else { return false }
    grant = value
    defaults.set(data, forKey: "openAIAPIGrantConfirmation")
    if let expiresAt { _ = confirmExpiry(expiresAt, requestPermission: false) }
    publishChange()
    return true
  }

  func clearGrant() {
    grant = nil
    defaults.removeObject(forKey: "openAIAPIGrantConfirmation")
    publishChange()
  }

  @discardableResult
  func confirmExpiry(_ date: Date, requestPermission: Bool = true) -> Bool {
    guard date.timeIntervalSince1970.isFinite else { return false }
    let value = OpenAIAPIGrantExpiry(expiresAt: date, confirmedAt: Date())
    guard let data = try? JSONEncoder().encode(value) else { return false }
    grantExpiry = value
    defaults.set(data, forKey: "openAIAPIGrantExpiry")
    if var grant {
      grant.expiresAt = date
      self.grant = grant
      if let saved = try? JSONEncoder().encode(grant) { defaults.set(saved, forKey: "openAIAPIGrantConfirmation") }
    }
    synchronizeReminders(requestPermission: requestPermission)
    publishChange()
    return true
  }

  func clearExpiry() {
    grantExpiry = nil
    defaults.removeObject(forKey: "openAIAPIGrantExpiry")
    if var grant {
      grant.expiresAt = nil
      self.grant = grant
      if let saved = try? JSONEncoder().encode(grant) { defaults.set(saved, forKey: "openAIAPIGrantConfirmation") }
    }
    synchronizeReminders(requestPermission: false)
    publishChange()
  }

  func setExpiryNotificationsEnabled(_ enabled: Bool) {
    expiryNotificationsEnabled = enabled
    defaults.set(enabled, forKey: "openAIAPIExpiryNotificationsEnabled")
    synchronizeReminders(requestPermission: enabled)
  }

  func retryExpiryReminders() { synchronizeReminders(requestPermission: true) }

  /// Allows callers to observe completion without inspecting notification contents.
  func waitForReminderUpdate() async { await reminderTask?.value }

  private func synchronizeReminders(requestPermission: Bool) {
    reminderGeneration += 1
    let current = reminderGeneration
    let previous = reminderTask
    let expiry = grantExpiry
    let enabled = expiryNotificationsEnabled
    let service = reminderService
    reminderTask = Task { [weak self] in
      await previous?.value
      guard let self, self.reminderGeneration == current else { return }
      let status = await service.synchronize(expiry: expiry, enabled: enabled, requestPermission: requestPermission)
      guard self.reminderGeneration == current else { return }
      self.expiryReminderStatus = status
    }
  }

  var currentReading: OpenAIAPICostReading? {
    guard isConnected, let reading, reading.costUSD.isFinite, reading.isCurrentPeriod(at: Date()),
          reading.sampledAt <= Date().addingTimeInterval(5) else { return nil }
    return reading
  }

  var isCostStale: Bool {
    guard let reading = currentReading else { return false }
    return Date().timeIntervalSince(reading.sampledAt) > 15 * 60 || message != "已读取 · 数据可能有统计延迟"
  }

  var costText: String {
    guard let reading = currentReading else { return "—" }
    return Self.money(reading.costUSD)
  }

  var grantText: String {
    guard let grant else { return "待确认" }
    guard !(grantExpiry?.hasExpired(at: Date()) ?? grant.isExpired(at: Date())) else { return "已过期" }
    return Self.money(grant.remainingUSD)
  }

  var costDetail: String {
    guard let reading = currentReading else { return isConnected ? message : "未连接" }
    let time = reading.sampledAt.formatted(date: .omitted, time: .shortened)
    if isCostStale {
      return "上次读取 \(time)"
    }
    return "更新于 \(time) · UTC 月度"
  }

  static func money(_ amount: Double) -> String {
    OpenAIAPIAmountFormat.money(amount)
  }

  private func errorMessage(_ error: Error) -> String {
    switch error as? OpenAIAPIUsageError {
    case .unauthorized: return "密钥无效，请重新连接"
    case .forbidden: return "当前密钥没有用量读取权限"
    case .rateLimited(let delay):
      let next = Date().addingTimeInterval(max(300, delay ?? 900))
      retryAt = next
      defaults.set(next, forKey: "openAIAPIUsageRetryAt")
      return "读取受限，将在 \(next.formatted(date: .omitted, time: .shortened)) 后重试"
    default: return "暂时无法读取，保留上次数据"
    }
  }

  private func publishChange() {
    if publishToWidget {
      let safe = OpenAIAPIWidgetSnapshot(
        publishedAt: Date(), isConnected: isConnected,
        monthlyCostUSD: currentReading?.costUSD, periodStart: currentReading?.periodStart,
        costSampledAt: currentReading?.sampledAt, status: message,
        grantTotalUSD: grant?.totalUSD, grantRemainingUSD: grant?.remainingUSD,
        grantCheckedAt: grant?.checkedAt, grantExpiresAt: grantExpiry?.expiresAt,
        grantExpiryConfirmedAt: grantExpiry?.confirmedAt
      )
      try? OpenAIAPIWidgetSnapshotStore.save(safe)
      if !PulsePreferences.isIsolated {
        WidgetCenter.shared.reloadTimelines(ofKind: OpenAIAPIWidgetSnapshotStore.widgetKind)
      }
    }
    NotificationCenter.default.post(name: .openAIAPIUsageChanged, object: nil)
  }
}
