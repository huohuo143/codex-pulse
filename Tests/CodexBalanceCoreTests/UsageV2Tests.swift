import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Codex v2 usage, pricing and sync")
struct UsageV2Tests {
  @Test
  func usageCSVIncludesSummaryModelsAndEscapesProjectNames() {
    let stats = TokenStats(
      rolling24HoursTokens: 1_200,
      monthTokens: 2_000,
      last7DaysTokens: 1_600,
      hourly: [TokenBucket(key: "2026071509", label: "09时", totalTokens: 1_200, inputTokens: 900, cachedInputTokens: 300, outputTokens: 300, calls: 2)],
      modelHourly: [ModelHourlyBucket(hourKey: "2026071509", model: "gpt-5.6-sol", totalTokens: 1_200, inputTokens: 900, cachedInputTokens: 300, outputTokens: 300, calls: 2)],
      cost24Hours: CostEstimate(usd: 0.01, pricedTokens: 1_200),
      cost7Days: CostEstimate(usd: 0.02, pricedTokens: 1_600),
      costMonth: CostEstimate(usd: 0.03, pricedTokens: 2_000),
      categoryBreakdown: [TokenCategoryBucket(
        category: .dataAnalysis,
        totalTokens: 1_200,
        inputTokens: 900,
        outputTokens: 300,
        reasoningOutputTokens: 50,
        calls: 2
      )],
      recentUsageEvents: [TokenUsageEvent(
        timestamp: Date(timeIntervalSince1970: 1_784_041_200),
        sourceName: "fixture.jsonl",
        model: "gpt-5.6-sol",
        totalTokens: 1_200,
        inputTokens: 900,
        cachedInputTokens: 300,
        outputTokens: 300,
        reasoningOutputTokens: 50,
        projectName: "水稻,\"BPH33\""
      )]
    )

    let csv = CodexUsageCSVExporter.makeCSV(
      stats: stats,
      cnyRate: 7.2,
      generatedAt: Date(timeIntervalSince1970: 1_784_041_200)
    )

    #expect(csv.contains("滚动24小时,1200,0.010000,0.072000"))
    #expect(csv.contains("gpt-5.6-sol,1200,900,300,300,2"))
    #expect(csv.contains("数据分析,1200,900,300,50,2"))
    #expect(csv.contains(#""水稻,""BPH33""""#))
  }

