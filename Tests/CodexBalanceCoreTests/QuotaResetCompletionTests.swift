import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Actual account reset completion")
struct QuotaResetCompletionTests {
  private let arrival = Date(timeIntervalSince1970: 1_800_000_000)
  private var rows: [QuotaSnapshot] {
    [QuotaSnapshot(recordedAt: arrival.addingTimeInterval(-300), remainingPercent: 5,
      resetsAt: arrival.addingTimeInterval(5 * 86400), windowMinutes: 10080),
     QuotaSnapshot(recordedAt: arrival, remainingPercent: 100,
      resetsAt: arrival.addingTimeInterval(7 * 86400 + 1), windowMinutes: 10080)]
  }
  private func snapshot(_ date: Date, postDate: Date? = nil) throws -> CodexRadarSnapshot {
    var value = try JSONDecoder().decode(CodexRadarSnapshot.self, from: Data("{}".utf8))
    value.syncState = .init(lastAttemptAt: date, lastSuccessAt: date)
    value.tiboAnalysis = .init(state: .announced, kind: .hard_reset, summaryZh: "旧预告", timingZh: "",
      evidenceIDs: ["announcement"], analyzedAt: date)
    value.tiboFeed = .init(updatedAt: date, posts: [.init(id: "announcement", url: nil,
      publishedAt: postDate ?? arrival.addingTimeInterval(-3600), relevance: "direct", relevanceLabel: "直接信号",
      originalText: "It is reset day today.", translationZh: nil, analysisZh: nil)])
    value.quotaResetConfirmedAt = CodexQuotaResetDetection.latestConfirmedAt(in: rows, now: date)
    return value
  }

  @Test func officialRefillClosesPendingAnnouncementAndRemovesDeadline() throws {
    let now = arrival.addingTimeInterval(600)
    var value = try snapshot(now)
    value.tiboAnalysis?.deadline = .init(localDateTime: "2026-10-22T10:00:00", sourceTimeZone: "PST", evidenceID: "announcement", sourceQuote: "before 10am PST")
    #expect(value.quotaResetConfirmedAt == arrival)
    #expect(value.tiboStatusTitle(at: now) == "重置已落实")
    #expect(value.tiboCompletionUntil(at: now) == arrival.addingTimeInterval(86400))
    #expect(!value.tiboHasAnnouncement(at: now))
    #expect(value.tiboDeadline(at: now) == nil)
    #expect(value.tiboStatusSummary(at: now).contains("本账号官方额度"))
  }

  @Test func refreshAndHistoryReloadKeepOriginalTwentyFourHourBoundary() throws {
    let stored = try JSONDecoder().decode([QuotaSnapshot].self, from: JSONEncoder().encode(rows))
    for age in [600.0, 3600.0, 86399.0, 86400.0, 86401.0] {
      let now = arrival.addingTimeInterval(age)
      var value = try snapshot(now)
      value.quotaResetConfirmedAt = CodexQuotaResetDetection.latestConfirmedAt(in: stored, now: now)
      #expect(value.tiboCompletionUntil(at: now) == (age < 86400 ? arrival.addingTimeInterval(86400) : nil))
      #expect(value.tiboStatusTitle(at: now) == (age < 86400 ? "重置已落实" : "等待新重置"))
    }
  }

  @Test func newAnnouncementPreemptsLocalCompletionButOldReanalysisDoesNot() throws {
    let now = arrival.addingTimeInterval(900)
    let old = try snapshot(now)
    #expect(old.tiboStatusTitle(at: now) == "重置已落实")
    let next = try snapshot(now, postDate: arrival.addingTimeInterval(600))
    #expect(next.tiboStatusTitle(at: now) == "重置已预告")
    #expect(next.tiboCompletionUntil(at: now) == nil)
    #expect(next.tiboHasAnnouncement(at: now))
  }

  @Test func failedFeedOrModelDoesNotEraseConfirmedArrivalOrReportHealthyRefresh() throws {
    let now = arrival.addingTimeInterval(1200)
    var value = try snapshot(now)
    value.syncState?.lastSuccessAt = arrival.addingTimeInterval(-7200)
    value.syncState?.consecutiveFailures = 2
    value.syncState?.isStale = true
    value.tiboAnalysisFailure = "模型失败"
    #expect(!value.tiboRefreshIsHealthy(at: now))
    #expect(value.tiboStatusTitle(at: now) == "重置已落实")
    #expect(value.tiboCompletionUntil(at: now) == arrival.addingTimeInterval(86400))
    var widget = CodexWidgetSnapshot(updatedAt: now, radarLevel: value.tiboStatusTitle(at: now),
      radarSummary: value.tiboStatusSummary(at: now), radarLastSuccessAt: arrival.addingTimeInterval(-7200),
      radarValidUntil: arrival, radarSyncStatus: "等待刷新", radarIsStale: true)
    widget.radarCompletionUntil = value.tiboCompletionUntil(at: now)
    let restored = try JSONDecoder().decode(CodexWidgetSnapshot.self, from: JSONEncoder().encode(widget))
    #expect(restored.effective(at: now).radarLevel == "重置已落实")
    #expect(restored.effective(at: now).radarCompletionUntil == arrival.addingTimeInterval(86400))
    #expect(restored.effective(at: arrival.addingTimeInterval(86400)).radarLevel == "等待新重置")
  }

  @Test func nearFullAccountStillRecognizesARealNewWeeklyWindow() {
    var samples = rows
    samples[0].remainingPercent = 95
    #expect(CodexQuotaResetDetection.latestConfirmedAt(in: samples, now: arrival) == arrival)
  }

  @Test(arguments: ["percentageCorrection", "normalRollover", "noRefill", "windowCorrection", "longGap", "fiveHour", "future", "nan"])
  func unrelatedQuotaChangesDoNotFabricateCompletion(mode: String) {
    var samples = rows
    switch mode {
    case "percentageCorrection": samples[1].resetsAt = samples[0].resetsAt
    case "normalRollover": samples[0].resetsAt = arrival
    case "noRefill": samples[0].remainingPercent = 100
    case "windowCorrection": samples[1].resetsAt = arrival.addingTimeInterval(4 * 86400)
    case "longGap": samples[0].recordedAt = arrival.addingTimeInterval(-3600)
    case "fiveHour": samples[0].windowMinutes = 300; samples[1].windowMinutes = 300
    case "future": samples[1].recordedAt = arrival.addingTimeInterval(60)
    default: samples[1].remainingPercent = .nan
    }
    #expect(CodexQuotaResetDetection.latestConfirmedAt(in: samples, now: arrival) == nil)
  }
}
