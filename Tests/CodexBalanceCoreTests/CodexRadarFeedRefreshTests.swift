import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Latest public Tibo feed")
struct CodexRadarFeedRefreshTests {
  private static func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/\(name)")
    return try Data(contentsOf: url)
  }

  @Test
  func currentKeepsLatestPublicPostsEvenWithoutResetSignals() async throws {
    let data = try Self.fixture("codex-radar-tibo-20261007.html")
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-07T03:02:01Z"))
    let page = try CodexRadarPublicPageParser.decode(data, now: now)
    #expect(page.tiboFeed.posts.count == 60)
    #expect(page.tiboFeed.posts.first?.id == "2107504197012988007")

    let service = CodexRadarService(
      fetcher: { throw CodexRadarError.server(503) },
      publicPageFetcher: { data },
      now: { now }
    )
    let snapshot = try await service.current(force: true)
    #expect(snapshot.tiboFeed?.posts.first?.id == "2107504197012988007")
    #expect(snapshot.tiboFeed?.posts.contains(where: { $0.id == "2107368734981517634" }) == true)
    #expect(snapshot.tiboPresence?.latestActivityAt == page.tiboFeed.posts.first?.publishedAt)
    #expect(snapshot.tiboPresence?.latestActivityZh?.contains("Auto-review") == true)
  }

  @Test
  func aSingleNonResetPostSurvivesTheService() async throws {
    let html = String(decoding: try Self.fixture("codex-radar-tibo-20261007.html"), as: UTF8.self)
    let start = try #require(html.range(of: "<li class=\"reset-tibo-post\""))
    let end = try #require(html.range(of: "</li>", range: start.lowerBound..<html.endIndex))
    let post = String(html[start.lowerBound..<end.upperBound])
    let data = Data("<section class=\"desktop-tibo-radar\"><ol>\(post)</ol></section>".utf8)
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-07T03:02:01Z"))
    let service = CodexRadarService(
      fetcher: { throw CodexRadarError.server(503) },
      publicPageFetcher: { data },
      now: { now }
    )
    let snapshot = try await service.current(force: true)
    #expect(snapshot.tiboFeed?.posts.first?.id == "2107504197012988007")
  }

  @Test
  func newerChallengeProgressIsIncludedAlongsideOriginalPosts() async throws {
    let data = try Self.fixture("codex-radar-challenge-20261007.html")
      + Self.fixture("codex-radar-tibo-20261007.html")
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-07T03:02:01Z"))
    let service = CodexRadarService(
      fetcher: { throw CodexRadarError.server(503) },
      publicPageFetcher: { data },
      now: { now }
    )
    let snapshot = try await service.current(force: true)
    #expect(snapshot.tiboFeed?.posts.first?.id == "2107575657014468879")
    #expect(snapshot.tiboPresence?.latestActivityAt == ISO8601DateFormatter().date(from: "2026-10-06T20:56:08Z"))
    #expect(snapshot.tiboPresence?.latestActivityZh?.contains("简化 API") == true)
    #expect(snapshot.tiboFeed?.posts.first?.originalText == "")
    #expect(snapshot.probability24hPercent == 0)
  }

  @Test
  func originalResetWordingIsEvaluatedDespiteAnUnrelatedUpstreamLabel() async throws {
    // Synthetic wording verifies the actual service-to-scorer path. A site's
    // display label must not discard a reset announcement before evaluation.
    let data = Data(#"""
    <section class="desktop-tibo-radar" data-tibo-post-ids="2107504197012988007">
      <li class="reset-tibo-post" data-tibo-post-id="2107504197012988007" data-reset-relevance="none">
        <a href="https://x.com/thsottiaux/status/2107504197012988007">Tibo X</a>
        <time datetime="2026-10-07T02:00:00Z"></time>
        <p class="reset-tibo-post-original">We are doing a global hard reset today.</p>
      </li>
    </section>
    """#.utf8)
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-07T03:02:01Z"))
    let service = CodexRadarService(
      fetcher: { throw CodexRadarError.server(503) },
      publicPageFetcher: { data },
      now: { now }
    )
    let snapshot = try await service.current(force: true)
    #expect(snapshot.probability24hPercent == 65)
    #expect(snapshot.localResetEstimate?.signals.contains(where: { $0.contains("明确重置措辞") }) == true)
  }

  @Test
  func latestTimelineSurvivesRestartWhenThePublicSourceFails() async throws {
    let historyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("radar-latest-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: historyURL) }
    let data = try Self.fixture("codex-radar-challenge-20261007.html")
      + Self.fixture("codex-radar-tibo-20261007.html")
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-07T03:02:01Z"))
    let firstService = CodexRadarService(
      fetcher: { throw CodexRadarError.server(503) },
      publicPageFetcher: { data },
      now: { now },
      historyURL: historyURL
    )
    let live = try await firstService.current(force: true)
    let offlineService = CodexRadarService(
      fetcher: { throw CodexRadarError.server(503) },
      publicPageFetcher: { throw CodexRadarError.server(503) },
      now: { now.addingTimeInterval(60) },
      historyURL: historyURL
    )
    let cached = try await offlineService.current(force: true)
    let livePosts = try #require(live.tiboFeed?.posts)
    let cachedPosts = try #require(cached.tiboFeed?.posts)
    #expect(cachedPosts.map(\.id) == livePosts.map(\.id))
    #expect(cachedPosts.map(\.displayTextZh) == livePosts.map(\.displayTextZh))
    for (cachedPost, livePost) in zip(cachedPosts, livePosts) {
      if let cachedDate = cachedPost.publishedAt, let liveDate = livePost.publishedAt {
        // Existing on-disk ISO dates retain whole-second precision.
        #expect(abs(cachedDate.timeIntervalSince(liveDate)) < 1)
      }
    }
    #expect(cached.tiboPresence?.latestActivityAt == live.tiboPresence?.latestActivityAt)
    #expect(cached.syncState?.isUsingCachedFeed == true)
    #expect(cached.syncState?.lastSuccessAt == now)
  }

  @Test
  func challengeSummariesRejectOtherAuthorsAndDoNotReplaceOriginals() throws {
    let challenge = String(decoding: try Self.fixture("codex-radar-challenge-20261007.html"), as: UTF8.self)
      .replacingOccurrences(
        of: "x.com/thsottiaux/status/2107575657014468879",
        with: "x.com/not-tibo/status/2107575657014468879"
      )
    let data = Data(challenge.utf8) + (try Self.fixture("codex-radar-tibo-20261007.html"))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-07T03:02:01Z"))
    let page = try CodexRadarPublicPageParser.decode(data, now: now)
    #expect(page.tiboFeed.posts.contains(where: { $0.id == "2107575657014468879" }) == false)
    let autoReview = try #require(page.tiboFeed.posts.first(where: { $0.id == "2107368734981517634" }))
    #expect(autoReview.originalText.contains("Day 2.1/"))
    #expect(autoReview.isPublicSummary == false)
    #expect(page.tiboFeed.posts.filter { $0.id == autoReview.id }.count == 1)
  }
}
