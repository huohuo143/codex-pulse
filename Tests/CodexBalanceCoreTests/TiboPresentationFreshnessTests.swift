import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Tibo status presentation freshness")
struct TiboPresentationFreshnessTests {
  private func snapshot(at now: Date, age: TimeInterval) throws -> CodexRadarSnapshot {
    var result = try JSONDecoder().decode(CodexRadarSnapshot.self, from: Data("{}".utf8))
    let success = now.addingTimeInterval(-age)
    result.syncState = .init(lastAttemptAt: success, lastSuccessAt: success, feedUpdatedAt: success,
      consecutiveFailures: 0, isUsingCachedFeed: false, isStale: false, failureMessage: nil)
    result.tiboAnalysis = .init(state: .announced, kind: .hard_reset, summaryZh: "OLD_ANNOUNCEMENT", timingZh: "", evidenceIDs: ["1"], analyzedAt: success)
    result.tiboAnalysisAttemptAt = success
    return result
  }

  @Test func expiredStatusCannotRemainAnnouncedWhenWidgetHasExpired() throws {
    let now = ISO8601DateFormatter().date(from: "2026-10-26T11:30:00+08:00")!
    let value = try snapshot(at: now, age: 12 * 60)
    var widget = CodexWidgetSnapshot.preview
    widget.radarLevel = value.tiboStatusTitle(at: now)
    widget.radarSummary = value.tiboStatusSummary(at: now)
    widget.radarLastSuccessAt = value.syncState?.lastSuccessAt
    widget.radarValidUntil = now.addingTimeInterval(-60)
    #expect(!value.tiboRefreshIsHealthy(at: now))
    #expect(widget.effective(at: now).radarLevel != "重置已预告")
    #expect(value.tiboStatusTitle(at: now) == "动态已过期")
    #expect(!value.tiboStatusSummary(at: now).contains("OLD_ANNOUNCEMENT"))
  }
  @Test(arguments: [659.999, 660.0, 661.0])
  func mainAndWidgetExpireAtTheSameBoundary(age: TimeInterval) throws {
    let now = ISO8601DateFormatter().date(from: "2026-10-26T11:30:00+08:00")!
    let value = try snapshot(at: now, age: age)
    var widget = CodexWidgetSnapshot.preview
    widget.radarLevel = "重置已预告"
    widget.radarSummary = "OLD_ANNOUNCEMENT"
    widget.radarSyncStatus = "刷新正常"
    widget.radarLastSuccessAt = value.syncState?.lastSuccessAt
    widget.radarValidUntil = value.tiboStatusValidUntil
    let current = age < 660
    #expect(value.tiboRefreshIsHealthy(at: now) == current)
    #expect(value.tiboStatusTitle(at: now) == (current ? "重置已预告" : "动态已过期"))
    #expect(widget.effective(at: now).radarLevel == value.tiboStatusTitle(at: now))
    if !current {
      #expect(widget.effective(at: now).radarSyncStatus != "刷新正常")
      #expect(!widget.effective(at: now).radarSummary!.contains("OLD_ANNOUNCEMENT"))
    }
    let before = try #require(value.syncState?.lastSuccessAt)
    #expect(widget.timelineDates(after: before).contains(try #require(value.tiboStatusValidUntil)))
  }

  @Test func freshSourceCannotMakeOlderOrUnfinishedAnalysisLookCurrent() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var value = try snapshot(at: now, age: 20)
    value.tiboAnalysis?.analyzedAt = now.addingTimeInterval(-30)
    value.tiboAnalysisAttemptAt = nil
    #expect(!value.tiboRefreshIsHealthy(at: now))
    #expect(value.tiboStatusTitle(at: now) == "等待分析")
    #expect(!value.tiboStatusSummary(at: now).contains("OLD_ANNOUNCEMENT"))
    value.tiboAnalysis?.analyzedAt = now.addingTimeInterval(-10)
    value.tiboAnalysisAttemptAt = now.addingTimeInterval(-5)
    #expect(value.tiboStatusTitle(at: now) == "等待分析")
    value.tiboAnalysis?.analyzedAt = now
    #expect(value.tiboStatusTitle(at: now) == "重置已预告")
  }

  @Test func futureTimestampsCannotShowHealthyOrAnnounced() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var value = try snapshot(at: now, age: -1)
    #expect(!value.tiboRefreshIsHealthy(at: now))
    #expect(value.tiboStatusTitle(at: now) == "动态已过期")
    value = try snapshot(at: now, age: 20)
    value.tiboAnalysis?.analyzedAt = now.addingTimeInterval(1)
    #expect(!value.tiboRefreshIsHealthy(at: now))
    #expect(value.tiboStatusTitle(at: now) == "等待分析")
  }

  @Test func failedFetchAndFailedAnalysisHideOldConclusion() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var value = try snapshot(at: now, age: 30)
    value.syncState?.consecutiveFailures = 1
    value.syncState?.failureMessage = "网络失败"
    #expect(value.tiboStatusTitle(at: now) == "动态未更新")
    #expect(value.tiboStatusSummary(at: now) == "网络失败")
    value.syncState?.consecutiveFailures = 0
    value.tiboAnalysisFailure = "模型失败"
    #expect(value.tiboStatusTitle(at: now) == "分析未成功")
    #expect(value.tiboStatusSummary(at: now) == "模型失败")
    #expect(!value.tiboRefreshIsHealthy(at: now))
  }

}
