import AppKit
import CodexBalanceCore
import Foundation
import Network
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

extension DashboardStore {
  func refreshCodexRadar(force: Bool = false) {
    guard codexRadarRefreshGate.request(force: force) else { return }
    recordRuntimeEvent("radar-request")
    codexRadarIsLoading = true
    codexRadarStatusMessage = "正在同步 Tibo 动态、站长推荐与智力效率…"
    let service = codexRadarService
    Task {
      do {
        let snapshot = try await service.current(force: force)
        applyCodexRadarSnapshot(snapshot)
      } catch {
        codexRadarStatusMessage = codexRadarSnapshot == nil
          ? error.localizedDescription
          : "更新失败，继续显示上次数据：\(error.localizedDescription)"
        dashboardLogger.error("Codex Radar refresh failed: \(error.localizedDescription, privacy: .public)")
        let failures = max(1, (codexRadarSnapshot?.syncState?.consecutiveFailures ?? 0) + 1)
        scheduleCodexRadarRetry(after: CodexRadarService.retryDelay(afterConsecutiveFailures: failures))
      }
      codexRadarIsLoading = false
      runPendingCodexRadarRefreshIfNeeded()
    }
  }

  func reevaluateCodexRadar() {
    let service = codexRadarService
    Task {
      guard let snapshot = await service.reevaluate() else { return }
      codexRadarSnapshot = snapshot
      recordRuntimeEvent("radar-local-evaluation")
      codexRadarLastSyncAt = DashboardStatusMergePolicy.radarReliabilityTimestamp(
        from: snapshot.syncState
      )
      updateCodexRadarStatusMessage(snapshot)
      if servicesEnabled {
        archiveRadarEvaluation(snapshot)
        writeWidgetSnapshotFile()
      }
    }
  }

  func applyCodexRadarSnapshot(_ snapshot: CodexRadarSnapshot) {
    codexRadarSnapshot = snapshot
    recordRuntimeEvent("radar-result")
    // Reliability must only advance after a real Tibo feed fetch succeeds.
    // A base/current.json response or a cached-feed recomputation is not a
    // successful source check and must not refresh the health timestamp.
    codexRadarLastSyncAt = DashboardStatusMergePolicy.radarReliabilityTimestamp(
      from: snapshot.syncState
    )
    updateCodexRadarStatusMessage(snapshot)
    if servicesEnabled {
      archiveRadarEvaluation(snapshot)
      writeWidgetSnapshotFile()
    }

    if let sync = snapshot.syncState, sync.isUsingCachedFeed {
      scheduleCodexRadarRetry(
        after: CodexRadarService.retryDelay(for: sync)
      )
    } else {
      codexRadarRetryTask?.cancel()
      codexRadarRetryTask = nil
      codexRadarNextSyncAt = codexRadarRefreshTimer?.fireDate ?? Date().addingTimeInterval(CodexRadarService.refreshInterval)
    }
  }

  func archiveRadarEvaluation(_ snapshot: CodexRadarSnapshot) {
    Task {
      do { radarEvaluation = try await radarEvaluationArchive.observe(snapshot) }
      catch { radarEvaluationMessage = "预测归档失败：\(error.localizedDescription)" }
    }
  }

  func saveRadarOutcome(_ outcome: RadarVerifiedOutcome) {
    Task {
      do {
        radarEvaluation = try await radarEvaluationArchive.record(outcome)
        radarEvaluationMessage = outcome.verified ? "已保存核实结果，评分已更新" : "已保存为待核实，不计入评分"
      } catch { radarEvaluationMessage = error.localizedDescription }
    }
  }

  func updateCodexRadarStatusMessage(_ snapshot: CodexRadarSnapshot) {
    guard let sync = snapshot.syncState else {
      codexRadarStatusMessage = snapshot.probabilityUpdate.map {
        "雷达更新于 \($0.formatted(date: .abbreviated, time: .shortened))"
      } ?? "Codex Radar 公开数据已更新"
      return
    }
    let checked = sync.lastAttemptAt?.formatted(date: .omitted, time: .shortened) ?? "--"
    let source = sync.feedUpdatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "--"
    codexRadarStatusMessage = "\(sync.statusLabel) · 本次检查 \(checked) · Tibo 源 \(source)"
  }

  func scheduleCodexRadarRetry(after delay: TimeInterval) {
    codexRadarRetryTask?.cancel()
    codexRadarNextSyncAt = Date().addingTimeInterval(delay)
    codexRadarRetryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.codexRadarRetryTask = nil
      self.refreshCodexRadar(force: true)
    }
  }

  func runPendingCodexRadarRefreshIfNeeded() {
    guard let force = codexRadarRefreshGate.finish() else { return }
    refreshCodexRadar(force: force)
  }

  func installCodexRadarLifecycleObservers() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.startAutoRefresh()
        self?.refreshCodexRadarAfterResume()
      }
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.startAutoRefresh()
        self?.refreshCodexRadarAfterResume()
      }
    }
  }

  func refreshCodexRadarAfterResume(now: Date = Date()) {
    recordRuntimeEvent("resume")
    refresh(forceFull: true)
    let lastSuccess = codexRadarSnapshot?.syncState?.lastSuccessAt
    if CodexRadarRefreshPolicy.shouldFetchAfterResume(
      lastSuccessAt: lastSuccess, now: now,
      consecutiveFailures: codexRadarSnapshot?.syncState?.consecutiveFailures ?? 0
    ) {
      refreshCodexRadar(force: true)
    } else {
      reevaluateCodexRadar()
    }
  }

  func handleCodexRadarNetworkUpdate(isAvailable: Bool, now: Date = Date()) {
    guard codexRadarNetworkRecoveryGate.shouldRefresh(
      isAvailable: isAvailable, sync: codexRadarSnapshot?.syncState, now: now
    )
    else { return }
    recordRuntimeEvent("radar-network-recovery")
    codexRadarRetryTask?.cancel()
    codexRadarRetryTask = nil
    refreshCodexRadar(force: true)
  }

  func installCodexRadarNetworkMonitor() {
    guard codexRadarNetworkMonitor == nil else { return }
    let monitor = NWPathMonitor()
    codexRadarNetworkMonitor = monitor
    monitor.pathUpdateHandler = { [weak self, weak monitor] path in
      let isAvailable = path.status == .satisfied
      Task { @MainActor in
        guard let self, let monitor, self.codexRadarNetworkMonitor === monitor else { return }
        self.handleCodexRadarNetworkUpdate(isAvailable: isAvailable)
      }
    }
    monitor.start(queue: DispatchQueue(label: "dev.codex.pulse.radar-network"))
  }

}
