import AppKit
import CodexBalanceCore
import SidebarCore
import SwiftUI

@MainActor
final class SidebarModel: ObservableObject {
  @Published var account: AccountSample?
  @Published var radar: RadarSnapshot?
  @Published var now = Date()
  @Published var accountFailed = false
  @Published var previewTrackingStatus = "等待定位"
  @Published var previewMoveResult = "等待模拟移动"
  @Published var visibility: SidebarVisibility
  @Published var enabled: Bool {
    didSet { defaults.set(enabled, forKey: "sidebarStatusEnabled") }
  }

  private let defaults: UserDefaults
  private var reading = false
  private var nextAccountRead = Date.distantPast
  private var lastRadarRead = Date.distantPast

  init(defaults: UserDefaults = PulsePreferences.shared) {
    self.defaults = defaults
    let legacy = PulsePreferences.isIsolated ? nil :
      UserDefaults.standard.persistentDomain(forName: "local.codexpulse.sidebar-status")
    visibility = SidebarVisibility.migrateAndLoad(from: defaults, legacy: legacy)
    enabled = defaults.object(forKey: "sidebarStatusEnabled") as? Bool ?? true
  }

  var isAccountCurrent: Bool {
    guard !accountFailed, let account, account.ok, let sampled = account.sampledAt else { return false }
    let age = now.timeIntervalSince1970 - sampled
    return age >= -5 && age < 5 * 60
  }

  func tick(visible: Bool) {
    let current = Date()
    if current.timeIntervalSince(now) >= 3 { now = current }
    if current.timeIntervalSince(lastRadarRead) >= 3 {
      lastRadarRead = current
      let path = PulsePaths.support.appendingPathComponent("widget-snapshot.json")
      let value = (try? Data(contentsOf: path)).flatMap { try? JSONDecoder().decode(RadarSnapshot.self, from: $0) }
      if value != radar { radar = value }
    }
    if visible && (visibility.quota || visibility.credits || visibility.reset) && current >= nextAccountRead {
      refreshAccount()
    }
  }

  func setVisibility(_ value: SidebarVisibility) {
    let needsAccount = (!visibility.quota && value.quota) || (!visibility.credits && value.credits) ||
      (!visibility.reset && value.reset)
    visibility = value
    value.save(to: defaults)
    if needsAccount { refreshAccount() }
  }

  func refreshAccount() {
    guard !reading else { return }
    reading = true
    nextAccountRead = Date().addingTimeInterval(60)
    let runningBundles = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
      .compactMap(\.bundleURL)
    let registeredBundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
    let directPaths = ["/Applications/ChatGPT.app", "/Applications/Codex.app"].map { URL(fileURLWithPath: $0) }
    let cli = (runningBundles + [registeredBundle].compactMap { $0 } + directPaths)
      .map(CodexApplicationPaths.embeddedCLI(in:))
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        cli.flatMap { CodexRPCReader.read(executable: $0) }
      }.value
      guard let self else { return }
      self.reading = false
      if let result, result.ok {
        self.account = result
        self.accountFailed = false
      } else {
        self.accountFailed = true
      }
      self.now = Date()
    }
  }
}
