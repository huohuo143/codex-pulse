import Foundation

/// Provenance of one independently refreshed data source. Writing a UI snapshot
/// never changes these timestamps. Also compiled directly into the Widget target.
public struct SourceReadMetadata: Codable, Equatable, Sendable {
  public var source: String
  public var sampledAt: Date?
  public var lastAttemptAt: Date?
  public var lastSuccessAt: Date?
  public var failure: String?

  public init(source: String = "官方账户", sampledAt: Date? = nil, lastAttemptAt: Date? = nil,
              lastSuccessAt: Date? = nil, failure: String? = nil) {
    self.source = source
    self.sampledAt = sampledAt
    self.lastAttemptAt = lastAttemptAt
    self.lastSuccessAt = lastSuccessAt
    self.failure = failure
  }

  public mutating func succeed(at date: Date, sampledAt: Date? = nil) {
    lastAttemptAt = date
    lastSuccessAt = date
    self.sampledAt = sampledAt ?? date
    failure = nil
  }

  public mutating func fail(at date: Date, reason: String) {
    lastAttemptAt = date
    failure = reason
  }

  public func state(at now: Date, resetAt: Date? = nil) -> DataFreshnessState {
    guard let sampledAt, let lastSuccessAt else { return .unavailable }
    guard sampledAt <= now.addingTimeInterval(5), lastSuccessAt <= now.addingTimeInterval(5) else { return .unavailable }
    if let resetAt, resetAt <= now { return .waitingForReset }
    if now.timeIntervalSince(min(sampledAt, lastSuccessAt)) > 30 * 60 { return .expired }
    if failure != nil || now.timeIntervalSince(lastSuccessAt) > 5 * 60 { return .cached }
    return .fresh
  }

  public func nextTransition(after now: Date) -> Date? {
    guard let date = lastSuccessAt else { return nil }
    return [date.addingTimeInterval(5 * 60 + 1), date.addingTimeInterval(30 * 60 + 1)]
      .filter { $0 > now }.min()
  }

  public static func newest(_ incoming: Self?, _ existing: Self?) -> Self? {
    guard let incoming else { return existing }
    guard let existing else { return incoming }
    return (incoming.lastAttemptAt ?? .distantPast) >= (existing.lastAttemptAt ?? .distantPast) ? incoming : existing
  }
}

public enum DataFreshnessState: String, Codable, Equatable, Sendable {
  case fresh, cached, expired, waitingForReset, unavailable
  public var canDisplayValue: Bool { self == .fresh || self == .cached }
  public var label: String {
    switch self {
    case .fresh: "官方数据已更新"
    case .cached: "使用缓存 · 等待官方更新"
    case .expired: "数据已过期"
    case .waitingForReset: "等待新周期数据"
    case .unavailable: "数据状态待确认"
    }
  }
}
