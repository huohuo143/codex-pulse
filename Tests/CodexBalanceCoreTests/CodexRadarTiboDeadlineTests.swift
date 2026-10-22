import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Explicit Tibo reset deadlines in Beijing time")
struct CodexRadarTiboDeadlineTests {
  private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
  private func deadline(_ local: String = "2026-10-23T10:00:00", zone: String = "PST", quote: String = "The Codex reset will arrive by tomorrow 10am PST.") -> CodexRadarTiboDeadline {
    .init(localDateTime: local, sourceTimeZone: zone, evidenceID: "123", sourceQuote: quote)
  }
  private func post(_ text: String = "The Codex reset will arrive by tomorrow 10am PST.", published: String = "2026-10-22T16:00:00Z") -> CodexRadarTiboPost {
    .init(id: "123", url: URL(string: "https://x.com/thsottiaux/status/123"), publishedAt: instant(published),
      relevance: "direct", relevanceLabel: "", originalText: text, translationZh: nil, analysisZh: nil)
  }
  private func output(_ deadline: CodexRadarTiboDeadline?, state: CodexRadarTiboAnalysis.State = .announced) throws -> Data {
    try JSONEncoder().encode(CodexRadarTiboAnalysis(state: state, kind: .hard_reset, summaryZh: "重置已预告，到账待确认。", timingZh: "", evidenceIDs: ["123"], deadline: deadline))
  }

  @Test func explicitPSTUsesFixedOffsetEvenDuringDaylightSavingAndCrossesBeijingDay() throws {
    let value = try #require(deadline().date)
    #expect(value == instant("2026-10-23T18:00:00Z"))
    #expect(BalanceFormatters.beijingDeadline(value) == "2026年10月24日 02:00")
    #expect(BalanceFormatters.beijingDeadline(value, compact: true) == "10/24 02:00")
    #expect(deadline(zone: "PDT").date == instant("2026-10-23T17:00:00Z"))
    #expect(deadline(zone: "PT").date == instant("2026-10-23T17:00:00Z"))
    #expect(deadline("2026-12-31T10:00:00", zone: "PT").date == instant("2026-12-31T18:00:00Z"))
    #expect(BalanceFormatters.beijingDeadline(deadline("2026-12-31T10:00:00").date!) == "2027年1月1日 02:00")
  }

  @Test func rejectsAmbiguousAndNonexistentPacificTimesButAcceptsExplicitOffsets() {
    #expect(deadline("2026-11-01T01:30:00", zone: "PT").date == nil)
    #expect(deadline("2026-03-08T02:30:00", zone: "PT").date == nil)
    #expect(deadline("2026-11-01T01:30:00", zone: "PST").date == instant("2026-11-01T09:30:00Z"))
    #expect(deadline("2026-11-01T01:30:00", zone: "PDT").date == instant("2026-11-01T08:30:00Z"))
  }

  @Test(arguments: ["", "CST", "local time", "UTC+25:00", "UTC+14:30", "UTC+08:60", "Invalid/Zone"])
  func unknownOrInvalidZoneDoesNotProduceDeadline(zone: String) {
    #expect(deadline(zone: zone).date == nil)
  }

  @Test func supportedOffsetsAndInvalidDates() {
    #expect(deadline(zone: "UTC+08:00").date == instant("2026-10-23T02:00:00Z"))
    #expect(deadline(zone: "北京时间").date == instant("2026-10-23T02:00:00Z"))
    #expect(deadline(zone: "America/Los_Angeles").date == instant("2026-10-23T17:00:00Z"))
    #expect(deadline("2026-02-30T10:00:00").date == nil)
    #expect(deadline("2026-10-23T25:00:00").date == nil)
  }

  @Test func tomorrowIsAnchoredToPostLocalDateNotCheckDate() throws {
    // 06:55 UTC is still October 21 in literal PST.
    let source = post(published: "2026-10-22T06:55:54Z")
    let correct = deadline("2026-10-22T10:00:00")
    #expect(correct.isGrounded(in: source))
    #expect(!deadline("2026-10-23T10:00:00").isGrounded(in: source))
    // A deadline may be past at analysis time; this never implies completion.
    let value = try CodexRadarTiboAnalyzer.validate(output(correct), posts: [source], at: instant("2026-10-23T12:00:00Z"))
    #expect(value.state == .announced)
    #expect(value.deadline?.date == instant("2026-10-22T18:00:00Z"))
  }

