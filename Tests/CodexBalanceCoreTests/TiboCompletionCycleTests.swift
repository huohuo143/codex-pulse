import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Tibo completion display cycle")
struct TiboCompletionCycleTests {
  private let confirmed = Date(timeIntervalSince1970: 1_792_650_000)
  private func post(_ id: String, at date: Date, text: String) -> CodexRadarTiboPost {
    .init(id: id, url: nil, publishedAt: date, relevance: "direct", relevanceLabel: "", originalText: text, translationZh: nil, analysisZh: nil)
  }
  private func completed(at now: Date) throws -> CodexRadarTiboAnalysis {
    let data = Data(#"{"state":"completed","kind":"hard_reset","summaryZh":"Tibo 确认重置已执行。","timingZh":"","evidenceIDs":["done"],"completionEvidenceID":"done","deadline":null}"#.utf8)
    return try CodexRadarTiboAnalyzer.validate(data, posts: [post("done", at: confirmed, text: "Codex usage reset has now been applied to everyone.")], at: now)
  }
  private func snapshot(at now: Date, analysis: CodexRadarTiboAnalysis) throws -> CodexRadarSnapshot {
    var value = try JSONDecoder().decode(CodexRadarSnapshot.self, from: Data("{}".utf8))
    value.syncState = .init(lastAttemptAt: now, lastSuccessAt: now)
    value.tiboAnalysis = analysis
    return value
  }

  @Test func publicConfirmationCannotClaimPersonalEntitlementsOrArrival() throws {
    let now = confirmed.addingTimeInterval(120)
    var publicOnly = try snapshot(at: now, analysis: completed(at: now))
    #expect(publicOnly.tiboStatusTitle(at: now) == "Tibo确认重置")
    #expect(publicOnly.tiboStatusSummary(at: now).contains("本账号是否到账"))
    publicOnly.tiboAnalysis?.kind = .reset_card
    #expect(publicOnly.tiboStatusTitle(at: now) == "Tibo确认发卡")
    publicOnly.quotaResetConfirmedAt = confirmed
    #expect(publicOnly.tiboStatusTitle(at: now) == "重置已落实")
    #expect(publicOnly.tiboStatusSummary(at: now).contains("本账号官方额度已恢复"))
    #expect(publicOnly.tiboCompletionUntil(at: now) == confirmed.addingTimeInterval(86400))
  }

  @Test func countdownUsesConfirmationSourceAndNeverRestartsOnRefreshOrRestart() throws {
    let first = try completed(at: confirmed.addingTimeInterval(120))
    let second = try completed(at: confirmed.addingTimeInterval(600))
    #expect(first.completedAt == confirmed && second.completedAt == confirmed)
    let restored = try JSONDecoder().decode(CodexRadarTiboAnalysis.self, from: JSONEncoder().encode(second))
    let snap = try snapshot(at: confirmed.addingTimeInterval(600), analysis: restored)
    #expect(snap.tiboCompletionUntil(at: confirmed.addingTimeInterval(600)) == confirmed.addingTimeInterval(86400))
    #expect(snap.tiboStatusTitle(at: confirmed.addingTimeInterval(600)) == "Tibo确认重置")
  }

  @Test(arguments: [86399.0, 86400.0, 86401.0])
  func exactTwentyFourHourBoundaryStartsNewCycle(seconds: Double) throws {
    let now = confirmed.addingTimeInterval(seconds)
    let value = try snapshot(at: now, analysis: completed(at: now))
    #expect(value.tiboStatusTitle(at: now) == (seconds < 86400 ? "Tibo确认重置" : "等待新重置"))
    #expect((value.tiboCompletionUntil(at: now) != nil) == (seconds < 86400))
  }

  @Test func newAnnouncementImmediatelyReplacesCompletionAndCountdown() throws {
    let now = confirmed.addingTimeInterval(1800)
    let old = try snapshot(at: now, analysis: completed(at: now))
    #expect(old.tiboCompletionUntil(at: now) != nil)
    let data = Data(#"{"state":"announced","kind":"hard_reset","summaryZh":"有新一轮重置预告。","timingZh":"","evidenceIDs":["new"],"completionEvidenceID":null,"deadline":null}"#.utf8)
    let next = try CodexRadarTiboAnalyzer.validate(data, posts: [post("new", at: now, text: "Another Codex reset is coming today.")], at: now)
    let value = try snapshot(at: now, analysis: next)
    #expect(value.tiboHasAnnouncement(at: now))
    #expect(value.tiboStatusTitle(at: now) == "重置已预告")
    #expect(value.tiboCompletionUntil(at: now) == nil)
    var oldWidget = CodexWidgetSnapshot.preview
    oldWidget.radarCompletionUntil = confirmed.addingTimeInterval(86400)
    var newWidget = oldWidget; newWidget.radarCompletionUntil = nil; newWidget.radarAnnouncementActive = true
    #expect(newWidget.affectedKinds(comparedTo: oldWidget).contains(.radar))
    #expect(newWidget.affectedKinds(comparedTo: oldWidget).contains(.overview))
  }

  @Test func completionRequiresExplicitGroundedEvidenceAndRejectsFutureTimestamp() throws {
    let source = post("done", at: confirmed, text: "Reset applied.")
    for json in [
      #"{"state":"completed","kind":"hard_reset","summaryZh":"到账","timingZh":"","evidenceIDs":["done"]}"#,
      #"{"state":"completed","kind":"hard_reset","summaryZh":"到账","timingZh":"","evidenceIDs":["done"],"completionEvidenceID":"invented"}"#,
      #"{"state":"announced","kind":"hard_reset","summaryZh":"预告","timingZh":"","evidenceIDs":["done"],"completionEvidenceID":"done"}"#
    ] {
      #expect(throws: CodexRadarTiboAnalysisError.self) {
        try CodexRadarTiboAnalyzer.validate(Data(json.utf8), posts: [source], at: confirmed)
      }
    }
    #expect(throws: CodexRadarTiboAnalysisError.self) { try completed(at: confirmed.addingTimeInterval(-1)) }
  }

  @Test func widgetSchedulesCountdownEndAndDoesNotRestartItWhenRepublished() {
    let now = confirmed.addingTimeInterval(86300), until = confirmed.addingTimeInterval(86400)
    var widget = CodexWidgetSnapshot.preview
    widget.radarLevel = "重置已落实"; widget.radarCompletionUntil = until
    widget.radarLastSuccessAt = now; widget.radarValidUntil = now.addingTimeInterval(660)
    #expect(widget.timelineDates(after: now).contains(until))
    #expect(widget.effective(at: until.addingTimeInterval(-1)).radarLevel == "重置已落实")
    #expect(widget.effective(at: until).radarLevel == "等待新重置")
    #expect(widget.effective(at: until).radarCompletionUntil == nil)
    widget.updatedAt = now.addingTimeInterval(50)
    #expect(widget.radarCompletionUntil == until)
  }

  @Test func modelPromptPrioritizesNewAnnouncementsAndRequiresCompletionEvidence() throws {
    let prompt = try CodexRadarTiboAnalyzer.prompt(posts: [], at: confirmed)
    #expect(prompt.contains("新预告优先"))
    #expect(prompt.contains("completionEvidenceID"))
    #expect(prompt.contains("不能因上一轮 24 小时展示期尚未结束而忽略新预告"))
  }
}
