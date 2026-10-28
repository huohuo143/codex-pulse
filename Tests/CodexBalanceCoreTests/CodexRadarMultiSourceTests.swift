import Foundation
import Testing
import CodexMobileCore
@testable import CodexBalanceCore

@Suite("Multi-source Tibo discovery")
struct CodexRadarMultiSourceTests {
  private func bundle(at now: Date, primary: Bool = true) async -> TiboPublicFeedBundle {
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("mobile/tests/Fixtures/tibo-multisource")
    let client=TiboPublicFeedClient { source in
      if source == .codexradar && !primary { throw CodexRadarError.invalidPayload }
      let name: String
      switch source { case .codexradar: name="codexradar-lagging.html"; case .tiboreset: name="tiboreset-day20.html"; case .didcodexreset: name="didcodexreset-day20.json" }
      return try Data(contentsOf:root.appendingPathComponent(name))
    }
    return await client.refresh(at:now)
  }
  @Test func missedPostsReachMacAnalyzerAndKeepActualPublicationTime() async throws {
    let now=ISO8601DateFormatter().date(from:"2026-10-25T04:30:00Z")!
    let data=try JSONEncoder().encode(await bundle(at:now))
    let service=CodexRadarService(fetcher:{throw CodexRadarError.invalidPayload}, publicPageFetcher:{data}, now:{now}, analyzer:{ posts, date in
      #expect(posts.contains { $0.id == "2114200152701575656" && $0.originalText == "Day 20/ Rest and reset" })
      #expect(posts.contains { $0.id == "2114200291319124163" && $0.originalText == "By midnight PST" })
      return .init(state:.uncertain,kind:.uncertain,summaryZh:"等待核验原帖",timingZh:"",evidenceIDs:[],analyzedAt:date)
    })
    let result=try await service.current(force:true)
    #expect(result.tiboFeed?.posts.first?.id == "2114200291319124163")
    #expect(result.tiboFeed?.updatedAt == ISO8601DateFormatter().date(from:"2026-10-25T03:40:04Z"))
    #expect(result.tiboSourceChecks?.filter(\.succeeded).count == 3)
  }
  @Test func primaryOutageStillProducesAValidMacPage() async throws {
    let now=ISO8601DateFormatter().date(from:"2026-10-25T04:30:00Z")!
    let data=try JSONEncoder().encode(await bundle(at:now,primary:false))
    let page=try CodexRadarPublicPageParser.decode(data,now:now)
    #expect(page.tiboFeed.posts.first?.id == "2114200291319124163")
    #expect(page.sourceChecks?.filter(\.succeeded).count == 2)
    #expect(page.resetAt == nil)
    #expect(CodexRadarPublicPageParser.calendarData(data) == nil)
  }
}
