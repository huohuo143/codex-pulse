import AppKit
import CodexBalanceCore
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

extension DashboardStore {
  func startAppUpdateChecks() {
    guard automaticUpdateChecksEnabled else { return }
    if appUpdateTimer == nil {
      let timer = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.checkForAppUpdate(manual: false) }
      }
      timer.tolerance = 15 * 60
      RunLoop.main.add(timer, forMode: .common)
      appUpdateTimer = timer
    }
    checkForAppUpdate(manual: false)
  }

  func checkForAppUpdate(manual: Bool = true) {
    guard !appUpdateIsChecking else { return }
    if !manual, appUpdateLastCheckError == nil,
       let lastAppUpdateCheckAt,
       Date().timeIntervalSince(lastAppUpdateCheckAt) < 24 * 60 * 60 {
      return
    }

    if let retryAt = appUpdateRetryAt, retryAt > Date() { return }
    appUpdateIsChecking = true
    if manual { appUpdateStatusMessage = "正在检查 GitHub Releases…" }
    let service = appUpdateService
    Task {
      do {
        let result = try await service.check(currentVersion: AppInfo.version)
        applyAppUpdateResult(result)
      } catch {
        appUpdateLastCheckError = error.localizedDescription
        if manual || latestAppRelease == nil {
          let retained = latestAppReleaseVersionText.map { " · 已保留 \($0) 的上次结果" } ?? ""
          appUpdateStatusMessage = error.localizedDescription + retained
        }
      }
      let retryState = await service.retryStateSnapshot()
      appUpdateRetryAt = retryState.nextAttemptAt
      if let data = try? JSONEncoder().encode(retryState) { PulsePreferences.shared.set(data, forKey: "appUpdateRetryState") }
      scheduleAppUpdateRetry()
      appUpdateIsChecking = false
    }
  }

  func openAppUpdatePage() {
    let fallback = URL(string: AppInfo.releasesURL)
    let candidate = latestAppRelease?.htmlURL ?? fallback
    guard let candidate, candidate.scheme == "https",
          let host = candidate.host?.lowercased(),
          host == "github.com" || host.hasSuffix(".github.com")
    else {
      appUpdateStatusMessage = "更新页面地址无效"
      return
    }
    NSWorkspace.shared.open(candidate)
  }

  func restartAppUpdateChecks() {
    appUpdateRetryTimer?.invalidate()
    appUpdateRetryTimer = nil
    appUpdateTimer?.invalidate()
    appUpdateTimer = nil
    guard automaticUpdateChecksEnabled else {
      appUpdateStatusMessage = lastAppUpdateCheckAt == nil
        ? "自动版本检查已关闭"
        : "自动版本检查已关闭 · 可手动检查"
      return
    }
    DispatchQueue.main.async { [weak self] in self?.startAppUpdateChecks() }
  }

  func scheduleAppUpdateRetry() {
    appUpdateRetryTimer?.invalidate()
    appUpdateRetryTimer = nil
    guard servicesEnabled, automaticUpdateChecksEnabled, let retryAt = appUpdateRetryAt else { return }
    let timer = Timer(timeInterval: max(1, retryAt.timeIntervalSinceNow), repeats: false) { [weak self] _ in
      Task { @MainActor in self?.checkForAppUpdate(manual: false) }
    }
    RunLoop.main.add(timer, forMode: .common)
    appUpdateRetryTimer = timer
  }

  func restoreCachedAppUpdate(defaults: UserDefaults) {
    appUpdateRetryAt = AppUpdateRetryState(data: defaults.data(forKey: "appUpdateRetryState")).nextAttemptAt
    if let retryAt = appUpdateRetryAt, retryAt > Date() { appUpdateLastCheckError = "暂未刷新版本信息"; scheduleAppUpdateRetry() }
    guard let data = defaults.data(forKey: "cachedAppRelease"),
          let release = try? JSONDecoder().decode(AppRelease.self, from: data),
          let currentVersion = SemanticVersion(AppInfo.version),
          let checkedAt = defaults.object(forKey: "lastAppUpdateCheckAt") as? Date,
          let result = try? GitHubReleaseUpdateService.evaluate(
            release: release,
            currentVersion: currentVersion,
            checkedAt: checkedAt
          )
    else { return }
    applyAppUpdateResult(result, persist: false)
    if let retryAt = appUpdateRetryAt, retryAt > Date() {
      appUpdateLastCheckError = "暂未刷新版本信息"
      appUpdateStatusMessage = "暂未刷新版本信息 · 已保留 " + release.tagName + " 的上次结果"
    }
  }

  func applyAppUpdateResult(_ result: AppUpdateResult, persist: Bool = true) {
    appUpdateLastCheckError = nil
    latestAppRelease = result.release
    appUpdateAvailability = result.availability
    lastAppUpdateCheckAt = result.checkedAt
    let remote = result.release.version.map { "v\($0)" } ?? result.release.tagName
    switch result.availability {
    case .updateAvailable:
      appUpdateStatusMessage = "发现新版本 \(remote)"
    case .upToDate:
      appUpdateStatusMessage = "当前已是最新版本 \(remote)"
    case .localVersionNewer:
      appUpdateStatusMessage = "当前 v\(AppInfo.version) 高于线上最新 \(remote)"
    }
    guard persist else { return }
    let defaults = PulsePreferences.shared
    if let data = try? JSONEncoder().encode(result.release) {
      defaults.set(data, forKey: "cachedAppRelease")
    }
    defaults.set(result.checkedAt, forKey: "lastAppUpdateCheckAt")
  }

}
