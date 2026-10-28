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
  public static let tiboPauseMessage = "北京时间 16:00–21:00 暂停检测 Tibo，21:00 后恢复；保留上次动态"
  // Hour 0...23, fixed Beijing time. Zero means no polling.
  public static let tiboPollingMinutes = [20, 20, 12, 8, 8, 8, 10, 15, 12, 8, 15, 10, 3, 3, 3, 20, 0, 0, 0, 0, 0, 20, 20, 20]

  private static var beijingCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    return calendar
  }

  public static func isTiboPollingPaused(at now: Date) -> Bool {
    tiboPollingInterval(at: now) == 0
  }

  public static func tiboPollingInterval(at now: Date) -> TimeInterval {
    TimeInterval(tiboPollingMinutes[beijingCalendar.component(.hour, from: now)] * 60)
  }

  public static func tiboPollingSummary(at now: Date) -> String {
    let minutes = Int(tiboPollingInterval(at: now) / 60)
    return minutes == 0 ? tiboPauseMessage : "本时段每 \(minutes) 分钟检查 Tibo"
  }

  /// Find the next real network check, evaluating the new cadence at every
  /// intervening hour. Neither a shorter nor a longer period leaks across it.
  public static func nextTiboPollDate(lastAttemptAt: Date?, now: Date) -> Date {
    var cursor = now
    for _ in 0..<48 {
      if let resumed = tiboResumeDate(at: cursor) { cursor = resumed }
      guard let lastAttemptAt else { return cursor }
      let candidate = max(cursor, lastAttemptAt.addingTimeInterval(tiboPollingInterval(at: cursor)))
      let boundary = beijingCalendar.dateInterval(of: .hour, for: cursor)!.end
      if candidate < boundary { return candidate }
      cursor = boundary
    }
    return nextTiboFetchDate(after: max(now, (lastAttemptAt ?? now).addingTimeInterval(20 * 60)))
  }

  public static func tiboResumeDate(at now: Date) -> Date? {
    guard isTiboPollingPaused(at: now) else { return nil }
    return beijingCalendar.date(byAdding: .hour, value: 21, to: beijingCalendar.startOfDay(for: now))
  }

  public static func nextTiboFetchDate(after proposed: Date) -> Date {
    tiboResumeDate(at: proposed) ?? proposed
  }

  public static func shouldFetchAfterResume(
    lastSuccessAt: Date?,
    now: Date,
    maximumAge: TimeInterval? = nil,
    consecutiveFailures: Int = 0
  ) -> Bool {
    guard !isTiboPollingPaused(at: now) else { return false }
    if consecutiveFailures > 0 { return true }
    guard let lastSuccessAt else { return true }
    return now.timeIntervalSince(lastSuccessAt) >= (maximumAge ?? tiboPollingInterval(at: now))
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
