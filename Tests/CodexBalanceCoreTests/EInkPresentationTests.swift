import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("E-ink display contract")
struct EInkPresentationTests {
  let now = Date(timeIntervalSince1970: 1_792_800_000)

  func fresh() -> CodexWidgetSnapshot {
    var value = CodexWidgetSnapshot(updatedAt: now, remainingPercent: 0, resetsAt: now.addingTimeInterval(86400),
      rolling24HoursTokens: 0, radarSummary: "PRIVATE-SUMMARY", resetCreditsAvailable: 0,
      topProjects: [.init(label: "/PRIVATE-PROJECT", tokens: 999)])
    let read = SourceReadMetadata(source: "PRIVATE-SOURCE", sampledAt: now, lastAttemptAt: now, lastSuccessAt: now)
    value.quotaRead = read; value.resetCreditsRead = read; value.usageUpdatedAt = now
    value.radarLastSuccessAt = now; value.radarLevel = "动态已更新"; value.radarCheckedAt = now
    value.quotaHistory = QuotaHistoryTrend.widgetHistory(snapshots: [
      .init(recordedAt: now.addingTimeInterval(-7200), remainingPercent: 50, resetsAt: now.addingTimeInterval(86400), windowMinutes: 10080),
      .init(recordedAt: now.addingTimeInterval(-6000), remainingPercent: 40, resetsAt: now.addingTimeInterval(86400), windowMinutes: 10080),
      .init(recordedAt: now, remainingPercent: 95, resetsAt: now.addingTimeInterval(172800), windowMinutes: 10080)
    ], now: now)
    return value
  }

