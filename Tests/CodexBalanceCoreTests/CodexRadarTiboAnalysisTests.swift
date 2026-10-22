import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Tibo announcement analysis and ten-minute checks")
struct CodexRadarTiboAnalysisTests {
  private let date = Date(timeIntervalSince1970: 1_792_650_000)
  private func post(_ id: String = "123", date: Date? = nil, text: String = "It's reset day today.") -> CodexRadarTiboPost {
    .init(id: id, url: URL(string: "https://x.com/thsottiaux/status/\(id)"), publishedAt: date ?? self.date,
      relevance: "direct", relevanceLabel: "直接信号", originalText: text, translationZh: nil, analysisZh: nil)
  }
  private var output: Data {
    Data(#"{"state":"announced","kind":"hard_reset","summaryZh":"已明确预告重置，完成待确认。","timingZh":"","evidenceIDs":["123"]}"#.utf8)
  }
  private var page: Data {
    let stamp = ISO8601DateFormatter().string(from: date)
    return Data("""
      <section class="desktop-tibo-radar" data-tibo-posts-updated-at="\(stamp)">
      <li class="reset-tibo-post" data-tibo-post-id="123" data-reset-relevance="direct">
      <a href="https://x.com/thsottiaux/status/123">Tibo</a><time datetime="\(stamp)"></time>
      <p class="reset-tibo-post-original">It's reset day today.</p></li>
      <li class="reset-tibo-post" data-tibo-post-id="124" data-reset-relevance="direct">
      <a href="https://x.com/thsottiaux/status/124">Tibo</a><time datetime="\(stamp)"></time>
      <p class="reset-tibo-post-original">@reader We will reset usage tomorrow.</p></li>
      </section>
      """.utf8)
  }

  @Test func validatesModelEvidenceAndPinsRequestedModel() throws {
    let value = try CodexRadarTiboAnalyzer.validate(output, posts: [post()], at: date)
    #expect(value.title == "重置已预告")
    #expect(value.model == "gpt-6-astra")
    #expect(value.reasoningEffort == "high")
    #expect(value.analyzedAt == date)
    let fabricated = String(decoding: output, as: UTF8.self).replacingOccurrences(of: "123", with: "999")
    #expect(throws: CodexRadarTiboAnalysisError.self) {
      try CodexRadarTiboAnalyzer.validate(Data(fabricated.utf8), posts: [post()], at: date)
    }
    #expect(throws: CodexRadarTiboAnalysisError.self) {
      try CodexRadarTiboAnalyzer.validate(output, posts: [post(date: date.addingTimeInterval(-8 * 86400))], at: date)
    }
  }

  @Test func promptIncludesPostsAndRepliesAsUntrustedData() throws {
    let posts = [post(), post("124", text: "@reader We will reset usage tomorrow."),
      post("125", date: date.addingTimeInterval(-8 * 86400), text: "STALE_SENTINEL")]
    let prompt = try CodexRadarTiboAnalyzer.prompt(posts: posts, at: date)
    #expect(prompt.contains("It's reset day today."))
    #expect(prompt.contains("@reader We will reset usage tomorrow."))
    #expect(!prompt.contains("STALE_SENTINEL"))
    #expect(prompt.contains("不可信数据"))
    #expect(prompt.contains("禁止使用任何工具"))
    #expect(prompt.contains("不预测概率"))
  }

  @Test func sevenDayRetentionClearsOldPostsAnalysisAndAttempts() {
    let boundary = date.addingTimeInterval(-7 * 86400)
    let keep = post("123", date: boundary)
    let old = post("124", date: boundary.addingTimeInterval(-1))
    var history = CodexRadarTiboHistory(resetAt: date.addingTimeInterval(-20 * 86400), posts: [keep, old])
    history.latestPosts = [keep, old]
    history.analysis = .init(state: .announced, kind: .hard_reset, summaryZh: "旧分析", timingZh: "", evidenceIDs: ["124"], analyzedAt: boundary.addingTimeInterval(-1))
    history.analysisLastAttemptAt = boundary.addingTimeInterval(-1)
    history.analysisFailureMessage = "旧错误"
    history.recentSyncAttempts = [.init(startedAt: boundary.addingTimeInterval(-1), completedAt: boundary.addingTimeInterval(-1), succeeded: true)]
    history.retainRecent(at: date)
    #expect(history.posts.map(\.id) == ["123"])
    #expect(history.latestPosts?.map(\.id) == ["123"])
    #expect(history.analysis == nil && history.analysisLastAttemptAt == nil && history.analysisFailureMessage == nil)
    #expect(history.recentSyncAttempts?.isEmpty == true)
    #expect(history.resetAt != nil) // Retention is not a fabricated reset event.
  }

  @Test func manualRefreshRestartAndClearCacheShareTenMinuteBudget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TiboAnalysisClock(date), count = TiboAnalysisCounter(), page = page, output = output
    let historyURL = root.appendingPathComponent("history.json")
    let fetch: CodexRadarService.Fetcher = { await count.fetched(); return page }
    let analyze: CodexRadarService.Analyzer = { posts, now in
      await count.analyzed(posts.map(\.id)); return try CodexRadarTiboAnalyzer.validate(output, posts: posts, at: now)
    }
    let threadFetch: CodexRadarService.ThreadFetcher = { _ in await count.threadFetched(); return "verified public thread" }
    let service = CodexRadarService(fetcher: { throw CodexRadarError.invalidPayload }, publicPageFetcher: fetch,
      now: { clock.now() }, historyURL: historyURL, analyzer: analyze, minimumFetchInterval: 600, threadFetcher: threadFetch)
    let first = try await service.current(force: true)
    #expect(first.tiboStatusTitle(at: date) == "重置已预告")
    #expect(first.tiboRefreshIsHealthy(at: date))
    clock.advance(599)
    _ = try await service.current(force: true)
    await service.clearCache()
    _ = try await service.current(force: true)
    let restarted = CodexRadarService(fetcher: { throw CodexRadarError.invalidPayload }, publicPageFetcher: fetch,
      now: { clock.now() }, historyURL: historyURL, analyzer: analyze, minimumFetchInterval: 600, threadFetcher: threadFetch)
    let restored = try await restarted.current(force: true)
    #expect(restored.tiboAnalysis == first.tiboAnalysis)
    #expect(await count.threadFetches == 2)
    #expect(restored.tiboFeed?.posts.allSatisfy { $0.threadContext == "verified public thread" } == true)
    #expect(await count.fetches == 1)
    #expect(await count.analyses == 1)
    #expect(await count.lastIDs == ["124", "123"])
    clock.advance(1)
    _ = try await restarted.current(force: true)
    #expect(await count.threadFetches == 2) // Restart uses persisted contexts; no duplicate thread reads.
    #expect(await count.fetches == 2)
    #expect(await count.analyses == 2)
  }

  @Test func concurrentRefreshesDoNotDuplicateNetworkOrModelCalls() async throws {
    let count = TiboAnalysisCounter(), page = page, output = output, now = date
    let service = CodexRadarService(fetcher: { throw CodexRadarError.invalidPayload }, publicPageFetcher: {
      await count.fetched(); try await Task.sleep(for: .milliseconds(50)); return page
    }, now: { now }, analyzer: { posts, date in
      await count.analyzed(posts.map(\.id)); return try CodexRadarTiboAnalyzer.validate(output, posts: posts, at: date)
    }, minimumFetchInterval: 600)
    async let first = service.current(force: true)
    async let second = service.current(force: true)
    _ = try await (first, second)
    #expect(await count.fetches == 1)
    #expect(await count.analyses == 1)
  }

  @Test func failedNetworkWaitsTenMinutesAndDoesNotRunModel() async throws {
    let clock = TiboAnalysisClock(date), count = TiboAnalysisCounter()
    let service = CodexRadarService(fetcher: { throw CodexRadarError.invalidPayload }, publicPageFetcher: {
      await count.fetched(); throw URLError(.notConnectedToInternet)
    }, now: { clock.now() }, analyzer: { _, _ in
      await count.analyzed([]); throw CodexRadarTiboAnalysisError.failed
    }, minimumFetchInterval: 600)
    _ = try await service.current(force: true)
    clock.advance(599)
    let cached = try await service.current(force: true)
    #expect(!cached.tiboRefreshIsHealthy(at: clock.now()))
    #expect(await count.fetches == 1)
    #expect(await count.analyses == 0)
    clock.advance(1)
    _ = try await service.current(force: true)
    #expect(await count.fetches == 2)
    #expect(await count.analyses == 0)
  }

  @Test func modelFailureAndOldSuccessNeverShowHealthyGreen() async throws {
    let page = page, now = date
    let service = CodexRadarService(fetcher: { throw CodexRadarError.invalidPayload }, publicPageFetcher: { page },
      now: { now }, analyzer: { _, _ in throw CodexRadarTiboAnalysisError.failed }, minimumFetchInterval: 600)
    let failed = try await service.current(force: true)
    #expect(failed.syncState?.lastSuccessAt == now)
    #expect(failed.tiboStatusTitle(at: now) == "分析未成功")
    #expect(!failed.tiboRefreshIsHealthy(at: now))
    var healthy = failed
    healthy.tiboAnalysisFailure = nil
    healthy.tiboAnalysis = try CodexRadarTiboAnalyzer.validate(output, posts: [post()], at: now)
    #expect(healthy.tiboRefreshIsHealthy(at: now))
    #expect(!healthy.tiboRefreshIsHealthy(at: now.addingTimeInterval(11 * 60 + 1)))
  }
}

private actor TiboAnalysisCounter {
  var fetches = 0, analyses = 0, threadFetches = 0
  func threadFetched() { threadFetches += 1 }
  var lastIDs: [String] = []
  func fetched() { fetches += 1 }
  func analyzed(_ ids: [String]) { analyses += 1; lastIDs = ids }
}
private final class TiboAnalysisClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ date: Date) { value = date }
  func now() -> Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
