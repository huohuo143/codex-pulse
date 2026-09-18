import Foundation

/// Pure scheduling state shared by the App and regression tests.
/// It coalesces any number of requests received during one network refresh into
/// exactly one follow-up request while preserving the strongest `force` flag.
public struct CodexRadarRefreshGate: Equatable, Sendable {
  public private(set) var isRefreshing = false
  public private(set) var hasPendingRequest = false
  public private(set) var pendingForce = false

  public init() {}

  @discardableResult
  public mutating func request(force: Bool) -> Bool {
    guard isRefreshing else {
      isRefreshing = true
      return true
    }
    hasPendingRequest = true
    pendingForce = pendingForce || force
    return false
  }

  /// Marks the current refresh complete and returns the coalesced follow-up.
  /// The caller starts that returned request through `request(force:)` again.
  public mutating func finish() -> Bool? {
    isRefreshing = false
    guard hasPendingRequest else { return nil }
    let force = pendingForce
    hasPendingRequest = false
    pendingForce = false
    return force
  }
}

public enum CodexRadarRefreshPolicy {
  public static func shouldFetchAfterResume(
    lastSuccessAt: Date?,
    now: Date,
    maximumAge: TimeInterval = CodexRadarService.localEvaluationInterval
  ) -> Bool {
    guard let lastSuccessAt else { return true }
    return now.timeIntervalSince(lastSuccessAt) >= maximumAge
  }
}
