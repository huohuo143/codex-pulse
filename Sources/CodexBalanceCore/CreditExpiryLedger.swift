import Foundation

public enum CreditExpiryBasis: String, Codable, CaseIterable, Sendable {
  case explicitDate, oneYearFromNotice, manual, legacy

  public var title: String {
    switch self {
    case .explicitDate: "来源明确写出到期日"
    case .oneYearFromNotice: "按通知日期推算一年"
    case .manual: "手动记录"
    case .legacy: "历史记录，待核实"
    }
  }

  public var isEstimated: Bool { self == .oneYearFromNotice }
}

/// A grant's face value and date-only expiry evidence. This never represents its remaining balance.
public struct CreditExpiryBatch: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var grantedCredits: Double?
  public var grantedAmountUSD: Double?
  public var noticeAt: Date?
  public var expiryDate: String
  public var basis: CreditExpiryBasis
  public var note: String
  public var record: CreditExpiryRecord

  public init(id: String = UUID().uuidString, title: String, grantedCredits: Double? = nil,
    grantedAmountUSD: Double? = nil, noticeAt: Date? = nil, expiryDate: String,
    basis: CreditExpiryBasis = .explicitDate, note: String = "", record: CreditExpiryRecord) {
    self.id = id; self.title = title; self.grantedCredits = grantedCredits
    self.grantedAmountUSD = grantedAmountUSD; self.noticeAt = noticeAt
    self.expiryDate = expiryDate; self.basis = basis; self.note = note; self.record = record
  }

  public var expiryLabel: String {
    basis.isEstimated ? "预计 \(expiryDate) 到期（推算）" : "\(expiryDate) 到期"
  }

  public var grantLabel: String {
    let number = NumberFormatter()
    number.locale = Locale(identifier: "en_US")
    number.numberStyle = .decimal
    number.maximumFractionDigits = 2
    var pieces: [String] = []
    if let usd = grantedAmountUSD { pieces.append(String(format: "US$%.0f", usd)) }
    if let credits = grantedCredits {
      pieces.append("\(number.string(from: NSNumber(value: credits)) ?? "--") credits")
    }
    return pieces.isEmpty ? "未记录发放数量" : "原发放 " + pieces.joined(separator: " · ")
  }

  // A mail can specify only a civil date. Keep it independent of the viewing device's time zone.
  public static func dateString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  public static func localDate(_ string: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: string), dateString(date) == string else { return nil }
    return date
  }
}

public struct CreditExpiryLedger: Codable, Equatable, Sendable {
  public var schemaVersion = 2
  public var batches: [CreditExpiryBatch]

  public init(batches: [CreditExpiryBatch] = []) { self.batches = batches }

  public func confirmedBatches(for account: String?) -> [CreditExpiryBatch] {
    batches.filter { $0.record.isConfirmed(for: account) && CreditExpiryBatch.localDate($0.expiryDate) != nil }
      .sorted { $0.expiryDate == $1.expiryDate ? $0.id < $1.id : $0.expiryDate < $1.expiryDate }
  }

  public func label(account: String?) -> String {
    let confirmed = confirmedBatches(for: account)
    guard !confirmed.isEmpty else { return "暂无已确认到期日" }
    return "\(confirmed.count) 笔到期记录" + (confirmed.contains { $0.basis.isEstimated } ? " · 含推算日期" : " · 已核对来源")
  }

  public mutating func upsert(_ batch: CreditExpiryBatch) {
    if let index = batches.firstIndex(where: { $0.id == batch.id }) { batches[index] = batch }
    else { batches.append(batch) }
  }

  /// Widget refresh boundary only; no inferred date is exported as a confirmed official deadline.
  public func nextExplicitExpiry(for account: String?, now: Date = Date()) -> Date? {
    confirmedBatches(for: account).filter { $0.basis == .explicitDate }
      .compactMap { CreditExpiryBatch.localDate($0.expiryDate) }.filter { $0 > now }.min()
  }
}

public enum CreditExpiryStorageError: Error, LocalizedError, Equatable, Sendable {
  case unreadableRecord
  case invalidRecord
  case invalidLegacyRecord
  case unsupportedVersion(Int)
  case unsupportedBackupVersion(Int)
  case missingRecord
  case noValidBackup
  case alreadyValid
  case unreadableBackup
  case changedOnDisk
  case recordTooLarge

