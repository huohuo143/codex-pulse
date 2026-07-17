import Foundation

public enum ReliabilityHealthLevel: String, Codable, Sendable {
  case healthy
  case warning
  case critical
  case unknown

  public var rank: Int {
    switch self {
    case .critical: 3
    case .warning: 2
    case .unknown: 1
    case .healthy: 0
    }
  }
}

public enum ReliabilityCheckID: String, Codable, CaseIterable, Sendable {
  case officialQuota
  case tokenAggregation
  case radar
  case quotaHistory
  case projectBudgets
  case widgetSnapshot
  case launchWatcher
}

public struct ReliabilityCheck: Identifiable, Equatable, Codable, Sendable {
  public var id: ReliabilityCheckID
  public var title: String
  public var level: ReliabilityHealthLevel
  public var detail: String
  public var checkedAt: Date

  public init(
    id: ReliabilityCheckID,
    title: String,
    level: ReliabilityHealthLevel,
    detail: String,
    checkedAt: Date
  ) {
    self.id = id
    self.title = title
    self.level = level
    self.detail = detail
    self.checkedAt = checkedAt
  }
}

public struct ReliabilitySnapshot: Equatable, Codable, Sendable {
  public var generatedAt: Date
  public var overall: ReliabilityHealthLevel
  public var checks: [ReliabilityCheck]

  public init(generatedAt: Date = Date(), checks: [ReliabilityCheck] = []) {
    self.generatedAt = generatedAt
    self.checks = checks
    overall = checks.max(by: { $0.level.rank < $1.level.rank })?.level ?? .unknown
  }

  public var warningCount: Int {
    checks.filter { $0.level == .warning }.count
  }

  public var criticalCount: Int {
    checks.filter { $0.level == .critical }.count
  }
}

public enum ReliabilityAuditor {
  public struct Inputs: Sendable {
    public var lastQuotaRefresh: Date?
    public var hasOfficialQuota: Bool
    public var lastUsageRefresh: Date?
    public var usageSampleCount: Int
    public var radarUpdatedAt: Date?
    public var launchWatcherEnabled: Bool
    public var quotaHistoryURL: URL
    public var projectBudgetsURL: URL
    public var widgetSnapshotURL: URL

    public init(
      lastQuotaRefresh: Date?,
      hasOfficialQuota: Bool,
      lastUsageRefresh: Date?,
      usageSampleCount: Int,
      radarUpdatedAt: Date?,
      launchWatcherEnabled: Bool,
      quotaHistoryURL: URL = QuotaHistoryStore.defaultURL,
      projectBudgetsURL: URL = ProjectBudgetStore.defaultURL,
      widgetSnapshotURL: URL = CodexWidgetSnapshotStore.defaultURL()
    ) {
      self.lastQuotaRefresh = lastQuotaRefresh
      self.hasOfficialQuota = hasOfficialQuota
      self.lastUsageRefresh = lastUsageRefresh
      self.usageSampleCount = usageSampleCount
      self.radarUpdatedAt = radarUpdatedAt
      self.launchWatcherEnabled = launchWatcherEnabled
      self.quotaHistoryURL = quotaHistoryURL
      self.projectBudgetsURL = projectBudgetsURL
      self.widgetSnapshotURL = widgetSnapshotURL
    }
  }

