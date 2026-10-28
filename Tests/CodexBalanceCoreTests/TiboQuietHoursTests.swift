import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Tibo Beijing quiet hours")
struct TiboQuietHoursTests {
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

  @Test func boundariesAndFixedBeijingTimezone() {
    for (text, paused) in [("2026-10-26T07:59:59Z", false), ("2026-10-26T08:00:00Z", true),
                           ("2026-10-26T12:59:59Z", true), ("2026-10-26T13:00:00Z", false),
                           ("2026-12-26T08:00:00Z", true), ("2026-12-26T13:00:00Z", false)] {
      #expect(CodexRadarRefreshPolicy.isTiboPollingPaused(at: date(text)) == paused)
    }
    let quiet = date("2026-10-26T08:00:00Z")
    #expect(CodexRadarRefreshPolicy.tiboResumeDate(at: quiet) == date("2026-10-26T13:00:00Z"))
    #expect(CodexRadarRefreshPolicy.nextTiboFetchDate(after: quiet) == date("2026-10-26T13:00:00Z"))
    #expect(!CodexRadarRefreshPolicy.shouldFetchAfterResume(lastSuccessAt: nil, now: quiet, consecutiveFailures: 5))
    #expect(CodexRadarRefreshPolicy.shouldFetchAfterResume(lastSuccessAt: nil, now: date("2026-10-26T13:00:00Z")))
  }

  @Test func forcedCallsCannotFetchOrAnalyzeDuringQuietHoursAndResumeAtNine() async throws {
    let clock = QuietClock(date("2026-10-26T08:00:00Z"))
    let calls = QuietCalls()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appendingPathComponent("history.json")
    let service = makeService(clock: clock, calls: calls, history: history)
    let quiet = try await service.current(force: true)
    _ = try await service.current(force: false)
    #expect(await calls.count == 0)
    #expect(quiet.syncState?.lastAttemptAt == nil)
    clock.set(date("2026-10-26T13:00:00Z"))
    let resumed = try await service.current(force: true)
    #expect(await calls.count == 5) // source, base, two optional sources, analyzer
    #expect(resumed.syncState?.lastSuccessAt == clock.now())
    clock.set(date("2026-10-27T08:00:00Z"))
    let paused = try await service.current(force: true)
    #expect(await calls.count == 5)
    #expect(paused.syncState?.lastAttemptAt == resumed.syncState?.lastAttemptAt)
    #expect(paused.syncState?.lastSuccessAt == resumed.syncState?.lastSuccessAt)
    #expect(paused.tiboAnalysisAttemptAt == resumed.tiboAnalysisAttemptAt)
    // A restarted app restores the original timeline without making it fresh.
    let restarted = makeService(clock: clock, calls: calls, history: history)
    let cached = try await restarted.current(force: true)
    #expect(await calls.count == 5)
    #expect(cached.tiboFeed?.posts.map(\.id) == resumed.tiboFeed?.posts.map(\.id))
    #expect(cached.syncState?.lastSuccessAt == resumed.syncState?.lastSuccessAt)
  }

  private func makeService(clock: QuietClock, calls: QuietCalls, history: URL) -> CodexRadarService {
    let html = Data(#"""
      <section class="desktop-tibo-radar"><li class="reset-tibo-post" data-tibo-post-id="2114599388454481930">
      <a href="https://x.com/thsottiaux/status/2114599388454481930">Tibo</a><time datetime="2026-10-26T06:05:56Z"></time>
      <p class="reset-tibo-post-original">Not enough resets</p></li></section>
      """#.utf8)
    return CodexRadarService(fetcher: { await calls.hit(); throw CodexRadarError.server(503) },
      publicPageFetcher: { await calls.hit(); return html },
      stationInsightsFetcher: { await calls.hit(); return Data() },
      efficiencyFetcher: { await calls.hit(); return Data() },
      now: { clock.now() }, historyURL: history,
      analyzer: { _, _ in await calls.hit(); throw CodexRadarError.invalidPayload })
  }
}

private actor QuietCalls { var count = 0; func hit() { count += 1 } }
private final class QuietClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ date: Date) { value = date }
  func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
  func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; value = date }
}
