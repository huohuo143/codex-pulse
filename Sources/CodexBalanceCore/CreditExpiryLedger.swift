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

public struct CreditExpiryLedgerStore: Sendable {
  public var url: URL
  public var legacyURL: URL

  public init(url: URL = PulsePaths.support.appendingPathComponent("credit-expiry-v2.json"),
    legacyURL: URL = PulsePaths.support.appendingPathComponent("credit-expiry-v1.json")) {
    self.url = url; self.legacyURL = legacyURL
  }

  public func load() -> CreditExpiryLedger {
    if let data = try? Data(contentsOf: url), let ledger = try? JSONDecoder().decode(CreditExpiryLedger.self, from: data),
      ledger.schemaVersion == 2 { return ledger }
    guard let data = try? Data(contentsOf: legacyURL),
      let record = try? JSONDecoder().decode(CreditExpiryRecord.self, from: data) else { return CreditExpiryLedger() }
    let batch = CreditExpiryBatch(id: "legacy-single-date-v1", title: "历史到期记录",
      expiryDate: CreditExpiryBatch.dateString(record.expiresAt), basis: .legacy,
      note: "旧版本的单笔记录；保留原有核实状态。", record: record)
    return CreditExpiryLedger(batches: [batch])
  }

  public func save(_ ledger: CreditExpiryLedger) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(ledger).write(to: url, options: .atomic)
  }
}
