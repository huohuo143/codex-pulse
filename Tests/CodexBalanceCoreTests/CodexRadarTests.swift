import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Codex Radar integration")
struct CodexRadarTests {
  @Test
  func decodesCodexOnlyProbabilityAnalysisAndTiboPresence() throws {
    let snapshot = try CodexRadarCodec.decode(Self.fixture)

    #expect(snapshot.service == "codex-reset-radar")
    #expect(snapshot.probability24hPercent == 86)
    #expect(snapshot.prediction?.probability48h == 0.93)
    #expect(snapshot.prediction?.levelLabel == "高概率")
    #expect(snapshot.prediction?.summary == "Tibo 正在公开试探下一次 Codex usage reset。")
    #expect(snapshot.tiboPresence?.timezone == "America/Los_Angeles")
    #expect(snapshot.tiboPresence?.locationLabelZh == "旧金山湾区 / PT")
    #expect(snapshot.tiboPresence?.handle == "@thsottiaux")
    #expect(snapshot.tiboPresence?.latestActivityZh?.contains("900 万") == true)
    #expect(snapshot.tiboPresence?.latestActivityAt != nil)
    #expect(snapshot.tiboPresence?.shouldDisplay == true)
    #expect(snapshot.latestUpdate != nil)
  }

  @Test
  func decodesWrappedFullAPIResponse() throws {
    let wrapped = Data("{\"data\":\(String(decoding: Self.fixture, as: UTF8.self))}".utf8)
    let snapshot = try CodexRadarCodec.decode(wrapped)
    #expect(snapshot.probability24hPercent == 86)
  }

  @Test
  func decodesMiniProgramDashboardAtEightyTwoPercent() throws {
    let snapshot = try CodexRadarCodec.decode(Self.miniProgramDashboardFixture)

    #expect(snapshot.service == "reset-radar-mini-program")
    #expect(snapshot.probability24hPercent == 82)
    #expect(snapshot.prediction?.levelLabel == "高概率")
    #expect(snapshot.prediction?.summary?.contains("900 万") == true)
    #expect(snapshot.tiboPresence?.handle == "@thsottiaux")
    #expect(snapshot.tiboPresence?.latestActivityZh?.contains("再次重置") == true)

    var shanghaiCalendar = Calendar(identifier: .gregorian)
    shanghaiCalendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let components = shanghaiCalendar.dateComponents(
      [.year, .month, .day, .hour, .minute],
      from: try #require(snapshot.probabilityUpdate)
    )
    #expect(components.year == 2026)
    #expect(components.month == 7)
    #expect(components.day == 15)
    #expect(components.hour == 18)
    #expect(components.minute == 21)
  }

  @Test
  func serviceCachesForThirtyMinutesAndForceBypassesCache() async throws {
    let counter = RadarFetchCounter()
    let fixedNow = try #require(ISO8601DateFormatter().date(from: "2026-07-15T08:00:00Z"))
    let clock = RadarTestClock(fixedNow)
    let service = CodexRadarService(
      fetcher: {
        await counter.increment()
        return Self.fixture
      },
      now: { clock.now() }
    )

    _ = try await service.current()
    clock.advance(by: 29 * 60 + 59)
    _ = try await service.current()
    #expect(await counter.value == 1)
    clock.advance(by: 1)
    _ = try await service.current()
    #expect(await counter.value == 2)
    _ = try await service.current(force: true)
    #expect(await counter.value == 3)
    #expect(CodexRadarService.refreshInterval == 30 * 60)
  }

  @Test
  func serviceUsesPublicSummaryWithoutCredentials() async throws {
    let service = CodexRadarService(fetcher: { Self.miniProgramDashboardFixture })
    let snapshot = try await service.current()
    #expect(snapshot.probability24hPercent == 82)
    #expect(CodexRadarService.endpointURL.absoluteString == "https://codexradar.com/")
    #expect(CodexRadarService.fullAPIURL.absoluteString == "https://codexradar.com/api/v1/current")
    #expect(CodexRadarService.publicSummaryModeText.contains("无需 API Key"))
    #expect(CodexRadarService.publicSummaryModeText.contains("X Cookie"))
  }

  @Test
  func olderPayloadCannotOverwriteNewerMiniProgramProbability() async throws {
    let sequence = RadarFixtureSequence([
      Self.miniProgramDashboardFixture,
      Self.stalePublicJSONFixture
    ])
    let service = CodexRadarService(
      fetcher: { await sequence.next() },
      cacheDuration: 0
    )

    let first = try await service.current()
    let second = try await service.current(force: true)

    #expect(first.probability24hPercent == 82)
    #expect(second.probability24hPercent == 82)
    #expect(second.probabilityUpdate == first.probabilityUpdate)
  }

  @Test
  func serviceMergesNewerHomepageJudgementWithoutChangingOlderProbability() async throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
    let service = CodexRadarService(
      fetcher: { Self.fixture },
      publicPageFetcher: { Self.publicPageFixture },
      now: { now }
    )

    let snapshot = try await service.current()
    #expect(snapshot.probability24hPercent == 86)
    #expect(snapshot.prediction?.updatedAt != snapshot.publicJudgement?.updatedAt)
    #expect(snapshot.publicJudgement?.kind == "硬重置")
    #expect(snapshot.publicJudgement?.level == "medium_high")
    #expect(snapshot.latestLevelLabel == "中高概率")
    #expect(snapshot.latestSummary?.contains("公开询问是否再次重置") == true)
    #expect(snapshot.publicJudgementIsNewer)
    #expect(snapshot.latestUpdate == snapshot.publicJudgement?.updatedAt)

