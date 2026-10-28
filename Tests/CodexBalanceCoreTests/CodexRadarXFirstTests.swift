import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("X first with public standby sources")
struct CodexRadarXFirstTests {
  let now = ISO8601DateFormatter().date(from: "2026-10-25T06:00:00Z")!
  let latest = ISO8601DateFormatter().date(from: "2026-10-25T03:40:04Z")!
  private func html(includeReply: Bool = true, mainText: String = "Day 20/ Rest and reset") throws -> Data {
    var posts = [XTiboTimeline.Post(url: "https://x.com/thsottiaux/status/2114200152701575656", date: "2026-10-25T03:39:31Z", text: mainText)]
    if includeReply { posts.append(.init(url: "https://x.com/thsottiaux/status/2114200291319124163", date: "2026-10-25T03:40:04Z", text: "By midnight PST")) }
    return try XTiboTimeline.feedHTML(posts: posts, checkedAt: now)
  }
  @Test func directSuccessDoesNotCallStandbyAndKeepsOriginalPublicationTime() async throws {
    let data = try html(), counter = XFirstCounter()
    let result = try await CodexRadarXFirstSource.fetch(x: { data }, backup: { await counter.increment(); throw CodexRadarError.server(503) }, now: now)
    let page = try CodexRadarPublicPageParser.decode(result, now: now)
    #expect(await counter.count == 0)
    #expect(page.readRoute?.xState == .success)
    #expect(page.readRoute?.usedBackup == false)
    #expect(page.tiboFeed.updatedAt == latest)
    #expect(page.tiboFeed.posts.count == 2)
    #expect(CodexRadarPublicPageParser.calendarData(result) == nil)
  }
  @Test(arguments: [XTiboTimeline.ReadError.loginRequired, .busy, .unavailable, .empty])
  func directFailureUsesStandbyWithoutClaimingXSuccess(error: XTiboTimeline.ReadError) async throws {
    let data = try html(), counter = XFirstCounter()
    let result = try await CodexRadarXFirstSource.fetch(x: { throw error }, backup: { await counter.increment(); return data }, now: now)
    let page = try CodexRadarPublicPageParser.decode(result, now: now)
    #expect(await counter.count == 1)
    #expect(page.readRoute?.xState != .success)
    #expect(page.readRoute?.usedBackup == true)
    #expect(page.readRoute?.backupSucceeded == true)
    #expect(page.tiboFeed.posts.first?.id == "2114200291319124163")
  }
  @Test func mediaOnlyLatestPostDoesNotTriggerFalseMissingPostFallback() async throws {
    let image = XTiboTimeline.Post(url: "https://x.com/thsottiaux/status/2114228445043691592",
      date: "2026-10-25T05:31:56Z", text: "", mediaKind: .image)
    let reply = XTiboTimeline.Post(url: "https://x.com/thsottiaux/status/2114200291319124163",
      date: "2026-10-25T03:40:04Z", text: "By midnight PST")
    let data = try XTiboTimeline.feedHTML(posts: [reply, image], checkedAt: now)
    let counter = XFirstCounter()
    let mediaDate = ISO8601DateFormatter().date(from: image.date)!
    let result = try await CodexRadarXFirstSource.fetch(x: { data }, backup: {
      await counter.increment(); throw CodexRadarError.server(503)
    }, now: now, knownLatest: mediaDate)
    let page = try CodexRadarPublicPageParser.decode(result, now: now)
    #expect(await counter.count == 0)
    #expect(page.readRoute?.xState == .success)
    #expect(page.readRoute?.xPostIDs == ["2114228445043691592", "2114200291319124163"])
    #expect(page.tiboFeed.posts.first?.originalText == "【仅图片帖：X 无文字正文；图片内容未读取】")
    #expect(page.tiboFeed.posts.last?.originalText == "By midnight PST")
    let blank = XTiboTimeline.Post(url: image.url, date: image.date, text: "")
    #expect(throws: (any Error).self) { try XTiboTimeline.feedHTML(posts: [blank], checkedAt: now) }
  }
  @Test func missingKnownReplyTriggersFallbackButXWordingWinsDuplicate() async throws {
    let direct = try html(includeReply: false), backup = try html(mainText: "A third-party altered title")
    let result = try await CodexRadarXFirstSource.fetch(x: { direct }, backup: { backup }, now: now, knownLatest: latest)
    let page = try CodexRadarPublicPageParser.decode(result, now: now)
    #expect(page.readRoute?.xState == .incomplete)
    #expect(page.tiboFeed.posts.count == 2)
    #expect(page.tiboFeed.posts.first?.id == "2114200291319124163")
    #expect(page.tiboFeed.posts.last?.originalText == "Day 20/ Rest and reset")
  }
  @Test func newestPostAloneDoesNotHideMissingRecentAnnouncement() async throws {
    let newest = XTiboTimeline.Post(url: "https://x.com/thsottiaux/status/2114228445043691592",
      date: "2026-10-25T05:31:56Z", text: "", mediaKind: .image)
    let direct = try XTiboTimeline.feedHTML(posts: [newest], checkedAt: now)
    let backup = try html()
    let result = try await CodexRadarXFirstSource.fetch(x: { direct }, backup: { backup }, now: now,
      knownLatest: latest, knownRecentPostIDs: ["2114200152701575656", "2114200291319124163"])
    let page = try CodexRadarPublicPageParser.decode(result, now: now)
    #expect(page.readRoute?.xState == .incomplete)
    #expect(page.readRoute?.backupSucceeded == true)
    #expect(page.readRoute?.xMissingKnownPostIDs?.count == 2)
    #expect(Set(page.tiboFeed.posts.map(\.id)) == ["2114228445043691592", "2114200152701575656", "2114200291319124163"])
  }
  @Test func originalPostPagesAcceptAuthorBoundRepliesAndRejectUnrelatedPages() throws {
    let post = XTiboTimeline.Post(url: "https://x.com/thsottiaux/status/2114200291319124163",
      date: "2026-10-25T03:40:04Z", text: "By midnight PST")
    let page = XTiboTimeline.Page(pageURL: post.url, requiresLogin: false, posts: [post])
    #expect(try XTiboTimeline.posts(from: JSONEncoder().encode(page), at: now) == [post])
    for url in ["https://x.com/other/status/123", "https://x.com/thsottiaux/status/123?x=1", "https://x.com.evil.test/thsottiaux/status/123"] {
      let invalid = XTiboTimeline.Page(pageURL: url, requiresLogin: false, posts: [post])
      #expect(throws: XTiboTimeline.ReadError.self) { try XTiboTimeline.posts(from: JSONEncoder().encode(invalid), at: now) }
    }
  }
  @Test func allSourcesFailRetainsExplicitFailedRouteAndCancellationNeverStartsBackup() async throws {
    let counter = XFirstCounter()
    let result = try await CodexRadarXFirstSource.fetch(x: { throw XTiboTimeline.ReadError.loginRequired }, backup: { throw CodexRadarError.server(503) }, now: now)
    #expect(TiboRoutedPage.decode(result)?.route.xState == .loginRequired)
    #expect(TiboRoutedPage.decode(result)?.route.backupSucceeded == false)
    #expect(throws: (any Error).self) { try CodexRadarPublicPageParser.decode(result, now: now) }
    do {
      _ = try await CodexRadarXFirstSource.fetch(x: { throw CancellationError() }, backup: { await counter.increment(); return Data() }, now: now)
      Issue.record("Cancellation must propagate")
    } catch is CancellationError {} catch { Issue.record("Unexpected error") }
    #expect(await counter.count == 0)
  }
  @Test func enablingXFirstPreservesHistoryAndSharedTenMinuteBudgetAcrossRestart() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("x-first-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let data = try html(), clock = now, counter = XFirstCounter()
    let original = CodexRadarService(fetcher: { throw CodexRadarError.server(503) }, publicPageFetcher: { data }, now: { clock }, historyURL: url, minimumFetchInterval: 600)
    _ = try await original.current(force: true)
    let replacement = CodexRadarService(fetcher: { throw CodexRadarError.server(503) }, publicPageFetcher: { await counter.increment(); return data }, now: { clock.addingTimeInterval(30) }, historyURL: url, minimumFetchInterval: 600, sourceIdentifier: { "x-first" })
    let waiting = try await replacement.current(force: true)
    #expect(await counter.count == 0)
    #expect(waiting.tiboFeed?.posts.count == 2)
    #expect(waiting.tiboReadRoute?.xState == .notChecked)
    #expect(waiting.syncState?.lastAttemptAt == clock)
  }
  @Test func serviceRecoversFromStandbyToDirectAndRetainsTimelineOnTotalFailure() async throws {
    let data = try html(), counter = XFirstCounter(), clock = XFirstClock(now)
    let service = CodexRadarService(fetcher: { throw CodexRadarError.server(503) }, publicPageFetcher: {
      let round = await counter.next()
      return try await CodexRadarXFirstSource.fetch(x: {
        if round == 2 { return data }
        throw XTiboTimeline.ReadError.loginRequired
      }, backup: {
        if round == 3 { throw CodexRadarError.server(503) }
        return data
      }, now: clock.get())
    }, now: { clock.get() }, minimumFetchInterval: 600, sourceIdentifier: { "x-first" })
    let fallback = try await service.current(force: true)
    #expect(fallback.tiboReadRoute?.usedBackup == true)
    #expect(fallback.tiboReadRoute?.backupSucceeded == true)
    clock.advance(600)
    let recovered = try await service.current(force: true)
    #expect(recovered.tiboReadRoute?.xState == .success)
    #expect(recovered.tiboReadRoute?.usedBackup == false)
    #expect(recovered.tiboSourceChecks == nil)
    clock.advance(600)
    let offline = try await service.current(force: true)
    #expect(offline.tiboReadRoute?.xState == .loginRequired)
    #expect(offline.tiboReadRoute?.backupSucceeded == false)
    #expect(offline.syncState?.consecutiveFailures == 1)
    #expect(offline.syncState?.lastSuccessAt == recovered.syncState?.lastSuccessAt)
    #expect(offline.tiboFeed?.posts.map(\.id) == recovered.tiboFeed?.posts.map(\.id))
  }
}

private actor XFirstCounter {
  var count = 0
  func increment() { count += 1 }
  func next() -> Int { count += 1; return count }
}

private final class XFirstClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date
  init(_ date: Date) { self.date = date }
  func get() -> Date { lock.lock(); defer { lock.unlock() }; return date }
  func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(interval) }
}
