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
  case missingRecord
  case noValidBackup
  case alreadyValid

  public var errorDescription: String? {
    switch self {
    case .unreadableRecord: "无法读取到期记录，已停止保存。请检查文件是否可访问，原文件未改动。"
    case .invalidRecord: "到期记录内容不完整或格式无效，已停止保存，原文件未改动。"
    case .invalidLegacyRecord: "历史到期记录无法读取，已停止保存，原文件未改动。"
    case let .unsupportedVersion(version): "到期记录使用暂不支持的版本（\(version)），请使用支持该版本的 App。原文件未改动。"
    case .missingRecord: "当前到期记录文件缺失，可恢复上次有效记录。"
    case .noValidBackup: "没有可恢复的有效记录备份，原文件未改动。"
    case .alreadyValid: "当前文件已是有效记录，请重新读取后继续。"
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
}

public struct CreditExpiryRecoveryResult: Sendable {
  public let ledger: CreditExpiryLedger
  public let preservedOriginalURL: URL?
}

public struct CreditExpiryLedgerStore: Sendable {
  public var url: URL
  public var legacyURL: URL
  public var previousURL: URL { url.deletingPathExtension().appendingPathExtension("previous.json") }

  public init(url: URL = PulsePaths.support.appendingPathComponent("credit-expiry-v2.json"),
    legacyURL: URL = PulsePaths.support.appendingPathComponent("credit-expiry-v1.json")) {
    self.url = url; self.legacyURL = legacyURL
  }

  public func load() -> CreditExpiryLedger { loadResult().ledger }

  public func loadResult() -> CreditExpiryReadResult {
    if FileManager.default.fileExists(atPath: url.path) {
      guard let data = try? Data(contentsOf: url) else {
        return .init(issue: .unreadableRecord)
      }
      do { return .init(ledger: try Self.decode(data)) }
      catch let issue as CreditExpiryStorageError {
        return .init(issue: issue, recovery: issue == .invalidRecord ? recoverySummary() : nil)
      } catch { return .init(issue: .invalidRecord, recovery: recoverySummary()) }
    }
    if FileManager.default.fileExists(atPath: previousURL.path) {
      if let recovery = recoverySummary() { return .init(issue: .missingRecord, recovery: recovery) }
      // A missing primary must not authorize overwriting the only remaining
      // backup, even if this version cannot read it.
      return .init(issue: .noValidBackup)
    }
    guard FileManager.default.fileExists(atPath: legacyURL.path) else { return .init() }
    guard let data = try? Data(contentsOf: legacyURL),
      let record = try? JSONDecoder().decode(CreditExpiryRecord.self, from: data),
      record.expiresAt.timeIntervalSinceReferenceDate.isFinite else {
      return .init(issue: .invalidLegacyRecord)
    }
    let batch = CreditExpiryBatch(id: "legacy-single-date-v1", title: "历史到期记录",
      expiryDate: CreditExpiryBatch.dateString(record.expiresAt), basis: .legacy,
      note: "旧版本的单笔记录；保留原有核实状态。", record: record)
    return .init(ledger: CreditExpiryLedger(batches: [batch]))
  }

  public func save(_ ledger: CreditExpiryLedger) throws {
    try Self.validate(ledger)
    // Never replace a corrupt or newer-format document with an empty fallback.
    // Recheck at write time as the file may have changed after the UI loaded it.
    let state = loadResult()
    if let issue = state.issue { throw issue }
    let data = try JSONEncoder().encode(ledger)
    let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : data
    _ = try Self.decode(previous)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // A failed backup must leave the current document untouched.
    try previous.write(to: previousURL, options: .atomic)
    guard try Data(contentsOf: previousURL) == previous else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url, options: .atomic)
  }

  public func restorePrevious() throws -> CreditExpiryRecoveryResult {
    var original: Data?
    if FileManager.default.fileExists(atPath: url.path) {
      guard let data = try? Data(contentsOf: url) else { throw CreditExpiryStorageError.unreadableRecord }
      do {
        _ = try Self.decode(data)
        throw CreditExpiryStorageError.alreadyValid
      } catch CreditExpiryStorageError.invalidRecord {
        original = data
      }
      // Unsupported versions and valid documents must never be downgraded.
    }
    guard let backup = try? Data(contentsOf: previousURL),
      let ledger = try? Self.decode(backup) else { throw CreditExpiryStorageError.noValidBackup }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var preserved: URL?
    if let original {
      let destination = url.deletingPathExtension().appendingPathExtension("damaged-\(UUID().uuidString).json")
      try original.write(to: destination, options: .withoutOverwriting)
      guard try Data(contentsOf: destination) == original else { throw CocoaError(.fileWriteUnknown) }
      preserved = destination
    }
    try backup.write(to: url, options: .atomic)
    return CreditExpiryRecoveryResult(ledger: ledger, preservedOriginalURL: preserved)
  }

  private func recoverySummary() -> CreditExpiryRecovery? {
    guard let data = try? Data(contentsOf: previousURL), let ledger = try? Self.decode(data) else { return nil }
    let modified = try? previousURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    return CreditExpiryRecovery(batchCount: ledger.batches.count, backedUpAt: modified)
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
