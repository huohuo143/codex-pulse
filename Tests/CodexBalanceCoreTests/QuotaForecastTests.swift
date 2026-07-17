import Foundation
import Testing
@testable import CodexBalanceCore

@Suite
struct QuotaForecastTests {
  @Test
  func historyStoreSamplesChangesAndPrunesOldRows() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("quota-history.json")
    let store = QuotaHistoryStore(url: url)
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-17T04:00:00Z"))
    let reset = now.addingTimeInterval(4 * 24 * 3600)

    let old = LimitWindow(
      usedPercent: 5,
      remainingPercent: 95,
      windowMinutes: 10_080,
      resetsAt: reset,
      inferredReset: false
    )
    _ = store.record(window: old, at: now.addingTimeInterval(-31 * 24 * 3600), now: now)
    _ = store.record(window: old, at: now, now: now)
    _ = store.record(window: old, at: now.addingTimeInterval(60), now: now.addingTimeInterval(60))
    let changed = LimitWindow(
      usedPercent: 5.2,
      remainingPercent: 94.8,
      windowMinutes: 10_080,
      resetsAt: reset,
      inferredReset: false
    )
    _ = store.record(window: changed, at: now.addingTimeInterval(90), now: now.addingTimeInterval(90))

    #expect(store.snapshots().count == 2)
    #expect(store.snapshots().last?.remainingPercent == 94.8)
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test
  func historyStoreRejectsInferredOrNonSevenDayWindows() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = QuotaHistoryStore(url: root.appendingPathComponent("history.json"))
    let now = Date()

    _ = store.record(
      window: LimitWindow(
        usedPercent: 10,
        remainingPercent: 90,
        windowMinutes: 300,
        resetsAt: now.addingTimeInterval(3600),
        inferredReset: false
      ),
      at: now
    )
    _ = store.record(
      window: LimitWindow(
        usedPercent: 10,
        remainingPercent: 90,
        windowMinutes: 10_080,
        resetsAt: now.addingTimeInterval(3600),
        inferredReset: true
      ),
      at: now
    )