  @Test
  func resetCreditSummaryDecodesOfficialCountAndSortsExpiryDates() throws {
    let fixture = #"""
    {
      "availableCount": 3,
      "credits": [
        {"id":"opaque-third","title":"Full reset","status":"available","resetType":"codexRateLimits","grantedAt":1783964133,"expiresAt":1786556133},
        {"id":"opaque-first","title":"Full reset","status":"available","resetType":"codexRateLimits","grantedAt":1782935919,"expiresAt":1785527919},
        {"id":"opaque-second","title":"Full reset","status":"available","resetType":"codexRateLimits","grantedAt":1783890499,"expiresAt":1786482499}
      ]
    }
    """#

    let summary = try JSONDecoder().decode(RateLimitResetCreditsSummary.self, from: Data(fixture.utf8))
    let timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))

    #expect(summary.availableCount == 3)
    #expect(summary.availableCredits.count == 3)
    #expect(summary.missingDetailCount == 0)
    #expect(summary.availableCredits.map { BalanceFormatters.resetExpiryDate($0.expiresAt, timeZone: timeZone) } == ["8/1", "8/12", "8/13"])
    #expect(!summary.availableCredits[0].id.contains("opaque-first"))
  }

  @Test
  func resetCreditSummaryKeepsOfficialCountWhenDetailsAreMissingOrCapped() throws {
    let countOnly = try JSONDecoder().decode(
      RateLimitResetCreditsSummary.self,
      from: Data(#"{"availableCount":3,"credits":null}"#.utf8)
    )
    #expect(countOnly.availableCount == 3)
    #expect(countOnly.credits == nil)
    #expect(countOnly.missingDetailCount == 3)

    let capped = RateLimitResetCreditsSummary(
      availableCount: 3,
      credits: [RateLimitResetCredit(grantedAt: Date(timeIntervalSince1970: 100), expiresAt: nil)]
    )
    #expect(capped.availableCredits.count == 1)
    #expect(capped.missingDetailCount == 2)
  }

  @Test
  func resetRadarSnakeCasePayloadDecodesWithoutPersistingOpaqueIDs() throws {
    let fixture = #"""
    {
      "available_count": 1,
      "credits": [
        {
          "id": "opaque-backend-credit-id",
          "status": "AVAILABLE",
          "reset_type": "codex_rate_limits",
          "granted_at": "2026-07-14T17:35:33.802432Z",
          "expires_at": 1786556133000
        }
      ]
    }
    """#
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let summary = try decoder.decode(RateLimitResetCreditsSummary.self, from: Data(fixture.utf8))

    #expect(summary.availableCount == 1)
    #expect(summary.availableCredits.count == 1)
    #expect(summary.availableCredits[0].resetType == "codex_rate_limits")
    #expect(summary.availableCredits[0].expiresAt == Date(timeIntervalSince1970: 1_786_556_133))
    #expect(!summary.availableCredits[0].id.contains("opaque-backend-credit-id"))
  }

  @Test
  func resetRadarLiveProbeOnlyWhenExplicitlyEnabled() throws {
    guard ProcessInfo.processInfo.environment["RUN_LIVE_RESET_RADAR_TEST"] == "1" else { return }
    let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    let source = CodexResetCreditsSource(codexHome: codexHome)
    let liveSummary = source.fresh(now: Date())
    print("Reset Radar live diagnostic: \(source.diagnosticFailure() ?? "ok")")
    let summary = try #require(liveSummary)

    #expect(summary.availableCount >= 0)
    #expect(summary.availableCredits.count <= summary.availableCount)
    let expiryTimes = summary.availableCredits.compactMap(\.expiresAt).map { Int64($0.timeIntervalSince1970) }
    print("Reset Radar live probe: available=\(summary.availableCount), expiries=\(expiryTimes)")
  }

  @Test
  func compactNumberPartsKeepChineseUnitVisuallySeparate() {
    let chinese = BalanceFormatters.compactNumberParts(230_000_000, usesMyriadUnits: true)
    let western = BalanceFormatters.compactNumberParts(230_000_000, usesMyriadUnits: false)

    #expect(chinese == CompactNumberParts(value: "2.3", unit: "亿"))
    #expect(chinese.combined == "2.3亿")
    #expect(western == CompactNumberParts(value: "230", unit: "M"))
    #expect(BalanceFormatters.compactNumberParts(nil, usesMyriadUnits: true).combined == "--")
  }

  @Test
  func sevenDayWindowSupportsNewPrimarySlotWithoutShowingFiveHourWindow() {
    let fiveHours = LimitWindow(
      usedPercent: 20,
      remainingPercent: 80,
      windowMinutes: 300,
      resetsAt: nil
    )
    let sevenDays = LimitWindow(
      usedPercent: 38,
      remainingPercent: 62,
      windowMinutes: 10_080,
      resetsAt: nil
    )

    let current = RateLimitEvent(
      timestamp: Date(),
      sourceName: "current.jsonl",
      sourcePath: "/tmp/current.jsonl",
      limitID: "codex",
      limitName: "Codex",
      primary: sevenDays,
      secondary: nil
    )
    let legacy = RateLimitEvent(
      timestamp: Date(),
      sourceName: "legacy.jsonl",
      sourcePath: "/tmp/legacy.jsonl",
      limitID: "codex",
      limitName: "Codex",
      primary: fiveHours,
      secondary: sevenDays
    )
    let fiveHourOnly = RateLimitEvent(
      timestamp: Date(),
      sourceName: "five-hour.jsonl",
      sourcePath: "/tmp/five-hour.jsonl",
      limitID: "codex",
      limitName: "Codex",
      primary: fiveHours,
      secondary: nil
    )

    #expect(current.sevenDayWindow?.remainingPercent == 62)
    #expect(legacy.sevenDayWindow?.remainingPercent == 62)
    #expect(fiveHourOnly.sevenDayWindow == nil)
  }

  @Test
  func readerParsesCurrentSevenDayPrimaryPayload() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("current-primary.jsonl")
    let line = """
    {"timestamp":"2026-07-14T03:15:28.908Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":38.0,"window_minutes":10080,"resets_at":1784487547},"secondary":null,"plan_type":"pro"},"info":{"total_token_usage":{"total_tokens":1000},"last_token_usage":{"total_tokens":1000,"input_tokens":800,"cached_input_tokens":400,"output_tokens":200,"reasoning_output_tokens":50}}}}
    """
    try line.write(to: file, atomically: true, encoding: .utf8)

    let now = try #require(isoDate("2026-07-14T03:16:00Z"))
    let status = try CodexStatusReader(codexHome: root).read(now: now)

    #expect(status.main?.sevenDayWindow?.remainingPercent == 62)
    #expect(status.main?.secondary == nil)
    #expect(status.tokenStats.rolling24HoursTokens == 1_000)
  }

  @Test
  func pricingSplitsCachedInputAndDoesNotDoubleChargeReasoning() {
    let event = TokenUsageEvent(
      timestamp: Date(),
      sourceName: "fixture.jsonl",
      model: "gpt-5.6-sol",
      totalTokens: 1_200,
      inputTokens: 1_000,
      cachedInputTokens: 400,
      outputTokens: 200,
      reasoningOutputTokens: 80
    )
    let estimate = ModelPricingCatalog.current.estimate(events: [event])

    // 600 * $5/M + 400 * $0.50/M + 200 * $30/M = $0.0092.
    #expect(abs(estimate.usd - 0.0092) < 0.000_000_1)
    #expect(estimate.pricedTokens == 1_200)
    #expect(!estimate.isPartial)
  }

  @Test
  func pricingAppliesOfficialLongContextMultipliersAbove272KInputTokens() {
    let event = TokenUsageEvent(
      timestamp: Date(),
      sourceName: "fixture.jsonl",
      model: "gpt-5.4",
      totalTokens: 300_000,
      inputTokens: 280_000,
      cachedInputTokens: 80_000,
      outputTokens: 20_000,
      reasoningOutputTokens: 5_000
    )
    let estimate = ModelPricingCatalog.current.estimate(events: [event])

    // Input and cached input are 2x; output is 1.5x.
    #expect(abs(estimate.usd - 1.49) < 0.000_000_1)
    #expect(estimate.pricedTokens == 300_000)
  }

  @Test
  func unknownModelsRemainUnpriced() {
    let event = TokenUsageEvent(
      timestamp: Date(),
      sourceName: "fixture.jsonl",
      model: "future-model",
      totalTokens: 900,
      inputTokens: 700,
      outputTokens: 200,
      reasoningOutputTokens: 40
    )
    let estimate = ModelPricingCatalog.current.estimate(events: [event])

    #expect(estimate.usd == 0)
    #expect(estimate.unpricedTokens == 900)
    #expect(estimate.unpricedModels == ["future-model"])
  }

  @Test
  func miniModelUsesItsOfficialRateCard() {
    let event = TokenUsageEvent(
      timestamp: Date(),
      sourceName: "fixture.jsonl",
      model: "gpt-5.4-mini",
      totalTokens: 2_000,
      inputTokens: 1_500,
      cachedInputTokens: 500,
      outputTokens: 500,
      reasoningOutputTokens: 100
    )
    let estimate = ModelPricingCatalog.current.estimate(events: [event])

    // 1,000 * $0.75/M + 500 * $0.075/M + 500 * $4.50/M = $0.0030375.
    #expect(abs(estimate.usd - 0.003_037_5) < 0.000_000_1)
    #expect(!estimate.isPartial)
  }

  @Test
  func readerTracksModelSwitchCachedInputAndExact24HourBoundary() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("models.jsonl")
    let now = try #require(isoDate("2026-07-14T12:00:00Z"))

    let lines = [
      turn(model: "gpt-5.6-sol"),
      token(timestamp: "2026-07-13T11:59:59Z", total: 100, last: 100, input: 80, cached: 40, output: 20),
      turn(model: "gpt-5.6-terra"),
      token(timestamp: "2026-07-13T12:00:00Z", total: 300, last: 200, input: 150, cached: 50, output: 50),
      turn(model: "gpt-5.6-sol"),
      token(timestamp: "2026-07-14T11:59:00Z", total: 600, last: 300, input: 240, cached: 120, output: 60)
    ].joined(separator: "\n")
    try lines.write(to: file, atomically: true, encoding: .utf8)

    let status = try CodexStatusReader(codexHome: root).read(now: now)
    #expect(status.tokenStats.rolling24HoursTokens == 500)
    #expect(status.tokenStats.recentUsageEvents.first?.model == "gpt-5.6-sol")
    #expect(status.tokenStats.recentUsageEvents.first?.cachedInputTokens == 120)
    #expect(Set(status.tokenStats.modelHourly.map(\.model)) == ["gpt-5.6-sol", "gpt-5.6-terra"])
  }

  @Test
  func readerDeduplicatesQuotaSnapshotsAtTheSameCumulativeTotal() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("repeated-snapshot.jsonl")
    let now = try #require(isoDate("2026-07-14T12:00:00Z"))
    let lines = [
      turn(model: "gpt-5.4"),
      token(timestamp: "2026-07-14T11:58:00Z", total: 500, last: 100, input: 75, cached: 20, output: 25),
      token(timestamp: "2026-07-14T11:59:00Z", total: 500, last: 40, input: 30, cached: 10, output: 10)
    ].joined(separator: "\n")
    try lines.write(to: file, atomically: true, encoding: .utf8)

    let status = try CodexStatusReader(codexHome: root).read(now: now)
    #expect(status.tokenStats.sampleCount == 1)
    #expect(status.tokenStats.rolling24HoursTokens == 100)
    #expect(status.tokenStats.todayTokens == 100)
  }

  @Test
  func rollingWindowUsesElapsedHoursAcrossDST() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("dst.jsonl")
    let now = try #require(isoDate("2026-03-09T08:30:00Z"))
    let lines = [
      turn(model: "gpt-5.6-sol"),
      token(timestamp: "2026-03-08T08:29:59Z", total: 100, last: 100, input: 70, cached: 20, output: 30),
      token(timestamp: "2026-03-08T08:30:00Z", total: 300, last: 200, input: 140, cached: 40, output: 60)
    ].joined(separator: "\n")
    try lines.write(to: file, atomically: true, encoding: .utf8)

    let status = try CodexStatusReader(codexHome: root).read(now: now)
    #expect(status.tokenStats.rolling24HoursTokens == 200)
  }

  @Test
  func exchangeRateCachesDailyAndFallsBackAfterFailure() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("rate.json")
    let firstDate = try #require(isoDate("2026-07-14T02:00:00Z"))
    let first = ExchangeRateService(
      cacheURL: cache,
      fetcher: { Data(#"{"date":"2026-07-14","base":"USD","quote":"CNY","rate":7.18}"#.utf8) },
      now: { firstDate }
    )
    let fetched = await first.current()
    #expect(fetched?.rate == 7.18)

    let nextDate = try #require(isoDate("2026-07-15T02:00:00Z"))
    let offline = ExchangeRateService(
      cacheURL: cache,
      fetcher: { throw URLError(.notConnectedToInternet) },
      now: { nextDate }
    )
    let fallback = await offline.current()
    #expect(fallback?.rate == 7.18)
    #expect(fallback?.rateDate == "2026-07-14")
  }

  @Test
  func schema2And3DecodeWhileV2FileWinsWithoutModifyingLegacy() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyURL = root.appendingPathComponent("lab-mac-codex.json")
    let legacy = """
    {"schemaVersion":3,"app":"codex","deviceID":"lab-mac","deviceName":"Lab Mac legacy","hostName":"lab","updatedAt":"2026-07-14T12:00:00Z","todayTokens":999,"monthTokens":1999,"sampleCount":9,"hourly":[{"key":"495612","label":"12时","totalTokens":999}],"daily":[],"monthly":[]}
    """
    try Data(legacy.utf8).write(to: legacyURL)
    let originalLegacy = try Data(contentsOf: legacyURL)

    let v2URL = root.appendingPathComponent("lab-mac-codex-v2.json")
    let v2 = """
    {"schemaVersion":4,"app":"codex","deviceID":"lab-mac","deviceName":"Lab Mac v2","hostName":"lab","updatedAt":"2026-07-13T12:00:00Z","todayTokens":222,"monthTokens":444,"sampleCount":2,"hourly":[],"modelHourly":[{"hourKey":"495612","model":"gpt-5.6-sol","totalTokens":222,"inputTokens":180,"cachedInputTokens":80,"outputTokens":42,"reasoningOutputTokens":10,"calls":1}],"daily":[],"monthly":[]}
    """
    try Data(v2.utf8).write(to: v2URL)

    let schema2 = """
    {"schemaVersion":2,"app":"codex","deviceID":"old-mac","deviceName":"Old Mac","updatedAt":"2026-07-12T12:00:00Z","todayTokens":12,"monthTokens":34,"daily":[],"monthly":[]}
    """
    try Data(schema2.utf8).write(to: root.appendingPathComponent("old-mac-codex.json"))

    let store = CodexUsageSyncStore(syncRoot: root, deviceID: "current", deviceName: "Current", hostName: "current")
    let snapshots = store.readSnapshots()
    #expect(snapshots.first { $0.deviceID == "lab-mac" }?.todayTokens == 222)
    #expect(snapshots.first { $0.deviceID == "lab-mac" }?.modelHourly.first?.model == "gpt-5.6-sol")
    #expect(snapshots.first { $0.deviceID == "old-mac" }?.schemaVersion == 2)
    #expect(try Data(contentsOf: legacyURL) == originalLegacy)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("CodexV2Tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func turn(model: String) -> String {
    #"{"timestamp":"2026-07-14T00:00:00Z","type":"turn_context","payload":{"model":"\#(model)","cwd":"/tmp/project"}}"#
  }

  private func token(
    timestamp: String,
    total: Int,
    last: Int,
    input: Int,
    cached: Int,
    output: Int
  ) -> String {
    """
    {"timestamp":"\(timestamp)","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","limit_name":"Codex","primary":{"used_percent":5,"window_minutes":300},"secondary":{"used_percent":20,"window_minutes":10080}},"info":{"total_token_usage":{"total_tokens":\(total)},"last_token_usage":{"total_tokens":\(last),"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"reasoning_output_tokens":10}}}}
    """
  }

  private func isoDate(_ value: String) -> Date? {
    ISO8601DateFormatter().date(from: value)
  }
}
