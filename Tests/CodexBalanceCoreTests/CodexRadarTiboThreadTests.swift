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
    var older = post("99"); older.publishedAt = .distantPast; older.threadContext = "Verified reset parent"
    let posts = (1...8).map { post(String($0)) } + [older]
    let result = await CodexRadarTiboThread.enrich(posts, previous: [older], activeDeadlineID: "99", fetcher: { _ in "new context" })
    #expect(result.last?.threadContext == "Verified reset parent")
    #expect(result.filter { $0.threadContext == "new context" }.count == 3)
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
