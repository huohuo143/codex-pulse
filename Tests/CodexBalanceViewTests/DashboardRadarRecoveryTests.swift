import CodexBalanceCore
import Foundation
import Testing
@testable import CodexBalance

@Suite("Dashboard radar reconnection")
@MainActor
struct DashboardRadarRecoveryTests {
  @Test
  func networkRecoveryRetriesARecentFailureThroughTheRealRefreshGate() async throws {
    let data = try fixture()
    let source = DashboardRadarTestSource(data: data)
    let store = makeStore(source: source)
    defer { store.stopAutoRefresh() }

    store.refreshCodexRadar(force: true)
    await waitForRadar(store)
    #expect(store.codexRadarSnapshot?.syncState?.consecutiveFailures == 0)
    await source.fail(with: URLError(.notConnectedToInternet))
    store.refreshCodexRadar(force: true)
    await waitForRadar(store)
    #expect(store.codexRadarSnapshot?.syncState?.consecutiveFailures == 1)
    #expect(store.codexRadarNextSyncAt != nil)

    await source.recover()
    store.handleCodexRadarNetworkUpdate(isAvailable: false)
    store.handleCodexRadarNetworkUpdate(isAvailable: true)
    await waitForRadar(store)
    #expect(await source.fetchCount == 3)
    #expect(store.codexRadarSnapshot?.syncState?.consecutiveFailures == 0)
    #expect(store.codexRadarSnapshot?.syncState?.isUsingCachedFeed == false)
    #expect(store.codexRadarRetryTask == nil)
    #expect(!store.codexRadarRefreshGate.isRefreshing)
  }

  @Test
  func normalInitialNetworkNotificationsDoNotDuplicateAHealthyRefresh() async throws {
    let source = DashboardRadarTestSource(data: try fixture())
    let store = makeStore(source: source)
    defer { store.stopAutoRefresh() }
    store.refreshCodexRadar(force: true)
    await waitForRadar(store)
    store.handleCodexRadarNetworkUpdate(isAvailable: true)
    store.handleCodexRadarNetworkUpdate(isAvailable: true)
    await waitForRadar(store)
    #expect(await source.fetchCount == 1)
  }

  @Test
  func networkRecoveryAndManualRefreshHonorTheServersWaitingTime() async throws {
    let source = DashboardRadarTestSource(data: try fixture())
    let store = makeStore(source: source)
    defer { store.stopAutoRefresh() }
    store.refreshCodexRadar(force: true)
    await waitForRadar(store)
    await source.fail(with: CodexRadarError.retryAfter(status: 429, seconds: 600))
    store.refreshCodexRadar(force: true)
    await waitForRadar(store)
    let heldUntil = try #require(store.codexRadarSnapshot?.syncState?.retryNotBefore)
    #expect(store.codexRadarNextSyncAt.map { $0 >= heldUntil.addingTimeInterval(-1) } == true)
    await source.recover()
    store.handleCodexRadarNetworkUpdate(isAvailable: false)
    store.handleCodexRadarNetworkUpdate(isAvailable: true)
    store.refreshCodexRadar(force: true)
    await waitForRadar(store)
    #expect(await source.fetchCount == 2)
    #expect(store.codexRadarSnapshot?.syncState?.consecutiveFailures == 1)
  }

  private func makeStore(source: DashboardRadarTestSource) -> DashboardStore {
    DashboardStore(startServices: false, radarService: CodexRadarService(
      fetcher: { throw CodexRadarError.server(503) },
      publicPageFetcher: { try await source.fetch() }
    ))
  }

  private func waitForRadar(_ store: DashboardStore) async {
    for _ in 0..<200 {
      if !store.codexRadarIsLoading && !store.codexRadarRefreshGate.isRefreshing { return }
      try? await Task.sleep(for: .milliseconds(15))
    }
    Issue.record("The radar did not release its refresh gate")
  }

  private func fixture() throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/codex-radar-tibo-20261007.html"))
  }
}

private actor DashboardRadarTestSource {
  let data: Data
  private var failure: (any Error)?
  private(set) var fetchCount = 0
  init(data: Data) { self.data = data }
  func fail(with error: any Error) { failure = error }
  func recover() { failure = nil }
  func fetch() throws -> Data {
    fetchCount += 1
    if let failure { throw failure }
    return data
  }
}
