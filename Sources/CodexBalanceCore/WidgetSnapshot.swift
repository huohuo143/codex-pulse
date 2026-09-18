import Darwin
import Foundation

public struct CodexWidgetPoint: Codable, Equatable, Sendable {
  public var label: String
  public var tokens: Int

  public init(label: String, tokens: Int) {
    self.label = label
    self.tokens = tokens
  }
}

public struct CodexWidgetMetric: Codable, Equatable, Sendable {
  public var label: String
  public var tokens: Int

  public init(label: String, tokens: Int) {
    self.label = label
    self.tokens = tokens
  }
}

public struct CodexWidgetResetCredit: Codable, Equatable, Sendable {
  public var title: String
  public var expiresAt: Date?

  public init(title: String, expiresAt: Date?) {
    self.title = title
    self.expiresAt = expiresAt
  }
}

/// 主 App 与 WidgetKit 扩展之间的聚合数据契约。
/// 不包含会话内容、源文件路径、项目路径、账户凭据或权益兑换 ID。
public struct CodexWidgetSnapshot: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var updatedAt: Date
  public var usageUpdatedAt: Date? = nil
  public var usageValidUntil: Date? = nil
  public var confirmedCreditExpiry: Date? = nil
  public var quotaRead: SourceReadMetadata? = nil
  public var flexibleCreditRead: SourceReadMetadata? = nil
  public var resetCreditsRead: SourceReadMetadata? = nil
  public var cost24Coverage: Double? = nil
  public var cost7Coverage: Double? = nil
  public var costMonthCoverage: Double? = nil
  public var unpricedModels: [String]? = nil
  public var remainingPercent: Double?
  public var usedPercent: Double?
  public var resetsAt: Date?
  public var fiveHourRemainingPercent: Double?
  public var fiveHourUsedPercent: Double?
  public var fiveHourResetsAt: Date?
  public var showsFiveHourQuota: Bool?
  public var rolling24HoursTokens: Int
  public var todayTokens: Int
  public var last7DaysTokens: Int
  public var monthTokens: Int
  public var cost24HoursUSD: Double
  public var cost7DaysUSD: Double
  public var costMonthUSD: Double
  public var cnyRate: Double?
  public var resetProbability24h: Int?
  public var radarLevel: String?
  public var radarSummary: String?
  public var radarUpdatedAt: Date?
  public var radarCheckedAt: Date?
  public var radarLastSuccessAt: Date?
  public var radarSourceUpdatedAt: Date?
  public var radarEvidenceUpdatedAt: Date?
  public var radarEvaluatedAt: Date?
  public var radarValidUntil: Date?
  public var radarSyncStatus: String?
  public var radarConsecutiveFailures: Int?
  public var radarIsUsingCachedFeed: Bool?
  public var radarIsStale: Bool?
  public var resetCreditsAvailable: Int?
  public var resetCredits: [CodexWidgetResetCredit]
  public var sampleCount: Int
  public var deviceCount: Int
  public var hourly24: [CodexWidgetPoint]
  public var daily14: [CodexWidgetPoint]
  public var topProjects: [CodexWidgetMetric]
  public var topCategories: [CodexWidgetMetric]

  public init(
    schemaVersion: Int = 4,
    updatedAt: Date = Date(),
    remainingPercent: Double? = nil,
    usedPercent: Double? = nil,
    resetsAt: Date? = nil,
    fiveHourRemainingPercent: Double? = nil,
    fiveHourUsedPercent: Double? = nil,
    fiveHourResetsAt: Date? = nil,
    showsFiveHourQuota: Bool = false,
    rolling24HoursTokens: Int = 0,
    todayTokens: Int = 0,
    last7DaysTokens: Int = 0,
    monthTokens: Int = 0,
    cost24HoursUSD: Double = 0,
    cost7DaysUSD: Double = 0,
    costMonthUSD: Double = 0,
    cnyRate: Double? = nil,
    resetProbability24h: Int? = nil,
    radarLevel: String? = nil,
    radarSummary: String? = nil,
    radarUpdatedAt: Date? = nil,
    radarCheckedAt: Date? = nil,
    radarLastSuccessAt: Date? = nil,
    radarSourceUpdatedAt: Date? = nil,
    radarEvidenceUpdatedAt: Date? = nil,
    radarEvaluatedAt: Date? = nil,
    radarValidUntil: Date? = nil,
    radarSyncStatus: String? = nil,
    radarConsecutiveFailures: Int? = nil,
    radarIsUsingCachedFeed: Bool? = nil,
    radarIsStale: Bool? = nil,
    resetCreditsAvailable: Int? = nil,
    resetCredits: [CodexWidgetResetCredit] = [],
    sampleCount: Int = 0,
    deviceCount: Int = 0,
    hourly24: [CodexWidgetPoint] = [],
    daily14: [CodexWidgetPoint] = [],
    topProjects: [CodexWidgetMetric] = [],
    topCategories: [CodexWidgetMetric] = []
  ) {
    self.schemaVersion = schemaVersion
    self.updatedAt = updatedAt
    self.remainingPercent = remainingPercent
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
    self.fiveHourRemainingPercent = fiveHourRemainingPercent
    self.fiveHourUsedPercent = fiveHourUsedPercent
    self.fiveHourResetsAt = fiveHourResetsAt
    self.showsFiveHourQuota = showsFiveHourQuota
    self.rolling24HoursTokens = rolling24HoursTokens
    self.todayTokens = todayTokens
    self.last7DaysTokens = last7DaysTokens
    self.monthTokens = monthTokens
    self.cost24HoursUSD = cost24HoursUSD
    self.cost7DaysUSD = cost7DaysUSD
    self.costMonthUSD = costMonthUSD
    self.cnyRate = cnyRate
    self.resetProbability24h = resetProbability24h
    self.radarLevel = radarLevel
    self.radarSummary = radarSummary
    self.radarUpdatedAt = radarUpdatedAt
    self.radarCheckedAt = radarCheckedAt
    self.radarLastSuccessAt = radarLastSuccessAt
    self.radarSourceUpdatedAt = radarSourceUpdatedAt
    self.radarEvidenceUpdatedAt = radarEvidenceUpdatedAt
    self.radarEvaluatedAt = radarEvaluatedAt
    self.radarValidUntil = radarValidUntil
    self.radarSyncStatus = radarSyncStatus
    self.radarConsecutiveFailures = radarConsecutiveFailures
    self.radarIsUsingCachedFeed = radarIsUsingCachedFeed
    self.radarIsStale = radarIsStale
    self.resetCreditsAvailable = resetCreditsAvailable
    self.resetCredits = resetCredits
    self.sampleCount = sampleCount
    self.deviceCount = deviceCount
    self.hourly24 = hourly24
    self.daily14 = daily14
    self.topProjects = topProjects
    self.topCategories = topCategories
  }

  /// Evaluate each source at display time, without promoting the snapshot write
  /// time to an official sample. Legacy fields stay decodable but unverified.
  public func effective(at now: Date) -> CodexWidgetSnapshot {
    var result = self
    if schemaVersion < 4 || quotaRead?.state(at: now, resetAt: resetsAt).canDisplayValue != true {
      result.remainingPercent = nil
      result.usedPercent = nil
    }
    if schemaVersion < 4 || quotaRead?.state(at: now, resetAt: fiveHourResetsAt).canDisplayValue != true {
      result.fiveHourRemainingPercent = nil
      result.fiveHourUsedPercent = nil
    }
    if schemaVersion < 4 || resetCreditsRead?.state(at: now).canDisplayValue != true {
      result.resetCreditsAvailable = nil
      result.resetCredits = []
    } else {
      let expired = resetCredits.filter { $0.expiresAt.map { $0 <= now } ?? false }
      result.resetCredits = resetCredits.filter { $0.expiresAt.map { $0 > now } ?? true }
      result.resetCreditsAvailable = resetCreditsAvailable.map { max(0, $0 - expired.count) }
    }
    if schemaVersion < 4 || radarIsStale == true || radarLastSuccessAt.map({ now.timeIntervalSince($0) > 90 * 60 }) != false || radarValidUntil.map({ $0 <= now }) == true {
      result.resetProbability24h = nil
      result.radarLevel = "数据过期"
    }
    if !usageState(at: now).canDisplayValue {
      result.hourly24 = []; result.daily14 = []; result.topProjects = []; result.topCategories = []
      result.cost24Coverage = nil; result.cost7Coverage = nil; result.costMonthCoverage = nil
    }
    return result
  }

  public func usageState(at now: Date) -> DataFreshnessState {
    guard schemaVersion >= 4, let date = usageUpdatedAt else { return .unavailable }
    let value = SourceReadMetadata(source: "本机日志", sampledAt: date, lastAttemptAt: date, lastSuccessAt: date).state(at: now)
    return value == .fresh && usageValidUntil.map({ $0 <= now }) == true ? .cached : value
  }

  public func timelineDates(after now: Date) -> [Date] {
    let sourceDates = [quotaRead, flexibleCreditRead, resetCreditsRead].compactMap { $0 }.flatMap { metadata in
      [metadata.lastSuccessAt?.addingTimeInterval(301), metadata.lastSuccessAt?.addingTimeInterval(1801)].compactMap { $0 }
    }
    let boundaries = [resetsAt, displaysFiveHourQuota ? fiveHourResetsAt : nil, confirmedCreditExpiry,
      radarValidUntil, radarLastSuccessAt?.addingTimeInterval(5401), usageValidUntil,
      usageUpdatedAt?.addingTimeInterval(301), usageUpdatedAt?.addingTimeInterval(1801)].compactMap { $0 }
      + resetCredits.compactMap(\.expiresAt) + sourceDates
    return [now] + Set(boundaries.filter { $0 > now && $0 <= now.addingTimeInterval(86400) }).sorted()
  }

  public static var empty: CodexWidgetSnapshot {
    CodexWidgetSnapshot(updatedAt: .distantPast)
  }

  public var displaysFiveHourQuota: Bool {
    showsFiveHourQuota == true
  }

  public static var preview: CodexWidgetSnapshot {
    let now = Date()
    var result = CodexWidgetSnapshot(
      updatedAt: now,
      remainingPercent: 68,
      usedPercent: 32,
      resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60 + 8 * 60 * 60),
      fiveHourRemainingPercent: 84,
      fiveHourUsedPercent: 16,
      fiveHourResetsAt: now.addingTimeInterval(2 * 60 * 60 + 20 * 60),
      showsFiveHourQuota: true,
      rolling24HoursTokens: 1_286_000,
      todayTokens: 846_000,
      last7DaysTokens: 5_420_000,
      monthTokens: 18_760_000,
      cost24HoursUSD: 24.18,
      cost7DaysUSD: 98.52,
      costMonthUSD: 326.47,
      cnyRate: 7.18,
      resetProbability24h: 72,
      radarLevel: "高概率",
      radarSummary: "公开信号升温，建议关注官方更新与重置窗口。",
      radarUpdatedAt: now.addingTimeInterval(-18 * 60),
      resetCreditsAvailable: 2,
      resetCredits: [
        CodexWidgetResetCredit(title: "Full reset #1", expiresAt: now.addingTimeInterval(5 * 24 * 60 * 60)),
        CodexWidgetResetCredit(title: "Full reset #2", expiresAt: now.addingTimeInterval(12 * 24 * 60 * 60))
      ],
      sampleCount: 128,
      deviceCount: 2,
      hourly24: (0..<24).map { index in
        CodexWidgetPoint(label: String(format: "%02d:00", index), tokens: ((index * 37) % 11 + 1) * 18_000)
      },
      daily14: (1...14).map { day in
        CodexWidgetPoint(label: "7/\(day)", tokens: ((day * 53) % 9 + 2) * 180_000)
      },
      topProjects: [
        CodexWidgetMetric(label: "Codex 脉动", tokens: 472_000),
        CodexWidgetMetric(label: "OsPTM 论文", tokens: 238_000),
        CodexWidgetMetric(label: "MTF Figure", tokens: 136_000)
      ],
      topCategories: [
        CodexWidgetMetric(label: "编程/APP", tokens: 486_000),
        CodexWidgetMetric(label: "论文/写作", tokens: 224_000),
        CodexWidgetMetric(label: "生物科研", tokens: 119_000)
      ]
    )
    let sample = SourceReadMetadata(source: "示例数据", sampledAt: now, lastAttemptAt: now, lastSuccessAt: now)
    result.quotaRead = sample; result.resetCreditsRead = sample; result.flexibleCreditRead = sample
    result.usageUpdatedAt = now; result.radarLastSuccessAt = now
    result.cost24Coverage = 100; result.cost7Coverage = 100; result.costMonthCoverage = 100
    return result
  }

  /// 比较会影响 Widget 展示的内容，忽略每次轮询都会改变的写入时间。
  package func hasSameWidgetContent(as other: CodexWidgetSnapshot) -> Bool {
    var lhs = self
    var rhs = other
    lhs.updatedAt = .distantPast
    rhs.updatedAt = .distantPast
    return lhs == rhs
  }
}

