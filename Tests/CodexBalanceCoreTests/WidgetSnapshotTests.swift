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
      fiveHourRemainingPercent: 84,
      fiveHourUsedPercent: 16,
      fiveHourResetsAt: updatedAt.addingTimeInterval(2 * 60 * 60),
      showsFiveHourQuota: true,
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
      radarCheckedAt: updatedAt.addingTimeInterval(60),
      radarLastSuccessAt: updatedAt.addingTimeInterval(30),
      radarSourceUpdatedAt: updatedAt.addingTimeInterval(-120),
      radarEvidenceUpdatedAt: updatedAt.addingTimeInterval(-300),
      radarEvaluatedAt: updatedAt.addingTimeInterval(60),
      radarValidUntil: updatedAt.addingTimeInterval(86_400),
      radarSyncStatus: "同步正常",
      radarConsecutiveFailures: 0,
      radarIsUsingCachedFeed: false,
      radarIsStale: false,
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
    #expect(decoded.schemaVersion == 4)
    #expect(decoded.radarCheckedAt == updatedAt.addingTimeInterval(60))
    #expect(decoded.radarLastSuccessAt == updatedAt.addingTimeInterval(30))
    #expect(decoded.radarValidUntil == updatedAt.addingTimeInterval(86_400))
    #expect(decoded.radarSyncStatus == "同步正常")
    #expect(decoded.radarConsecutiveFailures == 0)
    #expect(decoded.radarIsUsingCachedFeed == false)
    #expect(decoded.radarIsStale == false)
    #expect(decoded.displaysFiveHourQuota)
    #expect(decoded.fiveHourRemainingPercent == 84)
    #expect(!json.contains("projectPath"))
    #expect(!json.contains("sourcePath"))
    #expect(!json.contains("access_token"))
    #expect(!json.contains("redemption"))
  }

  @Test
  func previewSnapshotCoversAllWidgetSurfaces() {
    let snapshot = CodexWidgetSnapshot.preview

    #expect(snapshot.remainingPercent != nil)
    #expect(snapshot.fiveHourRemainingPercent != nil)
    #expect(snapshot.displaysFiveHourQuota)
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

  @Test
  func snapshotFromPreviousSystemBootIsNotPresentedAsLiveQuota() {
    let now = Date(timeIntervalSince1970: 10_000)
    let snapshot = CodexWidgetSnapshot(
      updatedAt: now.addingTimeInterval(-30),
      remainingPercent: 77,
      resetsAt: now.addingTimeInterval(86_400)
    )

    #expect(!CodexWidgetSnapshotFreshness.isFresh(
      snapshot,
      now: now,
      systemUptime: 20
    ))
  }

  @Test
  func recentSnapshotFromCurrentSystemBootRemainsLiveAcrossAppRestart() {
    let now = Date(timeIntervalSince1970: 10_000)
    let snapshot = CodexWidgetSnapshot(
      updatedAt: now.addingTimeInterval(-30),
      remainingPercent: 76,
      resetsAt: now.addingTimeInterval(86_400)
    )

    #expect(CodexWidgetSnapshotFreshness.isFresh(
      snapshot,
      now: now,
      systemUptime: 3_600
    ))
  }

  @Test
  func oldSnapshotFromCurrentBootExpiresInsteadOfMasqueradingAsLive() {
    let now = Date(timeIntervalSince1970: 10_000)
    let snapshot = CodexWidgetSnapshot(
      updatedAt: now.addingTimeInterval(-(CodexWidgetSnapshotFreshness.maximumLiveAge + 1)),
      remainingPercent: 76,
      resetsAt: now.addingTimeInterval(86_400)
    )

    #expect(!CodexWidgetSnapshotFreshness.isFresh(
      snapshot,
      now: now,
      systemUptime: 3_600
    ))
  }

  @Test
  func contentComparisonIgnoresOnlyRefreshTimestamp() {
    let original = CodexWidgetSnapshot(
      updatedAt: Date(timeIntervalSince1970: 100),
      remainingPercent: 68,
      rolling24HoursTokens: 120_000,
      resetProbability24h: 72,
      hourly24: [CodexWidgetPoint(label: "10:00", tokens: 12_000)],
      topProjects: [CodexWidgetMetric(label: "Codex 脉动", tokens: 60_000)]
    )
    var later = original
    later.updatedAt = Date(timeIntervalSince1970: 200)

    #expect(original.hasSameWidgetContent(as: later))

    later.remainingPercent = 67
    #expect(!original.hasSameWidgetContent(as: later))
    later = original
    later.fiveHourRemainingPercent = 84
    #expect(!original.hasSameWidgetContent(as: later))
    later = original
    later.showsFiveHourQuota = true
    #expect(!original.hasSameWidgetContent(as: later))
    later = original
    later.rolling24HoursTokens += 1
    #expect(!original.hasSameWidgetContent(as: later))
    later = original
    later.resetProbability24h = 71
    #expect(!original.hasSameWidgetContent(as: later))
    later = original
    later.radarEvaluatedAt = Date(timeIntervalSince1970: 300)
    #expect(!original.hasSameWidgetContent(as: later))
    later = original
    later.radarValidUntil = Date(timeIntervalSince1970: 400)
    #expect(!original.hasSameWidgetContent(as: later))
    later = original
    later.hourly24[0].tokens += 1
    #expect(!original.hasSameWidgetContent(as: later))
    later = original
    later.topProjects[0].tokens += 1
    #expect(!original.hasSameWidgetContent(as: later))
  }

  @Test
  func legacySnapshotWithoutFiveHourFieldsStillDecodes() throws {
    let json = """
      {
        "schemaVersion": 1,
        "updatedAt": 100,
        "rolling24HoursTokens": 0,
        "todayTokens": 0,
        "last7DaysTokens": 0,
        "monthTokens": 0,
        "cost24HoursUSD": 0,
        "cost7DaysUSD": 0,
        "costMonthUSD": 0,
        "resetCredits": [],
        "sampleCount": 0,
        "deviceCount": 0,
        "hourly24": [],
        "daily14": [],
        "topProjects": [],
        "topCategories": []
      }
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let snapshot = try decoder.decode(CodexWidgetSnapshot.self, from: Data(json.utf8))

    #expect(snapshot.schemaVersion == 1)
    #expect(snapshot.fiveHourRemainingPercent == nil)
    #expect(!snapshot.displaysFiveHourQuota)
    #expect(snapshot.radarCheckedAt == nil)
    #expect(snapshot.radarLastSuccessAt == nil)
    #expect(snapshot.radarValidUntil == nil)
    #expect(snapshot.radarSyncStatus == nil)
    #expect(snapshot.radarConsecutiveFailures == nil)
    #expect(snapshot.radarIsUsingCachedFeed == nil)
    #expect(snapshot.radarIsStale == nil)
  }

  @Test
  func reloadPolicyReloadsFirstChangeImmediately() {
    let policy = CodexWidgetReloadPolicy(minimumInterval: 10)

    #expect(policy.decision(
      needsReload: true,
      lastReloadAt: nil,
      hasPendingReload: false,
      now: Date(timeIntervalSince1970: 100)
    ) == .reloadNow)
  }

  @Test
  func reloadPolicyCoalescesChangesAtEarliestAllowedTime() {
    let policy = CodexWidgetReloadPolicy(minimumInterval: 10)
    let lastReload = Date(timeIntervalSince1970: 100)

    #expect(policy.decision(
      needsReload: true,
      lastReloadAt: lastReload,
      hasPendingReload: false,
      now: Date(timeIntervalSince1970: 103)
    ) == .schedule(after: 7))
    #expect(policy.decision(
      needsReload: true,
      lastReloadAt: lastReload,
      hasPendingReload: true,
      now: Date(timeIntervalSince1970: 105)
    ) == .none)
    #expect(policy.decision(
      needsReload: true,
      lastReloadAt: lastReload,
      hasPendingReload: false,
      now: Date(timeIntervalSince1970: 110)
    ) == .reloadNow)
  }

  @Test
  func reloadPolicySkipsUnchangedSnapshots() {
    let policy = CodexWidgetReloadPolicy(minimumInterval: 10)

    #expect(policy.decision(
      needsReload: false,
      lastReloadAt: nil,
      hasPendingReload: false,
      now: Date(timeIntervalSince1970: 100)
    ) == .none)
  }
}
