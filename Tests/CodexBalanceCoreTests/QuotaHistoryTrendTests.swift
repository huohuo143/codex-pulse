import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Official quota history trend")
struct QuotaHistoryTrendTests {
  let now = Date(timeIntervalSince1970: 1_791_677_000)

  func sample(_ age: TimeInterval, _ remaining: Double = 70, reset: Date? = nil) -> QuotaSnapshot {
    .init(recordedAt: now.addingTimeInterval(-age), remainingPercent: remaining,
      resetsAt: reset ?? now.addingTimeInterval(86_400), windowMinutes: 10080)
  }

  @Test func filtersWindowInvalidFutureAndNonWeeklySamples() {
    var nonWeekly = sample(5); nonWeekly.windowMinutes = 300
    let input = [sample(86_401), sample(86_400), sample(0), sample(-1),
      sample(20, .nan), sample(15, 101), sample(10, -1), nonWeekly,
      sample(30, 60, reset: now.addingTimeInterval(-40))]
    let points = QuotaHistoryTrend.points(snapshots: input, period: .day, now: now)
    #expect(points.map(\.snapshot.recordedAt) == [now.addingTimeInterval(-86_400), now])
    #expect(QuotaHistoryTrend.points(snapshots: [], period: .month, now: now).isEmpty)
  }

  @Test func segmentsResetUpwardAdjustmentAndLongMissingIntervals() {
    let newReset = now.addingTimeInterval(2 * 86_400)
    let input = [sample(10_000, 80), sample(9_000, 75), sample(8_000, 90),
      sample(7_000, 89, reset: newReset), sample(500, 70, reset: newReset), sample(0, 65, reset: newReset)]
    let points = QuotaHistoryTrend.points(snapshots: input, period: .week, now: now)
    #expect(points.map(\.segment) == [0, 0, 1, 2, 3, 3])
  }

  @Test func sortsDeduplicatesAndToleratesSmallResetClockJitter() {
    let reset = now.addingTimeInterval(86_400)
    let rows = [sample(0, 60, reset: reset.addingTimeInterval(60)), sample(300, 72), sample(300, 70)]
    let points = QuotaHistoryTrend.points(snapshots: rows, period: .day, now: now)
    #expect(points.map(\.snapshot.remainingPercent) == [70, 60])
    #expect(points.map(\.segment) == [0, 0])
  }

  @Test func csvExportsOnlySelectedSamplesAndUnambiguousTimes() {
    let points = QuotaHistoryTrend.points(snapshots: [sample(30 * 86_400 + 1), sample(0, 42.125)], period: .month, now: now)
    let csv = QuotaHistoryTrend.makeCSV(points: points, generatedAt: now)
    #expect(points.count == 1)
    #expect(csv.contains("42.125"))
    #expect(csv.contains(ISO8601DateFormatter().string(from: now)))
    #expect(csv.contains(",10080,1\n"))
    #expect(!csv.contains("/Users/"))
  }

  @Test func chartReductionPreservesExtremaAndSegmentBoundaries() {
    var rows: [QuotaHistoryPoint] = []
    for index in 0..<9_000 {
      let age: TimeInterval = Double(9_000 - index) * 10
      let remaining: Double = index == 4321 ? 0 : 80
      let snapshot = sample(age, remaining)
      rows.append(QuotaHistoryPoint(snapshot: snapshot, segment: index < 4500 ? 0 : 1))
    }
    let display = QuotaHistoryTrend.displayPoints(rows)
    #expect(display.count <= 1200)
    #expect(display.contains(rows[4321]))
    #expect(display.contains(rows[4499]))
    #expect(display.contains(rows[4500]))
    #expect(display.first == rows.first)
    #expect(display.last == rows.last)
    #expect(QuotaHistoryTrend.nearestPoint(to: rows[4321].id.addingTimeInterval(1), in: rows) == rows[4321])
    #expect(QuotaHistoryTrend.nearestPoint(to: now, in: []) == nil)
  }
}