package enum CodexWidgetReloadDecision: Equatable, Sendable {
  case none
  case reloadNow
  case schedule(after: TimeInterval)
}

/// WidgetKit 重载策略：首次立即刷新，密集变化合并到最早可刷新时刻。
package struct CodexWidgetReloadPolicy: Sendable {
  package let minimumInterval: TimeInterval

  package init(minimumInterval: TimeInterval = 60) {
    self.minimumInterval = minimumInterval
  }

  package func decision(
    needsReload: Bool,
    lastReloadAt: Date?,
    hasPendingReload: Bool,
    now: Date
  ) -> CodexWidgetReloadDecision {
    guard needsReload else { return .none }
    guard let lastReloadAt else { return .reloadNow }

    let remaining = minimumInterval - now.timeIntervalSince(lastReloadAt)
    if remaining <= 0 { return .reloadNow }
    if hasPendingReload { return .none }
    return .schedule(after: remaining)
  }
}

public enum CodexWidgetSnapshotStore {
  public static let fileName = "widget-snapshot.json"
  public static let widgetExtensionBundleIdentifier = "dev.codex.balance-dashboard.codex.widgets"

  public static func defaultURL(fileManager: FileManager = .default) -> URL {
    if let path = ProcessInfo.processInfo.environment["CODEX_PULSE_SUPPORT_DIR"] { return URL(fileURLWithPath: path).appendingPathComponent(fileName) }
    let home: URL
    if let password = getpwuid(getuid()), let directory = password.pointee.pw_dir {
      home = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    } else {
      home = fileManager.homeDirectoryForCurrentUser
    }
    return home
      .appendingPathComponent("Library/Application Support/CodexSuanliMeter", isDirectory: true)
      .appendingPathComponent(fileName)
  }

