import AppKit
import CodexBalanceCore
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

extension DashboardStore {
  func startReliabilityAutomation() {
    guard reliabilityTimer == nil else { return }
    runReliabilityCheck()
    guard reliabilityHealthChecksEnabled || reliabilityBackupsEnabled || reliabilityDailySummaryEnabled else { return }
    let timer = Timer(timeInterval: reliabilityIntervalOption.seconds, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.runReliabilityCheck() }
    }
    timer.tolerance = min(120, reliabilityIntervalOption.seconds * 0.1)
    RunLoop.main.add(timer, forMode: .common)
    reliabilityTimer = timer
  }

  func runReliabilityCheck(manual: Bool = false, allowAutomation: Bool = true) {
    let now = Date()
    let next = ReliabilityAuditor.audit(
      inputs: ReliabilityAuditor.Inputs(
        lastQuotaRefresh: status?.quotaRead?.lastSuccessAt,
        hasOfficialQuota: weekly != nil,
        lastUsageRefresh: lastFullRefresh,
        usageSampleCount: tokenStats.sampleCount,
        radarUpdatedAt: codexRadarLastSyncAt,
        launchWatcherEnabled: CodexWatcherManager.isEnabled(),
        quotaHistoryURL: quotaHistoryStore.storageURL,
        quotaState: quotaState
      ),
      now: now
    )
    reliabilitySnapshot = next

    if manual {
      appendReliabilityEvent(.init(
        timestamp: now,
        kind: .info,
        title: "手动健康检查完成",
        detail: "\(next.criticalCount) 项异常，\(next.warningCount) 项需关注"
      ))
      reliabilityMessage = "健康检查已完成"
    } else if let previous = lastReliabilityLevel, previous != next.overall, next.overall != .unknown {
      let recovered = previous.rank > next.overall.rank
      appendReliabilityEvent(.init(
        timestamp: now,
        kind: recovered ? .recovery : .warning,
        title: recovered ? "可靠性状态恢复" : "可靠性状态变化",
        detail: "当前状态：\(reliabilityLevelLabel(next.overall))"
      ))
    }
    lastReliabilityLevel = next.overall

    guard allowAutomation else { return }
    if reliabilityBackupsEnabled, !localAutomationArchive.hasBackup(for: now) {
      performLocalBackup(manual: false, now: now)
    }
    if reliabilityDailySummaryEnabled,
       Calendar.current.component(.hour, from: now) >= reliabilityDailySummaryHour,
       !localAutomationArchive.hasDailySummary(for: now) {
      archiveDailySummary(now: now)
    }
    if reliabilityHealthChecksEnabled, reliabilityAutoRecoveryEnabled {
      attemptAutomaticRecovery(snapshot: next, now: now)
    }
  }

  func performLocalBackup(manual: Bool = true, now: Date = Date(), archive: LocalAutomationArchive? = nil) {
    do {
      let result = try (archive ?? localAutomationArchive).backup(
        sourceURLs: [quotaHistoryStore.storageURL, ProjectBudgetStore.defaultURL],
        now: now,
        retentionDays: 7
      )
      reliabilityMessage = result.itemCount > 0
        ? "已备份 \(result.itemCount) 个关键数据文件"
        : "当前没有可备份的关键数据文件"
      appendReliabilityEvent(.init(
        timestamp: now,
        kind: .info,
        title: manual ? "手动备份完成" : "每日备份完成",
        detail: "已保存 \(result.itemCount) 个文件，保留最近 7 天"
      ))
    } catch {
      reliabilityMessage = "备份失败：\(error.localizedDescription)"
      appendReliabilityEvent(.init(timestamp: now, kind: .failure, title: "关键数据备份失败", detail: "本地归档未完成"))
    }
  }

  func exportDiagnosticReport() {
    runReliabilityCheck(allowAutomation: false)
    let panel = NSSavePanel()
    panel.title = "导出脱敏诊断报告"
    panel.prompt = "导出"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.plainText]
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmm"
    panel.nameFieldStringValue = "codex-pulse-diagnostics-\(formatter.string(from: Date())).md"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let markdown = ReliabilityReportBuilder.diagnosticMarkdown(
      appVersion: AppInfo.version,
      snapshot: reliabilitySnapshot,
      recentEvents: reliabilityEvents
    )
    do {
      try markdown.write(to: url, atomically: true, encoding: .utf8)
      reliabilityMessage = "诊断报告已导出：\(url.lastPathComponent)"
    } catch {
      reliabilityMessage = "诊断报告导出失败：\(error.localizedDescription)"
    }
  }

  func openAutomationFolder() {
    do {
      try FileManager.default.createDirectory(at: LocalAutomationArchive.defaultRoot, withIntermediateDirectories: true)
      NSWorkspace.shared.open(LocalAutomationArchive.defaultRoot)
    } catch {
      reliabilityMessage = "无法打开自动化目录：\(error.localizedDescription)"
    }
  }

  func restartReliabilityAutomation() {
    reliabilityTimer?.invalidate()
    reliabilityTimer = nil
    DispatchQueue.main.async { [weak self] in self?.startReliabilityAutomation() }
  }

  func attemptAutomaticRecovery(snapshot: ReliabilitySnapshot, now: Date) {
    let recoverable = snapshot.checks.filter {
      $0.level == .critical && [.officialQuota, .tokenAggregation, .radar, .widgetSnapshot].contains($0.id)
    }
    guard !recoverable.isEmpty else {
      if automaticRecoveryAttempts != 0 {
        automaticRecoveryAttempts = 0
        save(0, "automaticRecoveryAttempts")
      }
      return
    }
    guard automaticRecoveryAttempts < 2 else {
      reliabilityMessage = "自动恢复已达到本轮上限，等待下一次有效刷新"
      return
    }
    if let lastAutomaticRecoveryAt, now.timeIntervalSince(lastAutomaticRecoveryAt) < 15 * 60 { return }

    lastAutomaticRecoveryAt = now
    automaticRecoveryAttempts += 1
    save(now, "lastAutomaticRecoveryAt")
    save(automaticRecoveryAttempts, "automaticRecoveryAttempts")

    let ids = Set(recoverable.map(\.id))
    if ids.contains(.officialQuota) || ids.contains(.tokenAggregation) {
      refresh(forceFull: true)
    }
    if ids.contains(.radar) {
      refreshCodexRadar(force: true)
    }
    if ids.contains(.widgetSnapshot) {
      writeWidgetSnapshotFile()
    }
    appendReliabilityEvent(.init(
      timestamp: now,
      kind: .recovery,
      title: "已触发受控自动恢复",
      detail: "重新读取额度、汇总或刷新快照；第 \(automaticRecoveryAttempts)/2 次"
    ))
    reliabilityMessage = "已触发受控自动恢复"
  }

  func archiveDailySummary(now: Date) {
    let markdown = ReliabilityReportBuilder.dailySummaryMarkdown(
      remainingPercent: weekly?.remainingPercent,
      rolling24hTokens: tokenStats.rolling24HoursTokens,
      monthTokens: tokenStats.monthTokens,
      projectedMonthTokens: usageAnalysis.projectedMonthTokens,
      quotaRisk: quotaForecast?.risk.rawValue ?? "insufficientData",
      health: reliabilitySnapshot.overall,
      generatedAt: now
    )
    do {
      _ = try localAutomationArchive.archiveDailySummary(markdown, now: now)
      appendReliabilityEvent(.init(timestamp: now, kind: .info, title: "每日摘要已归档", detail: "已保存本机聚合指标"))
      reliabilityMessage = "今日自动摘要已归档"
    } catch {
      appendReliabilityEvent(.init(timestamp: now, kind: .failure, title: "每日摘要归档失败", detail: "本地文件未写入"))
      reliabilityMessage = "每日摘要归档失败：\(error.localizedDescription)"
    }
  }

  func appendReliabilityEvent(_ event: ReliabilityEvent) {
    do {
      reliabilityEvents = try reliabilityEventStore.append(event)
    } catch {
      dashboardLogger.error("Reliability event write failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  func reliabilityLevelLabel(_ level: ReliabilityHealthLevel) -> String {
    switch level {
    case .healthy: "健康"
    case .warning: "需关注"
    case .critical: "异常"
    case .unknown: "学习中"
    }
  }

}
