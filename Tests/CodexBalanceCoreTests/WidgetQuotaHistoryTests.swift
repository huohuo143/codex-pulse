import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Official quota history widget")
struct WidgetQuotaHistoryTests {
  let now = Date(timeIntervalSince1970: 1_792_800_000)

  func row(_ age: Double, _ percent: Double = 80, reset: Double = 86_400) -> QuotaSnapshot {
    .init(recordedAt: now.addingTimeInterval(-age), remainingPercent: percent,
      resetsAt: now.addingTimeInterval(reset), windowMinutes: 10080)
  }

  @Test func publishedPeriodsMatchTheAppAndPreserveDisconnections() throws {
    let input = [row(31 * 86_400), row(10 * 86_400), row(10_000, 80), row(9_000, 75),
      row(8_000, 90), row(7_000, 89, reset: 172_800), row(500, 70, reset: 172_800),
      row(0, 65, reset: 172_800), row(-1), row(5, 101)]
    let published = QuotaHistoryTrend.widgetHistory(snapshots: input, now: now)
    for period in QuotaHistoryPeriod.allCases {
      let series = try #require(published.first { $0.days == period.rawValue })
      let app = QuotaHistoryTrend.points(snapshots: input, period: period, now: now)
      #expect(series.sampleCount == app.count)
      #expect(series.points.map(\.recordedAt) == app.map(\.snapshot.recordedAt))
      #expect(series.points.map(\.segment) == app.map(\.segment))
    }
    #expect(published.first?.points.map(\.segment) == [0, 0, 1, 2, 3, 3])
  }

  @Test func denseHistoryKeepsExtremaResetEdgesAndLatestObservation() throws {
    var input: [QuotaSnapshot] = []
    for index in 0..<9000 {
      let age = Double(9000 - index) * 10
      let percent: Double = index == 4321 ? 0 : 80
      let reset: Double = index < 4500 ? 86_400 : 172_800
      input.append(row(age, percent, reset: reset))
    }
    let series = try #require(QuotaHistoryTrend.widgetHistory(snapshots: input, now: now).last)
    #expect(series.sampleCount == 9000)
    #expect(series.points.count < 1300)
    #expect(series.points.contains { $0.remainingPercent == 0 })
    #expect(series.points.contains { $0.recordedAt == input[4499].recordedAt })
    #expect(series.points.contains { $0.recordedAt == input[4500].recordedAt })
    #expect(series.points.first?.recordedAt == input.first?.recordedAt)
    #expect(series.points.last?.recordedAt == input.last?.recordedAt)
  }

  @Test func oldHistoryStaysHistoricalWhileRollingRangeAgesOut() throws {
    var snapshot = CodexWidgetSnapshot(updatedAt: now, remainingPercent: 80)
    snapshot.quotaHistory = QuotaHistoryTrend.widgetHistory(snapshots: [row(300), row(0, 75)], now: now)
    let later = snapshot.effective(at: now.addingTimeInterval(3600))
    #expect(later.remainingPercent == nil)
    #expect(later.quotaHistory == snapshot.quotaHistory)
    let series = try #require(later.quotaHistory?.first)
    #expect(series.visiblePoints(at: now.addingTimeInterval(3600)).count == 2)
    #expect(series.visiblePoints(at: now.addingTimeInterval(86_401)).isEmpty)
  }

  @Test func historyChangesAndAccountClearingRefreshOnlyTheHistoryWidget() {
    let before = CodexWidgetSnapshot(updatedAt: now)
    var after = before
    after.quotaHistory = QuotaHistoryTrend.widgetHistory(snapshots: [row(0)], now: now)
    #expect(after.affectedKinds(comparedTo: before) == [.quotaHistory])
    var cleared = after
    cleared.quotaHistory = QuotaHistoryTrend.widgetHistory(snapshots: [], now: now)
    #expect(cleared.affectedKinds(comparedTo: after) == [.quotaHistory])
    #expect(cleared.quotaHistory?.allSatisfy { $0.points.isEmpty } == true)
    #expect(after.affectedKinds(comparedTo: after).isEmpty)
  }

  @Test func payloadRoundTripsWithoutRawRecordsOrAccountIdentifiers() throws {
    var snapshot = CodexWidgetSnapshot(updatedAt: now)
    snapshot.quotaHistory = QuotaHistoryTrend.widgetHistory(snapshots: [row(0)], now: now)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
    let data = try encoder.encode(snapshot)
    #expect(try decoder.decode(CodexWidgetSnapshot.self, from: data) == snapshot)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("account"))
    #expect(!json.contains("windowMinutes"))
    #expect(!json.contains("sourcePath"))
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "quotaHistory")
    let legacy = try decoder.decode(CodexWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.quotaHistory == nil)
  }
}
