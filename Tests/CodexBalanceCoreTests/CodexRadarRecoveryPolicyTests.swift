import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Radar recovery persistence and scheduling")
struct CodexRadarRecoveryPolicyTests {
  @Test
  func waitingTimeSurvivesRestartAndForcedRefresh() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let historyURL = folder.appendingPathComponent("history.json")
    let clock = RadarRecoveryClock(date("2026-10-07T03:02:01Z"))
    let source = RadarRecoverySource(data: try fixture())
    await source.fail(with: CodexRadarError.retryAfter(status: 429, seconds: 600))
    let first = service(source: source, clock: clock, historyURL: historyURL)
    let failed = try await first.current(force: true)
    #expect(failed.syncState?.retryNotBefore == clock.now().addingTimeInterval(600))
    _ = try await first.current(force: true)
    let restarted = service(source: source, clock: clock, historyURL: historyURL)
    let held = try await restarted.current(force: true)
    #expect(await source.count == 1)
    #expect(held.syncState?.lastAttemptAt == failed.syncState?.lastAttemptAt)
    #expect(held.syncState?.consecutiveFailures == 1)
    #expect(held.latestLevelLabel == "等待数据")
    #expect(held.latestSummary?.contains("90 分钟") == false)
    await source.recover()
    clock.advance(601)
    let recovered = try await restarted.current(force: false)
    #expect(await source.count == 2)
    #expect(recovered.syncState?.lastSuccessAt == clock.now())
    #expect(recovered.syncState?.retryNotBefore == nil)
    #expect(recovered.syncState?.failureMessage == nil)
    let history = try #require(CodexRadarTiboHistoryStore.load(from: historyURL))
    #expect(history.recentSyncAttempts?.map(\.succeeded) == [false, true])
  }

  @Test
  func lastGoodTimelineIsRestoredDuringAServerWait() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let historyURL = folder.appendingPathComponent("history.json")
    let clock = RadarRecoveryClock(date("2026-10-07T03:02:01Z"))
    let source = RadarRecoverySource(data: try fixture())
    let original = service(source: source, clock: clock, historyURL: historyURL)
    let fresh = try await original.current(force: true)
    clock.advance(15)
    await source.fail(with: CodexRadarError.retryAfter(status: 503, seconds: 600))
    _ = try await original.current(force: true)
    let restarted = service(source: source, clock: clock, historyURL: historyURL)
    let cached = try await restarted.current(force: true)
    #expect(await source.count == 2)
    #expect(cached.tiboFeed?.posts.map(\.id) == fresh.tiboFeed?.posts.map(\.id))
    #expect(cached.syncState?.lastSuccessAt == fresh.syncState?.lastSuccessAt)
    #expect(cached.syncState?.isUsingCachedFeed == true)
    #expect(cached.syncState?.failureMessage?.contains("503") == true)
  }

  @Test
  func coldFailureCountSurvivesRestartWithoutInventingProbability() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let historyURL = folder.appendingPathComponent("history.json")
    let clock = RadarRecoveryClock(date("2026-10-07T03:02:01Z"))
    let source = RadarRecoverySource(data: try fixture())
    await source.fail(with: URLError(.notConnectedToInternet))
    for failureCount in 1...3 {
      let snapshot = try await service(source: source, clock: clock, historyURL: historyURL).current(force: true)
      #expect(snapshot.syncState?.consecutiveFailures == failureCount)
      #expect(snapshot.probability24hPercent == nil)
      #expect(snapshot.syncState?.lastSuccessAt == nil)
      #expect(snapshot.latestLevelLabel == "等待数据")
      clock.advance(60)
    }
    #expect(await source.count == 3)
  }

  @Test
  func successfulCompletionUsesTheActualCompletionTime() async throws {
    let started = date("2026-10-07T03:02:01Z")
    let clock = RadarRecoveryClock(started)
    let data = try fixture()
    let service = CodexRadarService(
      fetcher: { throw CodexRadarError.server(503) },
      publicPageFetcher: { clock.advance(10); return data },
      now: { clock.now() }
    )
    let snapshot = try await service.current(force: true)
    #expect(snapshot.syncState?.lastAttemptAt == started)
    #expect(snapshot.syncState?.lastSuccessAt == started.addingTimeInterval(10))
  }

  @Test
  func recoveryGateCoalescesNetworkFlappingAndHonorsSourceWaits() {
    let now = date("2026-10-07T03:02:01Z")
    var gate = CodexRadarNetworkRecoveryGate()
    let healthy = CodexRadarSyncState(lastSuccessAt: now)
    let transitions = [
      gate.shouldRefresh(isAvailable: true, sync: healthy, now: now),
      gate.shouldRefresh(isAvailable: false, sync: healthy, now: now),
      gate.shouldRefresh(isAvailable: true, sync: healthy, now: now),
      gate.shouldRefresh(isAvailable: false, sync: healthy, now: now.addingTimeInterval(1)),
      gate.shouldRefresh(isAvailable: true, sync: healthy, now: now.addingTimeInterval(2)),
      gate.shouldRefresh(isAvailable: false, sync: healthy, now: now.addingTimeInterval(31)),
      gate.shouldRefresh(isAvailable: true, sync: healthy, now: now.addingTimeInterval(32))
    ]
    #expect(transitions == [false, false, true, false, false, false, true])
    let held = CodexRadarSyncState(
      lastSuccessAt: now, consecutiveFailures: 1, isUsingCachedFeed: true,
      retryNotBefore: now.addingTimeInterval(600)
    )
    let heldOffline = gate.shouldRefresh(isAvailable: false, sync: held, now: now.addingTimeInterval(65))
    let heldOnline = gate.shouldRefresh(isAvailable: true, sync: held, now: now.addingTimeInterval(66))
    #expect(!heldOffline && !heldOnline)
    #expect(CodexRadarService.retryDelay(for: held, at: now) == 600)
    #expect(CodexRadarRefreshPolicy.shouldFetchAfterResume(
      lastSuccessAt: now, now: now.addingTimeInterval(1), consecutiveFailures: 1
    ))
  }

  private func service(source: RadarRecoverySource, clock: RadarRecoveryClock, historyURL: URL) -> CodexRadarService {
    CodexRadarService(
      fetcher: { throw CodexRadarError.server(503) },
      publicPageFetcher: { try await source.fetch() },
      now: { clock.now() }, historyURL: historyURL
    )
  }
  private func fixture() throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/codex-radar-tibo-20261007.html"))
  }
  private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
}

private actor RadarRecoverySource {
  private let data: Data
  private var failure: (any Error)?
  private(set) var count = 0
  init(data: Data) { self.data = data }
  func fail(with error: any Error) { failure = error }
  func recover() { failure = nil }
  func fetch() throws -> Data {
    count += 1
    if let failure { throw failure }
    return data
  }
}

private final class RadarRecoveryClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date) { self.value = value }
  func now() -> Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
