import AppKit
import CodexBalanceCore
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

extension DashboardStore {
  func updateUsageAnalysis(now: Date = Date()) {
    var stats = tokenStats
    stats.accountUsage = nil
    stats.deviceUsage = []
    guard stats != lastAnalysisStats else { return }
    lastAnalysisStats = stats
    let input = stats
    analysisGeneration += 1
    let generation = analysisGeneration
    let budgets = projectBudgets
    Task {
      let result = await Task.detached(priority: .utility) { UsageAnalyzer.analyze(stats: input, budgets: budgets, now: now) }.value
      guard generation == analysisGeneration else { return }
      usageAnalysis = result
    }
  }

  func updateQuotaForecast(now: Date = Date()) {
    let state = quotaState
    let event = state == .fresh ? status?.main : nil
    guard event != lastForecastEvent || state != lastForecastState || lastForecastAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
    lastForecastEvent = event; lastForecastState = state; lastForecastAt = now
    forecastGeneration += 1
    let generation = forecastGeneration
    let storage = quotaHistoryStore
    Task {
      let result = await Task.detached(priority: .utility) {
        var history = storage.snapshots()
        var current: QuotaSnapshot?
        if let event, let window = event.sevenDayWindow, let reset = window.resetsAt, !window.inferredReset {
          history = storage.record(window: window, at: event.timestamp, now: now)
          current = QuotaSnapshot(recordedAt: event.timestamp, remainingPercent: window.remainingPercent,
            resetsAt: reset, windowMinutes: window.windowMinutes)
        }
        return QuotaForecaster.forecast(snapshots: history, current: current, now: now)
      }.value
      guard generation == forecastGeneration else { return }
      quotaForecast = result
      evaluateQuotaAlerts(now: now)
    }
  }

  func evaluateQuotaAlerts(now: Date = Date()) {
    guard quotaAlertsEnabled, notificationAuthorization == .authorized else { return }
    let evaluation = QuotaAlertEvaluator.evaluate(
      remainingPercent: weekly?.remainingPercent,
      resetAt: weekly?.resetsAt,
      forecast: quotaForecast,
      resetCredits: rateLimitResetCredits?.availableCredits ?? [],
      thresholds: quotaAlertPreset.thresholds,
      thresholdAlertsEnabled: quotaThresholdAlertsEnabled && quotaState == .fresh,
      forecastAlertsEnabled: quotaForecastAlertsEnabled && quotaState == .fresh,
      resetCreditAlertsEnabled: quotaResetCreditAlertsEnabled && status?.resetCreditsRead?.state(at: now) == .fresh,
      ledger: quotaAlertLedger,
      now: now
    )
    quotaAlertLedger = evaluation.ledger
    if let data = try? JSONEncoder().encode(quotaAlertLedger) {
      PulsePreferences.shared.set(data, forKey: "quotaAlertLedger")
    }
    guard !evaluation.candidates.isEmpty else { return }
    let remaining = weekly?.remainingPercent
    let forecast = quotaForecast
    Task {
      for candidate in evaluation.candidates {
        await quotaNotificationService.deliver(candidate, remainingPercent: remaining, forecast: forecast)
      }
    }
  }

  func prepareAccount(_ account: String?) {
    guard account != status?.accountScope else { return }
    quotaHistoryStore = QuotaHistoryStore(url: PulsePaths.support.appendingPathComponent("quota-history-\(account ?? "unconfirmed").json"))
    quotaAlertLedger = QuotaAlertLedger()
    lastForecastEvent = nil
    forecastGeneration += 1
  }

}
