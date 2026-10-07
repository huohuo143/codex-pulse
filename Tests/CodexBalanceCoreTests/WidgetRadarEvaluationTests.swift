import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Independent widget states and radar evaluation")
struct WidgetRadarEvaluationTests {
  @Test func coldStartRadarWaitIsPreservedUntilARealFeedSucceeds() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var value = CodexWidgetSnapshot(updatedAt: now)
    value.resetProbability24h = 40
    value.radarLevel = "等待数据"
    value.radarSyncStatus = "等待数据·自动重连中"
    value.radarConsecutiveFailures = 1
    value.radarIsUsingCachedFeed = true
    value.radarIsStale = true
    let waiting = value.effective(at: now)
    #expect(waiting.resetProbability24h == nil)
    #expect(waiting.radarLevel == "等待数据")
    #expect(waiting.radarSyncStatus == "等待数据·自动重连中")
    value.radarLastSuccessAt = now.addingTimeInterval(-91 * 60)
    #expect(value.effective(at: now).radarLevel == "数据过期")
  }

  @Test func contentChangesOnlyReloadRelatedKinds() {
    let original = CodexWidgetSnapshot(updatedAt: Date())
    var next = original
    next.updatedAt = next.updatedAt.addingTimeInterval(60)
    #expect(next.affectedKinds(comparedTo: original).isEmpty)
    next.resetProbability24h = 30
    #expect(next.affectedKinds(comparedTo: original) == [.radar, .overview])
    next = original; next.monthTokens = 10
    #expect(next.affectedKinds(comparedTo: original) == [.overview, .tokenSummary])
    next = original; next.showsFiveHourQuota = true
    #expect(next.affectedKinds(comparedTo: original) == [.overview, .quota])
    next = original; next.topProjects = [.init(label: "Project", tokens: 4)]
    #expect(next.affectedKinds(comparedTo: original) == [.workload])
    #expect(original.affectedKinds(comparedTo: nil).count == 7)
    var restored = original
    restored.usageUpdatedAt = original.updatedAt
    #expect(restored.affectedKinds(comparedTo: original) == [.overview, .tokenSummary, .tokenTrend, .workload])
    let policy = CodexWidgetReloadPolicy()
    #expect(policy.decision(needsReload: true, lastReloadAt: original.updatedAt, hasPendingReload: false, now: original.updatedAt.addingTimeInterval(10)) == .schedule(after: 50))
  }

  @Test func eachModuleExpiresIndependentlyAndTimelineCoversBoundaries() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var value = CodexWidgetSnapshot(updatedAt: now, remainingPercent: 80, resetsAt: now.addingTimeInterval(600), rolling24HoursTokens: 100,
      resetProbability24h: 40, radarLastSuccessAt: now, resetCreditsAvailable: 1,
      resetCredits: [.init(title: "Full reset", expiresAt: now.addingTimeInterval(120))])
    value.quotaRead = live(at: now.addingTimeInterval(-1801))
    value.resetCreditsRead = live(at: now)
    value.usageUpdatedAt = now
    value.confirmedCreditExpiry = now.addingTimeInterval(3600)
    let evaluated = value.effective(at: now)
    #expect(evaluated.remainingPercent == nil)
    #expect(evaluated.resetProbability24h == 40)
    #expect(evaluated.resetCreditsAvailable == 1)
    #expect(evaluated.usageState(at: now) == .fresh)
    #expect(value.effective(at: now.addingTimeInterval(120)).resetCreditsAvailable == 0)
    let dates = value.timelineDates(after: now)
    #expect(dates.contains(now.addingTimeInterval(120)))
    #expect(dates.contains(now.addingTimeInterval(600)))
    #expect(dates.contains(now.addingTimeInterval(3600)))
    #expect(dates.contains(now.addingTimeInterval(301)))
    #expect(!CodexWidgetSnapshotFreshness.isFromCurrentBoot(value, now: now.addingTimeInterval(10), systemUptime: 2))
    value.schemaVersion = 3
    #expect(value.usageState(at: now) == .unavailable)
    #expect(value.effective(at: now).resetProbability24h == nil)
  }

  @Test func publicationCoalescesUnchangedFilesButKeepsHeartbeat() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("widget.json")
    let publisher = WidgetSnapshotPublisher(urls: [file], liveURL: directory.appendingPathComponent("live.json"))
    // Snapshot JSON uses millisecond dates; compare deterministic whole seconds.
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    var value = CodexWidgetSnapshot(updatedAt: date)
    #expect(try await publisher.publish(value).count == 7)
    value.updatedAt = date.addingTimeInterval(20)
    #expect(try await publisher.publish(value).isEmpty)
    #expect(try CodexWidgetSnapshotStore.load(from: file).updatedAt == date)
    value.updatedAt = date.addingTimeInterval(60)
    #expect(try await publisher.publish(value).isEmpty)
    #expect(try CodexWidgetSnapshotStore.load(from: file).updatedAt == value.updatedAt)
  }

  @Test func unknownAndIncompleteOutcomesNeverBecomeNegativeScores() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let archive = RadarEvaluationArchive(root: directory, startedAt: start)
    let first = RadarArchivedForecast(predictedAt: start, probability: 0.8, ruleVersion: "fixture", evidence: ["fixture evidence"], sourceURLs: [])
    let second = RadarArchivedForecast(predictedAt: start, probability: 0.2, ruleVersion: "fixture", evidence: [], sourceURLs: [])
    try await archive.append(first, now: start)
    try await archive.append(second, now: start)
    #expect(await archive.summary(now: start.addingTimeInterval(90000)).sampleCount == 0)
    let early = RadarVerifiedOutcome(forecastID: first.id, occurred: true, eventAt: start.addingTimeInterval(10), observedThrough: start.addingTimeInterval(20), source: "fixture", recordedAt: start.addingTimeInterval(20), verified: true)
    await #expect(throws: RadarArchiveError.self) { try await archive.record(early, now: start.addingTimeInterval(20)) }
    let end = start.addingTimeInterval(86401)
    var positive = early
    positive.observedThrough = end; positive.recordedAt = end; positive.verified = false
    #expect(try await archive.record(positive, now: end).sampleCount == 0)
    positive.verified = true
    #expect(try await archive.record(positive, now: end).sampleCount == 1)
    let negative = RadarVerifiedOutcome(forecastID: second.id, occurred: false, eventAt: nil, observedThrough: end, source: "checked complete fixture window", recordedAt: end, verified: true)
    let result = try await archive.record(negative, now: end)
    #expect(result.sampleCount == 2)
    #expect(abs((result.brierScore ?? -1) - 0.04) < 0.000001)
    let restarted = RadarEvaluationArchive(root: directory, startedAt: end)
    #expect(await restarted.summary(now: end).sampleCount == 2)
    await #expect(throws: RadarArchiveError.self) { try await restarted.append(first, now: end) }
  }

  @Test func forecastExplainsCurrentSpeedPeaksAndLowBalance() {
    let now = Date()
    var value = QuotaForecast(generatedAt: now, currentRemainingPercent: 40, resetsAt: now.addingTimeInterval(86400), ratePerHour: 2,
      earliestExhaustion: now.addingTimeInterval(3600), estimatedExhaustion: now.addingTimeInterval(7200), latestExhaustion: now.addingTimeInterval(172800), risk: .critical)
    #expect(value.sustainabilitySummary.contains("撑不到"))
    #expect(value.riskExplanation.contains("当前速度"))
    #expect(value.riskExplanation.contains("预测区间"))
    value.currentRemainingPercent = 4
    #expect(value.riskExplanation.contains("5% 紧急"))
    value.estimatedExhaustion = now.addingTimeInterval(172800)
    #expect(value.sustainabilitySummary.contains("剩余额度较低"))
  }

  @Test func officialSourceAndClockCanBeReplacedWithoutNetwork() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reader = CodexStatusReader(sessionsRoot: URL(fileURLWithPath: "/unused-test-root"), clock: { now }, officialRead: { date in
      CodexStatus(generatedAt: date, codexHome: "fixture", sessionsRoot: "fixture")
    }, preferLiveStatus: false)
    #expect(try reader.readFast().generatedAt == now)
    #expect(reader.diagnostics.bytesRead == 0)
  }

  private func live(at date: Date) -> SourceReadMetadata {
    SourceReadMetadata(source: "fixture", sampledAt: date, lastAttemptAt: date, lastSuccessAt: date)
  }
}