  public static func audit(
    inputs: Inputs,
    now: Date = Date(),
    fileManager: FileManager = .default
  ) -> ReliabilitySnapshot {
    let checks = [
      freshnessCheck(
        id: .officialQuota,
        title: "官方额度读取",
        date: inputs.lastQuotaRefresh,
        hasData: inputs.hasOfficialQuota,
        warningAfter: 10 * 60,
        criticalAfter: 30 * 60,
        now: now
      ),
      freshnessCheck(
        id: .tokenAggregation,
        title: "Token 完整汇总",
        date: inputs.lastUsageRefresh,
        hasData: inputs.usageSampleCount > 0,
        warningAfter: 20 * 60,
        criticalAfter: 90 * 60,
        now: now
      ),
      freshnessCheck(
        id: .radar,
        title: "重置雷达",
        date: inputs.radarUpdatedAt,
        hasData: inputs.radarUpdatedAt != nil,
        warningAfter: 90 * 60,
        criticalAfter: 4 * 60 * 60,
        now: now
      ),
      jsonFileCheck(
        id: .quotaHistory,
        title: "额度历史文件",
        url: inputs.quotaHistoryURL,
        missingLevel: inputs.hasOfficialQuota ? .warning : .unknown,
        now: now,
        fileManager: fileManager
      ),
      jsonFileCheck(
        id: .projectBudgets,
        title: "项目预算文件",
        url: inputs.projectBudgetsURL,
        missingLevel: .healthy,
        missingDetail: "尚未设置项目预算",
        now: now,
        fileManager: fileManager
      ),
      widgetCheck(url: inputs.widgetSnapshotURL, now: now, fileManager: fileManager),
      ReliabilityCheck(
        id: .launchWatcher,
        title: "自动启动守护",
        level: .healthy,
        detail: inputs.launchWatcherEnabled ? "已启用并可自动修复安装路径" : "未启用，按用户设置保持关闭",
        checkedAt: now
      )
    ]
    return ReliabilitySnapshot(generatedAt: now, checks: checks)
  }

  private static func freshnessCheck(
    id: ReliabilityCheckID,
    title: String,
    date: Date?,
    hasData: Bool,
    warningAfter: TimeInterval,
    criticalAfter: TimeInterval,
    now: Date
  ) -> ReliabilityCheck {
    guard hasData, let date else {
      return ReliabilityCheck(id: id, title: title, level: .unknown, detail: "等待首次有效数据", checkedAt: now)
    }
    let age = max(0, now.timeIntervalSince(date))
    let level: ReliabilityHealthLevel = age > criticalAfter ? .critical : (age > warningAfter ? .warning : .healthy)
    return ReliabilityCheck(
      id: id,
      title: title,
      level: level,
      detail: level == .healthy ? "数据新鲜" : "已 \(ageText(age)) 未更新",
      checkedAt: now
    )
  }

  private static func jsonFileCheck(
    id: ReliabilityCheckID,
    title: String,
    url: URL,
    missingLevel: ReliabilityHealthLevel,
    missingDetail: String = "等待首次生成",
    now: Date,
    fileManager: FileManager
  ) -> ReliabilityCheck {
    guard fileManager.fileExists(atPath: url.path) else {
      return ReliabilityCheck(id: id, title: title, level: missingLevel, detail: missingDetail, checkedAt: now)
    }
    do {
      let data = try Data(contentsOf: url)
      _ = try JSONSerialization.jsonObject(with: data)
      return ReliabilityCheck(id: id, title: title, level: .healthy, detail: "文件可读且 JSON 结构有效", checkedAt: now)
    } catch {
      return ReliabilityCheck(id: id, title: title, level: .critical, detail: "文件损坏或无法读取，等待隔离重建", checkedAt: now)
    }
  }

  private static func widgetCheck(url: URL, now: Date, fileManager: FileManager) -> ReliabilityCheck {
    guard fileManager.fileExists(atPath: url.path) else {
      return ReliabilityCheck(id: .widgetSnapshot, title: "Widget 快照", level: .warning, detail: "快照尚未生成", checkedAt: now)
    }
    do {
      let snapshot = try CodexWidgetSnapshotStore.load(from: url, fileManager: fileManager)
      let age = max(0, now.timeIntervalSince(snapshot.updatedAt))
      let level: ReliabilityHealthLevel = age > 2 * 60 * 60 ? .critical : (age > 30 * 60 ? .warning : .healthy)
      return ReliabilityCheck(
        id: .widgetSnapshot,
        title: "Widget 快照",
        level: level,
        detail: level == .healthy ? "快照可读且已同步" : "快照已 \(ageText(age)) 未更新",
        checkedAt: now
      )
    } catch {
      return ReliabilityCheck(id: .widgetSnapshot, title: "Widget 快照", level: .critical, detail: "快照损坏或无法解码", checkedAt: now)
    }
  }

