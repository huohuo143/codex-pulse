import Foundation
import Testing
@testable import CodexBalanceCore

@Suite
struct WidgetSnapshotTests {
  @Test
  func snapshotRoundTripsWithoutPrivateFields() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexPulseWidgetTests-\(UUID().uuidString)", isDirectory: true)
    let url = root.appendingPathComponent("widget-snapshot.json")
    defer { try? FileManager.default.removeItem(at: root) }

    let updatedAt = Date(timeIntervalSince1970: 1_786_300_000)
    let snapshot = CodexWidgetSnapshot(
      updatedAt: updatedAt,
      remainingPercent: 68,
      usedPercent: 32,
      resetsAt: updatedAt.addingTimeInterval(2 * 24 * 60 * 60),
      rolling24HoursTokens: 120_000,
      todayTokens: 90_000,
      last7DaysTokens: 840_000,
      monthTokens: 2_600_000,
      cost24HoursUSD: 2.4,
      cost7DaysUSD: 15.8,
      costMonthUSD: 48.5,
      cnyRate: 7.18,
      resetProbability24h: 72,
      radarLevel: "高概率",
      radarSummary: "公开雷达摘要",
      radarUpdatedAt: updatedAt,
      resetCreditsAvailable: 1,
      resetCredits: [CodexWidgetResetCredit(title: "Full reset", expiresAt: updatedAt.addingTimeInterval(86_400))],
      sampleCount: 48,
      deviceCount: 2,
      hourly24: [CodexWidgetPoint(label: "10:00", tokens: 12_000)],
      daily14: [CodexWidgetPoint(label: "7/16", tokens: 90_000)],
      topProjects: [CodexWidgetMetric(label: "Codex 脉动", tokens: 60_000)],
      topCategories: [CodexWidgetMetric(label: "编程/APP", tokens: 60_000)]
    )

    try CodexWidgetSnapshotStore.save(snapshot, to: url)
    let decoded = try CodexWidgetSnapshotStore.load(from: url)
    let json = try #require(String(data: Data(contentsOf: url), encoding: .utf8))

    #expect(decoded == snapshot)
    #expect(decoded.schemaVersion == 1)
    #expect(!json.contains("projectPath"))
    #expect(!json.contains("sourcePath"))
    #expect(!json.contains("access_token"))
    #expect(!json.contains("redemption"))
  }

  @Test
  func previewSnapshotCoversAllWidgetSurfaces() {
    let snapshot = CodexWidgetSnapshot.preview

    #expect(snapshot.remainingPercent != nil)
    #expect(snapshot.rolling24HoursTokens > 0)
    #expect(snapshot.resetProbability24h != nil)
    #expect(snapshot.resetCreditsAvailable != nil)
    #expect(snapshot.hourly24.count == 24)
    #expect(snapshot.daily14.count == 14)
    #expect(snapshot.topProjects.count == 3)
    #expect(snapshot.topCategories.count == 3)
  }

  @Test
  func widgetSnapshotPathsStayInsideTheExtensionContainer() {
    let userHome = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    let containerHome = userHome
      .appendingPathComponent("Library/Containers", isDirectory: true)
      .appendingPathComponent(CodexWidgetSnapshotStore.widgetExtensionBundleIdentifier, isDirectory: true)
      .appendingPathComponent("Data", isDirectory: true)

    let hostURL = CodexWidgetSnapshotStore.widgetContainerURL(userHome: userHome)
    let extensionURL = CodexWidgetSnapshotStore.sandboxedWidgetURL(containerHome: containerHome)

    #expect(hostURL == extensionURL)
    #expect(hostURL.path.contains(CodexWidgetSnapshotStore.widgetExtensionBundleIdentifier))
    #expect(hostURL.lastPathComponent == CodexWidgetSnapshotStore.fileName)
  }
}
