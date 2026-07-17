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
  public var remainingPercent: Double?
  public var usedPercent: Double?
  public var resetsAt: Date?
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
  public var resetCreditsAvailable: Int?
  public var resetCredits: [CodexWidgetResetCredit]
  public var sampleCount: Int
  public var deviceCount: Int
  public var hourly24: [CodexWidgetPoint]
  public var daily14: [CodexWidgetPoint]
  public var topProjects: [CodexWidgetMetric]
  public var topCategories: [CodexWidgetMetric]

  public init(
    schemaVersion: Int = 1,
    updatedAt: Date = Date(),
    remainingPercent: Double? = nil,
    usedPercent: Double? = nil,
    resetsAt: Date? = nil,
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
    self.resetCreditsAvailable = resetCreditsAvailable
    self.resetCredits = resetCredits
    self.sampleCount = sampleCount
    self.deviceCount = deviceCount
    self.hourly24 = hourly24
    self.daily14 = daily14
    self.topProjects = topProjects
    self.topCategories = topCategories
  }

  public static var empty: CodexWidgetSnapshot {
    CodexWidgetSnapshot(updatedAt: .distantPast)
  }

  public static var preview: CodexWidgetSnapshot {
    let now = Date()
    return CodexWidgetSnapshot(
      updatedAt: now,
      remainingPercent: 68,
      usedPercent: 32,
      resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60 + 8 * 60 * 60),
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

  package init(minimumInterval: TimeInterval = 10) {
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
