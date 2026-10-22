import CryptoKit
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
  case creditExpiry
  case widgetSnapshot
  case launchWatcher
  case localBackup
  case reliabilityEvents
  case dailySummary
}

public enum LocalBackupHealthState: Sendable {
  case notChecked
  case verified
  case noData
  case failed
}

public enum DailySummaryHealthState: Sendable {
  case notChecked
  case verified
  case failed
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
    public var quotaState: DataFreshnessState?
    public var lastUsageRefresh: Date?
    public var usageSampleCount: Int
    public var unreadableSessionFiles: Int
    public var radarUpdatedAt: Date?
    public var launchWatcherEnabled: Bool
    public var quotaHistoryURL: URL
    public var projectBudgetsURL: URL
    public var widgetSnapshotURL: URL
    public var quotaHistoryStorageMessage: String?
    public var projectBudgetStorageMessage: String?
    public var projectBudgetWriteFailed: Bool
    public var creditExpiryStore: CreditExpiryLedgerStore
    public var creditExpiryStorageIssue: CreditExpiryStorageError?
    public var creditExpiryWriteFailed: Bool
    public var localBackupHealth: LocalBackupHealthState
    public var automaticBackupsEnabled: Bool
    public var eventStorageIssue: ReliabilityEventStorageIssue?
    public var eventWriteFailed: Bool
    public var dailySummaryHealth: DailySummaryHealthState
    public var dailySummaryEnabled: Bool
    public var dailySummaryDue: Bool

