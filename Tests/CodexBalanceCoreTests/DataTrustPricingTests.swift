import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Source provenance and price coverage")
struct DataTrustPricingTests {
  let now = Date(timeIntervalSince1970: 1_788_600_000)

  @Test func failureDoesNotRenewOfficialSample() {
    var read = SourceReadMetadata()
    read.succeed(at: now)
    read.fail(at: now.addingTimeInterval(30), reason: "offline")
    #expect(read.lastSuccessAt == now)
    #expect(read.sampledAt == now)
    #expect(read.state(at: now.addingTimeInterval(30)) == .cached)
    #expect(read.state(at: now.addingTimeInterval(1801)) == .expired)
    read.succeed(at: now.addingTimeInterval(1802))
    #expect(read.state(at: now.addingTimeInterval(1802)) == .fresh)
  }

  @Test func ageAndResetAreIndependentOfFileHeartbeat() {
    var read = SourceReadMetadata(); read.succeed(at: now)
    #expect(read.state(at: now.addingTimeInterval(301)) == .cached)
    #expect(read.state(at: now, resetAt: now) == .waitingForReset)
    var snapshot = CodexWidgetSnapshot(updatedAt: now.addingTimeInterval(3600), remainingPercent: 71)
    snapshot.quotaRead = read
    #expect(snapshot.effective(at: now.addingTimeInterval(3600)).remainingPercent == nil)
    snapshot.schemaVersion = 3
    #expect(snapshot.effective(at: now).remainingPercent == nil)
  }

  @Test func officialCacheRetainsValueAndRecordsFailurePerDomain() {
    let source = CodexAppServerRateLimitSource()
    let event = RateLimitEvent(timestamp: now, sourceName: "Codex app-server", sourcePath: "account/rateLimits/read",
      limitID: "codex", limitName: "Codex", secondary: LimitWindow(usedPercent: 20, remainingPercent: 80,
        windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400)))
    _ = source.finishSnapshot(LiveAccountRateLimitSnapshot(events: [event], resetCredits: nil,
      flexibleCreditBalance: CodexFlexibleCreditBalance(hasCredits: true, balanceCredits: 500)), at: now)
    let failed = source.finishSnapshot(.empty, at: now.addingTimeInterval(60))
    #expect(failed.events.first?.sevenDayWindow?.remainingPercent == 80)
    #expect(failed.flexibleCreditBalance?.balanceCredits == 500)
    #expect(failed.quotaRead.state(at: now.addingTimeInterval(60)) == .cached)
    #expect(failed.quotaRead.lastSuccessAt == now)
    #expect(failed.resetRead.state(at: now) == .unavailable)
  }

  @Test func officialAstraPriceAndUnknownCoverage() {
    let catalog = ModelPricingCatalog.current
    #expect(catalog.rates["gpt-6-astra"]?.inputPerMillionUSD == 10)
    #expect(catalog.rates["gpt-5.6-sol"]?.inputPerMillionUSD == 4)
    #expect(catalog.rates["gpt-5.6-terra"]?.outputPerMillionUSD == 12)
    #expect(catalog.rates["gpt-5.6-luna"]?.outputPerMillionUSD == 1.2)
    let unknown = CostEstimate(unpricedTokens: 10, unpricedModels: ["future-model"])
    #expect(unknown.displayUSD == "暂无法估算")
    #expect(unknown.coveragePercent == 0)
    #expect(CostEstimate(usd: 2, pricedTokens: 75, unpricedTokens: 25).coveragePercent == 75)
  }

  @Test func invalidImportPreservesUsableConfiguration() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("prices.json")
    let store = ModelPricingStore(url: url)
    let before = store.snapshot().version
    let bad = Data(#"{"schemaVersion":1,"verifiedAt":"2026-09-05T00:00:00Z","models":[{"model":"x","aliases":[],"input":-1,"cachedInput":0,"output":1,"longContextInputMultiplier":1,"longContextOutputMultiplier":1,"sourceURL":"https://example.com"}]}"#.utf8)
    #expect(throws: (any Error).self) { try store.preview(data: bad) }
    #expect(store.snapshot().version == before)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    let valid = String(decoding: bad, as: UTF8.self).replacingOccurrences(of: "\"input\":-1", with: "\"input\":3")
    let preview = try store.preview(data: Data(valid.utf8))
    #expect(preview.summary.contains("x：未计价"))
    try store.install(preview.document)
    #expect(store.snapshot().catalog.rates["x"]?.inputPerMillionUSD == 3)
    #expect(store.snapshot().version != before)
    #expect(ModelPricingStore(url: url).snapshot().version == store.snapshot().version)
    let conflict = valid.replacingOccurrences(of: "\"aliases\":[]", with: "\"aliases\":[\"gpt-5.6\"]")
    #expect(throws: (any Error).self) { try store.preview(data: Data(conflict.utf8)) }
  }

  @Test func csvExplainsEntirelyUnpricedUsage() {
    let stats = TokenStats(rolling24HoursTokens: 100,
      cost24Hours: CostEstimate(unpricedTokens: 100, unpricedModels: ["unknown-new"]))
    let csv = CodexUsageCSVExporter.makeCSV(stats: stats, cnyRate: 7)
    #expect(csv.contains("滚动24小时,100,,,0.00,unknown-new,按当前价格表折算"))
  }

  @Test func rejectedPriceVariantsPreserveInstalledBytes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("prices.json")
    let store = ModelPricingStore(url: url)
    let row = #"{"model":"test-model","aliases":[],"input":2,"cachedInput":0.2,"output":12,"longContextInputMultiplier":1,"longContextOutputMultiplier":1,"sourceURL":"https://example.com/pricing"}"#
    func document(_ rows: String) -> Data {
      Data((#"{"schemaVersion":1,"verifiedAt":"2026-09-05T00:00:00Z","models":["# + rows + "]}").utf8)
    }
    try store.install(store.preview(data: document(row)).document)
    let installed = try Data(contentsOf: url)
    let version = store.snapshot().version
    let invalidRows = [
      row.replacingOccurrences(of: "\"input\":2", with: "\"input\":-2"),
      row.replacingOccurrences(of: "\"input\":2", with: "\"input\":1e9999"),
      row.replacingOccurrences(of: "\"input\":2", with: "\"input\":NaN"),
      row + "," + row,
      row.replacingOccurrences(of: "\"aliases\":[]", with: "\"aliases\":[\"test-model\"]"),
      row.replacingOccurrences(of: "\"aliases\":[]", with: "\"aliases\":[\"gpt-6-astra\"]")
    ]
    for invalid in invalidRows {
      #expect(throws: (any Error).self) { try store.preview(data: document(invalid)) }
      #expect(try Data(contentsOf: url) == installed)
      #expect(store.snapshot().version == version)
    }
  }

  @Test func unpublishedCachedPriceOnlyCountsKnownTokenCosts() {
    let event = TokenUsageEvent(timestamp: now, sourceName: "fixture", model: "gpt-5.4-pro",
      totalTokens: 1000, inputTokens: 800, cachedInputTokens: 500, outputTokens: 200, reasoningOutputTokens: 0)
    let cost = ModelPricingCatalog.current.estimate(events: [event])
    #expect(cost.pricedTokens == 500)
    #expect(cost.unpricedTokens == 500)
    #expect(cost.coveragePercent == 50)
    #expect(abs(cost.usd - 0.045) < 0.0000001)
    #expect(cost.unpricedModels == ["gpt-5.4-pro"])
  }
}
