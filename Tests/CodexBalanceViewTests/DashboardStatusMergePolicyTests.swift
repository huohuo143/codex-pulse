import CodexBalanceCore
import Foundation
import Testing
@testable import CodexBalance

@Suite("Dashboard quota status merging")
struct DashboardStatusMergePolicyTests {
  @Test
  func radarReliabilityAdvancesOnlyAfterRealTiboSuccess() {
    let attempt = date("2026-09-04T08:00:00Z")
    let success = date("2026-09-04T07:55:00Z")
    let failedFirstCheck = CodexRadarSyncState(
      lastAttemptAt: attempt,
      lastSuccessAt: nil,
      consecutiveFailures: 1,
      isUsingCachedFeed: true
    )
    let cachedAfterFailure = CodexRadarSyncState(
      lastAttemptAt: attempt,
      lastSuccessAt: success,
      consecutiveFailures: 1,
      isUsingCachedFeed: true
    )

    #expect(DashboardStatusMergePolicy.radarReliabilityTimestamp(from: nil) == nil)
    #expect(
      DashboardStatusMergePolicy.radarReliabilityTimestamp(from: failedFirstCheck) == nil
    )
    #expect(
      DashboardStatusMergePolicy.radarReliabilityTimestamp(from: cachedAfterFailure) == success
    )
  }

  @Test
  func fullScanKeepsNewCycleLiveQuotaAndUpdatesTokenStats() {
    let liveReset = date("2026-08-31T00:42:24Z")
    let staleReset = date("2026-08-27T06:03:33Z")
    let live = event(
      timestamp: date("2026-08-24T03:23:10Z"),
      remaining: 97,
      reset: liveReset,
      source: "Codex app-server"
    )
    let staleLog = event(
      timestamp: date("2026-08-23T15:56:17Z"),
      remaining: 59,
      reset: staleReset,
      source: "session.jsonl"
    )
    let existing = status(
      generatedAt: date("2026-08-24T03:23:11Z"),
      main: live,
      stats: TokenStats(rolling24HoursTokens: 10, sampleCount: 0)
    )
    let completedFullScan = status(
      generatedAt: date("2026-08-24T03:24:11Z"),
      main: staleLog,
      stats: TokenStats(rolling24HoursTokens: 123_456, sampleCount: 42)
    )

    let merged = DashboardStatusMergePolicy.mergeQuota(from: completedFullScan, with: existing)

    #expect(merged.main?.sevenDayWindow?.remainingPercent == 97)
    #expect(merged.main?.sevenDayWindow?.resetsAt == liveReset)
    #expect(merged.main?.sourceName == "Codex app-server")
    #expect(merged.limits.first?.sevenDayWindow?.remainingPercent == 97)
    #expect(merged.tokenStats.rolling24HoursTokens == 123_456)
    #expect(merged.tokenStats.sampleCount == 42)
    #expect(merged.generatedAt == completedFullScan.generatedAt)
  }

  @Test
  func fastFallbackCannotRegressToAnOlderSampleInTheSameCycle() {
    let reset = date("2026-08-31T00:42:24Z")
    let live = event(
      timestamp: date("2026-08-24T03:23:10Z"),
      remaining: 97,
      reset: reset,
      source: "Codex app-server"
    )
    let staleFallback = event(
      timestamp: date("2026-08-24T03:20:00Z"),
      remaining: 59,
      reset: reset,
      source: "session.jsonl"
    )

    let merged = DashboardStatusMergePolicy.mergeQuota(
      from: status(generatedAt: date("2026-08-24T03:24:11Z"), main: staleFallback),
      with: status(generatedAt: date("2026-08-24T03:23:11Z"), main: live)
    )

    #expect(merged.main == live)
    #expect(merged.limits.first == live)
  }

  @Test
  func newerQuotaSampleStillAdvancesNormally() {
    let reset = date("2026-08-31T00:42:24Z")
    let existing = event(
      timestamp: date("2026-08-24T03:23:10Z"),
      remaining: 97,
      reset: reset,
      source: "session.jsonl"
    )
    let newer = event(
      timestamp: date("2026-08-24T03:28:10Z"),
      remaining: 96,
      reset: reset,
      source: "session.jsonl"
    )

    let merged = DashboardStatusMergePolicy.mergeQuota(
      from: status(generatedAt: date("2026-08-24T03:28:11Z"), main: newer),
      with: status(generatedAt: date("2026-08-24T03:23:11Z"), main: existing)
    )

    #expect(merged.main == newer)
    #expect(merged.main?.sevenDayWindow?.remainingPercent == 96)
  }

  @Test
  func newerSessionLogCannotOverrideOfficialQuotaInTheSameCycle() {
    let reset = date("2026-08-31T00:42:24Z")
    let official = event(
      timestamp: date("2026-08-25T04:05:05Z"),
      remaining: 76,
      reset: reset,
      source: "Codex app-server"
    )
    let laterSessionLog = event(
      timestamp: date("2026-08-25T04:05:10Z"),
      remaining: 77,
      reset: reset,
      source: "session.jsonl"
    )

    let merged = DashboardStatusMergePolicy.mergeQuota(
      from: status(generatedAt: date("2026-08-25T04:05:11Z"), main: laterSessionLog),
      with: status(generatedAt: date("2026-08-25T04:05:06Z"), main: official)
    )

    #expect(merged.main == official)
    #expect(merged.limits.first == official)
  }

  private func status(
    generatedAt: Date,
    main: RateLimitEvent,
    stats: TokenStats = TokenStats()
  ) -> CodexStatus {
    CodexStatus(
      generatedAt: generatedAt,
      codexHome: "/tmp/.codex",
      sessionsRoot: "/tmp/.codex/sessions",
      main: main,
      limits: [main],
      tokenStats: stats
    )
  }

  private func event(
    timestamp: Date,
    remaining: Double,
    reset: Date,
    source: String
  ) -> RateLimitEvent {
    RateLimitEvent(
      timestamp: timestamp,
      sourceName: source,
      sourcePath: source == "Codex app-server" ? "account/rateLimits/read" : "/tmp/session.jsonl",
      limitID: "codex",
      limitName: "Codex",
      secondary: LimitWindow(
        usedPercent: 100 - remaining,
        remainingPercent: remaining,
        windowMinutes: 10_080,
        resetsAt: reset
      )
    )
  }

  private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }
}
