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
        return (history: history, forecast: QuotaForecaster.forecast(snapshots: history, current: current, now: now))
      }.value
      guard generation == forecastGeneration else { return }
      quotaHistory = result.history
      quotaForecast = result.forecast
      evaluateQuotaAlerts(now: now)
    }
  }

  func evaluateQuotaAlerts(now: Date = Date()) {
    guard quotaAlertsEnabled, notificationAuthorization == .authorized,
      !quotaAlertDeliveryState.isDelivering else { return }
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
    // Preserve a pending entry into critical until its notification is accepted. Otherwise a
    // failed re-entry within the prior six-hour cooldown would lose its eligibility to retry.
    if !evaluation.candidates.contains(where: { $0.kind == .forecastCritical }) {
      quotaAlertLedger.lastRisk = evaluation.ledger.lastRisk
    }
    persistQuotaAlertLedger()
    guard !evaluation.candidates.isEmpty,
      let attempt = quotaAlertDeliveryState.begin(at: now) else { return }
    let remaining = weekly?.remainingPercent
    let forecast = quotaForecast
    let account = status?.accountScope
    quotaAlertDeliveryTask = Task {
      var hadFailure = false
      defer {
        if quotaAlertDeliveryState.finish(attempt, hadFailure: hadFailure, at: Date()) {
          quotaAlertDeliveryTask = nil
        }
      }
      for candidate in evaluation.candidates {
        guard !Task.isCancelled, quotaAlertDeliveryState.isCurrent(attempt),
          status?.accountScope == account, quotaAlertsEnabled,
          notificationAuthorization == .authorized else { return }
        do {
          try await quotaNotificationService.deliver(candidate, remainingPercent: remaining, forecast: forecast)
          guard !Task.isCancelled, quotaAlertDeliveryState.isCurrent(attempt),
            status?.accountScope == account else { return }
          QuotaAlertDeliveryCommit.accepted(candidate, ledger: &quotaAlertLedger, at: Date())
          persistQuotaAlertLedger()
        } catch {
          guard quotaAlertDeliveryState.isCurrent(attempt), status?.accountScope == account else { return }
          hadFailure = true
          dashboardLogger.notice("额度通知暂未被系统接受，将在冷却后重试：\(error.localizedDescription, privacy: .private)")
        }
      }
    }
  }

  private func persistQuotaAlertLedger() {
    if let data = try? JSONEncoder().encode(quotaAlertLedger) {
      PulsePreferences.shared.set(data, forKey: "quotaAlertLedger")
    }
  }

  func prepareAccount(_ account: String?) {
    guard account != status?.accountScope else { return }
    quotaAlertDeliveryTask?.cancel()
    quotaAlertDeliveryTask = nil
    quotaAlertDeliveryState.invalidate()
    quotaHistoryStore = QuotaHistoryStore(url: PulsePaths.support.appendingPathComponent("quota-history-\(account ?? "unconfirmed").json"))
    quotaAlertLedger = QuotaAlertLedger()
    quotaHistory = []
    quotaForecast = nil
    lastForecastEvent = nil
    lastForecastAt = nil
    forecastGeneration += 1
  }

}
