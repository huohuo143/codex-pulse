import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Day 21 reset wording and attention")
struct TiboDay21AttentionTests {
  private let now = ISO8601DateFormatter().date(from: "2026-10-26T06:10:00Z")!
  private let text = "Day 21/ Wonder what happens the remaining seven days. But today is a reset."
  private func post(_ id: String, text: String, secondsAgo: Double = 0) -> CodexRadarTiboPost {
    .init(id: id, url: URL(string: "https://x.com/thsottiaux/status/\(id)"),
      publishedAt: now.addingTimeInterval(-secondsAgo), relevance: "unknown", relevanceLabel: "待研判",
      originalText: text, translationZh: nil, analysisZh: nil)
  }

  @Test(arguments: [
    "Day 21/ Wonder what happens the remaining seven days. But today is a reset.",
    "Day 20/ Rest and reset", "But yes… that’s a reset!", "TODAY IS A RESET.",
    "Is there more to ship? But today is a reset.",
    "We did not ship today. But today is a reset."
  ])
  func recognizesClearStatementsIncludingTheirFinalSentence(_ value: String) {
    #expect(CodexRadarTiboAttention.containsResetKeyword(value))
    #expect(CodexRadarTiboAttention.isResetDayAnnouncement(value))
  }

  @Test(arguments: [
    "Not enough resets", "Today is not a reset.", "Today is a reset?", "If today is a reset, let me know.",
    "I wish today is a reset.", "Someone said today is a reset.", "Today is a banked reset.",
    "Today is reset day for BANKED usage reset cards.", "Lands tomorrow before 10am PST.",
    "Today is a resettable demo."
  ])
  func keywordOrSpeculationAloneCannotBecomeAnAnnouncement(_ value: String) {
    #expect(!CodexRadarTiboAttention.isResetDayAnnouncement(value))
  }

  @Test func xOriginalIsDirectEvenWithNoUpstreamClassification() throws {
    let raw = XTiboTimeline.Post(url: "https://x.com/thsottiaux/status/2114588174249071102",
      date: "2026-10-26T05:21:22Z", text: text)
    let html = try XTiboTimeline.feedHTML(posts: [raw], checkedAt: now)
    let page = try CodexRadarPublicPageParser.decode(html, now: now)
    let original = try #require(page.tiboFeed.posts.first)
    #expect(original.relevance == "direct")
    #expect(original.originalText == text)
    #expect(CodexRadarTiboAttention.label(for: original) == "明确重置表态")
    // Day 21 has an explicit declaration, even while yesterday's reset is closed.
    let estimate = CodexRadarResetScorer.estimate(from: page, now: now)
    #expect(estimate.probability24hPercent == 65)
    #expect(estimate.summary.contains("待确认"))
  }

  @Test func declarationStaysVisibleAndItsThreadIsReadAfterManyNewReplies() async {
    let declaration = post("2114588174249071102", text: text, secondsAgo: 2900)
    let newer = (1...9).map { post(String($0), text: "An ordinary product reply.", secondsAgo: Double($0)) }
    let posts = newer + [declaration]
    let preview = CodexRadarTiboAttention.previewPosts(posts, at: now)
    #expect(preview.map(\.id) == [declaration.id, "1", "2"])
    let enriched = await CodexRadarTiboThread.enrich(posts, previous: [], at: now, fetcher: { _ in "checked" })
    #expect(enriched.first { $0.id == declaration.id }?.threadContext == "checked")
    #expect(enriched.filter { $0.threadContext == "checked" }.count == 3)
    #expect(CodexRadarTiboAttention.previewPosts(posts, at: now.addingTimeInterval(86400)).first?.id == "1")
  }

  @Test func keywordIsAReviewCueAndModelReceivesFullDeclaration() throws {
    let joke = post("123", text: "Not enough resets")
    #expect(CodexRadarTiboAttention.label(for: joke) == "含 reset · 重点关注")
    #expect(!CodexRadarTiboAttention.containsResetKeyword("A preset menu"))
    let prompt = try CodexRadarTiboAnalyzer.prompt(posts: [joke, post("124", text: text)], at: now)
    #expect(prompt.contains(text))
    #expect(prompt.contains("resetKeyword"))
    #expect(prompt.contains("末句或 But 后的转折"))
    #expect(prompt.contains("attentionReason"))
    #expect(prompt.contains("同等证据地位"))
  }

  @Test func resetReplySurvivesNewerOrdinaryPostsAndGetsParentContext() async {
    let reply = post("500", text: "Not enough resets", secondsAgo: 3000)
    let timing = post("501", text: "By midnight PST", secondsAgo: 3100)
    let newer = (1...10).map { post(String($0), text: "An ordinary product reply.", secondsAgo: Double($0)) }
    let posts = newer + [reply, timing]
    #expect(CodexRadarTiboAttention.previewPosts(posts, at: now).map(\.id) == ["500", "501", "1"])
    let enriched = await CodexRadarTiboThread.enrich(posts, previous: [], at: now, fetcher: { _ in "Verified public parent context" })
    #expect(enriched.first { $0.id == reply.id }?.threadContext != nil)
    #expect(enriched.first { $0.id == timing.id }?.threadContext != nil)
    #expect(enriched.filter { $0.threadContext != nil }.count == 3)
    #expect(!CodexRadarTiboAttention.isResetDayAnnouncement(reply.originalText))
    #expect(CodexRadarTiboAttention.relatedCueLabel("Higher usage limits") == "额度线索 · 重点核验")
    #expect(CodexRadarTiboAttention.relatedCueLabel("It is all propagated") != nil)
    #expect(CodexRadarTiboAttention.relatedCueLabel("A preset menu and a landingpage") == nil)
    #expect(CodexRadarTiboAttention.previewPosts(posts, at: now.addingTimeInterval(86400)).first?.id == "1")
  }
}
