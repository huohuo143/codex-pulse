import Foundation
import Testing
import CodexBalanceCore
@testable import CodexBalance

@Suite("Account history maintenance")
struct AccountHistoryMaintenanceTests {
  @MainActor @Test func healthAndBackupFollowCurrentAccountHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let historyURL = root.appendingPathComponent("quota-history-qa-account.json")
    let history = QuotaHistoryStore(url: historyURL)
    let now = Date()
    history.record(window: .init(usedPercent: 20, remainingPercent: 80, windowMinutes: 10080,
      resetsAt: now.addingTimeInterval(86400)), at: now, now: now)
    let store = DashboardStore(startServices: false)
    store.quotaHistoryStore = history
    store.runReliabilityCheck(allowAutomation: false)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .quotaHistory }?.level == .healthy)
    let backupRoot = root.appendingPathComponent("archive")
    store.performLocalBackup(manual: false, now: now, archive: LocalAutomationArchive(root: backupRoot))
    let enumerator = try #require(FileManager.default.enumerator(at: backupRoot, includingPropertiesForKeys: nil))
    let copied = try #require(enumerator.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == historyURL.lastPathComponent })
    #expect(try Data(contentsOf: copied) == Data(contentsOf: historyURL))
    #expect(store.reliabilityMessage?.contains("已备份") == true)
  }
}
