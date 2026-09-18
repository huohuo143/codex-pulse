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
    if !manual,
       let lastAppUpdateCheckAt,
       Date().timeIntervalSince(lastAppUpdateCheckAt) < 24 * 60 * 60 {
      return
    }

    appUpdateIsChecking = true
    if manual { appUpdateStatusMessage = "正在检查 GitHub Releases…" }
    let service = appUpdateService
    Task {
      do {
        let result = try await service.check(currentVersion: AppInfo.version)
        applyAppUpdateResult(result)
      } catch {
        if manual || latestAppRelease == nil {
          appUpdateStatusMessage = "版本检查失败：\(error.localizedDescription)"
        }
      }
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

  func restoreCachedAppUpdate(defaults: UserDefaults) {
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
  }

  func applyAppUpdateResult(_ result: AppUpdateResult, persist: Bool = true) {
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
