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
    #expect(CodexRadarService.endpointURL.absoluteString == "https://api.tangka.online/radar-api/dashboard")
    #expect(CodexRadarService.fullAPIURL.absoluteString == "https://codexradar.com/api/v1/current")
    #expect(CodexRadarService.publicSummaryModeText.contains("无需 API Key"))
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
  func publicSummaryKeepsSourceAttribution() {
    #expect(CodexRadarService.attributionText.contains("重置雷达小程序"))
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
