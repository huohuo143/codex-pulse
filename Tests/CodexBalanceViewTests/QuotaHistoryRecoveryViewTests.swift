import Foundation
import Testing
import CodexBalanceCore
@testable import CodexBalance

@MainActor @Suite("Quota history recovery feedback", .serialized)
struct QuotaHistoryRecoveryViewTests {
  @Test(arguments: [false, true])
  func refreshSurfacesRecoveryStateAndAccountSwitchClearsIt(futureVersion: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("quota-history.json")
    let original = Data((futureVersion ? #"{"schemaVersion":2,"futureHistory":[]}"# : "{damaged history").utf8)
    try original.write(to: url)
    let storage = QuotaHistoryStore(url: url)
    let store = DashboardStore(startServices: false)
    store.quotaHistoryStore = storage
    let now = Date()
    let event = RateLimitEvent(timestamp: now, sourceName: "隔离验收", sourcePath: "fixture", limitID: "codex", limitName: "Codex",
      secondary: .init(usedPercent: 20, remainingPercent: 80, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400)))
    var status = CodexStatus(codexHome: "fixture", sessionsRoot: "fixture", main: event, limits: [event])
    status.accountScope = "synthetic-a"
    status.quotaRead = .init(source: "隔离验收", sampledAt: now, lastAttemptAt: now, lastSuccessAt: now)
    store.status = status
    store.updateQuotaForecast(now: now)
    for _ in 0..<200 {
      if store.quotaHistoryStorageMessage != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.quotaHistoryStorageMessage == storage.storageMessage)
    #expect(store.quotaHistoryStorageMessage != nil)
    #expect(store.quotaHistory.count == 1)
    #expect(store.quotaForecast?.currentRemainingPercent == 80)
    if futureVersion {
      #expect(try Data(contentsOf: url) == original)
      #expect(store.quotaHistoryStorageMessage?.contains("暂停保存") == true)
    } else {
      #expect(try Data(contentsOf: #require(storage.preservedOriginalURL)) == original)
      #expect(store.quotaHistoryStorageMessage?.contains("独立备份") == true)
    }
    store.prepareAccount("synthetic-b")
    #expect(store.quotaHistoryStorageMessage == nil)
    #expect(store.quotaHistory.isEmpty)
    #expect(store.quotaForecast == nil)
  }
}