  private static func ageText(_ interval: TimeInterval) -> String {
    if interval >= 3600 { return "\(Int(interval / 3600)) 小时" }
    return "\(max(1, Int(interval / 60))) 分钟"
  }
}

public enum ReliabilityEventKind: String, Codable, Sendable {
  case info
  case warning
  case recovery
  case failure
}

public struct ReliabilityEvent: Identifiable, Equatable, Codable, Sendable {
  public var id: UUID
  public var timestamp: Date
  public var kind: ReliabilityEventKind
  public var title: String
  public var detail: String

  public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    kind: ReliabilityEventKind,
    title: String,
    detail: String
  ) {
    self.id = id
    self.timestamp = timestamp
    self.kind = kind
    self.title = title
    self.detail = detail
  }
}

public final class ReliabilityEventStore: @unchecked Sendable {
  public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodexSuanliMeter/reliability-events-v1.json")

  private struct Payload: Codable {
    var schemaVersion: Int
    var events: [ReliabilityEvent]
  }

  private let url: URL
  private let fileManager: FileManager
  private let lock = NSLock()

  public init(url: URL = ReliabilityEventStore.defaultURL, fileManager: FileManager = .default) {
    self.url = url
    self.fileManager = fileManager
  }

  public func load() -> [ReliabilityEvent] {
    lock.withLock { loadUnlocked() }
  }

  @discardableResult
  public func append(_ event: ReliabilityEvent) throws -> [ReliabilityEvent] {
    try lock.withLock {
      var rows = loadUnlocked()
      rows.append(event)
      rows = Array(rows.sorted { $0.timestamp < $1.timestamp }.suffix(500))
      try saveUnlocked(rows)
      return rows
    }
  }

  private func loadUnlocked() -> [ReliabilityEvent] {
    guard fileManager.fileExists(atPath: url.path) else { return [] }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder.reliability.decode(Payload.self, from: data).events
    } catch {
      quarantineCorruptFile()
      return []
    }
  }

  private func saveUnlocked(_ rows: [ReliabilityEvent]) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder.reliability.encode(Payload(schemaVersion: 1, events: rows))
    try data.write(to: url, options: .atomic)
  }

  private func quarantineCorruptFile() {
    guard fileManager.fileExists(atPath: url.path) else { return }
    let target = url.deletingPathExtension()
      .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
    try? fileManager.moveItem(at: url, to: target)
  }
}

public struct LocalAutomationResult: Equatable, Sendable {
  public var outputURL: URL
  public var itemCount: Int

  public init(outputURL: URL, itemCount: Int) {
    self.outputURL = outputURL
    self.itemCount = itemCount
  }
}

public final class LocalAutomationArchive: @unchecked Sendable {
  public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodexSuanliMeter/automation", isDirectory: true)

  private let root: URL
  private let fileManager: FileManager
  private let calendar: Calendar

  public init(
    root: URL = LocalAutomationArchive.defaultRoot,
    fileManager: FileManager = .default,
    calendar: Calendar = .current
  ) {
    self.root = root
    self.fileManager = fileManager
    self.calendar = calendar
  }

  public func backup(
    sourceURLs: [URL],
    now: Date = Date(),
    retentionDays: Int = 7
  ) throws -> LocalAutomationResult {
    let day = dayKey(now)
    let destination = root.appendingPathComponent("backups/\(day)", isDirectory: true)
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    var count = 0
    for source in sourceURLs where fileManager.fileExists(atPath: source.path) {
      let data = try Data(contentsOf: source)
      try data.write(to: destination.appendingPathComponent(source.lastPathComponent), options: .atomic)
      count += 1
    }
    try pruneBackups(now: now, retentionDays: retentionDays)
    return LocalAutomationResult(outputURL: destination, itemCount: count)
  }

