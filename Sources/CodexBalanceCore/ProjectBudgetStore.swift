import Foundation

public enum ProjectBudgetStorageIssue: Error, LocalizedError, Equatable, Sendable {
  case unreadableRecord
  case invalidRecord
  case unsupportedVersion(Int)
  case unsupportedBackupVersion(Int)
  case unreadableBackup
  case missingRecord
  case noValidBackup
  case alreadyValid
  case changedOnDisk
  case recordTooLarge

  public var errorDescription: String? {
    switch self {
    case .unreadableRecord: "无法读取预算文件，已停止保存。请检查文件是否可访问，原文件未改动。"
    case .invalidRecord: "预算内容不完整或格式无效，已停止保存，原文件未改动。"
    case let .unsupportedVersion(version): "预算来自暂不支持的版本（\(version)），已停止保存，原文件未改动。请使用支持该记录版本的 App。"
    case let .unsupportedBackupVersion(version): "预算备份使用暂不支持的版本（\(version)），已停止写入，当前预算和备份均未改动。请使用支持该记录版本的 App。"
    case .unreadableBackup: "无法安全读取预算备份，已停止写入。请检查备份是否可访问，现有文件未改动。"
    case .missingRecord: "预算主文件缺失，已停止保存以保护现有备份。"
    case .noValidBackup: "没有可恢复的有效预算备份，现有文件未改动。"
    case .alreadyValid: "当前预算文件有效，无需恢复。请重新读取后继续。"
    case .changedOnDisk: "预算文件在操作期间发生变化，已停止写入。请重新读取后继续。"
    case .recordTooLarge: "预算内容过大，已停止保存。请缩短项目名称或减少记录后重试，现有文件未改动。"
    }
  }
}

public struct ProjectBudgetRecovery: Equatable, Sendable {
  public let budgetCount: Int
  public let backedUpAt: Date?
}

public struct ProjectBudgetReadResult: Sendable {
  public var budgets: [ProjectBudget] = []
  public var issue: ProjectBudgetStorageIssue?
  public var recovery: ProjectBudgetRecovery?
  public var backupIssue: ProjectBudgetStorageIssue?
}

public struct ProjectBudgetRecoveryResult: Sendable {
  public let budgets: [ProjectBudget]
  public let preservedOriginalURL: URL?
}

public final class ProjectBudgetStore: @unchecked Sendable {
  public static let defaultURL = PulsePaths.support.appendingPathComponent("project-budgets-v1.json")
  public var storageURL: URL { url }
  public var previousURL: URL { url.deletingPathExtension().appendingPathExtension("previous.json") }

  private struct Payload: Codable {
    var schemaVersion: Int
    var budgets: [ProjectBudget]
  }

  private let url: URL
  private let fileManager: FileManager
  private let lock = NSLock()

  public init(url: URL = ProjectBudgetStore.defaultURL, fileManager: FileManager = .default) {
    self.url = url
    self.fileManager = fileManager
  }

  public func load() -> [ProjectBudget] { loadResult().budgets }

  public func loadResult() -> ProjectBudgetReadResult {
    lock.lock()
    defer { lock.unlock() }
    do {
      let current = try readCurrent()
      let backup: Data?
      do { backup = try readBackup() }
      catch { return .init(budgets: current.budgets, issue: .unreadableBackup) }
      let issue = Self.backupIssue(backup)
      return .init(budgets: current.budgets, issue: issue == .invalidRecord ? nil : issue,
        backupIssue: issue == .invalidRecord ? issue : nil)
    }
    catch let issue as ProjectBudgetStorageIssue {
      return .init(issue: issue, recovery: [.invalidRecord, .missingRecord].contains(issue) ? recoverySummary() : nil)
    } catch { return .init(issue: .unreadableRecord) }
  }

  @discardableResult
  public func upsert(_ budget: ProjectBudget) throws -> [ProjectBudget] {
    lock.lock()
    defer { lock.unlock() }
    let current = try readCurrent()
    var rows = current.budgets
    if let index = rows.firstIndex(where: { $0.id == budget.id }) {
      var next = budget
      next.createdAt = rows[index].createdAt
      rows[index] = next
    } else { rows.append(budget) }
    rows.sort { $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending }
    try save(rows, replacing: current.data)
    return rows
  }

  @discardableResult
  public func remove(id: String) throws -> [ProjectBudget] {
    lock.lock()
    defer { lock.unlock() }
    let current = try readCurrent()
    let rows = current.budgets.filter { $0.id != id }
    guard rows != current.budgets else {
      _ = try writableBackup()
      return rows
    }
    try save(rows, replacing: current.data)
    return rows
  }