  /// The host app is intentionally not sandboxed, so it can publish the
  /// redacted snapshot directly into the Widget extension's own container.
  public static func widgetContainerURL(
    userHome: URL? = nil,
    fileManager: FileManager = .default
  ) -> URL {
    if userHome == nil, let path = ProcessInfo.processInfo.environment["CODEX_PULSE_SUPPORT_DIR"] { return URL(fileURLWithPath: path).appendingPathComponent("widget-container/" + fileName) }
    let home = userHome ?? resolvedUserHome(fileManager: fileManager)
    return home
      .appendingPathComponent("Library/Containers", isDirectory: true)
      .appendingPathComponent(widgetExtensionBundleIdentifier, isDirectory: true)
      .appendingPathComponent("Data/Library/Application Support/CodexSuanliMeter", isDirectory: true)
      .appendingPathComponent(fileName)
  }

  /// Inside the extension sandbox this resolves to its container's Data home.
  public static func sandboxedWidgetURL(
    containerHome: URL? = nil,
    fileManager: FileManager = .default
  ) -> URL {
    if containerHome == nil, let path = ProcessInfo.processInfo.environment["CODEX_PULSE_SUPPORT_DIR"] { return URL(fileURLWithPath: path).appendingPathComponent("widget-container/" + fileName) }
    let home = containerHome ?? fileManager.homeDirectoryForCurrentUser
    return home
      .appendingPathComponent("Library/Application Support/CodexSuanliMeter", isDirectory: true)
      .appendingPathComponent(fileName)
  }

