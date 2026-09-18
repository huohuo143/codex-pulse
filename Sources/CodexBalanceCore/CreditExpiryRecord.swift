import Foundation
import CryptoKit

public struct CreditExpiryRecord: Codable, Equatable, Sendable {
  public var expiresAt: Date
  public var source: String
  public var confirmedAt: Date?
  public var accountScope: String?
  public init(expiresAt: Date, source: String, confirmedAt: Date? = nil, accountScope: String? = nil) {
    self.expiresAt = expiresAt; self.source = source; self.confirmedAt = confirmedAt; self.accountScope = accountScope
  }
  public func isConfirmed(for account: String?) -> Bool {
    confirmedAt != nil && account != nil && accountScope == account && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  public func label(account: String?) -> String {
    guard isConfirmed(for: account) else { return "暂无已确认到期日" }
    return "已确认到期日 " + expiresAt.formatted(date: .numeric, time: .omitted)
  }
}

public struct CreditExpiryStore: Sendable {
  public var url: URL
  public init(url: URL = PulsePaths.support.appendingPathComponent("credit-expiry-v1.json")) { self.url = url }
  public func load() -> CreditExpiryRecord {
    if let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(CreditExpiryRecord.self, from: data) { return record }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let record = CreditExpiryRecord(expiresAt: calendar.date(from: DateComponents(year: 2027, month: 7, day: 21))!, source: "旧版本历史记录，待核实；未找到官方到期字段")
    if !FileManager.default.fileExists(atPath: url.path) { try? save(record) }
    return record
  }
  public func save(_ record: CreditExpiryRecord) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(record).write(to: url, options: .atomic)
  }
}

/// Only a locally salted, irreversible account digest leaves the credential reader.
enum AnonymousAccountScope {
  static func make(accountID: String?, salt: String) -> String? {
    guard let accountID, !accountID.isEmpty else { return nil }
    return SHA256.hash(data: Data((salt + "|" + accountID).utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static let localSalt: String = {
    let url = PulsePaths.support.appendingPathComponent("account-scope-salt.txt")
    if let value = try? String(contentsOf: url, encoding: .utf8), !value.isEmpty { return value }
    let value = UUID().uuidString
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? value.write(to: url, atomically: true, encoding: .utf8)
    return value
  }()
}
