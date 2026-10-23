import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Tibo public reply context")
struct CodexRadarTiboThreadTests {
  func post(_ id: String = "123") -> CodexRadarTiboPost {
    .init(id: id, url: URL(string: "https://x.com/thsottiaux/status/\(id)"), publishedAt: Date(timeIntervalSince1970: 1792652154), relevance: "direct", relevanceLabel: "", originalText: "Lands tomorrow before 10am PST.", translationZh: nil, analysisZh: nil)
  }
  @Test func validatesTargetAndKeepsParentRelationshipInModelInput() throws {
    var p = post()
    let raw = "URL Source: https://x.com/thsottiaux/status/123\nMarkdown Content:\n* [Tibo](https://x.com/thsottiaux/status/122) It’s reset day today.\n* Tibo: Lands tomorrow before 10am PST."
    p.threadContext = try CodexRadarTiboThread.validated(Data(raw.utf8), for: p)
    let prompt = try CodexRadarTiboAnalyzer.prompt(posts: [p], at: p.publishedAt!.addingTimeInterval(60))
    #expect(prompt.contains("threadContext"))
    #expect(prompt.contains("reset day today"))
    #expect(prompt.contains("不可信数据"))
    #expect(throws: CodexRadarError.self) { try CodexRadarTiboThread.validated(Data(raw.replacingOccurrences(of: "URL Source: https://x.com/thsottiaux/status/123", with: "URL Source: https://x.com/thsottiaux/status/999").utf8), for: p) }
    #expect(throws: CodexRadarError.self) { try CodexRadarTiboThread.validated(Data(raw.replacingOccurrences(of: p.originalText, with: "missing").utf8), for: p) }
  }
  @Test func cachesContextAndBoundsEachCheck() async throws {
    let posts = (1...8).map { post(String($0)) }
    let first = await CodexRadarTiboThread.enrich(posts, previous: [], fetcher: { _ in "context" })
    #expect(first.filter { $0.threadContext != nil }.count == 3)
    let persisted = try JSONDecoder().decode([CodexRadarTiboPost].self, from: JSONEncoder().encode(first))
    let second = await CodexRadarTiboThread.enrich(posts, previous: persisted, fetcher: { _ in "new context" })
    #expect(second.filter { $0.threadContext == "context" }.count == 3)
    #expect(second.filter { $0.threadContext != nil }.count == 6)
    var changed = posts[0]; changed.originalText = "Changed original"
    let refreshed = await CodexRadarTiboThread.enrich([changed], previous: persisted, fetcher: { _ in "replacement" })
    #expect(refreshed[0].threadContext == "replacement")
  }
  @Test func activeDeadlineContextSurvivesNewerUnrelatedPosts() async {
    let now = Date()
    var older = post("99"); older.publishedAt = .distantPast; older.threadContext = "Verified reset parent"
    older.threadContextCheckedAt = now; older.threadContextAttemptedAt = now
    let posts = (1...8).map { post(String($0)) } + [older]
    let result = await CodexRadarTiboThread.enrich(posts, previous: [older], activeDeadlineID: "99", at: now, fetcher: { _ in "new context" })
    #expect(result.last?.threadContext == "Verified reset parent")
    #expect(result.filter { $0.threadContext == "new context" }.count == 3)
  }

  @Test func unchangedOriginalStillRefreshesLaterRepliesAfterTenMinutes() async throws {
    let now = Date(timeIntervalSince1970: 1792653000)
    let p = post()
    let first = await CodexRadarTiboThread.enrich([p], previous: [], at: now, fetcher: { _ in "Original announcement" })
    // Exercise persisted timestamps, including the ISO date strategy used by history.
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let persisted = try decoder.decode([CodexRadarTiboPost].self, from: encoder.encode(first))
    let early = await CodexRadarTiboThread.enrich([p], previous: persisted, at: now.addingTimeInterval(599), fetcher: { _ in
      Issue.record("A supplementary request must not bypass the ten-minute budget")
      return "unexpected"
    })
    #expect(early.first?.threadContext == "Original announcement")
    let next = await CodexRadarTiboThread.enrich([p], previous: early, at: now.addingTimeInterval(600), fetcher: { _ in
      "Original announcement; Tibo added a deadline reply"
    })
    #expect(next.first?.threadContext?.contains("deadline reply") == true)
    #expect(next.first?.threadContextCheckedAt == now.addingTimeInterval(600))
    #expect(try CodexRadarTiboAnalyzer.prompt(posts: next, at: now.addingTimeInterval(600)).contains("threadContextCheckedAt"))
  }