  public static func save(
    _ snapshot: CodexWidgetSnapshot,
    to url: URL? = nil,
    fileManager: FileManager = .default
  ) throws {
    let target = url ?? defaultURL(fileManager: fileManager)
    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(snapshot).write(to: target, options: [.atomic])
  }

  public static func load(
    from url: URL? = nil,
    fileManager: FileManager = .default
  ) throws -> CodexWidgetSnapshot {
    let target = url ?? defaultURL(fileManager: fileManager)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try decoder.decode(CodexWidgetSnapshot.self, from: Data(contentsOf: target))
  }

  private static func resolvedUserHome(fileManager: FileManager) -> URL {
    if let password = getpwuid(getuid()), let directory = password.pointee.pw_dir {
      return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }
    return fileManager.homeDirectoryForCurrentUser
  }
}

public enum CodexWidgetSnapshotFreshness {
  public static let maximumLiveAge: TimeInterval = 5 * 60
  private static let clockTolerance: TimeInterval = 5

  /// A Widget snapshot is live only when it was written during the current
  /// system boot and recently refreshed. This prevents a pre-reboot quota from
  /// being presented as current while the host App is still reconnecting.
  public static func isFromCurrentBoot(_ snapshot: CodexWidgetSnapshot, now: Date = Date(), systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
    systemUptime >= 0 && snapshot.updatedAt <= now.addingTimeInterval(clockTolerance)
      && snapshot.updatedAt >= now.addingTimeInterval(-systemUptime - clockTolerance)
  }