    var shanghaiCalendar = Calendar(identifier: .gregorian)
    shanghaiCalendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let components = shanghaiCalendar.dateComponents(
      [.year, .month, .day, .hour, .minute],
      from: try #require(snapshot.publicJudgement?.updatedAt)
    )
    #expect(components.year == 2026)
    #expect(components.month == 7)
    #expect(components.day == 15)
    #expect(components.hour == 19)
    #expect(components.minute == 40)
  }

  @Test
  func serviceReportsPublicSummaryAccessFailure() async {
    let denied = CodexRadarService(fetcher: {
      throw CodexRadarError.accessDenied
    })
    await #expect(throws: CodexRadarError.accessDenied) {
      _ = try await denied.current()
    }
  }

  @Test
  func productLaunchAndCapacityLanguageDoNotPredictGlobalHardReset() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-30T03:00:00Z"))
    let page = try CodexRadarPublicPageParser.decode(Self.currentPublicPageFixture, now: now)
    let estimate = CodexRadarResetScorer.estimate(from: page, now: now)

    #expect(page.eventKind == "window_closed")
    #expect(page.eventStatus == "completed")
    #expect(page.tiboFeed.posts.count == 3)
    let firstPost = try #require(page.tiboFeed.posts.first)
    #expect(firstPost.kindLabel == "Reply")
    #expect(firstPost.relevance == "indirect")
    #expect(firstPost.translationZh?.contains("智能体") == true)
    #expect(firstPost.url?.absoluteString.contains("2082982139948380465") == true)
    #expect(firstPost.isResetRelevantForDisplay == false)
    #expect(estimate.probability24hPercent == 0)
    #expect(estimate.level == "very_low")
    #expect(estimate.signals.contains(where: { $0.contains("窗口基准 0%") }))
    #expect(estimate.signals.contains(where: { $0.contains("Tibo 状态 +0%") }))
    #expect(estimate.signals.contains(where: { $0.contains("发布预告") }) == false)
    #expect(estimate.signals.contains(where: { $0.contains("低成本 / 高供给") }) == false)
    #expect(estimate.signals.contains(where: { $0.contains("明确重置措辞") }) == false)
    #expect(estimate.evidenceUpdatedAt == nil)
  }

  @Test
  func parsesCurrentTiboOnlyHomepageAndKeepsBankedResetSeparate() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-21T14:00:00Z"))
    var page = try CodexRadarPublicPageParser.decode(Self.currentTiboOnlyPageFixture, now: now)
    page.resetAt = ISO8601DateFormatter().date(from: "2026-08-13T04:40:53Z")
    page.eventKind = "window_closed"
    page.eventStatus = "completed"
    let estimate = CodexRadarResetScorer.estimate(from: page, now: now)

    #expect(page.judgement.kind == "Tibo 动态")
    #expect(page.tiboFeed.posts.count == 2)
    #expect(page.tiboFeed.posts.first?.originalText.contains("BANKED reset") == true)
    #expect(estimate.probability24hPercent == 0)
    #expect(estimate.signals.contains(where: { $0.contains("BANKED reset") }))
    #expect(estimate.signals.contains(where: { $0.contains("Tibo 状态 +0%") }))
    #expect(estimate.signals.contains(where: { $0.contains("明确重置措辞") }) == false)
    #expect(estimate.summary.contains("不等于全局硬重置"))
  }

  @Test
  func bankedUsageResetWordingIsStillAlwaysExcluded() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-21T14:00:00Z"))
    let html = String(decoding: Self.currentTiboOnlyPageFixture, as: UTF8.self)
      .replacingOccurrences(of: "BANKED reset", with: "BANKED usage reset")
    var page = try CodexRadarPublicPageParser.decode(Data(html.utf8), now: now)
    page.resetAt = ISO8601DateFormatter().date(from: "2026-08-13T04:40:53Z")
    page.eventKind = "window_closed"
    page.eventStatus = "completed"

    let estimate = CodexRadarResetScorer.estimate(from: page, now: now)

    #expect(estimate.probability24hPercent == 0)
    #expect(estimate.signals.contains(where: { $0.contains("明确重置措辞") }) == false)
  }

  @Test
  func currentTiboPostsOverrideStaleRemoteProbabilityWithLocalEstimate() async throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-21T14:00:00Z"))
    let service = CodexRadarService(
      fetcher: { Self.staleRadarWithCompletedWindowFixture },
      publicPageFetcher: { Self.currentTiboOnlyPageFixture },
      now: { now }
    )

    let snapshot = try await service.current()

    #expect(snapshot.prediction?.probability24h == 0.14)
    #expect(snapshot.localResetEstimate != nil)
    #expect(snapshot.probability24hPercent == 0)
    #expect(snapshot.probabilityUpdate == now)
    #expect(snapshot.localResetEstimate?.evidenceUpdatedAt == nil)
    #expect(snapshot.tiboFeed?.posts.count == 2)
    #expect(snapshot.tiboPresence?.latestActivityZh?.contains("恭喜") == true)
    #expect(snapshot.tiboFeed?.posts.contains(where: { $0.translationZh?.contains("可储存") == true }) == true)
    #expect(snapshot.latestSummary?.contains("不等于全局硬重置") == true)
  }

  @Test
  func resetButtonTomorrowPostProducesContextualTwentyFourHourEstimate() async throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-27T06:40:00Z"))
    let service = CodexRadarService(
      fetcher: { Self.staleRadarWithCompletedWindowFixture },
      publicPageFetcher: { Self.resetButtonTomorrowPageFixture },
      now: { now }
    )

    let snapshot = try await service.current(force: true)

    #expect(snapshot.tiboFeed?.posts.map(\.id) == ["2092862554632826968"])
    #expect(snapshot.probability24hPercent == 60)
    #expect(snapshot.latestLevelLabel == "中高概率")
    #expect(snapshot.localResetEstimate?.signals.contains(where: {
      $0.contains("含歧义的重置时点暗示 +55%")
    }) == true)
    #expect(snapshot.latestSummary?.contains("明天") == true)
    #expect(snapshot.latestSummary?.contains("未明确承诺") == true)
  }

  @Test
  func directLabelWithoutNearTermSemanticsDoesNotCreateProbability() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-09-04T07:00:00Z"))
    let html = #"""
    <!doctype html>
    <section class="desktop-tibo-radar" aria-label="Tibo 雷达"
      data-tibo-post-ids="2094293383573545000"
      data-tibo-posts-updated-at="2026-08-31T13:17:07+08:00">
      <ol class="reset-tibo-posts">
        <li class="reset-tibo-post" data-tibo-post-id="2094293383573545000" data-reset-relevance="direct">
          <a href="https://x.com/thsottiaux/status/2094293383573545000">Tibo X</a>
          <time datetime="2026-08-31T13:17:07+08:00">8月31日 13:17</time>
          <span class="reset-tibo-post-relevance">直接信号</span>
          <p class="reset-tibo-post-original"><b>英文原文</b>@melvindvivas I try to pre-announce them these days when I can</p>
          <p class="reset-tibo-post-translation"><b>中文翻译</b>@melvindvivas 现在只要条件允许，我都会尽量提前通知这些重置。</p>
        </li>
      </ol>
    </section>
    """#
    var page = try CodexRadarPublicPageParser.decode(Data(html.utf8), now: now)
    page.resetAt = ISO8601DateFormatter().date(from: "2026-08-31T02:34:27Z")
    page.eventKind = "window_closed"
    page.eventStatus = "completed"

    let estimate = CodexRadarResetScorer.estimate(from: page, now: now)

    #expect(estimate.probability24hPercent == 0)
    #expect(estimate.signals.contains(where: { $0.contains("Tibo 状态 +0%") }))
  }

  @Test
  func contextualTomorrowSignalExpiresAfterItsPTTargetDay() throws {
    let initialNow = try #require(ISO8601DateFormatter().date(from: "2026-08-27T06:40:00Z"))
    let expiredNow = try #require(ISO8601DateFormatter().date(from: "2026-08-28T07:01:00Z"))
    let page = try CodexRadarPublicPageParser.decode(Self.resetButtonTomorrowPageFixture, now: initialNow)

    let fresh = CodexRadarResetScorer.estimate(from: page, now: initialNow)
    let expired = CodexRadarResetScorer.estimate(from: page, now: expiredNow)

    #expect(fresh.probability24hPercent == 60)
    #expect(expired.probability24hPercent == 0)
  }

  @Test
  func ordinaryNearTermSignalDecaysAtSixTwelveAndTwentyFourHours() throws {
    let publishedAt = try #require(ISO8601DateFormatter().date(from: "2026-09-03T00:00:00Z"))
    let post = CodexRadarTiboPost(
      id: "2095000000000000001",
      url: URL(string: "https://x.com/thsottiaux/status/2095000000000000001"),
      publishedAt: publishedAt,
      relevance: "direct",
      relevanceLabel: "直接信号",
      originalText: "We may do a global usage reset within 24 hours.",
      translationZh: "我们可能在 24 小时内进行全局用量重置。",
      analysisZh: nil
    )
    let page = CodexRadarPublicPageSnapshot(
      judgement: CodexRadarPublicJudgement(
        updatedAt: publishedAt,
        kind: "Tibo 动态",
        level: nil,
        headline: "本地时效测试",
        summary: "固定时钟回归样本。"
      ),
      eventKind: "window_closed",
      eventStatus: "completed",
      confirmation: nil,
      resetAt: publishedAt.addingTimeInterval(-60),
      tiboFeed: CodexRadarTiboFeed(updatedAt: publishedAt, posts: [post])
    )

    let atSixHours = CodexRadarResetScorer.estimate(
      from: page,
      now: publishedAt.addingTimeInterval(6 * 60 * 60)
    )
    let atTwelveHours = CodexRadarResetScorer.estimate(
      from: page,
      now: publishedAt.addingTimeInterval(12 * 60 * 60)
    )
    let atTwentyFourHours = CodexRadarResetScorer.estimate(
      from: page,
      now: publishedAt.addingTimeInterval(24 * 60 * 60)
    )

    #expect(atSixHours.probability24hPercent == 65)
    #expect(atTwelveHours.probability24hPercent == 43)
    #expect(atTwentyFourHours.probability24hPercent == 0)
    #expect(atSixHours.validUntil == publishedAt.addingTimeInterval(24 * 60 * 60))
    #expect(atTwentyFourHours.evidenceUpdatedAt == nil)
  }

  @Test
  func unrelatedNewPostChangesFeedTimeButNotEvidenceOrProbability() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-27T06:40:00Z"))
    var page = try CodexRadarPublicPageParser.decode(Self.resetButtonTomorrowPageFixture, now: now)
    let before = CodexRadarResetScorer.estimate(from: page, now: now)
    let newerFeedTime = now.addingTimeInterval(60)
    page.tiboFeed.updatedAt = newerFeedTime
    page.tiboFeed.posts.insert(
      CodexRadarTiboPost(
        id: "2095000000000000002",
        url: URL(string: "https://x.com/thsottiaux/status/2095000000000000002"),
        publishedAt: newerFeedTime,
        relevance: "none",
        relevanceLabel: "无重置信号",
        originalText: "Nice work!",
        translationZh: "干得漂亮！",
        analysisZh: nil
      ),
      at: 0
    )
    let after = CodexRadarResetScorer.estimate(from: page, now: now)

    #expect(page.tiboFeed.updatedAt == newerFeedTime)
    #expect(after.probability24hPercent == before.probability24hPercent)
    #expect(after.evidenceUpdatedAt == before.evidenceUpdatedAt)
  }

  @Test
  func localReevaluationDecaysWithoutAnotherNetworkFetch() async throws {
    let historyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-radar-reevaluation-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: historyURL) }
    let start = try #require(ISO8601DateFormatter().date(from: "2026-08-27T06:40:00Z"))
    let clock = RadarTestClock(start)
    let service = CodexRadarService(
      fetcher: { Self.staleRadarWithCompletedWindowFixture },
      publicPageFetcher: { Self.resetButtonTomorrowPageFixture },
      now: { clock.now() },
      historyURL: historyURL
    )

    let fresh = try await service.current(force: true)
    let lastSuccess = fresh.syncState?.lastSuccessAt
    clock.advance(by: 24 * 60 * 60 + 21 * 60)
    let expired = try #require(await service.reevaluate())

    #expect(fresh.probability24hPercent == 60)
    #expect(expired.localResetEstimate?.probability24hPercent == 0)
    #expect(expired.probability24hPercent == nil)
    #expect(expired.localResetEstimate?.evaluatedAt == clock.now())
    #expect(expired.localResetEstimate?.evidenceUpdatedAt == nil)
    #expect(expired.syncState?.lastSuccessAt == lastSuccess)
    #expect(expired.syncState?.isStale == true)
  }

  @Test
  func tiboFailureKeepsCacheButDoesNotPretendSyncSucceeded() async throws {
    let historyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-radar-flaky-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: historyURL) }
    let start = try #require(ISO8601DateFormatter().date(from: "2026-08-27T06:40:00Z"))
    let clock = RadarTestClock(start)
    let pageFetcher = RadarFlakyPageFetcher(first: Self.resetButtonTomorrowPageFixture)
    let service = CodexRadarService(
      fetcher: { Self.staleRadarWithCompletedWindowFixture },
      publicPageFetcher: { try await pageFetcher.next() },
      now: { clock.now() },
      historyURL: historyURL
    )

    let first = try await service.current(force: true)
    clock.advance(by: 31 * 60)
    let cached = try await service.current(force: true)

    #expect(first.syncState?.isUsingCachedFeed == false)
    #expect(cached.syncState?.isUsingCachedFeed == true)
    #expect(cached.syncState?.consecutiveFailures == 1)
    #expect(cached.syncState?.lastSuccessAt == first.syncState?.lastSuccessAt)
    #expect(cached.syncState?.lastAttemptAt == clock.now())
    #expect(cached.probability24hPercent != nil)

    clock.advance(by: 91 * 60)
    let stale = try await service.current(force: true)
    #expect(stale.syncState?.isStale == true)
    #expect(stale.probability24hPercent == nil)
    #expect(stale.latestLevelLabel == "数据过期")
  }

  @Test
  func tiboSourceRecoversAutomaticallyAfterSimulatedOfflineFailure() async throws {
    let historyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-radar-recovery-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: historyURL) }
    let start = try #require(ISO8601DateFormatter().date(from: "2026-08-27T06:40:00Z"))
    let clock = RadarTestClock(start)
    let pageFetcher = RadarRecoveringPageFetcher(page: Self.resetButtonTomorrowPageFixture)
    let service = CodexRadarService(
      fetcher: { Self.staleRadarWithCompletedWindowFixture },
      publicPageFetcher: { try await pageFetcher.next() },
      now: { clock.now() },
      historyURL: historyURL
    )

    let online = try await service.current(force: true)
    clock.advance(by: 31 * 60)
    let offline = try await service.current(force: true)
    clock.advance(by: 5 * 60)
    let recovered = try await service.current(force: true)

    #expect(online.syncState?.consecutiveFailures == 0)
    #expect(offline.syncState?.consecutiveFailures == 1)
    #expect(offline.syncState?.isUsingCachedFeed == true)
    #expect(recovered.syncState?.consecutiveFailures == 0)
    #expect(recovered.syncState?.isUsingCachedFeed == false)
    #expect(recovered.syncState?.lastSuccessAt == clock.now())
    #expect(recovered.probability24hPercent != nil)
  }

  @Test
  func regressedFeedMarkerCannotOverwriteNewerTiboState() async throws {
    let historyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-radar-regression-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: historyURL) }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-27T06:40:00Z"))
    let sequence = RadarFixtureSequence([
      Self.resetButtonTomorrowPageFixture,
      Self.currentTiboOnlyPageFixture
    ])
    let service = CodexRadarService(
      fetcher: { Self.staleRadarWithCompletedWindowFixture },
      publicPageFetcher: { await sequence.next() },
      now: { now },
      cacheDuration: 0,
      historyURL: historyURL
    )

    let first = try await service.current(force: true)
    let second = try await service.current(force: true)

    #expect(second.syncState?.isUsingCachedFeed == true)
    #expect(second.syncState?.consecutiveFailures == 1)
    #expect(second.syncState?.feedUpdatedAt == first.syncState?.feedUpdatedAt)
    #expect(second.tiboFeed?.posts.map(\.id) == first.tiboFeed?.posts.map(\.id))
  }

  @Test
  func parserRejectsPostWhoseXAuthorDoesNotMatchTibo() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-27T06:40:00Z"))
    let invalid = String(decoding: Self.resetButtonTomorrowPageFixture, as: UTF8.self)
      .replacingOccurrences(of: "x.com/thsottiaux/status/", with: "x.com/not-tibo/status/")

    #expect(throws: CodexRadarError.invalidPayload) {
      _ = try CodexRadarPublicPageParser.decode(Data(invalid.utf8), now: now)
    }
  }

  @Test
  func retryBackoffIsBoundedAtNormalRefreshInterval() {
    #expect(CodexRadarService.retryDelay(afterConsecutiveFailures: 1) == 60)
    #expect(CodexRadarService.retryDelay(afterConsecutiveFailures: 2) == 5 * 60)
    #expect(CodexRadarService.retryDelay(afterConsecutiveFailures: 3) == 15 * 60)
    #expect(CodexRadarService.retryDelay(afterConsecutiveFailures: 4) == 30 * 60)
    #expect(CodexRadarService.retryDelay(afterConsecutiveFailures: 20) == 30 * 60)
  }

  @Test
  func concurrentRefreshRequestsAreCoalescedWithoutDroppingForce() {
    var gate = CodexRadarRefreshGate()

    #expect(gate.request(force: false) == true)
    #expect(gate.request(force: false) == false)
    #expect(gate.request(force: true) == false)
    #expect(gate.hasPendingRequest == true)
    #expect(gate.finish() == true)
    #expect(gate.request(force: true) == true)
    #expect(gate.finish() == nil)
  }

  @Test
  func resumeFetchesOnlyWhenLastSuccessfulTiboCheckIsOlderThanFiveMinutes() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-09-04T08:00:00Z"))

    #expect(CodexRadarRefreshPolicy.shouldFetchAfterResume(lastSuccessAt: nil, now: now))
    #expect(CodexRadarRefreshPolicy.shouldFetchAfterResume(
      lastSuccessAt: now.addingTimeInterval(-(5 * 60 - 1)),
      now: now
    ) == false)
    #expect(CodexRadarRefreshPolicy.shouldFetchAfterResume(
      lastSuccessAt: now.addingTimeInterval(-5 * 60),
      now: now
    ))
  }

  @Test
  func deferredCelebrationAtResetBoundaryStartsNextCycleAtHighProbability() async throws {
    let historyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-radar-deferred-cycle-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: historyURL) }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-30T06:50:00Z"))
    let service = CodexRadarService(
      fetcher: { Self.deferredCelebrationCompletedWindowFixture },
      publicPageFetcher: { Self.deferredCelebrationBoundaryPageFixture },
      now: { now },
      historyURL: historyURL
    )

    let snapshot = try await service.current(force: true)

    #expect(snapshot.tiboFeed?.posts.map(\.id) == ["2093811840258293947"])
    #expect(snapshot.probability24hPercent == 75)
    #expect(snapshot.latestLevelLabel == "高概率")
    #expect(snapshot.localResetEstimate?.signals.contains(where: {
      $0.contains("跨周期次日庆祝强信号 +70%")
    }) == true)
    #expect(snapshot.localResetEstimate?.signals.contains(where: {
      $0.contains("独立 Post 权重 +5%")
    }) == true)
    #expect(snapshot.latestSummary?.contains("延期至明天") == true)
    #expect(snapshot.latestSummary?.contains("仍未明确承诺") == true)

    let stored = try #require(CodexRadarTiboHistoryStore.load(from: historyURL))
    #expect(stored.posts.map(\.id) == ["2093811840258293947"])
    #expect(stored.resetAt == stored.posts.first?.publishedAt)
  }

  @Test
  func laterCompletedResetClearsDeferredBoundarySignal() async throws {
    let boundary = try #require(
      ISO8601DateFormatter().date(from: "2026-08-29T21:23:38Z")
    )
    let post = CodexRadarTiboPost(
      id: "2093811840258293947",
      url: URL(string: "https://x.com/thsottiaux/status/2093811840258293947"),
      publishedAt: boundary,
      relevance: "direct",
      relevanceLabel: "直接信号",
      originalText: "This celebration is moved to tomorrow as the button was already pressed today.",
      translationZh: "这场庆祝活动改到明天了，因为按钮今天已经按下了。",
      analysisZh: nil
    )
    let ordinaryCompletion = CodexRadarTiboPost(
      id: "completion",
      url: nil,
      publishedAt: boundary,
      relevance: "direct",
      relevanceLabel: "直接信号",
      originalText: "Usage reset is complete for all paid users.",
      translationZh: "所有付费用户的用量重置已完成。",
      analysisZh: nil
    )

    let atBoundary = CodexRadarVerifiedTiboSignals.mergedPosts(
      current: [ordinaryCompletion, post],
      resetAt: boundary,
      now: boundary.addingTimeInterval(60)
    )
    #expect(atBoundary.map(\.id) == ["2093811840258293947"])

    let afterNextReset = CodexRadarVerifiedTiboSignals.mergedPosts(
      current: [ordinaryCompletion, post],
      resetAt: boundary.addingTimeInterval(24 * 60 * 60),
      now: boundary.addingTimeInterval(24 * 60 * 60 + 60)
    )
    #expect(afterNextReset.isEmpty)
  }

  @Test
  func staleRemoteProbabilityIsHiddenWhenTiboPageCannotBeParsed() async throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-21T14:00:00Z"))
    let service = CodexRadarService(
      fetcher: { Self.staleRadarWithCompletedWindowFixture },
      publicPageFetcher: { Data("<html><body>no radar feed</body></html>".utf8) },
      now: { now }
    )

    let snapshot = try await service.current()

    #expect(snapshot.localResetEstimate?.probability24hPercent == 0)
    #expect(snapshot.syncState?.isStale == true)
    #expect(snapshot.syncState?.isUsingCachedFeed == true)
    #expect(snapshot.probability24hPercent == nil)
    #expect(snapshot.syncState?.lastSuccessAt == nil)
    #expect(snapshot.latestLevelLabel == "等待数据")
    #expect(snapshot.latestSummary?.contains("90 分钟") == false)
  }

  @Test
  func publicPageFallbackAlsoMergesRecommendationsAndEfficiency() async throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-30T03:00:00Z"))
    let service = CodexRadarService(
      fetcher: { throw CodexRadarError.accessDenied },
      publicPageFetcher: { Self.currentPublicPageFixture },
      stationInsightsFetcher: { Self.stationInsightsFixture },
      efficiencyFetcher: { Self.efficiencyFixture },
      now: { now }
    )

    let snapshot = try await service.current()
    #expect(snapshot.service == "codex-radar-public")
    #expect(snapshot.probability24hPercent == 0)
    #expect(snapshot.tiboFeed?.posts.count == 1)
    let shippingPost = try #require(
      snapshot.tiboFeed?.posts.first(where: {
        $0.id == CodexRadarVerifiedTiboSignals.shippingSignalID
      })
    )
    #expect(shippingPost.kindLabel == "Post")
    #expect(shippingPost.relevanceLabel == "组合强信号")
    #expect(shippingPost.isResetRelevantForDisplay)
    #expect(shippingPost.originalText.contains("Tomorrow we ship again"))
    #expect(shippingPost.url?.absoluteString == "https://x.com/thsottiaux/status/2082655731204096275")
    #expect(snapshot.stationInsights?.recommendations.first?.title == "日常开发")
    #expect(snapshot.stationInsights?.recommendations.first?.items.first?.modelLabel == "Luna")
    #expect(snapshot.efficiency?.points.first?.modelLabel == "Sol")
    #expect(snapshot.efficiency?.points.first?.iq == 75)
  }

  @Test
  func nextCompletedResetClearsEarlierTiboSignalsAndProbability() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-31T05:00:00Z"))
    let html = String(decoding: Self.currentPublicPageFixture, as: UTF8.self)
      .replacingOccurrences(
        of: "2026-07-29T13:42:35+08:00",
        with: "2026-07-31T12:00:00+08:00"
      )
    let page = try CodexRadarPublicPageParser.decode(Data(html.utf8), now: now)
    let estimate = CodexRadarResetScorer.estimate(from: page, now: now)

    #expect(estimate.probability24hPercent == 0)
    #expect(estimate.level == "very_low")
    #expect(estimate.signals.contains(where: { $0.contains("其后收录 0 条") }))
    #expect(estimate.signals.contains(where: { $0.contains("Tibo 状态 +0%") }))
    #expect(estimate.signals.contains(where: { $0.contains("旧状态已清零") }))
  }

  @Test
  func persistedTiboHistorySurvivesRestartAndClearsAtNextReset() async throws {
    let historyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-radar-history-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: historyURL) }
    let firstNow = try #require(
      ISO8601DateFormatter().date(from: "2026-07-30T03:00:00Z")
    )
    let firstService = CodexRadarService(
      fetcher: { throw CodexRadarError.accessDenied },
      publicPageFetcher: { Self.currentPublicPageFixture },
      now: { firstNow },
      historyURL: historyURL
    )

    let first = try await firstService.current()
    #expect(first.probability24hPercent == 0)
    let storedBeforeReset = try #require(
      CodexRadarTiboHistoryStore.load(from: historyURL)
    )
    #expect(storedBeforeReset.posts.count == 1)

    let nextResetHTML = String(decoding: Self.currentPublicPageFixture, as: UTF8.self)
      .replacingOccurrences(
        of: "2026-07-29T13:42:35+08:00",
        with: "2026-07-31T12:00:00+08:00"
      )
    let secondNow = try #require(
      ISO8601DateFormatter().date(from: "2026-07-31T05:00:00Z")
    )
    let secondService = CodexRadarService(
      fetcher: { throw CodexRadarError.accessDenied },
      publicPageFetcher: { Data(nextResetHTML.utf8) },
      now: { secondNow },
      historyURL: historyURL
    )

    let second = try await secondService.current()
    #expect(second.probability24hPercent == 0)
    let storedAfterReset = try #require(
      CodexRadarTiboHistoryStore.load(from: historyURL)
    )
    #expect(storedAfterReset.posts.isEmpty)
    #expect(storedAfterReset.resetAt != storedBeforeReset.resetAt)
  }

  @Test
  func decodesPublicRecommendationAndEfficiencyPayloads() throws {
    let insights = try CodexRadarStationInsights.decode(from: Self.stationInsightsFixture)
    let efficiency = try CodexRadarEfficiencySnapshot.decode(from: Self.efficiencyFixture)

    #expect(insights.recommendations.count == 1)
    #expect(insights.recommendations[0].items[0].averageCostUsd == 0.466631)
    #expect(insights.sourceUpdatedAt != nil)
    #expect(efficiency.points.count == 2)
    #expect(efficiency.points[1].effortLabel == "medium")
    #expect(efficiency.sourceUpdatedAt != nil)
  }

  @Test
  func publicSummaryKeepsSourceAttribution() {
    #expect(CodexRadarService.attributionText.contains("Codex Radar"))
    #expect(CodexRadarService.attributionText.contains("本地规则"))
    #expect(CodexRadarService.refreshInterval == 30 * 60)
  }

  private static let miniProgramDashboardFixture = Data(#"""
  {
    "generatedAt": "2026-07-15T10:21:00.000Z",
    "refreshIntervalSeconds": 1800,
    "platforms": [
      {
        "id": "codex",
        "name": "Codex",
        "probability": 82,
        "statusLabel": "高概率",
        "updatedAt": "2026-07-15T10:21:00.000Z",
        "resetAt": "2026-07-21T22:39:32.000Z",
        "summary": "Tibo：900 万可能很快到达；官方正在征询是否再次重置额度。",
        "summaryBlocks": [
          { "id": "release", "text": "Tibo：900 万可能很快到达" },
          { "id": "community", "text": "官方正在征询是否再次重置额度" }
        ]
      },
      {
        "id": "claude",
        "name": "Claude Code",
        "probability": 7,
        "statusLabel": "冷却观察",
        "updatedAt": "2026-07-15T10:21:00.000Z",
        "summary": "Claude Code 冷却观察。"
      }
    ],
    "accountPosts": {
      "codex": {
        "id": "2077271889626706300",
        "author": "Tibo",
        "handle": "@thsottiaux",
        "text": "看来我们可能很快会达到900万。我们是应该再次重置ChatGPT Work和Codex的使用额度，还是给它留点空间？",
        "publishedAt": "2026-07-15T05:59:46.000Z"
      }
    }
  }
  """#.utf8)

  private static let stalePublicJSONFixture = Data(#"""
  {
    "service": "codex-reset-radar",
    "monitored_at": "2026-07-13T22:08:00+08:00",
    "prediction": {
      "level": "low",
      "probability_24h": 0.14,
      "probability_48h": 0.27,
      "summary": "旧公开摘要",
      "updated_at": "2026-07-13T22:08:00+08:00"
    }
  }
  """#.utf8)

  private static let fixture = Data(#"""
  {
    "schema_version": "2.0",
    "service": "codex-reset-radar",
    "type": "public_summary",
    "monitored_at": "2026-07-15T16:21:07.261261+08:00",
    "timezone": "Asia/Shanghai",
    "window_open": false,
    "status": "prediction",
    "recommended_action": "wait",
    "window": {
      "open": false,
      "status": "prediction",
      "action": "wait",
      "message": "当前尚未确认开启重置窗口。",
      "title": "ChatGPT Work / Codex usage reset",
      "scope": "ChatGPT Work 和 Codex 用户",
      "opened_at": null,
      "closed_at": null,
      "source_url": "https://x.com/thsottiaux"
    },
    "prediction": {
      "level": "high",
      "probability_24h": 0.86,
      "probability_48h": 0.93,
      "summary": "Tibo 正在公开试探下一次 Codex usage reset。",
      "summary_en": "Tibo is publicly probing another Codex usage reset.",
      "updated_at": "2026-07-15T16:21:07.802432+08:00"
    },
    "tibo_presence": {
      "handle": "@thsottiaux",
      "timezone": "America/Los_Angeles",
      "location_label_zh": "旧金山湾区 / PT",
      "location_label_en": "San Francisco Bay Area / PT",
      "probability": 0.3,
      "confidence": "low",
      "evidence_summary_zh": "公开动态未明确披露当前位置，因此采用默认 PT 时区。",
      "should_display": true,
      "safety_note_zh": "仅展示粗粒度公开时区推测。",
      "latest_activity_zh": "资源过剩的窘境。不过看来我们可能很快会达到 900 万。",
      "latest_activity_at": "2026-07-15T13:59:00+08:00",
      "updated_at": "2026-07-15T07:36:17.896568Z",
      "observed_at": "2026-07-15T06:39:09Z",
      "stale_at": null
    },
    "links": {
      "html": "https://codexradar.com/",
      "full_api": "https://codexradar.com/api/v1/current"
    }
  }
  """#.utf8)

  private static let publicPageFixture = Data(#"""
  <!doctype html>
  <section class="reset-judgement" aria-label="重置雷达">
    <div class="reset-judgement-head">
      <h2>重置雷达 <em>7月15日19:40更新</em></h2>
    </div>
    <div class="reset-judgement-grid">
      <article class="reset-judgement-card">
        <span>发重置卡</span>
        <strong>中 · 社区偏好发卡</strong>
        <p>社区偏好不能当作官方确认。</p>
      </article>
      <article class="reset-judgement-card reset-judgement-card-high">
        <span>硬重置</span>
        <strong>中高 · Tibo 正在试探 9M 再重置</strong>
        <p>Tibo 公开询问是否再次重置 Codex usage，但尚未宣布决定。</p>
      </article>
    </div>
  </section>
  """#.utf8)

  private static let currentPublicPageFixture = Data(#"""
  <!doctype html>
  <section class="reset-judgement" aria-label="重置雷达"
    data-reset-radar-event-kind="window_closed"
    data-reset-radar-event-status="completed"
    data-reset-radar-confirmation="official"
    data-reset-radar-updated-at="2026-07-29T13:42:35+08:00"
    data-tibo-posts-updated-at="2026-07-31T08:10:16+08:00">
    <div class="reset-judgement-head">
      <h2>重置雷达 <em>事件更新 7月29日 13:42</em></h2>
    </div>
    <article class="reset-judgement-card" data-reset-track="banked_reset">
      <span>发重置卡</span><strong>本轮是直接重置</strong><p>未宣布。</p>
    </article>
    <article class="reset-judgement-card" data-reset-track="hard_reset">
      <span>硬重置</span>
      <strong>官方重置完成</strong>
      <p>7月29日 12:09，Tibo 确认直接用量重置已完成；当前没有开启的重置窗口。</p>
    </article>
    <ol class="reset-tibo-posts">
      <li class="reset-tibo-post" data-tibo-post-id="2082982139948380465" data-reset-relevance="indirect">
        <a href="https://x.com/thsottiaux/status/2082982139948380465">Tibo X</a>
        <time datetime="2026-07-31T08:10:16+08:00">7月31日 08:10</time>
        <span class="reset-tibo-post-relevance">间接相关</span>
        <p class="reset-tibo-post-original"><b>英文原文</b>@dedene It’s agents all the way down</p>
        <p class="reset-tibo-post-translation"><b>中文翻译</b>@dedene 一层套一层，全都是智能体。</p>
        <p class="reset-tibo-post-analysis"><b>模型语境解读 · 非官方</b>回复本身没有承诺重置或改变限额。</p>
      </li>
      <li class="reset-tibo-post" data-tibo-post-id="2082981910209540352" data-reset-relevance="none">
        <a href="https://x.com/thsottiaux/status/2082981910209540352">Tibo X</a>
        <time datetime="2026-07-31T08:09:21+08:00">7月31日 08:09</time>
        <span class="reset-tibo-post-relevance">无重置信号</span>
        <p class="reset-tibo-post-original"><b>英文原文</b>Benefits all</p>
        <p class="reset-tibo-post-translation"><b>中文翻译</b>惠及所有人。</p>
      </li>
      <li class="reset-tibo-post" data-tibo-post-id="2082976110384660739" data-reset-relevance="none">
        <a href="https://x.com/thsottiaux/status/2082976110384660739">Tibo X</a>
        <time datetime="2026-07-31T07:46:19+08:00">7月31日 07:46</time>
        <span class="reset-tibo-post-relevance">无重置信号</span>
        <p class="reset-tibo-post-original"><b>英文原文</b>@mweinbach Facts</p>
        <p class="reset-tibo-post-translation"><b>中文翻译</b>@mweinbach 确实。</p>
      </li>
    </ol>
  </section>
  """#.utf8)

  private static let currentTiboOnlyPageFixture = Data(#"""
  <!doctype html>
  <section class="desktop-tibo-radar" aria-label="Tibo 雷达"
    data-tibo-post-ids="2090766694897619318,2090774982271848809"
    data-tibo-posts-updated-at="2026-08-21T20:16:15+08:00">
    <ol class="reset-tibo-posts">
      <li class="reset-tibo-post" data-tibo-post-id="2090766694897619318" data-reset-relevance="direct">
        <a href="https://x.com/thsottiaux/status/2090766694897619318">Tibo X</a>
        <time datetime="2026-08-21T19:43:19+08:00">8月21日 19:43</time>
        <span class="reset-tibo-post-relevance">直接信号</span>
        <p class="reset-tibo-post-original"><b>英文原文</b>It's me again. During the day we will credit every Codex and ChatGPT Work user with a BANKED reset that you can use at your own leisure.</p>
        <p class="reset-tibo-post-translation"><b>中文翻译</b>我们会在今天之内向每位用户发放一个可储存的重置额度，你可以在自己方便的时候使用。</p>
        <p class="reset-tibo-post-analysis"><b>模型语境解读</b>BANKED reset 是可储存权益，不表示当前全局限额即将统一清零。</p>
      </li>
      <li class="reset-tibo-post" data-tibo-post-id="2090774982271848809" data-reset-relevance="none">
        <a href="https://x.com/thsottiaux/status/2090774982271848809">Tibo X</a>
        <time datetime="2026-08-21T20:16:15+08:00">8月21日 20:16</time>
        <span class="reset-tibo-post-relevance">无重置信号</span>
        <p class="reset-tibo-post-original"><b>英文原文</b>@theo Congrats!!</p>
        <p class="reset-tibo-post-translation"><b>中文翻译</b>@theo 恭喜！！</p>
      </li>
    </ol>
  </section>
  """#.utf8)

  private static let resetButtonTomorrowPageFixture = Data(#"""
  <!doctype html>
  <section class="desktop-tibo-radar" aria-label="Tibo 雷达"
    data-tibo-post-ids="2092862554632826968"
    data-tibo-posts-updated-at="2026-08-27T14:31:31+08:00">
    <ol class="reset-tibo-posts">
      <li class="reset-tibo-post" data-tibo-post-id="2092862554632826968" data-reset-relevance="none">
        <a href="https://x.com/thsottiaux/status/2092862554632826968">Tibo X</a>
        <time datetime="2026-08-27T14:31:31+08:00">8月27日 14:31</time>
        <span class="reset-tibo-post-relevance">无重置信号</span>
        <p class="reset-tibo-post-original"><b>英文原文</b>A good thing about having aged is that I feel that it’s been 20 years since I’ve pressed the reset button. Intrigued to see if I can find it tomorrow and dust it up</p>
        <p class="reset-tibo-post-translation"><b>中文翻译</b>上了年纪的一件好事是，我感觉自己已经有 20 年没按过重置按钮了。挺好奇明天能不能找到它，把灰掸一掸。</p>
        <p class="reset-tibo-post-analysis"><b>模型语境解读 · 非官方</b>这里的“重置按钮”可能是生活化比喻；但 reset button 与 tomorrow 同时出现，仍应进入本地概率研判。</p>
      </li>
    </ol>
  </section>
  """#.utf8)

  private static let deferredCelebrationBoundaryPageFixture = Data(#"""
  <!doctype html>
  <section class="desktop-tibo-radar" aria-label="Tibo 雷达"
    data-tibo-post-ids="2093811840258293947"
    data-tibo-posts-updated-at="2026-08-30T05:23:38+08:00">
    <ol class="reset-tibo-posts">
      <li class="reset-tibo-post" data-tibo-post-id="2093811840258293947" data-reset-relevance="direct">
        <a href="https://x.com/thsottiaux/status/2093811840258293947">Tibo X</a>
        <time datetime="2026-08-30T05:23:38+08:00">8月30日 05:23</time>
        <span class="reset-tibo-post-relevance">直接信号</span>
        <p class="reset-tibo-post-original"><b>英文原文</b>This celebration is moved to tomorrow as the button was already pressed today.</p>
        <p class="reset-tibo-post-translation"><b>中文翻译</b>这场庆祝活动改到明天了，因为按钮今天已经按下了。</p>
        <p class="reset-tibo-post-analysis"><b>模型语境解读 · 非官方</b>本轮重置已完成，但次日庆祝仍是新周期信号。</p>
      </li>
    </ol>
  </section>
  """#.utf8)

  private static let deferredCelebrationCompletedWindowFixture = Data(#"""
  {
    "service": "codex-reset-radar",
    "monitored_at": "2026-08-30T13:13:10+08:00",
    "window": {
      "open": false,
      "status": "community_confirmed",
      "message": "官方重置已完成",
      "closed_at": "2026-08-30T05:23:38+08:00",
      "source_url": "https://x.com/thsottiaux/status/2093811840258293947"
    },
    "prediction": {
      "level": "low",
      "probability_24h": 0.14,
      "probability_48h": 0.27,
      "summary": "旧公开摘要",
      "updated_at": "2026-07-13T22:08:06+08:00"
    }
  }
  """#.utf8)

  private static let staleRadarWithCompletedWindowFixture = Data(#"""
  {
    "service": "codex-reset-radar",
    "monitored_at": "2026-07-22T06:57:20+08:00",
    "window": {
      "open": false,
      "status": "community_confirmed",
      "message": "官方重置已完成",
      "closed_at": "2026-08-13T12:40:53+08:00"
    },
    "prediction": {
      "level": "low",
      "probability_24h": 0.14,
      "probability_48h": 0.27,
      "summary": "旧公开摘要",
      "updated_at": "2026-07-13T22:08:06+08:00"
    }
  }
  """#.utf8)

  private static let stationInsightsFixture = Data(#"""
  {
    "schema": 1,
    "generated_at": "2026-07-31T02:41:16+00:00",
    "source_updated_at": "2026-07-31T02:39:31+00:00",
    "recommendations": [
      {
        "key": "daily_development",
        "title": "日常开发",
        "rule": "测试规则",
        "items": [
          {
            "model": "gpt-5.6-luna",
            "effort": "max",
            "iq": 92.41,
            "average_cost_usd": 0.466631,
            "average_duration_minutes": 31.8,
            "slot": "value"
          }
        ]
      }
    ]
  }
  """#.utf8)

  private static let efficiencyFixture = Data(#"""
  {
    "schema": 2,
    "type": "distributed_intelligence_efficiency",
    "source_updated_at": "2026-07-31T09:37:53+08:00",
    "models": 1,
    "points": [
      {
        "model": "gpt-5.6-sol",
        "effort": "low",
        "iq": 75.0,
        "average_price_usd": 2.187131,
        "average_minutes": 11.9524
      },
      {
        "model": "gpt-5.6-sol",
        "effort": "medium",
        "iq": 80.3571,
        "average_price_usd": 3.860807,
        "average_minutes": 16.6274
      }
    ]
  }
  """#.utf8)
}

private actor RadarFetchCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

private actor RadarFixtureSequence {
  private var fixtures: [Data]

  init(_ fixtures: [Data]) {
    self.fixtures = fixtures
  }

  func next() -> Data {
    if fixtures.count > 1 { return fixtures.removeFirst() }
    return fixtures[0]
  }
}

private actor RadarFlakyPageFetcher {
  private var first: Data?

  init(first: Data) {
    self.first = first
  }

  func next() throws -> Data {
    if let first {
      self.first = nil
      return first
    }
    throw URLError(.notConnectedToInternet)
  }
}

private actor RadarRecoveringPageFetcher {
  private let page: Data
  private var callCount = 0

  init(page: Data) {
    self.page = page
  }

  func next() throws -> Data {
    callCount += 1
    if callCount == 2 {
      throw URLError(.notConnectedToInternet)
    }
    return page
  }
}

private final class RadarTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) {
    self.date = date
  }

  func now() -> Date {
    lock.withLock { date }
  }

  func advance(by interval: TimeInterval) {
    lock.withLock { date = date.addingTimeInterval(interval) }
  }
}
