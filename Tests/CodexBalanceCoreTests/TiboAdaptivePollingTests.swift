import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Tibo density-based Beijing polling")
struct TiboAdaptivePollingTests {
  private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

  @Test func completeHourlyScheduleAndBoundaries() {
    let expected = [20,20,12,8,8,8,10,15,12,8,15,10,3,3,3,20,0,0,0,0,0,20,20,20]
    let start = date("2026-10-26T00:00:00+08:00")
    for hour in 0..<24 {
      #expect(CodexRadarRefreshPolicy.tiboPollingInterval(at: start.addingTimeInterval(Double(hour * 3600))) == Double(expected[hour] * 60))
    }
    for (last, next) in [("01:59:00", "02:11:00"), ("08:59:00", "09:07:00"),
                         ("11:59:00", "12:02:00"), ("14:59:00", "15:19:00"),
                         ("15:55:00", "21:00:00")] {
      let checked = date("2026-10-26T\(last)+08:00")
      #expect(CodexRadarRefreshPolicy.nextTiboPollDate(lastAttemptAt: checked, now: checked) == date("2026-10-26T\(next)+08:00"))
    }
    let last = date("2026-10-26T23:59:00+08:00")
    #expect(CodexRadarRefreshPolicy.nextTiboPollDate(lastAttemptAt: last, now: last) == date("2026-10-27T00:19:00+08:00"))
    #expect(CodexRadarRefreshPolicy.nextTiboPollDate(lastAttemptAt: nil, now: date("2026-10-26T16:00:00+08:00")) == date("2026-10-26T21:00:00+08:00"))
  }

  @Test func realServiceBudgetPersistsAcrossRestartAndChangesAtHourBoundaries() async throws {
    let clock = AdaptiveClock(date("2026-10-26T12:00:00+08:00"))
    let calls = AdaptiveCalls()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appendingPathComponent("history.json")
    func service() -> CodexRadarService {
      CodexRadarService(fetcher: { Data("{}".utf8) }, publicPageFetcher: {
        await calls.hit()
        return Data("<section class=\"desktop-tibo-radar\"><li class=\"reset-tibo-post\" data-tibo-post-id=\"2114599388454481930\"><a href=\"https://x.com/thsottiaux/status/2114599388454481930\">Tibo</a><time datetime=\"\(ISO8601DateFormatter().string(from: clock.now()))\"></time><p class=\"reset-tibo-post-original\">Not enough resets</p></li></section>".utf8)
      }, now: { clock.now() }, historyURL: history, adaptivePolling: true)
    }
    var source = service()
    _ = try await source.current(force: true)
    clock.set(date("2026-10-26T12:02:59+08:00"))
    source = service()
    _ = try await source.current(force: true)
    #expect(await calls.count == 1)
    clock.set(date("2026-10-26T12:03:00+08:00"))
    _ = try await source.current(force: false)
    #expect(await calls.count == 2)
    clock.set(date("2026-10-26T14:59:00+08:00"))
    _ = try await source.current(force: true)
    clock.set(date("2026-10-26T15:02:00+08:00"))
    _ = try await source.current(force: true)
    #expect(await calls.count == 3)
    clock.set(date("2026-10-26T15:19:00+08:00"))
    _ = try await source.current(force: true)
    #expect(await calls.count == 4)
    for time in ["16:00:00", "20:59:59"] {
      clock.set(date("2026-10-26T\(time)+08:00"))
      _ = try await source.current(force: true)
    }
    #expect(await calls.count == 4)
    clock.set(date("2026-10-26T21:00:00+08:00"))
    _ = try await source.current(force: true)
    #expect(await calls.count == 5)
    clock.set(date("2026-10-26T21:19:59+08:00"))
    _ = try await service().current(force: true)
    #expect(await calls.count == 5)
    clock.set(date("2026-10-26T21:20:00+08:00"))
    _ = try await service().current(force: true)
    #expect(await calls.count == 6)
  }

  @Test func freshnessUsesTheScheduledCheckRatherThanTenMinutes() throws {
    var snapshot = try JSONDecoder().decode(CodexRadarSnapshot.self, from: Data("{}".utf8))
    snapshot.syncState = .init(lastSuccessAt: date("2026-10-26T01:00:00+08:00"))
    #expect(snapshot.tiboStatusValidUntil == date("2026-10-26T01:21:00+08:00"))
    snapshot.syncState?.lastSuccessAt = date("2026-10-26T12:00:00+08:00")
    #expect(snapshot.tiboStatusValidUntil == date("2026-10-26T12:04:00+08:00"))
  }
}
private actor AdaptiveCalls { var count = 0; func hit() { count += 1 } }
private final class AdaptiveClock: @unchecked Sendable {
  private let lock = NSLock(); private var value: Date
  init(_ value: Date) { self.value = value }
  func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
  func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; value = date }
}