    public init(
      lastQuotaRefresh: Date?,
      hasOfficialQuota: Bool,
      lastUsageRefresh: Date?,
      usageSampleCount: Int,
      radarUpdatedAt: Date?,
      launchWatcherEnabled: Bool,
      quotaHistoryURL: URL = QuotaHistoryStore.defaultURL,
      projectBudgetsURL: URL = ProjectBudgetStore.defaultURL,
      widgetSnapshotURL: URL = CodexWidgetSnapshotStore.defaultURL(),
      quotaState: DataFreshnessState? = nil,
      quotaHistoryStorageMessage: String? = nil,
      projectBudgetStorageMessage: String? = nil,
      projectBudgetWriteFailed: Bool = false,
      creditExpiryStore: CreditExpiryLedgerStore = CreditExpiryLedgerStore(),
      creditExpiryStorageIssue: CreditExpiryStorageError? = nil,
      creditExpiryWriteFailed: Bool = false,
      localBackupHealth: LocalBackupHealthState = .notChecked,
      automaticBackupsEnabled: Bool = false,
      eventStorageIssue: ReliabilityEventStorageIssue? = nil,
      eventWriteFailed: Bool = false,
      dailySummaryHealth: DailySummaryHealthState = .notChecked,
      dailySummaryEnabled: Bool = false,
      dailySummaryDue: Bool = false,
      unreadableSessionFiles: Int = 0
    ) {
      self.quotaState = quotaState
      self.lastQuotaRefresh = lastQuotaRefresh
      self.hasOfficialQuota = hasOfficialQuota
      self.lastUsageRefresh = lastUsageRefresh
      self.usageSampleCount = usageSampleCount
      self.unreadableSessionFiles = unreadableSessionFiles
      self.radarUpdatedAt = radarUpdatedAt
      self.launchWatcherEnabled = launchWatcherEnabled
      self.quotaHistoryURL = quotaHistoryURL
      self.projectBudgetsURL = projectBudgetsURL
      self.widgetSnapshotURL = widgetSnapshotURL
      self.quotaHistoryStorageMessage = quotaHistoryStorageMessage
      self.projectBudgetStorageMessage = projectBudgetStorageMessage
      self.projectBudgetWriteFailed = projectBudgetWriteFailed
      self.creditExpiryStore = creditExpiryStore
      self.creditExpiryStorageIssue = creditExpiryStorageIssue
      self.creditExpiryWriteFailed = creditExpiryWriteFailed
      self.localBackupHealth = localBackupHealth
      self.automaticBackupsEnabled = automaticBackupsEnabled
      self.eventStorageIssue = eventStorageIssue
      self.eventWriteFailed = eventWriteFailed
      self.dailySummaryHealth = dailySummaryHealth
      self.dailySummaryEnabled = dailySummaryEnabled
      self.dailySummaryDue = dailySummaryDue
    }
  }

  public static func audit(
    inputs: Inputs,
    now: Date = Date(),
    fileManager: FileManager = .default
  ) -> ReliabilitySnapshot {
    var checks = [
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
      projectBudgetCheck(inputs: inputs, now: now, fileManager: fileManager),
      creditExpiryCheck(inputs: inputs, now: now),
      widgetCheck(url: inputs.widgetSnapshotURL, now: now, fileManager: fileManager),
      localBackupCheck(inputs: inputs, now: now),
      eventHistoryCheck(issue: inputs.eventStorageIssue, writeFailed: inputs.eventWriteFailed, now: now),
      ReliabilityCheck(
        id: .launchWatcher,
        title: "自动启动守护",
        level: .healthy,
        detail: inputs.launchWatcherEnabled ? "已启用并可自动修复安装路径" : "未启用，按用户设置保持关闭",
        checkedAt: now
      )
    ]
    if inputs.unreadableSessionFiles > 0, let index = checks.firstIndex(where: { $0.id == .tokenAggregation }) {
      checks[index] = ReliabilityCheck(id: .tokenAggregation, title: "Token 完整汇总",
        level: checks[index].level == .critical ? .critical : .warning,
        detail: "有 \(inputs.unreadableSessionFiles) 个会话日志暂时无法完整读取，当前统计可能不完整；已保留可用记录并将自动重试。", checkedAt: now)
    }
    if inputs.dailySummaryEnabled || inputs.dailySummaryHealth != .notChecked {
      let level: ReliabilityHealthLevel = inputs.dailySummaryHealth == .failed ? .warning
        : (inputs.dailySummaryHealth == .notChecked && inputs.dailySummaryDue ? .unknown : .healthy)
      let detail: String = switch inputs.dailySummaryHealth {
      case .failed: "最近一次摘要归档未完成，请检查提示并重试。"
      case .verified: "今日摘要已读取并通过内容检查。"
      case .notChecked: inputs.dailySummaryDue ? "尚未检查今日摘要；自动归档会等待额度和用量读取完成。" : "将在设定时间检查归档，也可手动提前生成。"
      }
      checks.append(.init(id: .dailySummary, title: "每日聚合摘要", level: level, detail: detail, checkedAt: now))
    }
    if let state = inputs.quotaState {
      let level: ReliabilityHealthLevel = switch state {
      case .fresh: .healthy
      case .cached, .waitingForReset: .warning
      case .expired: .critical
      case .unavailable: .unknown
      }
      checks[0] = ReliabilityCheck(id: .officialQuota, title: "官方额度读取", level: level,
        detail: state.label, checkedAt: now)
    }
    for (id, message) in [(ReliabilityCheckID.quotaHistory, inputs.quotaHistoryStorageMessage)] {
      if let message, let index = checks.firstIndex(where: { $0.id == id }) {
        if checks[index].level.rank < ReliabilityHealthLevel.warning.rank { checks[index].level = .warning }
        checks[index].detail = message
      }
    }
    return ReliabilitySnapshot(generatedAt: now, checks: checks)
  }

  private static func localBackupCheck(inputs: Inputs, now: Date) -> ReliabilityCheck {
    let level: ReliabilityHealthLevel
    let detail: String
    switch inputs.localBackupHealth {
    case .failed:
      level = .warning
      detail = "最近一次备份未完成；请检查失败提示并重试。"
    case .verified:
      level = .healthy
      detail = "最近一次备份检查已验证归档文件和清单。"
    case .noData:
      level = .healthy
      detail = "当前没有可备份的关键数据文件。"
    case .notChecked:
      level = inputs.automaticBackupsEnabled ? .unknown : .healthy
      detail = inputs.automaticBackupsEnabled ? "本次启动尚未检查备份，可点击立即自检或立即备份。" : "每日自动备份已关闭，可随时手动备份。"
    }
    return .init(id: .localBackup, title: "本地备份任务", level: level, detail: detail, checkedAt: now)
  }

  public static func eventHistoryCheck(issue: ReliabilityEventStorageIssue?, writeFailed: Bool, now: Date) -> ReliabilityCheck {
    let detail = issue?.localizedDescription ?? (writeFailed
      ? ReliabilityEventStorageIssue.writeFailed.localizedDescription
      : "事件记录可正常读取；尚无事件时保持空记录。")
    return .init(id: .reliabilityEvents, title: "运行事件记录",
      level: issue != nil || writeFailed ? .warning : .healthy, detail: detail, checkedAt: now)
  }

  private static func projectBudgetCheck(inputs: Inputs, now: Date, fileManager: FileManager) -> ReliabilityCheck {
    let state = ProjectBudgetStore(url: inputs.projectBudgetsURL, fileManager: fileManager).loadResult()
    let level: ReliabilityHealthLevel
    let detail: String
    if let issue = state.issue {
      level = .critical
      detail = issue.localizedDescription
    } else if state.backupIssue != nil {
      level = .warning
      detail = "当前预算可读，但上次有效备份已损坏；下次成功保存时将重新生成备份。"
    } else if inputs.projectBudgetStorageMessage != nil {
      level = .warning
      detail = "文件现已可读，请在项目预算中重新读取后继续。"
    } else if inputs.projectBudgetWriteFailed {
      level = .warning
      detail = "最近一次写入未完成；已有文件可读，请保留未保存输入并重试。"
    } else {
      level = .healthy
      detail = state.budgets.isEmpty ? "尚未设置项目预算" : "\(state.budgets.count) 个项目预算可读且格式有效。"
    }
    return .init(id: .projectBudgets, title: "项目预算文件", level: level, detail: detail, checkedAt: now)
  }

  private static func creditExpiryCheck(inputs: Inputs, now: Date) -> ReliabilityCheck {
    // loadResult is read-only: health checks never migrate, restore or rewrite records.
    let state = inputs.creditExpiryStore.loadResult()
    let level: ReliabilityHealthLevel
    let detail: String
    if let issue = state.issue {
      level = .critical
      detail = issue.localizedDescription
    } else if state.backupIssue != nil {
      level = .warning
      detail = "当前记录可读，但上次有效备份已损坏；下次成功保存时将重新生成备份。"
    } else if inputs.creditExpiryStorageIssue != nil {
      level = .warning
      detail = "文件现已可读，请在到期记录中重新读取后继续。"
    } else if inputs.creditExpiryWriteFailed {
      level = .warning
      detail = "最近一次写入未完成；已有文件可读，请保留未保存输入并重试。"
    } else {
      level = .healthy
      detail = state.ledger.batches.isEmpty ? "尚未设置到期记录"
        : "\(state.ledger.batches.count) 笔记录可读且格式有效；到期日来源需自行核实。"
    }
    return ReliabilityCheck(id: .creditExpiry, title: "到期记录文件", level: level, detail: detail, checkedAt: now)
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
    do {
      guard let data = try LocalRecordFile.read(at: url) else {
        return ReliabilityCheck(id: id, title: title, level: missingLevel, detail: missingDetail, checkedAt: now)
      }
      if id == .quotaHistory { try QuotaHistoryStore.validateContents(data) }
      return ReliabilityCheck(id: id, title: title, level: .healthy, detail: "文件可读且记录格式有效", checkedAt: now)
    } catch {
      let detail = error is ProjectBudgetStorageIssue || error is QuotaHistoryStorageIssue
        ? error.localizedDescription : "文件无法读取或不是可支持的普通文件，原文件未改动。"
      return ReliabilityCheck(id: id, title: title, level: .critical, detail: detail, checkedAt: now)
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

public enum ReliabilityEventStorageIssue: Error, LocalizedError, Equatable, Sendable {
  case unreadableRecord
  case invalidRecord
  case unsupportedVersion(Int)
  case changedOnDisk
  case preservationFailed
  case writeFailed
  case recordTooLarge
  case notCorrupt

  public var errorDescription: String? {
    switch self {
    case .unreadableRecord: "无法安全读取运行事件记录，已停止写入。请检查是否为可访问且不超过 8 MB 的普通文件，原文件未改动。"
    case .invalidRecord: "运行事件记录内容损坏，已停止写入并保留原件。可保留原件后重建记录。"
    case let .unsupportedVersion(version): "运行事件记录来自暂不支持的版本（\(version)），已停止写入，原文件未改动。请使用支持该版本的 App。"
    case .changedOnDisk: "运行事件记录在操作期间发生变化，已停止写入。请重新读取后重试。"
    case .preservationFailed: "未能验证保存运行事件记录原件，已停止重建，原文件未改动。"
    case .writeFailed: "最近一次运行事件未能写入，请检查文件访问权限后重试。"
    case .recordTooLarge: "运行事件内容过大，已停止写入，已有记录未改动。"
    case .notCorrupt: "当前运行事件记录无需重建，请重新读取。"
    }
  }
}

public struct ReliabilityEventReadResult: Sendable {
  public var events: [ReliabilityEvent] = []
  public var issue: ReliabilityEventStorageIssue?
}

public final class ReliabilityEventStore: @unchecked Sendable {
  public static let defaultURL = PulsePaths.support.appendingPathComponent("reliability-events-v1.json")
  public var storageURL: URL { url }

  private struct Header: Decodable { var schemaVersion: Int }
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

  public func load() -> [ReliabilityEvent] { loadResult().events }

  /// Reading never moves, replaces, or repairs a record.
  public func loadResult() -> ReliabilityEventReadResult {
    lock.withLock {
      do {
        guard let data = try read() else { return .init() }
        return .init(events: try Self.decode(data))
      } catch let issue as ReliabilityEventStorageIssue { return .init(issue: issue) }
      catch { return .init(issue: .unreadableRecord) }
    }
  }

  @discardableResult
  public func append(_ event: ReliabilityEvent) throws -> [ReliabilityEvent] {
    try lock.withLock {
      let original = try read()
      var rows = try original.map(Self.decode) ?? []
      rows.append(event)
      try Self.validate(rows)
      rows = Self.retained(rows)
      let data = try Self.encode(rows)
      try prepareDirectory()
      try requireUnchanged(original)
      try write(data)
      return rows
    }
  }

  /// Only an explicit rebuild of a malformed v1 record may replace it, after preserving a verified copy.
  @discardableResult
  public func rebuildAfterPreservingCorruption() throws -> URL {
    try lock.withLock {
      guard let original = try read() else { throw ReliabilityEventStorageIssue.notCorrupt }
      do {
        _ = try Self.decode(original)
        throw ReliabilityEventStorageIssue.notCorrupt
      } catch ReliabilityEventStorageIssue.invalidRecord {
        // Unknown versions and unsafe paths are never eligible for rebuilding.
      }
      let data = try Self.encode([])
      try prepareDirectory()
      try requireUnchanged(original)
      let preserved = url.deletingPathExtension().appendingPathExtension("corrupt-\(UUID().uuidString).json")
      do {
        try fileManager.copyItem(at: url, to: preserved)
        guard try LocalRecordFile.read(at: preserved) == original else {
          throw ReliabilityEventStorageIssue.preservationFailed
        }
      } catch { throw ReliabilityEventStorageIssue.preservationFailed }
      try requireUnchanged(original)
      try write(data)
      return preserved
    }
  }

  private func read() throws -> Data? {
    do {
      try LocalRecordFile.requireDirectoryIfPresent(at: url.deletingLastPathComponent())
      return try LocalRecordFile.read(at: url)
    } catch { throw ReliabilityEventStorageIssue.unreadableRecord }
  }

  private func prepareDirectory() throws {
    do {
      try LocalRecordFile.requireDirectoryIfPresent(at: url.deletingLastPathComponent())
      try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try LocalRecordFile.requireDirectoryIfPresent(at: url.deletingLastPathComponent())
    } catch { throw ReliabilityEventStorageIssue.writeFailed }
  }

  private func requireUnchanged(_ expected: Data?) throws {
    guard try read() == expected else { throw ReliabilityEventStorageIssue.changedOnDisk }
  }

  private func write(_ data: Data) throws {
    do {
      try data.write(to: url, options: .atomic)
      guard try read() == data else { throw ReliabilityEventStorageIssue.writeFailed }
    } catch { throw ReliabilityEventStorageIssue.writeFailed }
  }

  private static func decode(_ data: Data) throws -> [ReliabilityEvent] {
    let header: Header
    do { header = try JSONDecoder.reliability.decode(Header.self, from: data) }
    catch { throw ReliabilityEventStorageIssue.invalidRecord }
    guard header.schemaVersion == 1 else { throw ReliabilityEventStorageIssue.unsupportedVersion(header.schemaVersion) }
    do {
      let rows = try JSONDecoder.reliability.decode(Payload.self, from: data).events
      try validate(rows)
      return retained(rows)
    } catch { throw ReliabilityEventStorageIssue.invalidRecord }
  }

  private static func validate(_ rows: [ReliabilityEvent]) throws {
    guard Set(rows.map(\.id)).count == rows.count,
      rows.allSatisfy({ $0.timestamp.timeIntervalSince1970.isFinite }) else {
      throw ReliabilityEventStorageIssue.invalidRecord
    }
  }

  private static func retained(_ rows: [ReliabilityEvent]) -> [ReliabilityEvent] {
    Array(rows.sorted {
      $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp < $1.timestamp
    }.suffix(500))
  }

  private static func encode(_ rows: [ReliabilityEvent]) throws -> Data {
    let data: Data
    do { data = try JSONEncoder.reliability.encode(Payload(schemaVersion: 1, events: rows)) }
    catch { throw ReliabilityEventStorageIssue.invalidRecord }
    guard data.count <= LocalRecordFile.maximumSize else { throw ReliabilityEventStorageIssue.recordTooLarge }
    return data
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

public enum LocalBackupError: Error, LocalizedError, Equatable, Sendable {
  case unreadableSource
  case unsafeArchive
  case invalidManifest
  case unsupportedManifest(Int)
  case changedOnDisk

  public var errorDescription: String? {
    switch self {
    case .unreadableSource: "有关键数据文件无法安全读取。请检查文件是否为可访问的普通文件且不超过 8 MB；已有备份未改动。"
    case .unsafeArchive: "备份目录或文件无法安全访问。请检查归档目录，链接和特殊文件不能用作备份。"
    case .invalidManifest: "备份清单损坏或内容无效，本次备份已停止，已有备份保留。"
    case let .unsupportedManifest(version): "备份清单来自暂不支持的版本（\(version)），已停止写入。请使用支持该版本的 App。"
    case .changedOnDisk: "归档文件在备份期间发生变化，已停止写入。请检查归档目录后重试。"
    }
  }
}

public enum DailySummaryArchiveError: Error, LocalizedError, Equatable, Sendable {
  case unsafeArchive
  case invalidSummary
  case preservationFailed
  case changedOnDisk
  case writeFailed

  public var errorDescription: String? {
    switch self {
    case .unsafeArchive: "摘要目录或文件无法安全访问。链接、特殊文件及超过 512 KB 的文件不能用作摘要归档。"
    case .invalidSummary: "摘要内容不完整或过大，已停止归档，已有文件未改动。"
    case .preservationFailed: "未能验证保存原摘要副本，已停止重建，原文件未改动。"
    case .changedOnDisk: "摘要文件在操作期间发生变化，已停止写入。请检查归档目录后重试。"
    case .writeFailed: "摘要未能写入或验证，请检查目录访问权限后重试。"
    }
  }
}

public struct DailySummaryArchiveResult: Sendable {
  public let outputURL: URL
  public let alreadyPresent: Bool
  public let preservedOriginalURL: URL?
}

public final class LocalAutomationArchive: @unchecked Sendable {
  public static let defaultRoot = PulsePaths.support.appendingPathComponent("automation", isDirectory: true)

  private struct BackupManifest: Codable {
    var schemaVersion = 1
    var files: [String: String] = [:]
  }

  private static let manifestName = "backup-manifest-v1.json"
  static let maximumDailySummarySize = 512 * 1024
  private let root: URL
  private let fileManager: FileManager
  private let calendar: Calendar
  private let lock = NSLock()

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
    lock.lock()
    defer { lock.unlock() }
    let day = dayKey(now)
    let destination = root.appendingPathComponent("backups/\(day)", isDirectory: true)
    // Read every available source before changing the archive. An unavailable input
    // must leave the day eligible for another attempt, including on first launch.
    var sources: [String: Data] = [:]
    for source in sourceURLs {
      let data: Data?
      do { data = try LocalRecordFile.read(at: source) }
      catch { throw LocalBackupError.unreadableSource }
      guard let data else { continue }
      guard sources[source.lastPathComponent] == nil,
        source.lastPathComponent != Self.manifestName else {
        throw CocoaError(.fileWriteFileExists)
      }
      sources[source.lastPathComponent] = data
    }
    guard !sources.isEmpty else { return LocalAutomationResult(outputURL: destination, itemCount: 0) }

    try validateDirectories(destination)
    let manifestURL = destination.appendingPathComponent(Self.manifestName)
    let previousManifest = try readArchiveFile(manifestURL, limit: 512 * 1024)
    var manifest = try decodeManifest(previousManifest) ?? BackupManifest()
    var priorTargets: [String: Data] = [:]
    for name in sources.keys {
      if let data = try readArchiveFile(destination.appendingPathComponent(name)) { priorTargets[name] = data }
    }
    for (name, data) in sources { manifest.files[name] = Self.backupDigest(data) }
    let manifestData = try JSONEncoder.reliability.encode(manifest)
    guard manifestData.count <= 512 * 1024 else { throw LocalBackupError.invalidManifest }
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    try validateDirectories(destination)
    guard try readArchiveFile(manifestURL, limit: 512 * 1024) == previousManifest else { throw LocalBackupError.changedOnDisk }
    for name in sources.keys {
      guard try readArchiveFile(destination.appendingPathComponent(name)) == priorTargets[name] else {
        throw LocalBackupError.changedOnDisk
      }
    }
    for (name, data) in sources {
      let target = destination.appendingPathComponent(name)
      try validateDirectories(destination)
      guard try readArchiveFile(target) == priorTargets[name] else { throw LocalBackupError.changedOnDisk }
      try data.write(to: target, options: .atomic)
      let digest = Self.backupDigest(data)
      guard let saved = try readArchiveFile(target), Self.backupDigest(saved) == digest else {
        throw CocoaError(.fileWriteUnknown)
      }
    }
    // Only a fully verified write gets a receipt. Existing receipts for other
    // accounts in the same day are retained so switching back does not lose them.
    try validateDirectories(destination)
    guard try readArchiveFile(manifestURL, limit: 512 * 1024) == previousManifest else { throw LocalBackupError.changedOnDisk }
    try manifestData.write(to: manifestURL, options: .atomic)
    guard try readArchiveFile(manifestURL, limit: 512 * 1024) == manifestData else { throw CocoaError(.fileWriteUnknown) }
    try pruneBackups(now: now, retentionDays: retentionDays)
    return LocalAutomationResult(outputURL: destination, itemCount: sources.count)
  }

  public func archiveDailySummary(_ markdown: String, now: Date = Date()) throws -> DailySummaryArchiveResult {
    lock.lock()
    defer { lock.unlock() }
    let data = Data(markdown.utf8)
    guard Self.isValidDailySummary(data) else { throw DailySummaryArchiveError.invalidSummary }
    let directory = root.appendingPathComponent("daily-reports", isDirectory: true)
    let target = directory.appendingPathComponent("codex-daily-summary-\(dayKey(now)).md")
    try validateSummaryDirectory(directory)
    let original = try readSummaryFile(target)
    if let original, Self.isValidDailySummary(original) {
      return .init(outputURL: target, alreadyPresent: true, preservedOriginalURL: nil)
    }
    do { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
    catch { throw DailySummaryArchiveError.writeFailed }
    try validateSummaryDirectory(directory)
    guard try readSummaryFile(target) == original else { throw DailySummaryArchiveError.changedOnDisk }
    var preserved: URL?
    if let original {
      let copy = target.deletingPathExtension().appendingPathExtension("incomplete-\(UUID().uuidString).md")
      do {
        try fileManager.copyItem(at: target, to: copy)
        guard try readSummaryFile(copy) == original else { throw DailySummaryArchiveError.preservationFailed }
      } catch { throw DailySummaryArchiveError.preservationFailed }
      preserved = copy
    }
    try validateSummaryDirectory(directory)
    guard try readSummaryFile(target) == original else { throw DailySummaryArchiveError.changedOnDisk }
    do { try data.write(to: target, options: .atomic) }
    catch { throw DailySummaryArchiveError.writeFailed }
    try validateSummaryDirectory(directory)
    guard try readSummaryFile(target) == data else { throw DailySummaryArchiveError.writeFailed }
    return .init(outputURL: target, alreadyPresent: false, preservedOriginalURL: preserved)
  }

  private func validateSummaryDirectory(_ directory: URL) throws {
    do {
      for url in [root, directory] { try LocalRecordFile.requireDirectoryIfPresent(at: url) }
    } catch { throw DailySummaryArchiveError.unsafeArchive }
  }

  private func readSummaryFile(_ url: URL) throws -> Data? {
    do { return try LocalRecordFile.read(at: url, limit: Self.maximumDailySummarySize) }
    catch { throw DailySummaryArchiveError.unsafeArchive }
  }

  private static func isValidDailySummary(_ data: Data) -> Bool {
    guard !data.isEmpty, data.count <= maximumDailySummarySize, let text = String(data: data, encoding: .utf8) else { return false }
    let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard lines.first == "# Codex 脉动每日摘要",
      lines.contains("> 只包含本机聚合指标，不包含对话正文或项目路径。") else { return false }
    let fields = ["- 日期：", "- 7 天剩余额度：", "- 额度风险：", "- 滚动 24h Token：", "- 本月 Token：", "- 月末预计 Token：", "- 可靠性状态："]
    return fields.allSatisfy { field in
      let matches = lines.filter { $0.hasPrefix(field) }
      return matches.count == 1 && matches[0].dropFirst(field.count).trimmingCharacters(in: .whitespaces).isEmpty == false
    }
  }

  public func hasBackup(for date: Date, sourceURLs: [URL]? = nil) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let destination = root.appendingPathComponent("backups/\(dayKey(date))", isDirectory: true)
    do { try validateDirectories(destination) } catch { return false }
    guard let raw = try? readArchiveFile(destination.appendingPathComponent(Self.manifestName), limit: 512 * 1024),
      let manifest = try? decodeManifest(raw), !manifest.files.isEmpty else { return false }
    let requiredNames: Set<String>
    if let sourceURLs {
      var names = Set<String>()
      do {
        for source in sourceURLs where try LocalRecordFile.read(at: source) != nil { names.insert(source.lastPathComponent) }
      } catch { return false }
      requiredNames = names
    } else {
      requiredNames = Set(manifest.files.keys)
    }
    guard !requiredNames.isEmpty else { return false }
    return requiredNames.allSatisfy { name in
      guard name == URL(fileURLWithPath: name).lastPathComponent,
        let expected = manifest.files[name],
        let data = try? readArchiveFile(destination.appendingPathComponent(name)) else { return false }
      return Self.backupDigest(data) == expected
    }
  }

  private func validateDirectories(_ destination: URL) throws {
    do {
      for url in [root, root.appendingPathComponent("backups"), destination] {
        try LocalRecordFile.requireDirectoryIfPresent(at: url)
      }
    } catch { throw LocalBackupError.unsafeArchive }
  }

  private func readArchiveFile(_ url: URL, limit: Int = LocalRecordFile.maximumSize) throws -> Data? {
    do { return try LocalRecordFile.read(at: url, limit: limit) }
    catch { throw LocalBackupError.unsafeArchive }
  }

  private func decodeManifest(_ data: Data?) throws -> BackupManifest? {
    guard let data else { return nil }
    struct Header: Decodable { let schemaVersion: Int }
    guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw LocalBackupError.invalidManifest }
    guard header.schemaVersion == 1 else { throw LocalBackupError.unsupportedManifest(header.schemaVersion) }
    guard let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data),
      manifest.files.allSatisfy({ name, digest in
        !name.isEmpty && name != "." && name != ".." && name != Self.manifestName
          && !name.contains("\0") && name == URL(fileURLWithPath: name).lastPathComponent
          && digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
      }) else { throw LocalBackupError.invalidManifest }
    return manifest
  }

  private static func backupDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public func hasDailySummary(for date: Date) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let directory = root.appendingPathComponent("daily-reports", isDirectory: true)
    do { try validateSummaryDirectory(directory) } catch { return false }
    guard let data = try? readSummaryFile(directory.appendingPathComponent("codex-daily-summary-\(dayKey(date)).md")) else { return false }
    return Self.isValidDailySummary(data)
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
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private func dayDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
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
