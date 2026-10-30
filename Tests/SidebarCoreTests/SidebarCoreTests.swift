import XCTest
@testable import SidebarCore

final class SidebarCoreTests: XCTestCase {
  func testVisibilityDefaultsAndPersistsIndependently() throws {
    let suite = "SidebarVisibilityTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(SidebarVisibility.load(from: defaults), SidebarVisibility())
    SidebarVisibility(quota: false, radar: true, credits: false, reset: false, apiUsage: false).save(to: defaults)
    XCTAssertEqual(SidebarVisibility.load(from: defaults), SidebarVisibility(quota: false, radar: true, credits: false, reset: false, apiUsage: false))
  }

  func testMigrationPreservesExplicitChoicesAndDoesNotOverwritePulse() throws {
    let suite = "SidebarMigrationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "sidebarShowsQuota")
    let legacy: [String: Any] = ["sidebarShowsQuota": false, "sidebarShowsRadar": false,
                                 "sidebarShowsCredits": true, "sidebarShowsReset": false]
    let migrated = SidebarVisibility.migrateAndLoad(from: defaults, legacy: legacy)
    XCTAssertEqual(migrated, SidebarVisibility(quota: true, radar: false, credits: true, reset: false))
    XCTAssertEqual(SidebarVisibility.load(from: defaults), migrated)
    defaults.set(true, forKey: "sidebarShowsRadar")
    XCTAssertTrue(SidebarVisibility.migrateAndLoad(from: defaults, legacy: legacy).radar)
  }

  func testCLIPathTracksTheCurrentlySelectedApplicationBundle() {
    let first = CodexApplicationPaths.embeddedCLI(in: URL(fileURLWithPath: "/Applications/ChatGPT.app"))
    let moved = CodexApplicationPaths.embeddedCLI(in: URL(fileURLWithPath: "/Users/example/Applications/Codex.app"))
    XCTAssertTrue(first.path.hasPrefix("/Applications/ChatGPT.app/"))
    XCTAssertTrue(moved.path.hasPrefix("/Users/example/Applications/Codex.app/"))
    XCTAssertTrue(moved.path.hasSuffix("/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))
  }

  func testQuotaBoundariesAndUnavailableValues() {
    XCTAssertEqual(QuotaBand.classify(100), .green)
    XCTAssertEqual(QuotaBand.classify(50), .green)
    XCTAssertEqual(QuotaBand.classify(49.9), .yellow)
    XCTAssertEqual(QuotaBand.classify(25), .yellow)
    XCTAssertEqual(QuotaBand.classify(24.9), .pink)
    XCTAssertEqual(QuotaBand.classify(10), .pink)
    XCTAssertEqual(QuotaBand.classify(9.9), .red)
    XCTAssertEqual(QuotaBand.classify(0), .red)
    XCTAssertEqual(QuotaBand.classify(nil), .unavailable)
    XCTAssertEqual(QuotaBand.classify(-1), .unavailable)
    XCTAssertEqual(QuotaBand.classify(101), .unavailable)
    XCTAssertEqual(SidebarFormat.percentage(49.9), "49.9%")
  }

  func testCreditBalanceIsNotResetCount() {
    XCTAssertEqual(SidebarFormat.credits(12345.75), "12,346")
    XCTAssertEqual(SidebarFormat.credits(nil), "—")
    XCTAssertEqual(SidebarFormat.credits(-1), "—")
  }

  func testRadarNeverPromotesStaleOrUnconfirmedAnnouncement() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var s = RadarSnapshot(radarLevel: "重置已预告", radarDeadlineAt: now.timeIntervalSince1970 + 3600,
                          radarValidUntil: now.timeIntervalSince1970 + 100,
                          radarLastSuccessAt: now.timeIntervalSince1970, radarAnnouncementActive: false)
    XCTAssertEqual(RadarDisplay.resolve(s, now: now).title, "待分析")
    s.radarAnnouncementActive = true
    XCTAssertEqual(RadarDisplay.resolve(s, now: now).kind, .announced)
    s.radarIsStale = true
    XCTAssertEqual(RadarDisplay.resolve(s, now: now).title, "待刷新")
    s.radarCompletionUntil = now.timeIntervalSince1970 + 20
    s.radarLevel = "重置已落地"
    XCTAssertEqual(RadarDisplay.resolve(s, now: now).title, "已落地")
    XCTAssertEqual(RadarDisplay.resolve(s, now: now.addingTimeInterval(21)).title, "待预告")
  }

  func testDisabledAnalysisDoesNotBecomeNoAnnouncement() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let s = RadarSnapshot(radarLevel: "动态已更新", radarValidUntil: now.timeIntervalSince1970 + 60,
                          radarLastSuccessAt: now.timeIntervalSince1970)
    XCTAssertEqual(RadarDisplay.resolve(s, now: now).title, "动态更新")
  }
}
