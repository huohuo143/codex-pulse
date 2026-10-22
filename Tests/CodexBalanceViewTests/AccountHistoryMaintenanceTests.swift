import Foundation
import Testing
import CodexBalanceCore
@testable import CodexBalance

@Suite("Account history maintenance")
struct AccountHistoryMaintenanceTests {
  @MainActor @Test func healthAndBackupFollowCurrentAccountHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let historyURL = root.appendingPathComponent("quota-history-qa-account.json")
    let history = QuotaHistoryStore(url: historyURL)
    let now = Date()
    history.record(window: .init(usedPercent: 20, remainingPercent: 80, windowMinutes: 10080,
      resetsAt: now.addingTimeInterval(86400)), at: now, now: now)
    let store = DashboardStore(startServices: false)
    store.quotaHistoryStore = history
    let backupRoot = root.appendingPathComponent("archive")
    let archive = LocalAutomationArchive(root: backupRoot)
    #expect(!store.canRunAutomaticBackup)
    store.runReliabilityCheck(allowAutomation: false)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .quotaHistory }?.level == .healthy)
    await store.performLocalBackup(manual: false, now: now, archive: archive)
    let enumerator = try #require(FileManager.default.enumerator(at: backupRoot, includingPropertiesForKeys: nil))
    let copied = try #require(enumerator.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == historyURL.lastPathComponent })
    #expect(try Data(contentsOf: copied) == Data(contentsOf: historyURL))
    #expect(store.reliabilityMessage?.contains("已备份") == true)
    #expect(archive.hasBackup(for: now, sourceURLs: [historyURL]))
  }
}
