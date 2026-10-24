import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Reset arrival survives unrelated Tibo updates")
struct TiboAnnouncementBoundaryTests {
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  private var now: Date { date("2026-10-24T02:00:40Z") }
  private var arrival: Date { date("2026-10-23T17:41:17Z") }
  private var deadlinePostDate: Date { date("2026-10-23T04:47:34Z") }
  private var updateDate: Date { date("2026-10-23T23:12:31Z") }
  private var posts: [CodexRadarTiboPost] {
    [post("reset", at: date("2026-10-23T04:46:19Z"), text: "Day 18/ But yes, that's a reset!"),
     post("deadline", at: deadlinePostDate, text: "Landing tomorrow before 10am PST together with a small ship."),
     post("update", at: updateDate, text: "Day 19/ Small updates. Calls connect much faster; we've also updated the codex cli.")]
  }
  private func post(_ id: String, at date: Date, text: String) -> CodexRadarTiboPost {
    .init(id: id, url: nil, publishedAt: date, relevance: "direct", relevanceLabel: "",
      originalText: text, translationZh: nil, analysisZh: nil)
  }
  private var analysis: CodexRadarTiboAnalysis {
    .init(state: .announced, kind: .hard_reset, summaryZh: "Day 18 预告；Day 19 为普通产品更新。",
      timingZh: "", evidenceIDs: ["reset", "deadline", "update"], analyzedAt: now,
      deadline: .init(localDateTime: "2026-10-23T10:00:00", sourceTimeZone: "PST",
        evidenceID: "deadline", sourceQuote: "Landing tomorrow before 10am PST together with a small ship."))
  }
  private func snapshot(_ history: CodexRadarTiboHistory) throws -> CodexRadarSnapshot {
    var value = try JSONDecoder().decode(CodexRadarSnapshot.self, from: Data("{}".utf8))
    value.syncState = .init(lastAttemptAt: now, lastSuccessAt: now)
    value.tiboFeed = .init(updatedAt: now, posts: posts)
    value.tiboAnalysis = history.analysis
    value.tiboLatestAnnouncementAt = history.latestAnnouncementAt
    value.quotaResetConfirmedAt = CodexQuotaResetDetection.latestConfirmedAt(in: [
      .init(recordedAt: arrival.addingTimeInterval(-102), remainingPercent: 2,
        resetsAt: date("2026-10-29T17:12:12Z"), windowMinutes: 10080),
      .init(recordedAt: arrival, remainingPercent: 100,
        resetsAt: arrival.addingTimeInterval(7 * 86400 + 2), windowMinutes: 10080)
    ], now: now)
    return value
  }

  @Test func contextualProductUpdateMustNotBecomeANewAnnouncement() throws {
    var history = CodexRadarTiboHistory(resetAt: nil, posts: posts)
    history.analysis = analysis
    history.recordAnnouncement(at: now)
    #expect(history.latestAnnouncementAt == deadlinePostDate)
    let value = try snapshot(history)
    #expect(value.quotaResetConfirmedAt == arrival)
    #expect(value.tiboStatusTitle(at: now) == "重置已落地")
    #expect(!value.tiboHasAnnouncement(at: now))
    #expect(value.tiboCompletionUntil(at: now) == arrival.addingTimeInterval(86400))
    #expect(value.tiboDeadline(at: now) == nil)
  }

  @Test func upgradeRepairsPersistedBoundaryWithoutRestartingCountdown() throws {
    var history = CodexRadarTiboHistory(resetAt: nil, posts: posts)
    history.analysis = analysis
    history.latestAnnouncementAt = updateDate // Written by the previous version.
    let restored = try JSONDecoder().decode(CodexRadarTiboHistory.self, from: JSONEncoder().encode(history))
    var migrated = restored
    migrated.retainRecent(at: now)
    #expect(migrated.latestAnnouncementAt == deadlinePostDate)
    let value = try snapshot(migrated)
    #expect(value.tiboCompletionUntil(at: now) == arrival.addingTimeInterval(86400))
    #expect(value.tiboCompletionUntil(at: arrival.addingTimeInterval(86400)) == nil)
    #expect(value.tiboStatusTitle(at: arrival.addingTimeInterval(86400)) == "等待新重置")
  }

  @Test func modelPinsAnnouncementSeparatelyFromContextualEvidence() throws {
    let output = Data(#"{"state":"announced","kind":"hard_reset","summaryZh":"新的重置预告，产品更新仅供上下文对比。","timingZh":"","evidenceIDs":["reset","update"],"announcementEvidenceID":"reset"}"#.utf8)
    let validated = try CodexRadarTiboAnalyzer.validate(output, posts: posts, at: now)
    #expect(validated.announcementPublishedAt(in: posts, at: now) == posts[0].publishedAt)
    for invalid in ["invented", "deadline"] {
      let forged = String(decoding: output, as: UTF8.self)
        .replacingOccurrences(of: #""announcementEvidenceID":"reset""#, with: #""announcementEvidenceID":"\#(invalid)""#)
      #expect(throws: CodexRadarTiboAnalysisError.self) {
        try CodexRadarTiboAnalyzer.validate(Data(forged.utf8), posts: posts, at: now)
      }
    }
  }

  @Test func newAnchoredAnnouncementStillSupersedesArrivalAcrossRestartAndFailure() throws {
    var history = CodexRadarTiboHistory(resetAt: nil, posts: posts)
    history.analysis = analysis
    history.latestAnnouncementAt = updateDate
    history.recordAnnouncement(at: now)
    let newDate = arrival.addingTimeInterval(600)
    let newPost = post("next", at: newDate, text: "Another reset is coming today.")
    history.posts.append(newPost)
    history.analysis = .init(state: .announced, kind: .hard_reset, summaryZh: "新一轮重置预告。",
      timingZh: "", evidenceIDs: ["next", "update"], analyzedAt: now, announcementEvidenceID: "next")
    history.recordAnnouncement(at: now)
    #expect(history.latestAnnouncementAt == newDate)
    var value = try snapshot(history)
    value.tiboFeed?.posts.append(newPost)
    #expect(value.tiboStatusTitle(at: now) == "重置已预告")
    #expect(value.tiboCompletionUntil(at: now) == nil)
    history.analysis = nil
    var restored = try JSONDecoder().decode(CodexRadarTiboHistory.self, from: JSONEncoder().encode(history))
    restored.retainRecent(at: now)
    #expect(restored.latestAnnouncementAt == newDate)
    #expect(try snapshot(restored).tiboCompletionUntil(at: now) == nil)
  }

  @Test func ambiguousLegacyEvidenceCannotAssignProductUpdateTimestamp() {
    var ambiguous = analysis
    ambiguous.deadline = nil
    #expect(ambiguous.announcementPublishedAt(in: posts, at: now) == nil)
  }
}