  @Test func failedRefreshPreservesDeadlineContextWithoutAdvancingSuccess() async {
    let now = Date(timeIntervalSince1970: 1792653000)
    let first = await CodexRadarTiboThread.enrich([post()], previous: [], at: now, fetcher: { _ in "Verified reset parent and deadline" })
    let failed = await CodexRadarTiboThread.enrich([post()], previous: first, activeDeadlineID: "123", at: now.addingTimeInterval(600), fetcher: { _ in
      throw CodexRadarError.server(503)
    })
    #expect(failed.first?.threadContext == first.first?.threadContext)
    #expect(failed.first?.threadContextCheckedAt == now)
    #expect(failed.first?.threadContextAttemptedAt == now.addingTimeInterval(600))
  }

  @Test func pendingEvidenceIsRefreshedOutsideLatestSixAndOthersRotate() async {
    let now = Date(timeIntervalSince1970: 1792653000)
    var old = post("90"); old.publishedAt = now.addingTimeInterval(-86400)
    var deadline = old; deadline.id = "91"; deadline.url = URL(string: "https://x.com/thsottiaux/status/91")
    let posts = (1...8).map { post(String($0)) } + [old, deadline]
    var previous: [CodexRadarTiboPost] = []
    for round in 0..<6 {
      let date = now.addingTimeInterval(Double(round) * 600)
      previous = await CodexRadarTiboThread.enrich(posts, previous: previous, activeDeadlineID: "91", activeEvidenceIDs: ["91", "90"], at: date, fetcher: { p in "Updated thread \(p.id)" })
      #expect(previous.filter { $0.threadContextCheckedAt == date }.count == 3)
      #expect(previous.first { $0.id == "90" }?.threadContextCheckedAt == date)
      #expect(previous.first { $0.id == "91" }?.threadContextCheckedAt == date)
    }
    #expect(previous.filter { $0.threadContext != nil }.count == 8)
  }

  @Test func legacyContextWithoutTimestampIsRechecked() async {
    let now = Date(timeIntervalSince1970: 1792653000)
    var cached = post(); cached.threadContext = "Old indefinitely cached context"
    let result = await CodexRadarTiboThread.enrich([post()], previous: [cached], at: now, fetcher: { _ in "New public reply" })
    #expect(result.first?.threadContext == "New public reply")
    #expect(result.first?.threadContextCheckedAt == now)
  }
  @Test func realReplyRelativeDateUsesAuthorsStatedZone() throws {
    var p = post(); p.publishedAt = ISO8601DateFormatter().date(from: "2026-10-22T06:55:54Z")!
    let deadline = CodexRadarTiboDeadline(localDateTime: "2026-10-22T10:00:00", sourceTimeZone: "PST", evidenceID: p.id, sourceQuote: p.originalText)
    #expect(deadline.isGrounded(in: p))
    #expect(BalanceFormatters.beijingDeadline(try #require(deadline.date)) == "2026年10月23日 02:00")
    #expect(deadline.timeZoneClarification?.contains("10/23 01:00") == true)
    let wrong = CodexRadarTiboDeadline(localDateTime: "2026-10-23T10:00:00", sourceTimeZone: "PST", evidenceID: p.id, sourceQuote: p.originalText)
    #expect(!wrong.isGrounded(in: p))
  }
}
