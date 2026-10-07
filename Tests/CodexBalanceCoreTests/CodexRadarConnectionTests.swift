import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Radar connection recovery")
struct CodexRadarConnectionTests {
  @Test
  func aConnectionLostOnceRecoversDuringTheSameRefresh() async throws {
    let pageURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/codex-radar-tibo-20261007.html")
    let page = try Data(contentsOf: pageURL)
    let scenario = RadarConnectionScenario([
      .failure(URLError(.networkConnectionLost)),
      .response(200, page)
    ])
    let (url, session) = RadarConnectionURLProtocol.session(for: scenario)
    defer { session.invalidateAndCancel() }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-07T03:02:01Z"))
    let service = CodexRadarService(
      fetcher: { throw CodexRadarError.server(503) },
      publicPageFetcher: {
        try await CodexRadarService.fetch(url: url, accept: "text/html", session: session)
      },
      now: { now }
    )
    let snapshot = try await service.current(force: true)
    #expect(snapshot.syncState?.isUsingCachedFeed == false)
    #expect(snapshot.syncState?.lastSuccessAt == now)
    #expect(snapshot.tiboFeed?.posts.first?.id == "2107504197012988007")
    #expect(scenario.requestCount == 2)
  }

  @Test
  func aTemporaryServerFailureRecoversWithoutUserRefresh() async throws {
    let data = Data("recovered".utf8)
    let scenario = RadarConnectionScenario([.response(503, Data()), .response(200, data)])
    let (url, session) = RadarConnectionURLProtocol.session(for: scenario)
    defer { session.invalidateAndCancel() }
    let result = try await CodexRadarService.fetch(url: url, accept: "application/json", session: session)
    #expect(result == data)
    #expect(scenario.requestCount == 2)
  }

  @Test
  func accessDeniedDoesNotHammerTheSource() async throws {
    let scenario = RadarConnectionScenario([.response(403, Data()), .response(200, Data())])
    let (url, session) = RadarConnectionURLProtocol.session(for: scenario)
    defer { session.invalidateAndCancel() }
    await #expect(throws: CodexRadarError.accessDenied) {
      try await CodexRadarService.fetch(url: url, accept: "text/html", session: session)
    }
    #expect(scenario.requestCount == 1)
  }

  @Test
  func aStalledResponseIsCancelledWithinTheTransferBudget() async throws {
    let scenario = RadarConnectionScenario([.stall])
    let (url, session) = RadarConnectionURLProtocol.session(for: scenario)
    defer { session.invalidateAndCancel() }
    let started = ContinuousClock.now
    await #expect(throws: URLError(.timedOut)) {
      try await CodexRadarService.fetch(
        url: url, accept: "text/html", session: session,
        options: .init(maximumAttempts: 1, maximumDuration: 0.05, requestTimeout: 0.05)
      )
    }
    #expect(started.duration(to: .now) < .seconds(1))
    #expect(scenario.stopCount >= 1)
  }

  @Test
  func cancellationAndOfflineErrorsAreNotRetriedInATightLoop() async throws {
    for code in [URLError.Code.cancelled, .notConnectedToInternet] {
      let scenario = RadarConnectionScenario([.failure(URLError(code)), .response(200, Data())])
      let (url, session) = RadarConnectionURLProtocol.session(for: scenario)
      defer { session.invalidateAndCancel() }
      do {
        _ = try await CodexRadarService.fetch(url: url, accept: "text/html", session: session)
        Issue.record("An offline or cancelled request unexpectedly succeeded")
      } catch {
        #expect((error as? URLError)?.code == code)
      }
      #expect(scenario.requestCount == 1)
    }
  }

  @Test
  func serverRetryAfterIsRespectedRatherThanImmediatelyRetried() async throws {
    let scenario = RadarConnectionScenario([
      .response(429, Data(), headers: ["Retry-After": "600"]), .response(200, Data())
    ])
    let (url, session) = RadarConnectionURLProtocol.session(for: scenario)
    defer { session.invalidateAndCancel() }
    await #expect(throws: CodexRadarError.retryAfter(status: 429, seconds: 600)) {
      try await CodexRadarService.fetch(url: url, accept: "text/html", session: session)
    }
    #expect(scenario.requestCount == 1)
  }

  @Test
  func repeatedTransientFailuresStopAfterTheConfiguredAttemptLimit() async throws {
    let scenario = RadarConnectionScenario([
      .response(503, Data()), .response(503, Data()), .response(503, Data()),
      .response(200, Data())
    ])
    let (url, session) = RadarConnectionURLProtocol.session(for: scenario)
    defer { session.invalidateAndCancel() }
    await #expect(throws: CodexRadarError.server(503)) {
      try await CodexRadarService.fetch(
        url: url, accept: "text/html", session: session,
        options: .init(retryDelays: [0])
      )
    }
    #expect(scenario.requestCount == 3)
  }

  @Test
  func retryAttemptsShareOneTransferDeadline() async throws {
    let scenario = RadarConnectionScenario([.stall, .stall, .stall])
    let (url, session) = RadarConnectionURLProtocol.session(for: scenario)
    defer { session.invalidateAndCancel() }
    let started = ContinuousClock.now
    await #expect(throws: URLError(.timedOut)) {
      try await CodexRadarService.fetch(
        url: url, accept: "text/html", session: session,
        options: .init(maximumAttempts: 3, maximumDuration: 0.18, requestTimeout: 0.1, retryDelays: [0.01])
      )
    }
    #expect(started.duration(to: .now) < .seconds(0.5))
    #expect(scenario.requestCount == 2)
    #expect(scenario.stopCount >= 2)
  }

  @Test
  func coldStartFailuresReturnHonestStatusAndIncreasingBackoff() async throws {
    let service = CodexRadarService(
      fetcher: { throw CodexRadarError.server(503) },
      publicPageFetcher: { throw URLError(.notConnectedToInternet) }
    )
    for failureCount in 1...3 {
      let snapshot = try await service.current(force: true)
      #expect(snapshot.syncState?.consecutiveFailures == failureCount)
      #expect(snapshot.syncState?.lastSuccessAt == nil)
      #expect(snapshot.probability24hPercent == nil)
      #expect(snapshot.latestLevelLabel == "等待数据")
    }
  }

  @Test
  func pageFetchStartsBeforeTheIndependentResetAnchorFinishes() async throws {
    let pageURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/codex-radar-tibo-20261007.html")
    let data = try Data(contentsOf: pageURL)
    let probe = RadarParallelFetchProbe()
    let service = CodexRadarService(
      fetcher: {
        await probe.waitForPage()
        throw CodexRadarError.server(503)
      },
      publicPageFetcher: {
        await probe.pageStarted()
        return data
      }
    )
    _ = try await service.current(force: true)
    #expect(await probe.pageWasConcurrent)
  }

  @Test
  func minorHomepageMarkupChangesDoNotDisconnectTheFeed() throws {
    let pageURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/codex-radar-tibo-20261007.html")
    let html = try String(contentsOf: pageURL, encoding: .utf8)
      .replacingOccurrences(
        of: #"<section class="desktop-tibo-radar" id="tibo-updates""#,
        with: #"<section id="tibo-updates" class="layout-card desktop-tibo-radar""#
      )
      .replacingOccurrences(of: "\"", with: "'")
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-07T03:02:01Z"))
    let page = try CodexRadarPublicPageParser.decode(Data(html.utf8), now: now)
    #expect(page.tiboFeed.posts.count == 60)
    #expect(page.tiboFeed.posts.first?.id == "2107504197012988007")
  }
}