  public func archiveDailySummary(_ markdown: String, now: Date = Date()) throws -> URL {
    let directory = root.appendingPathComponent("daily-reports", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent("codex-daily-summary-\(dayKey(now)).md")
    try markdown.write(to: target, atomically: true, encoding: .utf8)
    return target
  }

  public func hasBackup(for date: Date) -> Bool {
    fileManager.fileExists(atPath: root.appendingPathComponent("backups/\(dayKey(date))").path)
  }

  public func hasDailySummary(for date: Date) -> Bool {
    fileManager.fileExists(atPath: root.appendingPathComponent("daily-reports/codex-daily-summary-\(dayKey(date)).md").path)
  }

  private func pruneBackups(now: Date, retentionDays: Int) throws {
    let directory = root.appendingPathComponent("backups", isDirectory: true)
    guard let rows = try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    let cutoff = calendar.date(byAdding: .day, value: -max(1, retentionDays), to: calendar.startOfDay(for: now)) ?? .distantPast
    for row in rows {
      guard let date = dayDate(row.lastPathComponent), date < cutoff else { continue }
      try fileManager.removeItem(at: row)
    }
  }

  private func dayKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private func dayDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)
  }
}

public enum ReliabilityReportBuilder {
  public static func diagnosticMarkdown(
    appVersion: String,
    snapshot: ReliabilitySnapshot,
    recentEvents: [ReliabilityEvent],
    generatedAt: Date = Date()
  ) -> String {
    var rows = [
      "# Codex 脉动诊断报告",
      "",
      "- 版本：\(appVersion)",
      "- 系统：\(ProcessInfo.processInfo.operatingSystemVersionString)",
      "- 生成时间：\(generatedAt.formatted(date: .numeric, time: .standard))",
      "- 总体状态：\(snapshot.overall.rawValue)",
      "",
      "## 健康检查",
      ""
    ]
    for check in snapshot.checks {
      rows.append("- [\(check.level.rawValue)] \(check.title)：\(check.detail)")
    }
    rows.append(contentsOf: ["", "## 最近可靠性事件", ""])
    if recentEvents.isEmpty {
      rows.append("- 暂无事件")
    } else {
      for event in recentEvents.suffix(20).reversed() {
        rows.append("- \(event.timestamp.formatted(date: .numeric, time: .shortened)) [\(event.kind.rawValue)] \(event.title)：\(event.detail)")
      }
    }
    rows.append(contentsOf: [
      "",
      "> 本报告不包含账号、对话、项目路径、凭据或 API Key。",
      ""
    ])
    return rows.joined(separator: "\n")
  }

  public static func dailySummaryMarkdown(
    remainingPercent: Double?,
    rolling24hTokens: Int,
    monthTokens: Int,
    projectedMonthTokens: Int,
    quotaRisk: String,
    health: ReliabilityHealthLevel,
    generatedAt: Date = Date()
  ) -> String {
    let remainingText = remainingPercent.map { "\(Int($0.rounded()))%" } ?? "--"
    return [
      "# Codex 脉动每日摘要",
      "",
      "- 日期：\(generatedAt.formatted(date: .numeric, time: .shortened))",
      "- 7 天剩余额度：\(remainingText)",
      "- 额度风险：\(quotaRisk)",
      "- 滚动 24h Token：\(rolling24hTokens)",
      "- 本月 Token：\(monthTokens)",
      "- 月末预计 Token：\(projectedMonthTokens)",
      "- 可靠性状态：\(health.rawValue)",
      "",
      "> 只包含本机聚合指标，不包含对话正文或项目路径。",
      ""
    ].joined(separator: "\n")
  }
}

private extension JSONEncoder {
  static var reliability: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

private extension JSONDecoder {
  static var reliability: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
