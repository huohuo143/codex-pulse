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
    maximumAge: TimeInterval = CodexRadarService.localEvaluationInterval,
    consecutiveFailures: Int = 0
  ) -> Bool {
    if consecutiveFailures > 0 { return true }
    guard let lastSuccessAt else { return true }
    return now.timeIntervalSince(lastSuccessAt) >= maximumAge
  }
}

/// Network callbacks can repeat or arrive during an existing refresh. A real
/// offline-to-online transition bypasses the normal age check, with a short
/// cooldown for flapping interfaces and the source's own waiting time intact.
public struct CodexRadarNetworkRecoveryGate: Sendable {
  private var wasAvailable: Bool?
  private var lastRecoveryAt: Date?

  public init() {}

  public mutating func shouldRefresh(
    isAvailable: Bool,
    sync: CodexRadarSyncState?,
    now: Date,
    cooldown: TimeInterval = 30
  ) -> Bool {
    let previous = wasAvailable
    wasAvailable = isAvailable
    guard let previous, isAvailable else { return false }
    if let heldUntil = sync?.retryNotBefore, now < heldUntil { return false }
    if let lastRecoveryAt, now.timeIntervalSince(lastRecoveryAt) < cooldown { return false }
    let restored = previous == false
    let needsRecovery = (sync?.consecutiveFailures ?? 0) > 0
      || CodexRadarRefreshPolicy.shouldFetchAfterResume(lastSuccessAt: sync?.lastSuccessAt, now: now)
    guard restored || needsRecovery else { return false }
    lastRecoveryAt = now
    return true
  }
}
