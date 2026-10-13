import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Update rate-limit recovery")
struct AppUpdateReliabilityTests {
  static let now = Date(timeIntervalSince1970: 1_791_870_000)
  static let payload = Data("""
  {"schemaVersion":1,"tag_name":"v2.13.0","html_url":"https://github.com/huohuo143/codex-pulse/releases/tag/v2.13.0","published_at":"2026-10-13T04:00:00Z","draft":false,"prerelease":false,"assets":[{"name":"Codex-Pulse-v2.13.0-arm64.dmg","browser_download_url":"https://github.com/huohuo143/codex-pulse/releases/download/v2.13.0/app.dmg","state":"uploaded"}]}
  """.utf8)

  @Test func manifestSuccessDoesNotConsumeAPIQuota() async throws {
    let scenario = UpdateScenario([.init(status: 200, body: Self.payload)])
    let session = UpdateProtocol.session(scenario)
    defer { session.invalidateAndCancel() }
    let service = GitHubReleaseUpdateService(session: session)
    let result = try await service.check(currentVersion: "2.12.2", now: Self.now)
    #expect(result.availability == .updateAvailable)
    #expect(scenario.urls.count == 1)
    #expect(scenario.urls.first == GitHubReleaseUpdateService.defaultManifestEndpoint)
  }

  @Test func concurrentChecksShareOneTransfer() async throws {
    let scenario = UpdateScenario([.init(status: 200, body: Self.payload)])
    let session = UpdateProtocol.session(scenario)
    defer { session.invalidateAndCancel() }
    let service = GitHubReleaseUpdateService(session: session)
    async let first = service.check(currentVersion: "2.12.2", now: Self.now)
    async let second = service.check(currentVersion: "2.12.2", now: Self.now)
    let results = try await (first, second)
    #expect(results.0 == results.1)
    #expect(scenario.urls.count == 1)
  }

  @Test func failedManifestFallsBackToAPI() async throws {
    let scenario = UpdateScenario([.init(status: 503), .init(status: 200, body: Self.payload)])
    let session = UpdateProtocol.session(scenario)
    defer { session.invalidateAndCancel() }
    let result = try await GitHubReleaseUpdateService(session: session).check(currentVersion: "2.12.2", now: Self.now)
    #expect(result.availability == .updateAvailable)
    #expect(scenario.urls == [GitHubReleaseUpdateService.defaultManifestEndpoint, GitHubReleaseUpdateService.defaultEndpoint])
  }

  @Test func rateLimitDeadlineSurvivesServiceRestartAndRepeatedChecks() async throws {
    let scenario = UpdateScenario([.init(status: 403, headers: ["x-ratelimit-remaining":"0", "x-ratelimit-reset":String(Int(Self.now.timeIntervalSince1970 + 120))])])
    let session = UpdateProtocol.session(scenario)
    defer { session.invalidateAndCancel() }
    let service = GitHubReleaseUpdateService(session: session, manifestEndpoint: nil)
    await #expect(throws: AppUpdateError.self) { try await service.check(currentVersion: "2.12.2", now: Self.now) }
    let policy = await service.retryStateSnapshot()
    #expect(policy.nextAttemptAt == Self.now.addingTimeInterval(120))
    let restored = GitHubReleaseUpdateService(session: session, manifestEndpoint: nil, retryState: AppUpdateRetryState(data: try JSONEncoder().encode(policy)))
    await #expect(throws: AppUpdateError.self) { try await restored.check(currentVersion: "2.12.2", now: Self.now) }
    #expect(scenario.urls.count == 1)
  }