  @Test func forgedQuoteWrongEvidenceMissingZoneAndCompletedStateAreRejected() throws {
    var wrongID = deadline(); wrongID.evidenceID = "999"
    for value in [wrongID, deadline(quote: "fabricated PST"), deadline(zone: "PDT"), deadline(zone: "PT")] {
      #expect(throws: CodexRadarTiboAnalysisError.self) {
        try CodexRadarTiboAnalyzer.validate(output(value), posts: [post()], at: instant("2026-10-22T17:00:00Z"))
      }
    }
    #expect(throws: CodexRadarTiboAnalysisError.self) {
      try CodexRadarTiboAnalyzer.validate(output(deadline(), state: .completed), posts: [post()], at: instant("2026-10-22T17:00:00Z"))
    }
    let accepted = try CodexRadarTiboAnalyzer.validate(output(deadline()), posts: [post()], at: instant("2026-10-22T17:00:00Z"))
    #expect(accepted.deadline?.date == instant("2026-10-23T18:00:00Z"))
  }

  @Test func staleFailedAndCompletedSnapshotsHideDeadline() throws {
    let now = instant("2026-10-22T17:00:00Z")
    var snapshot = try JSONDecoder().decode(CodexRadarSnapshot.self, from: Data("{}".utf8))
    snapshot.syncState = .init(lastAttemptAt: now, lastSuccessAt: now)
    snapshot.tiboAnalysis = try CodexRadarTiboAnalyzer.validate(output(deadline()), posts: [post()], at: now)
    #expect(snapshot.tiboDeadline(at: now) != nil)
    #expect(snapshot.tiboDeadline(at: now.addingTimeInterval(660)) == nil)
    snapshot.tiboAnalysisFailure = "failure"
    #expect(snapshot.tiboDeadline(at: now) == nil)
    snapshot.tiboAnalysisFailure = nil
    snapshot.tiboAnalysis?.state = .completed
    #expect(snapshot.tiboDeadline(at: now) == nil)
  }

  @Test func widgetDeadlineChangesTriggerReloadAndScheduleBoundaryThenExpire() {
    let now = instant("2026-10-22T17:00:00Z")
    var before = CodexWidgetSnapshot.preview
    before.radarLastSuccessAt = now; before.radarValidUntil = now.addingTimeInterval(660)
    before.radarIsStale = false; before.radarSyncStatus = "刷新正常"
    var after = before; after.radarDeadlineAt = now.addingTimeInterval(120)
    #expect(after.affectedKinds(comparedTo: before).contains(.radar))
    #expect(after.affectedKinds(comparedTo: before).contains(.overview))
    #expect(after.timelineDates(after: now).contains(after.radarDeadlineAt!))
    #expect(after.effective(at: now.addingTimeInterval(121)).radarLevel == "重置已预告")
    #expect(after.effective(at: now.addingTimeInterval(121)).radarDeadlineAt != nil)
    #expect(after.effective(at: now.addingTimeInterval(660)).radarDeadlineAt == nil)
    #expect(before.affectedKinds(comparedTo: after).contains(.radar))
  }

  @Test func olderSavedAnalysisAndWidgetDecodeWithoutDeadline() throws {
    let old = Data(#"{"state":"announced","kind":"hard_reset","summaryZh":"预告","timingZh":"","evidenceIDs":["123"]}"#.utf8)
    #expect(try JSONDecoder().decode(CodexRadarTiboAnalysis.self, from: old).deadline == nil)
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(CodexWidgetSnapshot.preview)) as? [String: Any])
    json.removeValue(forKey: "radarDeadlineAt")
    #expect(try JSONDecoder().decode(CodexWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: json)).radarDeadlineAt == nil)
  }
}