    #expect(store.snapshots().isEmpty)
  }

  @Test
  func steadyUsageProducesForecastAndHealthyRisk() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-17T12:00:00Z"))
    let reset = now.addingTimeInterval(24 * 3600)
    let rows = stride(from: 12, through: 0, by: -1).map { hoursAgo in
      QuotaSnapshot(
        recordedAt: now.addingTimeInterval(Double(-hoursAgo) * 3600),
        remainingPercent: 70 + Double(hoursAgo),
        resetsAt: reset,
        windowMinutes: 10_080
      )
    }
    let forecast = QuotaForecaster.forecast(snapshots: rows, current: rows.last, now: now)

    #expect(forecast.isUsable)
    #expect(abs((forecast.ratePerHour ?? 0) - 1) < 0.001)
    #expect(abs((forecast.expectedRemainingAtReset ?? 0) - 46) < 0.001)
    #expect(forecast.risk == .healthy)
    #expect(forecast.confidence == .medium)
  }

  @Test
  func forecastMarksLikelyEarlyExhaustionCritical() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-17T12:00:00Z"))
    let reset = now.addingTimeInterval(48 * 3600)
    let rows = stride(from: 8, through: 0, by: -1).map { hoursAgo in
      QuotaSnapshot(
        recordedAt: now.addingTimeInterval(Double(-hoursAgo) * 3600),
        remainingPercent: 20 + Double(hoursAgo * 3),
        resetsAt: reset,
        windowMinutes: 10_080
      )
    }
    let forecast = QuotaForecaster.forecast(snapshots: rows, current: rows.last, now: now)

    #expect(forecast.risk == .critical)
    #expect(forecast.estimatedExhaustion.map { $0 < reset.addingTimeInterval(-6 * 3600) } == true)
  }

  @Test
  func upwardCorrectionStartsNewLearningSegment() throws {
    let now = Date()
    let reset = now.addingTimeInterval(48 * 3600)
    let rows = [
      QuotaSnapshot(recordedAt: now.addingTimeInterval(-8 * 3600), remainingPercent: 70, resetsAt: reset, windowMinutes: 10_080),
      QuotaSnapshot(recordedAt: now.addingTimeInterval(-7 * 3600), remainingPercent: 69, resetsAt: reset, windowMinutes: 10_080),
      QuotaSnapshot(recordedAt: now.addingTimeInterval(-3 * 3600), remainingPercent: 80, resetsAt: reset, windowMinutes: 10_080),
      QuotaSnapshot(recordedAt: now.addingTimeInterval(-2 * 3600), remainingPercent: 79.9, resetsAt: reset, windowMinutes: 10_080),
      QuotaSnapshot(recordedAt: now.addingTimeInterval(-1 * 3600), remainingPercent: 79.8, resetsAt: reset, windowMinutes: 10_080),
      QuotaSnapshot(recordedAt: now, remainingPercent: 79.7, resetsAt: reset, windowMinutes: 10_080)
    ]
    let forecast = QuotaForecaster.forecast(snapshots: rows, current: rows.last, now: now)

    #expect(forecast.risk == .insufficientData)
    #expect(forecast.sampleCount == 4)
  }

  @Test
  func alertEvaluatorDeduplicatesThresholdAndCriticalCooldown() throws {
    let now = Date()
    let reset = now.addingTimeInterval(24 * 3600)
    let forecast = QuotaForecast(
      generatedAt: now,
      currentRemainingPercent: 14,
      resetsAt: reset,
      ratePerHour: 2,
      estimatedExhaustion: now.addingTimeInterval(7 * 3600),
      risk: .critical,
      confidence: .medium,
      sampleCount: 10,
      dataSpanHours: 10
    )
    let first = QuotaAlertEvaluator.evaluate(
      remainingPercent: 14,
      resetAt: reset,
      forecast: forecast,
      resetCredits: [],
      thresholds: [30, 15, 5],
      thresholdAlertsEnabled: true,
      forecastAlertsEnabled: true,
      resetCreditAlertsEnabled: true,
      ledger: QuotaAlertLedger(),
      now: now
    )
    let second = QuotaAlertEvaluator.evaluate(
      remainingPercent: 14,
      resetAt: reset,
      forecast: forecast,
      resetCredits: [],
      thresholds: [30, 15, 5],
      thresholdAlertsEnabled: true,
      forecastAlertsEnabled: true,
      resetCreditAlertsEnabled: true,
      ledger: first.ledger,
      now: now.addingTimeInterval(60)
    )

    #expect(first.candidates.contains { $0.kind == .threshold(15) })
    #expect(first.candidates.contains { $0.kind == .forecastCritical })
    #expect(second.candidates.isEmpty)
  }

  @Test
  func resetCreditExpiryAlertsOnce() {
    let now = Date()
    let credit = RateLimitResetCredit(
      title: "Full reset",
      grantedAt: now.addingTimeInterval(-3600),
      expiresAt: now.addingTimeInterval(20 * 3600)
    )
    let first = QuotaAlertEvaluator.evaluate(
      remainingPercent: nil,
      resetAt: nil,
      forecast: nil,
      resetCredits: [credit],
      thresholds: [],
      thresholdAlertsEnabled: false,
      forecastAlertsEnabled: false,
      resetCreditAlertsEnabled: true,
      ledger: QuotaAlertLedger(),
      now: now
    )
    let second = QuotaAlertEvaluator.evaluate(
      remainingPercent: nil,
      resetAt: nil,
      forecast: nil,
      resetCredits: [credit],
      thresholds: [],
      thresholdAlertsEnabled: false,
      forecastAlertsEnabled: false,
      resetCreditAlertsEnabled: true,
      ledger: first.ledger,
      now: now.addingTimeInterval(60)
    )

    #expect(first.candidates.count == 1)
    #expect(second.candidates.isEmpty)
  }
}