  @Test func manifestCanRecoverWhileAPIStillCoolingDown() async throws {
    let scenario = UpdateScenario([.init(status: 503), .init(status: 429, headers: ["Retry-After":"600"]), .init(status: 200, body: Self.payload)])
    let session = UpdateProtocol.session(scenario)
    defer { session.invalidateAndCancel() }
    let service = GitHubReleaseUpdateService(session: session)
    await #expect(throws: AppUpdateError.self) { try await service.check(currentVersion: "2.12.2", now: Self.now) }
    let result = try await service.check(currentVersion: "2.12.2", now: Self.now.addingTimeInterval(61))
    #expect(result.availability == .updateAvailable)
    #expect(scenario.urls.filter { $0 == GitHubReleaseUpdateService.defaultEndpoint }.count == 1)
    #expect(await service.retryStateSnapshot().nextAttemptAt == nil)
  }

  @Test func failedChecksBackOffAndRecoveryClearsFailureState() async throws {
    let scenario = UpdateScenario([.init(status: 503), .init(status: 503), .init(status: 200, body: Self.payload)])
    let session = UpdateProtocol.session(scenario)
    defer { session.invalidateAndCancel() }
    let service = GitHubReleaseUpdateService(session: session)
    await #expect(throws: AppUpdateError.self) { try await service.check(currentVersion: "2.12.2", now: Self.now) }
    #expect(await service.retryStateSnapshot().nextAttemptAt == Self.now.addingTimeInterval(60))
    _ = try await service.check(currentVersion: "2.12.2", now: Self.now.addingTimeInterval(61))
    #expect(await service.retryStateSnapshot().failureCount == 0)
  }

  @Test func foreignManifestDownloadsAreRejected() async throws {
    let bad = Data(String(decoding: Self.payload, as: UTF8.self).replacingOccurrences(of: "https://github.com/huohuo143/codex-pulse/releases/download/", with: "https://evil.example/releases/download/").utf8)
    let scenario = UpdateScenario([.init(status: 200, body: bad), .init(status: 200, body: Self.payload)])
    let session = UpdateProtocol.session(scenario)
    defer { session.invalidateAndCancel() }
    _ = try await GitHubReleaseUpdateService(session: session).check(currentVersion: "2.12.2", now: Self.now)
    #expect(scenario.urls.count == 2)
  }

  @Test func retryHeadersUseLaterDeadlineAndParseHTTPDate() throws {
    let response = try #require(HTTPURLResponse(url: GitHubReleaseUpdateService.defaultEndpoint, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After":"Tue, 13 Oct 2026 06:00:00 GMT", "x-ratelimit-remaining":"0", "x-ratelimit-reset":String(Int(Self.now.timeIntervalSince1970 + 7200))]))
    #expect(GitHubReleaseUpdateService.rateLimitRetryAt(response: response, now: Self.now) == Self.now.addingTimeInterval(7200))
  }
}

private final class UpdateScenario: @unchecked Sendable {
  struct Reply: Sendable { let status: Int; var headers: [String:String] = [:]; var body: Data = Data() }
  let id = UUID().uuidString
  private let lock = NSLock()
  private var replies: [Reply]
  private var requests: [URL] = []
  init(_ replies: [Reply]) { self.replies = replies }
  var urls: [URL] { lock.withLock { requests } }
  func next(_ url: URL) -> Reply { lock.withLock { requests.append(url); return replies.isEmpty ? Reply(status: 500) : replies.removeFirst() } }
}
private final class UpdateRegistry: @unchecked Sendable {
  let lock = NSLock(); var entries: [String:UpdateScenario] = [:]
}
private final class UpdateProtocol: URLProtocol, @unchecked Sendable {
  static let registry = UpdateRegistry()
  static func session(_ scenario: UpdateScenario) -> URLSession {
    registry.lock.withLock { registry.entries[scenario.id] = scenario }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Self.self]
    config.httpAdditionalHeaders = ["X-Test-Scenario":scenario.id]
    return URLSession(configuration: config)
  }
  override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-Test-Scenario") != nil }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let id = request.value(forHTTPHeaderField: "X-Test-Scenario"), let url = request.url,
          let scenario = Self.registry.lock.withLock({ Self.registry.entries[id] }),
          let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
    let reply = scenario.next(url)
    let actual = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers) ?? response
    client?.urlProtocol(self, didReceive: actual, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply.body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