  public static func isFresh(
    _ snapshot: CodexWidgetSnapshot,
    now: Date = Date(),
    systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
    maximumAge: TimeInterval = maximumLiveAge
  ) -> Bool {
    guard systemUptime >= 0, maximumAge >= 0 else { return false }
    let bootTime = now.addingTimeInterval(-systemUptime)
    let age = now.timeIntervalSince(snapshot.updatedAt)
    guard age >= -clockTolerance, age <= maximumAge else { return false }
    return snapshot.updatedAt >= bootTime.addingTimeInterval(-clockTolerance)
  }
}

public enum CodexWidgetKind: String, CaseIterable, Sendable {
  case overview, quota, radar, resetCredits = "reset-credits", tokenSummary = "token-summary", tokenTrend = "token-trend", workload
  public var identifier: String { "dev.codex.balance-dashboard.codex." + rawValue }
}

public extension CodexWidgetSnapshot {
  func affectedKinds(comparedTo previous: CodexWidgetSnapshot?) -> Set<CodexWidgetKind> {
    guard let previous, schemaVersion == previous.schemaVersion else { return Set(CodexWidgetKind.allCases) }
    var kinds = Set<CodexWidgetKind>()
    // Renew a domain that has become stale since its previous timeline was
    // published, without reloading on every unchanged statistics heartbeat.
    if usageState(at: updatedAt) != previous.usageState(at: updatedAt) {
      kinds.formUnion([.overview, .tokenSummary, .tokenTrend, .workload])
    }
    if remainingPercent != previous.remainingPercent || usedPercent != previous.usedPercent || resetsAt != previous.resetsAt || fiveHourRemainingPercent != previous.fiveHourRemainingPercent || fiveHourUsedPercent != previous.fiveHourUsedPercent || fiveHourResetsAt != previous.fiveHourResetsAt || showsFiveHourQuota != previous.showsFiveHourQuota || quotaRead != previous.quotaRead { kinds.formUnion([.quota, .overview]) }
    if resetProbability24h != previous.resetProbability24h || radarLevel != previous.radarLevel || radarSummary != previous.radarSummary || radarLastSuccessAt != previous.radarLastSuccessAt || radarEvidenceUpdatedAt != previous.radarEvidenceUpdatedAt || radarEvaluatedAt != previous.radarEvaluatedAt || radarValidUntil != previous.radarValidUntil || radarSyncStatus != previous.radarSyncStatus || radarConsecutiveFailures != previous.radarConsecutiveFailures || radarIsStale != previous.radarIsStale || radarIsUsingCachedFeed != previous.radarIsUsingCachedFeed { kinds.formUnion([.radar, .overview]) }
    if resetCreditsAvailable != previous.resetCreditsAvailable || resetCredits != previous.resetCredits || resetCreditsRead != previous.resetCreditsRead || confirmedCreditExpiry != previous.confirmedCreditExpiry { kinds.formUnion([.resetCredits, .overview]) }
    if rolling24HoursTokens != previous.rolling24HoursTokens || todayTokens != previous.todayTokens || last7DaysTokens != previous.last7DaysTokens || monthTokens != previous.monthTokens || cost24HoursUSD != previous.cost24HoursUSD || cost7DaysUSD != previous.cost7DaysUSD || costMonthUSD != previous.costMonthUSD || cost24Coverage != previous.cost24Coverage || cost7Coverage != previous.cost7Coverage || costMonthCoverage != previous.costMonthCoverage || unpricedModels != previous.unpricedModels || cnyRate != previous.cnyRate { kinds.formUnion([.tokenSummary, .overview]) }
    if hourly24 != previous.hourly24 || daily14 != previous.daily14 { kinds.formUnion([.tokenTrend, .overview]) }
    if topProjects != previous.topProjects || topCategories != previous.topCategories { kinds.formUnion([.workload]) }
    return kinds
  }
}