private actor RadarParallelFetchProbe {
  private var pageHasStarted = false
  private var baseFinished = false
  private(set) var pageWasConcurrent = false
  func waitForPage() async {
    for _ in 0..<20 {
      if pageHasStarted { break }
      try? await Task.sleep(for: .milliseconds(5))
    }
    baseFinished = true
  }
  func pageStarted() {
    pageHasStarted = true
    pageWasConcurrent = !baseFinished
  }
}

private final class RadarConnectionScenario: @unchecked Sendable {
  enum Result: Sendable {
    case response(Int, Data, headers: [String: String] = [:])
    case failure(URLError)
    case stall
  }
  private let lock = NSLock()
  private var results: [Result]
  private var count = 0
  private var stops = 0

  init(_ results: [Result]) { self.results = results }
  var requestCount: Int { lock.withLock { count } }
  var stopCount: Int { lock.withLock { stops } }
  func stopped() { lock.withLock { stops += 1 } }
  func next() -> Result {
    lock.withLock {
      count += 1
      return results.isEmpty ? .failure(URLError(.cannotConnectToHost)) : results.removeFirst()
    }
  }
}

private final class RadarConnectionScenarios: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: RadarConnectionScenario] = [:]
  func register(_ scenario: RadarConnectionScenario, id: String) {
    lock.withLock { values[id] = scenario }
  }
  func get(_ id: String) -> RadarConnectionScenario? { lock.withLock { values[id] } }
}

private final class RadarConnectionURLProtocol: URLProtocol, @unchecked Sendable {
  private static let scenarios = RadarConnectionScenarios()
  private var scenario: RadarConnectionScenario?

  static func session(for scenario: RadarConnectionScenario) -> (URL, URLSession) {
    let id = UUID().uuidString
    scenarios.register(scenario, id: id)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RadarConnectionURLProtocol.self]
    return (URL(string: "https://radar.test/\(id)")!, URLSession(configuration: config))
  }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "radar.test" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url, let scenario = Self.scenarios.get(url.lastPathComponent) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    self.scenario = scenario
    switch scenario.next() {
    case .failure(let error):
      client?.urlProtocol(self, didFailWithError: error)
    case .response(let status, let data, let headers):
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    case .stall:
      break
    }
  }
  override func stopLoading() { scenario?.stopped() }
}