  @Test func projectionOnlyContainsApprovedInformationAndKeepsRealZero() throws {
    let value = EInkPresentation(snapshot: fresh(), at: now)
    #expect(value.remainingPercent == 0); #expect(value.tokens24h == 0); #expect(value.resetCredits == 0)
    let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    #expect(!text.contains("PRIVATE")); #expect(!text.contains("topProjects")); #expect(!text.contains("account"))
    #expect(value.history.map(\.segment) == [0, 0, 1])
  }
  @Test func expiredSourcesBecomeMissingWhileHistoricalObservationsRemain() {
    let value = EInkPresentation(snapshot: fresh(), at: now.addingTimeInterval(1900))
    #expect(value.remainingPercent == nil); #expect(value.tokens24h == nil); #expect(value.resetCredits == nil)
    #expect(value.history.count == 3); #expect(value.history.last?.remainingPercent == 95)
    #expect(EInkPresentation(snapshot: .empty, at: now).tokens24h == nil)
  }
  @Test func sampleHistoryIncludesIdleLightAndBurstUsageWithResetGaps() throws {
    let sample = EInkPresentation.sample(at: now)
    #expect(sample.isSample)
    #expect(sample.history == EInkPresentation.sample(at: now).history)
    #expect(sample.history.count == 169)
    #expect(sample.history.first?.recordedAt == now.addingTimeInterval(-7*86400))
    #expect(sample.history.last?.recordedAt == now)
    #expect(sample.history.last?.remainingPercent == sample.remainingPercent)
    let cycles = Dictionary(grouping: sample.history, by: \.segment)
    #expect(cycles.count == 4)
    for points in cycles.values {
      #expect(points.first?.remainingPercent == 100)
      let drops = zip(points, points.dropFirst()).map { $0.remainingPercent - $1.remainingPercent }
      #expect(drops.allSatisfy { $0 >= 0 })
      #expect(drops.contains { $0 == 0 })
      #expect(drops.contains { $0 > 0 && $0 < 2 })
    }
    #expect(zip(sample.history, sample.history.dropFirst()).contains {
      $0.segment == $1.segment && $0.remainingPercent - $1.remainingPercent >= 20
    })
    let resets = zip(sample.history, sample.history.dropFirst()).filter { $0.segment != $1.segment }
    #expect(resets.count == 3)
    #expect(resets.allSatisfy { $1.remainingPercent == 100 && $0.remainingPercent < 10 })
  }
  @Test func newAnnouncementHasPriorityAndCompletionNeverExtends() {
    var input = fresh()
    input.radarCompletionUntil = now.addingTimeInterval(100)
    input.radarAnnouncementActive = true; input.radarDeadlineAt = now.addingTimeInterval(7200)
    let announcement = EInkPresentation(snapshot: input, at: now)
    #expect(announcement.radarState == "重置已预告"); #expect(announcement.completionUntil == nil)
    #expect(announcement.radarDeadline == input.radarDeadlineAt)
    input.radarAnnouncementActive = false
    #expect(EInkPresentation(snapshot: input, at: now).completionUntil == input.radarCompletionUntil)
    let expired = EInkPresentation(snapshot: input, at: now.addingTimeInterval(100))
    #expect(expired.completionUntil == nil); #expect(expired.radarState == "等待新重置")
  }
  @Test func schedulerLimitsRoutineUpdatesAndRetriesButPrioritizesResetChanges() {
    let value = EInkPresentation(snapshot: fresh(), at: now)
    var policy = EInkSyncPolicy()
    #expect(policy.shouldPublish(value, at: now)); policy.succeeded(value, at: now)
    #expect(!policy.shouldPublish(value, at: now.addingTimeInterval(599)))
    #expect(policy.shouldPublish(value, at: now.addingTimeInterval(600)))
    var reset = fresh(); reset.radarAnnouncementActive = true
    let attention = EInkPresentation(snapshot: reset, at: now)
    #expect(policy.shouldPublish(attention, at: now.addingTimeInterval(1)))
    policy.failed(at: now)
    #expect(!policy.shouldPublish(attention, at: now.addingTimeInterval(29)))
    #expect(policy.shouldPublish(attention, at: now.addingTimeInterval(30)))
    policy.failed(at: now.addingTimeInterval(30))
    #expect(policy.nextAttempt == now.addingTimeInterval(90))
  }
  @Test func screenGeometryFitsTheUpstreamContentRegion() throws {
    for profile in EInkScreenProfile.presets + [.init(width: 400, height: 800), .init(width: 1200, height: 825)] {
      #expect(profile.isValid)
      #expect(profile.headerHeight + profile.imageHeight + profile.footerHeight <= profile.height)
      let url = URL(string: "https://xiaowuai.vip/api/uploads/00000000-0000-0000-0000-000000000001")!
      let device = XiaowuDevice(mac: "AA:BB:CC:DD:EE:FF")
      let data = try XiaowuCloudContract.modeDefinition(modeID: "CODEX_PULSE_TEST", device: device, profile: profile, imageURL: url)
      let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(root["mac"] as? String == device.mac); #expect(root["cacheable"] as? Bool == false)
      #expect(root["modes"] == nil); #expect(root["refreshInterval"] == nil)
      let layout = try #require(root["layout"] as? [String: Any]); let image = try #require((layout["body"] as? [[String: Any]])?.first)
      #expect(image["fit"] as? String == "contain"); #expect(image["photo_enhance"] as? Bool == false)
    }
    #expect(!EInkScreenProfile(width: 200, height: 200).isValid)
    #expect(!EInkScreenProfile(colors: 6).canPublish)
  }
  @Test func uploadReplyCannotRedirectTheImageToAnotherService() throws {
    for url in ["https://evil.example/api/uploads/00000000-0000-0000-0000-000000000001",
      "http://xiaowuai.vip/api/uploads/00000000-0000-0000-0000-000000000001", "https://xiaowuai.vip/login"] {
      let data = try JSONSerialization.data(withJSONObject: ["ok": true, "url": url])
      #expect(throws: XiaowuCloudError.unsupported) { try XiaowuCloudContract.uploadURL(from: data) }
    }
    let devices = try XiaowuCloudContract.devices(from: Data(#"{"devices":[{"mac":"aa:bb:cc:dd:ee:ff","nickname":"桌面"},{"mac":"invalid"},{"mac":"AA:BB:CC:DD:EE:FF"}]}"#.utf8))
    #expect(devices == [.init(mac: "AA:BB:CC:DD:EE:FF", nickname: "桌面")])
    #expect(EInkFormat.date(now, full: true) == "10/24 08:00")
  }
}
