import CodexBalanceCore
import Foundation
import Testing

@Suite("Quota alert delivery receipts")
struct QuotaAlertDeliveryTests {
  @Test func failuresRetryAfterCooldownAndOverlappingBatchesAreBlocked() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var state = QuotaAlertDeliveryState()
    let firstResult = state.begin(at: now)
    let first = try #require(firstResult)
    let overlappingResult = state.begin(at: now.addingTimeInterval(30))
    #expect(overlappingResult == nil)
    let failedFinish = state.finish(first, hadFailure: true, at: now)
    #expect(failedFinish)
    let earlyRetryResult = state.begin(at: now.addingTimeInterval(59))
    #expect(earlyRetryResult == nil)
    let retryResult = state.begin(at: now.addingTimeInterval(60))
    let retry = try #require(retryResult)
    let successfulFinish = state.finish(retry, hadFailure: false, at: now.addingTimeInterval(60))
    #expect(successfulFinish)
    #expect(state.retryAfter == nil)
    #expect(!state.isDelivering)
  }

  @Test func oldAccountCannotFinishNewAccountsBatch() throws {
    let now = Date()
    var state = QuotaAlertDeliveryState()
    let oldResult = state.begin(at: now)
    let old = try #require(oldResult)
    state.invalidate()
    let currentResult = state.begin(at: now)
    let current = try #require(currentResult)
    #expect(!state.isCurrent(old))
    let oldFinish = state.finish(old, hadFailure: true, at: now)
    #expect(!oldFinish)
    #expect(state.isCurrent(current))
    #expect(state.retryAfter == nil)
  }

  @Test func partialSuccessCommitsOnlyAcceptedThresholds() throws {
    let now = Date()
    let reset = now.addingTimeInterval(86400)
    let forecast = QuotaForecast(generatedAt: now, resetsAt: reset, risk: .critical)
    var ledger = QuotaAlertLedger()
    let evaluation = evaluate(ledger: ledger, forecast: forecast, reset: reset, now: now)
    let threshold = try #require(evaluation.candidates.first { $0.kind == .threshold(15) })
    #expect(ledger.sentKeys.isEmpty)
    QuotaAlertDeliveryCommit.accepted(threshold, ledger: &ledger, at: now)
    #expect(ledger.sentKeys.count == 2)
    #expect(ledger.lastForecastCriticalAt == nil)
    let retry = evaluate(ledger: ledger, forecast: forecast, reset: reset, now: now.addingTimeInterval(60))
    #expect(retry.candidates.map(\.kind) == [.forecastCritical])
    let accepted = try #require(retry.candidates.first)
    QuotaAlertDeliveryCommit.accepted(accepted, ledger: &ledger, at: now.addingTimeInterval(60))
    #expect(ledger.lastRisk == .critical)
    #expect(ledger.lastForecastCriticalAt == now.addingTimeInterval(60))
    #expect(evaluate(ledger: ledger, forecast: forecast, reset: reset,
      now: now.addingTimeInterval(120)).candidates.isEmpty)
  }

  @Test func individualCreditReceiptDoesNotMarkOtherCreditsSent() throws {
    let now = Date()
    let credits = (1...2).map { index in
      RateLimitResetCredit(title: "Full reset \(index)", grantedAt: now,
        expiresAt: now.addingTimeInterval(Double(index) * 3600))
    }
    var ledger = QuotaAlertLedger()
    let evaluation = QuotaAlertEvaluator.evaluate(remainingPercent: nil, resetAt: nil, forecast: nil,
      resetCredits: credits, thresholds: [], thresholdAlertsEnabled: false,
      forecastAlertsEnabled: false, resetCreditAlertsEnabled: true, ledger: ledger, now: now)
    QuotaAlertDeliveryCommit.accepted(try #require(evaluation.candidates.first), ledger: &ledger, at: now)
    #expect(ledger.sentKeys == ["credit.\(credits[0].id)"])
  }

  private func evaluate(ledger: QuotaAlertLedger, forecast: QuotaForecast, reset: Date, now: Date) -> QuotaAlertEvaluation {
    QuotaAlertEvaluator.evaluate(remainingPercent: 14, resetAt: reset, forecast: forecast,
      resetCredits: [], thresholds: [30, 15, 5], thresholdAlertsEnabled: true,
      forecastAlertsEnabled: true, resetCreditAlertsEnabled: false, ledger: ledger, now: now)
  }
}
