import AppKit
import CodexBalanceCore
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

extension DashboardStore {
  func updateTouchBar() {
    writeLiveBalanceFile()
    writeWidgetSnapshotFile()
    publishMobileSnapshots()
    guard touchBarEnabled else { return }
    TouchBarStripController.shared.update(codex: .init(
      color24h: NSColor(palette.usage24h),
      color7d: NSColor(palette.weekly),
      percent7d: weekly?.remainingPercent,
      reset7d: weekly?.resetsAt,
      tokens24h: hasUsageData ? tokenStats.rolling24HoursTokens : nil,
      cost24hUSD: tokenStats.cost24Hours.usd,
      quotaStatus: quotaState == .cached ? " 缓存" : "",
      costText: hasUsageData ? tokenStats.cost24Hours.displayUSD : "统计中…"
    ))
    pushSessionsToTouchBar()
  }

  func publishMobileSnapshots() {
    if var mobileStatus = status {
      // This is publication time; quotaRead/usageAt retain their source times.
      // A radar-only update must not wait for another quota polling result.
      mobileStatus.generatedAt = Date()
      let usageAt = lastFullRefresh
      let history = quotaAlertAccountScope == mobileStatus.accountScope ? quotaHistory : []
      let forecast = quotaAlertAccountScope == mobileStatus.accountScope ? quotaForecast : nil
      let budgets = projectBudgets; let radar = codexRadarSnapshot
      let rate = exchangeRate; let health = reliabilitySnapshot
      Task { [mobileStatus] in
        do {
          if try await mobileSnapshotPublisher.publish(mobileStatus) != nil {
            mobileSyncStatus = "移动快照已导出 · " + mobileStatus.generatedAt.formatted(date: .omitted, time: .shortened)
          } else if MobileSnapshotPublisher.defaultRoot() == nil {
            mobileSyncStatus = "未找到 iCloud Drive，请在系统设置中启用"
          }
          try await mobileSnapshotPublisher.publishDetails(status: mobileStatus, usageAt: usageAt,
            history: history, forecast: forecast, budgets: budgets, radar: radar, rate: rate, health: health)
        } catch {
          mobileSyncStatus = "移动快照写入失败，已保留上次有效文件"
          dashboardLogger.error("Mobile snapshot write failed; retained previous snapshot.")
        }
      }
    }
  }

  func pushSessionsToTouchBar() {
    guard touchBarEnabled else { return }
    guard touchBarShowsSessions else { TouchBarStripController.shared.updateSessions([]); return }
    let limit = touchBarSessionCount
    Task.detached(priority: .utility) {
      let sessions = RecentSessionScanner.shared.recentSessions(limit: limit)
      await MainActor.run { TouchBarStripController.shared.updateSessions(sessions) }
    }
  }

  func writeLiveBalanceFile() {
    let stats = tokenStats
    var codex: [String: Any] = [
      "rolling24h": hasUsageData ? stats.rolling24HoursTokens as Any : NSNull(),
      "week": hasUsageData ? stats.last7DaysTokens as Any : NSNull(),
      "month": hasUsageData ? stats.monthTokens as Any : NSNull(),
      "cost24hUSD": hasUsageData && stats.cost24Hours.hasEstimate ? stats.cost24Hours.usd as Any : NSNull(),
      "pricingCoverage": hasUsageData ? stats.cost24Hours.coveragePercent as Any : NSNull(),
      "pricingBasis": "按当前价格表折算",
      "usageState": hasUsageData ? "ready" : "pending",
      "quotaState": quotaStatusLabel
    ]
    if let p7 = weekly?.remainingPercent { codex["p7"] = p7 }
    if let r7 = weekly?.resetsAt { codex["r7"] = r7.timeIntervalSince1970 }
    codex["categories"] = stats.categoryBreakdown
      .filter { $0.totalTokens > 0 }
      .map {
        [
          "id": $0.category.rawValue,
          "label": $0.category.label,
          "tokens": $0.totalTokens,
          "calls": $0.calls
        ] as [String: Any]
      }
    codex["todayProjects"] = stats.todayTopProjects.map {
      ["name": $0.projectName, "tokens": $0.totalTokens, "calls": $0.calls] as [String: Any]
    }
    codex["monthProjects"] = stats.monthTopProjects.map {
      ["name": $0.projectName, "tokens": $0.totalTokens, "calls": $0.calls] as [String: Any]
    }
    var root: [String: Any] = ["updatedAt": Date().timeIntervalSince1970, "codex": codex]
    if let lastFullRefresh { root["statsUpdatedAt"] = lastFullRefresh.timeIntervalSince1970 }
    guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
    Task { await snapshotPublisher.publishLive(data) }
  }

