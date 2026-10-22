import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Reset day announcement recognition")
struct CodexRadarResetDayTests {
  private let date = ISO8601DateFormatter().date(from: "2026-10-22T06:55:22Z")!

  private func post(_ text: String, at date: Date? = nil, id: String = "2113162277688070445") -> CodexRadarTiboPost {
    CodexRadarTiboPost(id: id, url: URL(string: "https://x.com/thsottiaux/status/\(id)"),
      publishedAt: date ?? self.date, relevance: "direct", relevanceLabel: "直接信号",
      originalText: text, translationZh: nil, analysisZh: nil)
  }

  private func page(_ posts: [CodexRadarTiboPost]) -> CodexRadarPublicPageSnapshot {
    CodexRadarPublicPageSnapshot(judgement: .init(updatedAt: date, kind: "Tibo 动态",
      level: nil, headline: "根据 Tibo 公开动态本地估算", summary: "公开动态"),
      eventKind: "window_closed", eventStatus: "completed", confirmation: nil,
      resetAt: date.addingTimeInterval(-48 * 3600),
      tiboFeed: .init(updatedAt: date, posts: posts))
  }

  @Test
  func actualDay17AnnouncementOverridesOlderBankedExplanation() {
    let announcement = post("Day 17/ Bet you thought we forgot, but no, it’s reset day today.")
    let oldCard = post("A BANKED reset for everyone.", at: date.addingTimeInterval(-36 * 3600), id: "old-card")
    let result = CodexRadarResetScorer.estimate(from: page([announcement, oldCard]), now: date.addingTimeInterval(3 * 3600))
    #expect(result.probability24hPercent == 65)
    #expect(result.evidenceUpdatedAt == date)
    #expect(result.summary.contains("预告"))
    #expect(result.summary.contains("待确认"))
    #expect(!result.summary.contains("BANKED"))
  }

  @Test(arguments: ["It's reset day today.", "It is reset day today.", "Today is reset day."])
  func recognizesAffirmativeResetDayVariants(_ text: String) {
    let result = CodexRadarResetScorer.estimate(from: page([post(text)]), now: date)
    #expect(result.probability24hPercent == 65)
  }

  @Test(arguments: ["Is it reset day today?", "Today is not reset day.", "I don't think it's reset day today.",
    "Today is reset day for BANKED usage reset cards.", "Lands tomorrow before 10am PST.", "I demand a reset"])
  func doesNotInventCommitmentsOrReplyContext(_ text: String) {
    let result = CodexRadarResetScorer.estimate(from: page([post(text)]), now: date)
    #expect(result.probability24hPercent == 0)
  }

  @Test
  func expiryAndCompletedBoundaryStillClearAnnouncement() {
    let p = page([post("It's reset day today.")])
    let expired = CodexRadarResetScorer.estimate(from: p, now: date.addingTimeInterval(24 * 3600))
    #expect(expired.probability24hPercent == 0)
    #expect(expired.evidenceUpdatedAt == nil)
    var completed = p
    completed.resetAt = date.addingTimeInterval(3600)
    #expect(CodexRadarResetScorer.estimate(from: completed, now: date.addingTimeInterval(2 * 3600)).probability24hPercent == 0)
  }

  @Test
  func expiredBankedPostDoesNotDescribeCurrentState() {
    let p = page([post("A BANKED reset for everyone.", at: date.addingTimeInterval(-36 * 3600))])
    let result = CodexRadarResetScorer.estimate(from: p, now: date)
    #expect(result.probability24hPercent == 0)
    #expect(!result.summary.contains("BANKED"))
    #expect(result.summary.contains("不代表不会发生"))
  }
  @Test
  func openWindowWithoutTiboSignalDoesNotClaimZeroScore() {
    var p = page([])
    p.eventKind = "window_open"
    p.eventStatus = "active"
    let result = CodexRadarResetScorer.estimate(from: p, now: date)
    #expect(result.probability24hPercent == 90)
    #expect(!result.summary.contains("0%"))
    #expect(result.summary.contains("公开重置窗口"))
  }

}