  public var errorDescription: String? {
    switch self {
    case .unreadableRecord: "无法读取到期记录，已停止保存。请检查文件是否可访问，原文件未改动。"
    case .invalidRecord: "到期记录内容不完整或格式无效，已停止保存，原文件未改动。"
    case .invalidLegacyRecord: "历史到期记录无法读取，已停止保存，原文件未改动。"
    case let .unsupportedVersion(version): "到期记录使用暂不支持的版本（\(version)），请使用支持该版本的 App。原文件未改动。"
    case let .unsupportedBackupVersion(version): "到期记录备份使用暂不支持的版本（\(version)），已停止保存以保护备份。请使用支持该版本的 App。"
    case .missingRecord: "当前到期记录文件缺失，可恢复上次有效记录。"
    case .noValidBackup: "没有可恢复的有效记录备份，原文件未改动。"
    case .alreadyValid: "当前文件已是有效记录，请重新读取后继续。"
    case .unreadableBackup: "无法安全读取到期记录备份，已停止保存。请检查备份文件是否可访问，现有记录未改动。"
    case .changedOnDisk: "到期记录在操作期间发生变化，已停止写入。请重新读取后继续。"
    case .recordTooLarge: "到期记录超过 8 MB，未保存。请缩短过长的来源或说明后重试，原文件未改动。"
    }
  }
}

public struct CreditExpiryRecovery: Equatable, Sendable {
  public let batchCount: Int
  public let backedUpAt: Date?
}

public struct CreditExpiryReadResult: Sendable {
  public var ledger = CreditExpiryLedger()
  public var issue: CreditExpiryStorageError?
  public var recovery: CreditExpiryRecovery?
  public var backupIssue: CreditExpiryStorageError?
}

public struct CreditExpiryRecoveryResult: Sendable {
  public let ledger: CreditExpiryLedger
  public let preservedOriginalURL: URL?
}

public struct CreditExpiryLedgerStore: Sendable {
  public var url: URL
  public var legacyURL: URL
  private var prepareDirectory: @Sendable (URL) throws -> Void = {
    try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
  }
  public var previousURL: URL { url.deletingPathExtension().appendingPathExtension("previous.json") }

  public init(url: URL = PulsePaths.support.appendingPathComponent("credit-expiry-v2.json"),
    legacyURL: URL = PulsePaths.support.appendingPathComponent("credit-expiry-v1.json")) {
    self.url = url; self.legacyURL = legacyURL
  }

  init(url: URL, legacyURL: URL, prepareDirectory: @escaping @Sendable (URL) throws -> Void) {
    self.init(url: url, legacyURL: legacyURL)
    self.prepareDirectory = prepareDirectory
  }

  public func load() -> CreditExpiryLedger { loadResult().ledger }

  public func loadResult() -> CreditExpiryReadResult {
    do {
      let current = try readCurrent()
      let backup: Data?
      do { backup = try read(previousURL, issue: .unreadableBackup) }
      catch { return .init(ledger: current.ledger, issue: .unreadableBackup) }
      let issue = backupIssue(backup)
      if case let .unsupportedVersion(version) = issue {
        return .init(ledger: current.ledger, issue: .unsupportedBackupVersion(version))
      }
      return .init(ledger: current.ledger, backupIssue: issue)
    } catch let issue as CreditExpiryStorageError {
      return .init(issue: issue, recovery: [.invalidRecord, .missingRecord].contains(issue) ? recoverySummary() : nil)
    } catch { return .init(issue: .unreadableRecord) }
  }

  public func save(_ ledger: CreditExpiryLedger) throws {
    try Self.validate(ledger)
    // Never replace a corrupt or newer-format document with an empty fallback.
    // Recheck at write time as the file may have changed after the UI loaded it.
    let current = try readCurrent()
    let oldBackup = try read(previousURL, issue: .unreadableBackup)
    if case let .unsupportedVersion(version) = backupIssue(oldBackup) {
      throw CreditExpiryStorageError.unsupportedBackupVersion(version)
    }
    if current.data == nil, oldBackup != nil { throw CreditExpiryStorageError.changedOnDisk }
    let data = try JSONEncoder().encode(ledger)
    // Never write a document that the bounded reader would reject on restart.
    guard data.count <= LocalRecordFile.maximumSize else { throw CreditExpiryStorageError.recordTooLarge }
    let previous = current.data ?? data
    try prepareDirectory(url.deletingLastPathComponent())
    try requireUnchanged(current)
    try requireUnchanged(previousURL, expected: oldBackup, issue: .unreadableBackup)
    // A failed backup must leave the current document untouched.
    try previous.write(to: previousURL, options: .atomic)
    guard try read(previousURL, issue: .unreadableBackup) == previous else { throw CocoaError(.fileWriteUnknown) }
    try requireUnchanged(current)
    try data.write(to: url, options: .atomic)
  }