  func writeWidgetSnapshotFile() {
    // Startup tasks such as exchange-rate loading and Radar refresh can finish
    // before the first authoritative quota read. Preserve the last Widget file
    // until a real status exists instead of overwriting it with an empty quota.
    guard status != nil else { return }
    let stats = tokenStats
    let radar = codexRadarSnapshot
    let credits = rateLimitResetCredits
    var snapshot = CodexWidgetSnapshot(
      updatedAt: Date(),
      remainingPercent: weekly?.remainingPercent,
      usedPercent: weekly?.usedPercent,
      resetsAt: weekly?.resetsAt,
      fiveHourRemainingPercent: fiveHour?.remainingPercent,
      fiveHourUsedPercent: fiveHour?.usedPercent,
      fiveHourResetsAt: fiveHour?.resetsAt,
      showsFiveHourQuota: widgetShowsFiveHourQuota,
      rolling24HoursTokens: stats.rolling24HoursTokens,
      todayTokens: stats.todayTokens,
      last7DaysTokens: stats.last7DaysTokens,
      monthTokens: stats.monthTokens,
      cost24HoursUSD: stats.cost24Hours.usd,
      cost7DaysUSD: stats.cost7Days.usd,
      costMonthUSD: stats.costMonth.usd,
      cnyRate: exchangeRate?.rate,
      resetProbability24h: nil,
      radarLevel: radar?.tiboStatusTitle,
      radarSummary: radar?.tiboStatusSummary,
      radarUpdatedAt: radar?.tiboAnalysis?.analyzedAt,
      radarCheckedAt: radar?.syncState?.lastAttemptAt,
      radarLastSuccessAt: radar?.syncState?.lastSuccessAt,
      radarSourceUpdatedAt: radar?.syncState?.feedUpdatedAt,
      radarEvidenceUpdatedAt: radar?.tiboFeed?.posts.filter { radar?.tiboAnalysis?.evidenceIDs.contains($0.id) == true }.compactMap(\.publishedAt).max(),
      radarEvaluatedAt: radar?.tiboAnalysis?.analyzedAt,
      radarValidUntil: radar?.tiboStatusValidUntil,
      radarSyncStatus: radar.map { $0.tiboDisplayRefreshIsHealthy(at: Date()) ? "刷新正常" : "等待刷新或分析" },
      radarConsecutiveFailures: radar?.syncState?.consecutiveFailures,
      radarIsUsingCachedFeed: radar?.syncState?.isUsingCachedFeed,
      radarIsStale: radar?.syncState?.isStale,
      resetCreditsAvailable: credits?.availableCount,
      resetCredits: credits?.availableCredits.map {
        CodexWidgetResetCredit(title: $0.title, expiresAt: $0.expiresAt)
      } ?? [],
      sampleCount: stats.sampleCount,
      deviceCount: stats.deviceUsage.count,
      hourly24: stats.hourly.suffix(24).map {
        CodexWidgetPoint(label: $0.label, tokens: $0.totalTokens)
      },
      daily14: stats.daily.suffix(14).map {
        CodexWidgetPoint(label: $0.label, tokens: $0.totalTokens)
      },
      topProjects: stats.todayTopProjects.prefix(3).map {
        CodexWidgetMetric(label: $0.projectName, tokens: $0.totalTokens)
      },
      topCategories: stats.categoryBreakdown
        .filter { $0.totalTokens > 0 }
        .sorted { $0.totalTokens > $1.totalTokens }
        .prefix(3)
        .map { CodexWidgetMetric(label: $0.category.label, tokens: $0.totalTokens) }
    )

    snapshot.quotaHistory = QuotaHistoryTrend.widgetHistory(
      snapshots: quotaAlertAccountScope == status?.accountScope ? quotaHistory : [], now: snapshot.updatedAt)
    snapshot.quotaRead = status?.quotaRead
    snapshot.flexibleCreditRead = status?.flexibleCreditRead
    snapshot.resetCreditsRead = status?.resetCreditsRead
    snapshot.cost24Coverage = stats.cost24Hours.coveragePercent
    snapshot.cost7Coverage = stats.cost7Days.coveragePercent
    snapshot.costMonthCoverage = stats.costMonth.coveragePercent
    snapshot.unpricedModels = stats.costMonth.unpricedModels
    snapshot.radarDeadlineAt = radar?.tiboDeadline(at: Date())?.date
    snapshot.radarCompletionUntil = radar?.tiboCompletionUntil(at: Date())
    snapshot.radarAnnouncementActive = radar?.tiboHasAnnouncement(at: Date())

    snapshot.usageUpdatedAt = lastFullRefresh
    snapshot.usageValidUntil = status?.usageValidUntil
    snapshot.confirmedCreditExpiry = creditExpiry.nextExplicitExpiry(for: status?.accountScope)
    eInk.ingest(snapshot, accountScope: status?.accountScope)
    pendingSnapshotTask?.cancel()
    pendingSnapshotTask = Task { [weak self, snapshot] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled, let self else { return }
      do {
        let affected = try await self.snapshotPublisher.publish(snapshot)
        self.pendingWidgetKinds.formUnion(affected)
        self.requestWidgetReload(needsReload: !affected.isEmpty, now: Date(), radarChanged: affected.contains(.radar))
      } catch { dashboardLogger.error("Widget write failed: \(error.localizedDescription, privacy: .public)") }
    }
  }

  func requestWidgetReload(needsReload: Bool, now: Date, radarChanged: Bool = false) {
    let decision = widgetReloadPolicy.decision(
      needsReload: needsReload,
      lastReloadAt: lastWidgetReloadAt,
      hasPendingReload: pendingWidgetReloadTask != nil,
      now: now,
      radarChanged: radarChanged
    )

    switch decision {
    case .none:
      return
    case .reloadNow:
      pendingWidgetReloadTask?.cancel()
      pendingWidgetReloadTask = nil
      reloadAllWidgetTimelines(at: now)
    case .schedule(let delay):
      pendingWidgetReloadTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, let self else { return }
        self.pendingWidgetReloadTask = nil
        self.reloadAllWidgetTimelines(at: Date())
      }
    }
  }

  func reloadAllWidgetTimelines(at date: Date) {
    for kind in pendingWidgetKinds { WidgetCenter.shared.reloadTimelines(ofKind: kind.identifier) }
    pendingWidgetKinds.removeAll()
    lastWidgetReloadAt = date
  }

}
