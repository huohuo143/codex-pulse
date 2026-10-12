import Foundation

/// Serializes notification batches and bounds retries without marking failed requests as sent.
public struct QuotaAlertDeliveryState: Sendable {
  public struct Attempt: Equatable, Sendable {
    fileprivate let id: UUID
    fileprivate let generation: UInt64
  }

  public static let failureRetryInterval: TimeInterval = 60
  public private(set) var retryAfter: Date?
  public var isDelivering: Bool { activeAttempt != nil }
  private var generation: UInt64 = 0
  private var activeAttempt: Attempt?

  public init() {}

  public mutating func begin(at now: Date) -> Attempt? {
    guard activeAttempt == nil, retryAfter.map({ now >= $0 }) ?? true else { return nil }
    let attempt = Attempt(id: UUID(), generation: generation)
    activeAttempt = attempt
    return attempt
  }

  public func isCurrent(_ attempt: Attempt) -> Bool {
    activeAttempt == attempt && attempt.generation == generation
  }

  @discardableResult
  public mutating func finish(_ attempt: Attempt, hadFailure: Bool, at now: Date) -> Bool {
    guard isCurrent(attempt) else { return false }
    activeAttempt = nil
    retryAfter = hadFailure ? now.addingTimeInterval(Self.failureRetryInterval) : nil
    return true
  }

  /// A result from a prior account must not release or update the new account's batch.
  public mutating func invalidate() {
    generation &+= 1
    activeAttempt = nil
    retryAfter = nil
  }
}

public enum QuotaAlertDeliveryCommit {
  public static func accepted(
    _ candidate: QuotaAlertCandidate,
    ledger: inout QuotaAlertLedger,
    at now: Date
  ) {
    ledger.sentKeys.formUnion(candidate.ledgerKeys)
    if case .forecastCritical = candidate.kind {
      ledger.lastForecastCriticalAt = now
      ledger.lastForecastCycle = candidate.forecastCycle
      ledger.lastRisk = .critical
    }
    if ledger.sentKeys.count > 200 {
      // Retain the just-accepted keys and bound old receipts independently of failed candidates.
      let older = ledger.sentKeys.subtracting(candidate.ledgerKeys).sorted().suffix(100)
      ledger.sentKeys = Set(older).union(candidate.ledgerKeys)
    }
  }
}
