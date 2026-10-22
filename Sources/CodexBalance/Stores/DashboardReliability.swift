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
    resetDailySummaryForNewDay(now: now)
    refreshReliabilityEvents()
    let next = ReliabilityAuditor.audit(
      inputs: ReliabilityAuditor.Inputs(
        lastQuotaRefresh: status?.quotaRead?.lastSuccessAt,
        hasOfficialQuota: weekly != nil,
        lastUsageRefresh: lastFullRefresh,
        usageSampleCount: tokenStats.sampleCount,
        radarUpdatedAt: codexRadarLastSyncAt,
        launchWatcherEnabled: CodexWatcherManager.isEnabled(),
        quotaHistoryURL: quotaHistoryStore.storageURL,
        projectBudgetsURL: projectBudgetStore.storageURL,
        quotaState: quotaState,
        quotaHistoryStorageMessage: quotaHistoryStorageMessage,
        projectBudgetStorageMessage: projectBudgetStorageIssue?.localizedDescription,
        projectBudgetWriteFailed: projectBudgetWriteFailed,
        creditExpiryStore: creditExpiryStore,
        creditExpiryStorageIssue: creditExpiryStorageIssue,
        creditExpiryWriteFailed: creditExpiryWriteFailed,
        localBackupHealth: localBackupHealth,
        automaticBackupsEnabled: reliabilityBackupsEnabled,
        eventStorageIssue: reliabilityEventStorageIssue,
        eventWriteFailed: reliabilityEventWriteFailed,
        dailySummaryHealth: dailySummaryHealth,
        dailySummaryEnabled: reliabilityDailySummaryEnabled,
        dailySummaryDue: reliabilityDailySummaryEnabled && Calendar.current.component(.hour, from: now) >= reliabilityDailySummaryHour,
        unreadableSessionFiles: status?.readerDiagnostics?.unreadableFiles ?? 0
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
    lastReliabilityLevel = reliabilitySnapshot.overall

    guard allowAutomation else { return }
    if canRunAutomaticBackup {
      Task { [weak self] in await self?.performLocalBackup(manual: false, now: now) }
    }
    if canRunAutomaticDailySummary(at: now) {
      Task { [weak self] in
        guard let self, self.canRunAutomaticDailySummary(at: now) else { return }
        await self.archiveDailySummary(now: now)
      }
    }
    if reliabilityHealthChecksEnabled, reliabilityAutoRecoveryEnabled {
      attemptAutomaticRecovery(snapshot: next, now: now)
    }
  }

  var canRunAutomaticBackup: Bool {
    // The first asynchronous quota read selects the account-specific history.
    // Do not let a startup backup of the legacy path consume the day's attempt.
    !isBackingUp && reliabilityBackupsEnabled && status?.accountScope?.isEmpty == false
  }

  var localBackupSourceURLs: [URL] {
    [quotaHistoryStore.storageURL, projectBudgetStore.storageURL, projectBudgetStore.previousURL,
      creditExpiryStore.url, creditExpiryStore.legacyURL, creditExpiryStore.previousURL,
      PulsePaths.support.appendingPathComponent("codex-reset-calendar-v1.json")]
  }

  func performLocalBackup(manual: Bool = true, now: Date = Date(), archive: LocalAutomationArchive? = nil) async {
    guard !isBackingUp else { return }
    isBackingUp = true
    defer {
      isBackingUp = false
      runReliabilityCheck(allowAutomation: false)
    }
    let storage = archive ?? localAutomationArchive
    let sources = localBackupSourceURLs
    let retryFailed = localBackupHealth == .failed
    do {
      let result = try await Task.detached(priority: .utility) { () -> LocalAutomationResult? in
        if !manual && !retryFailed && storage.hasBackup(for: now, sourceURLs: sources) { return nil }
        return try storage.backup(sourceURLs: sources, now: now, retentionDays: 7)
      }.value
      guard let result else { localBackupHealth = .verified; return }
      localBackupHealth = result.itemCount > 0 ? .verified : .noData
      reliabilityMessage = result.itemCount > 0
        ? "已备份 \(result.itemCount) 个关键数据文件"
        : "当前没有可备份的关键数据文件"
      if result.itemCount > 0 {
        appendReliabilityEvent(.init(
          timestamp: now,
          kind: .info,
          title: manual ? "手动备份完成" : "每日备份完成",
          detail: "已验证保存 \(result.itemCount) 个文件，保留最近 7 天"
        ))
      }
    } catch {
      localBackupHealth = .failed
      reliabilityMessage = "备份失败：\(error.localizedDescription)"
      appendReliabilityEvent(.init(timestamp: now, kind: .failure, title: "关键数据备份失败", detail: "本地归档未完成"))
    }
  }

  func exportDiagnosticReport() {
    guard !isExporting else { return }
    runReliabilityCheck(allowAutomation: false)
    let snapshot = reliabilitySnapshot
    let events = reliabilityEvents
    let panel = NSSavePanel()
    panel.title = "导出脱敏诊断报告"
    panel.prompt = "导出"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.plainText]
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmm"
    panel.nameFieldStringValue = "codex-pulse-diagnostics-\(formatter.string(from: Date())).md"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      await writeExport({
        ReliabilityReportBuilder.diagnosticMarkdown(appVersion: AppInfo.version, snapshot: snapshot, recentEvents: events)
      }, to: url, title: "脱敏诊断报告", successMessage: "诊断报告已导出：\(url.lastPathComponent)",
        failurePrefix: "诊断报告导出失败")
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

  func canRunAutomaticDailySummary(at now: Date) -> Bool {
    !isArchivingDailySummary && reliabilityDailySummaryEnabled
      && Calendar.current.component(.hour, from: now) >= reliabilityDailySummaryHour
      && dailySummaryDataReady
  }

  var dailySummaryDataReady: Bool {
    status?.accountScope?.isEmpty == false && weekly != nil && lastFullRefresh != nil
  }

  func resetDailySummaryForNewDay(now: Date) {
    guard !isArchivingDailySummary, let previous = lastDailySummaryAttempt,
      !Calendar.current.isDate(previous, inSameDayAs: now) else { return }
    dailySummaryHealth = .notChecked
    dailySummaryMessage = nil
    lastDailySummaryAttempt = nil
  }

  func archiveDailySummary(now: Date = Date(), archive: LocalAutomationArchive? = nil) async {
    guard !isArchivingDailySummary else { return }
    guard dailySummaryDataReady else {
      dailySummaryMessage = "等待本次启动的额度和用量读取完成后，再生成摘要。"
      return
    }
    isArchivingDailySummary = true
    lastDailySummaryAttempt = now
    defer {
      isArchivingDailySummary = false
      runReliabilityCheck(allowAutomation: false)
    }
    let storage = archive ?? localAutomationArchive
    let stats = tokenStats
    let budgets = projectBudgets
    let remainingPercent = weekly?.remainingPercent
    let quotaRisk = quotaForecast?.risk.rawValue ?? "insufficientData"
    let health = reliabilitySnapshot.overall
    do {
      let result = try await Task.detached(priority: .utility) {
        let analysis = UsageAnalyzer.analyze(stats: stats, budgets: budgets, now: now)
        let markdown = ReliabilityReportBuilder.dailySummaryMarkdown(
          remainingPercent: remainingPercent, rolling24hTokens: stats.rolling24HoursTokens,
          monthTokens: stats.monthTokens, projectedMonthTokens: analysis.projectedMonthTokens,
          quotaRisk: quotaRisk, health: health, generatedAt: now)
        return try storage.archiveDailySummary(markdown, now: now)
      }.value
      dailySummaryHealth = .verified
      if result.alreadyPresent {
        dailySummaryMessage = "今日摘要已存在并通过内容检查，保持原样。"
      } else if result.preservedOriginalURL != nil {
        dailySummaryMessage = "已保留不完整摘要原件，并重新生成今日摘要。"
      } else {
        dailySummaryMessage = "今日摘要已生成并验证保存。"
      }
      if !result.alreadyPresent {
        appendReliabilityEvent(.init(timestamp: now, kind: .info, title: "每日摘要已归档",
          detail: result.preservedOriginalURL == nil ? "已验证保存本机聚合指标" : "原摘要已独立保留，新摘要已验证保存"))
      }
    } catch {
      dailySummaryHealth = .failed
      let message = (error as? DailySummaryArchiveError)?.localizedDescription
        ?? DailySummaryArchiveError.writeFailed.localizedDescription
      dailySummaryMessage = "每日摘要归档失败：\(message)"
      appendReliabilityEvent(.init(timestamp: now, kind: .failure, title: "每日摘要归档失败", detail: "本地文件未写入"))
    }
  }

  func appendReliabilityEvent(_ event: ReliabilityEvent) {
    do {
      reliabilityEvents = try reliabilityEventStore.append(event)
      reliabilityEventStorageIssue = nil
      reliabilityEventWriteFailed = false
    } catch {
      reliabilityEventStorageIssue = (error as? ReliabilityEventStorageIssue) ?? .writeFailed
      reliabilityEventWriteFailed = true
      dashboardLogger.error("Reliability event write failed; existing record retained")
    }
    updateReliabilityEventHealth()
  }

  var reliabilityEventStorageMessage: String? {
    reliabilityEventStorageIssue?.localizedDescription
      ?? (reliabilityEventWriteFailed ? ReliabilityEventStorageIssue.writeFailed.localizedDescription : nil)
  }

  func refreshReliabilityEvents() {
    let result = reliabilityEventStore.loadResult()
    reliabilityEventStorageIssue = result.issue
    if result.issue == nil { reliabilityEvents = result.events }
  }

  func reloadReliabilityEvents() {
    refreshReliabilityEvents()
    updateReliabilityEventHealth()
  }

  func rebuildReliabilityEvents() {
    do {
      let preserved = try reliabilityEventStore.rebuildAfterPreservingCorruption()
      reliabilityEvents = []
      reliabilityEventStorageIssue = nil
      reliabilityEventWriteFailed = false
      appendReliabilityEvent(.init(kind: .recovery, title: "运行事件记录已重建", detail: "损坏原件已独立保留并验证"))
      reliabilityMessage = "已保留原件并重建记录：\(preserved.lastPathComponent)"
    } catch {
      reliabilityEventStorageIssue = (error as? ReliabilityEventStorageIssue) ?? .writeFailed
      reliabilityEventWriteFailed = true
      reliabilityMessage = "事件记录未重建：\(reliabilityEventStorageMessage ?? "请重新读取后重试")"
    }
    updateReliabilityEventHealth()
  }

  private func updateReliabilityEventHealth() {
    let now = Date()
    let check = ReliabilityAuditor.eventHistoryCheck(issue: reliabilityEventStorageIssue,
      writeFailed: reliabilityEventWriteFailed, now: now)
    var checks = reliabilitySnapshot.checks
    if let index = checks.firstIndex(where: { $0.id == .reliabilityEvents }) { checks[index] = check }
    else { checks.append(check) }
    reliabilitySnapshot = .init(generatedAt: now, checks: checks)
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