  public func restorePrevious() throws -> ProjectBudgetRecoveryResult {
    lock.lock()
    defer { lock.unlock() }
    let original = try read(url)
    if let original {
      do {
        _ = try Self.decode(original)
        throw ProjectBudgetStorageIssue.alreadyValid
      } catch ProjectBudgetStorageIssue.invalidRecord {
        // Only corrupt documents or a missing primary may be restored.
        // A valid or future-format primary must never be replaced here.
      }
    }
    guard let backup = try? LocalRecordFile.read(at: previousURL),
      let rows = try? Self.decode(backup) else { throw ProjectBudgetStorageIssue.noValidBackup }
    var preserved: URL?
    if let original {
      let target = url.deletingPathExtension().appendingPathExtension("damaged-\(UUID().uuidString).json")
      try fileManager.copyItem(at: url, to: target)
      guard try read(target) == original else { throw CocoaError(.fileWriteUnknown) }
      preserved = target
    }
    try requireUnchanged(original)
    try requireBackupUnchanged(backup)
    try backup.write(to: url, options: .atomic)
    return .init(budgets: rows, preservedOriginalURL: preserved)
  }

  private func readCurrent() throws -> (data: Data?, budgets: [ProjectBudget]) {
    if let data = try read(url) { return (data, try Self.decode(data)) }
    // A missing primary must not authorize overwriting the sole remaining copy.
    do {
      if try LocalRecordFile.read(at: previousURL) != nil { throw ProjectBudgetStorageIssue.missingRecord }
    } catch ProjectBudgetStorageIssue.missingRecord { throw ProjectBudgetStorageIssue.missingRecord }
    catch { throw ProjectBudgetStorageIssue.noValidBackup }
    return (nil, [])
  }

  private func read(_ location: URL) throws -> Data? {
    do { return try LocalRecordFile.read(at: location) }
    catch { throw ProjectBudgetStorageIssue.unreadableRecord }
  }

  private func requireUnchanged(_ expected: Data?) throws {
    guard try read(url) == expected else { throw ProjectBudgetStorageIssue.changedOnDisk }
  }

  private func readBackup() throws -> Data? {
    do { return try LocalRecordFile.read(at: previousURL) }
    catch { throw ProjectBudgetStorageIssue.unreadableBackup }
  }

  private func writableBackup() throws -> Data? {
    let data = try readBackup()
    if let issue = Self.backupIssue(data), issue != .invalidRecord { throw issue }
    return data
  }

  private func requireBackupUnchanged(_ expected: Data?) throws {
    guard try readBackup() == expected else { throw ProjectBudgetStorageIssue.changedOnDisk }
  }

  private static func backupIssue(_ data: Data?) -> ProjectBudgetStorageIssue? {
    guard let data else { return nil }
    do { _ = try decode(data); return nil }
    catch ProjectBudgetStorageIssue.unsupportedVersion(let version) { return .unsupportedBackupVersion(version) }
    catch { return .invalidRecord }
  }

  private func save(_ rows: [ProjectBudget], replacing original: Data?) throws {
    try Self.validate(rows)
    let oldBackup = try writableBackup()
    guard original != nil || oldBackup == nil else { throw ProjectBudgetStorageIssue.changedOnDisk }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(Payload(schemaVersion: 1, budgets: rows))
    guard data.count <= LocalRecordFile.maximumSize else { throw ProjectBudgetStorageIssue.recordTooLarge }
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try requireUnchanged(original)
    try requireBackupUnchanged(oldBackup)
    let backup = original ?? data
    try backup.write(to: previousURL, options: .atomic)
    guard try read(previousURL) == backup else { throw CocoaError(.fileWriteUnknown) }
    try requireUnchanged(original)
    try data.write(to: url, options: .atomic)
  }

  private func recoverySummary() -> ProjectBudgetRecovery? {
    guard let data = try? LocalRecordFile.read(at: previousURL), let rows = try? Self.decode(data) else { return nil }
    let modified = try? previousURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    return .init(budgetCount: rows.count, backedUpAt: modified)
  }

  private static func decode(_ data: Data) throws -> [ProjectBudget] {
    struct Header: Decodable { let schemaVersion: Int }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let header = try? decoder.decode(Header.self, from: data) else { throw ProjectBudgetStorageIssue.invalidRecord }
    guard header.schemaVersion == 1 else { throw ProjectBudgetStorageIssue.unsupportedVersion(header.schemaVersion) }
    guard let payload = try? decoder.decode(Payload.self, from: data) else { throw ProjectBudgetStorageIssue.invalidRecord }
    try validate(payload.budgets)
    return payload.budgets
  }

  private static func validate(_ rows: [ProjectBudget]) throws {
    var identifiers = Set<String>()
    guard rows.allSatisfy({ row in
      !row.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && identifiers.insert(row.id).inserted
        && !row.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && row.monthlyTokenLimit > 0
        && row.createdAt.timeIntervalSinceReferenceDate.isFinite
        && row.updatedAt.timeIntervalSinceReferenceDate.isFinite
    }) else { throw ProjectBudgetStorageIssue.invalidRecord }
  }
}