  public func restorePrevious() throws -> CreditExpiryRecoveryResult {
    let original = try read(url)
    if let data = original {
      do {
        _ = try Self.decode(data)
        throw CreditExpiryStorageError.alreadyValid
      } catch CreditExpiryStorageError.invalidRecord {
        // Keep these original bytes until a separate copy has been verified.
      }
      // Unsupported versions and valid documents must never be downgraded.
    }
    guard let backup = try? LocalRecordFile.read(at: previousURL),
      let ledger = try? Self.decode(backup) else { throw CreditExpiryStorageError.noValidBackup }
    try prepareDirectory(url.deletingLastPathComponent())
    try requireUnchanged(url, expected: original)
    try requireUnchanged(previousURL, expected: backup, issue: .noValidBackup)
    var preserved: URL?
    if let original {
      let destination = url.deletingPathExtension().appendingPathExtension("damaged-\(UUID().uuidString).json")
      try original.write(to: destination, options: .withoutOverwriting)
      guard try read(destination) == original else { throw CocoaError(.fileWriteUnknown) }
      preserved = destination
    }
    try requireUnchanged(url, expected: original)
    try requireUnchanged(previousURL, expected: backup, issue: .noValidBackup)
    try backup.write(to: url, options: .atomic)
    return CreditExpiryRecoveryResult(ledger: ledger, preservedOriginalURL: preserved)
  }

  private func recoverySummary() -> CreditExpiryRecovery? {
    guard let data = try? LocalRecordFile.read(at: previousURL), let ledger = try? Self.decode(data) else { return nil }
    let modified = try? previousURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    return CreditExpiryRecovery(batchCount: ledger.batches.count, backedUpAt: modified)
  }

  private func backupIssue(_ data: Data?) -> CreditExpiryStorageError? {
    guard let data else { return nil }
    do { _ = try Self.decode(data); return nil }
    catch let issue as CreditExpiryStorageError { return issue }
    catch { return .invalidRecord }
  }

  private struct CurrentRecord {
    var data: Data?
    var legacy: Data?
    var ledger: CreditExpiryLedger
  }

  private func readCurrent() throws -> CurrentRecord {
    if let data = try read(url) { return .init(data: data, ledger: try Self.decode(data)) }
    // Links (including dangling links), pipes and oversized files are not absent files.
    // Preserve the sole remaining backup even when it cannot be decoded.
    if let backup = try read(previousURL, issue: .noValidBackup) {
      guard (try? Self.decode(backup)) != nil else { throw CreditExpiryStorageError.noValidBackup }
      throw CreditExpiryStorageError.missingRecord
    }
    guard let data = try read(legacyURL, issue: .invalidLegacyRecord) else {
      return .init(ledger: CreditExpiryLedger())
    }
    guard let record = try? JSONDecoder().decode(CreditExpiryRecord.self, from: data),
      record.expiresAt.timeIntervalSinceReferenceDate.isFinite else {
      throw CreditExpiryStorageError.invalidLegacyRecord
    }
    let batch = CreditExpiryBatch(id: "legacy-single-date-v1", title: "历史到期记录",
      expiryDate: CreditExpiryBatch.dateString(record.expiresAt), basis: .legacy,
      note: "旧版本的单笔记录；保留原有核实状态。", record: record)
    return .init(legacy: data, ledger: CreditExpiryLedger(batches: [batch]))
  }

  private func read(_ location: URL, issue: CreditExpiryStorageError = .unreadableRecord) throws -> Data? {
    do { return try LocalRecordFile.read(at: location) }
    catch { throw issue }
  }

  private func requireUnchanged(_ location: URL, expected: Data?,
    issue: CreditExpiryStorageError = .unreadableRecord) throws {
    guard try read(location, issue: issue) == expected else { throw CreditExpiryStorageError.changedOnDisk }
  }

  private func requireUnchanged(_ current: CurrentRecord) throws {
    try requireUnchanged(url, expected: current.data)
    if current.data == nil {
      try requireUnchanged(legacyURL, expected: current.legacy, issue: .invalidLegacyRecord)
    }
  }

  private static func decode(_ data: Data) throws -> CreditExpiryLedger {
    struct Header: Decodable { let schemaVersion: Int }
    guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
      throw CreditExpiryStorageError.invalidRecord
    }
    guard header.schemaVersion == 2 else { throw CreditExpiryStorageError.unsupportedVersion(header.schemaVersion) }
    guard let ledger = try? JSONDecoder().decode(CreditExpiryLedger.self, from: data) else {
      throw CreditExpiryStorageError.invalidRecord
    }
    try validate(ledger)
    return ledger
  }

  private static func validate(_ ledger: CreditExpiryLedger) throws {
    guard ledger.schemaVersion == 2 else { throw CreditExpiryStorageError.unsupportedVersion(ledger.schemaVersion) }
    var ids = Set<String>()
    for batch in ledger.batches {
      guard !batch.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        ids.insert(batch.id).inserted,
        !batch.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        CreditExpiryBatch.localDate(batch.expiryDate) != nil,
        batch.record.expiresAt.timeIntervalSinceReferenceDate.isFinite,
        batch.grantedCredits.map({ $0.isFinite && $0 > 0 }) ?? true,
        batch.grantedAmountUSD.map({ $0.isFinite && $0 >= 0 }) ?? true else {
        throw CreditExpiryStorageError.invalidRecord
      }
    }
  }
}
