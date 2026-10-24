import Foundation
import Testing
@testable import CodexMobileCore

@Suite("Mobile snapshot data trust")
struct MobileAccountSnapshotTests {
  let now = Date(timeIntervalSince1970: 1_790_000_000)
  func sample(device: String = "mac-a", account: String = "anonymous-a", offset: Double = 0) -> MobileAccountSnapshot {
    let date = now.addingTimeInterval(offset)
    return MobileAccountSnapshot(publishedAt: date, device: .init(id: device, name: "Test Mac"),
      account: .init(id: account, plan: "pro"), quotaRead: .init(sampledAt: date, lastSuccessAt: date),
      windows: [.init(id: "codex:secondary", bucketID: "codex", durationMinutes: 10080,
                      usedPercent: 27, resetsAt: now.addingTimeInterval(3600))])
  }
  @Test func roundTripContainsOnlyWhitelistedFields() throws {
    let snapshot = sample()
    let data = try snapshot.encoded()
    #expect(try MobileAccountSnapshot.decode(data, now: now) == snapshot)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == Set(["schemaVersion", "publishedAt", "device", "account", "quotaRead", "windows"]))
    let text = String(decoding: data, as: UTF8.self)
    for forbidden in ["access_token", "refresh_token", "cookie", "projectPath", "sourcePath", "codexHome", "tokens"] {
      #expect(!text.contains(forbidden))
    }
  }
  @Test func missingValuesStayUnknown() {
    var value = sample().windows[0]; value.usedPercent = nil; value.durationMinutes = nil
    #expect(value.remainingPercent == nil)
    #expect(value.durationLabel == "额度周期")
    #expect(MobileSourceRead().state(at: now) == .unavailable)
  }
  @Test func preservesArbitraryOfficialWindowDuration() {
    var value = sample().windows[0]; value.durationMinutes = 90
    #expect(value.durationLabel == "90 分钟额度")
    value.durationMinutes = 60
    #expect(value.durationLabel == "1 小时额度")
  }
  @Test func expiredOrResetDataCannotLookCurrent() {
    let s = sample()
    #expect(s.windows[0].displayRemaining(read: s.quotaRead, at: now) == 73)
    #expect(s.quotaRead.state(at: now.addingTimeInterval(301)) == .cached)
    #expect(s.windows[0].displayRemaining(read: s.quotaRead, at: now.addingTimeInterval(1801)) == nil)
    #expect(s.quotaRead.state(at: now.addingTimeInterval(3600), resetsAt: s.windows[0].resetsAt) == .waitingForReset)
    #expect(s.windows[0].remainingPercent == 73)
  }
  @Test func failedReadAndRepublishingDoNotRenewSampleTime() {
    var s = sample(); s.publishedAt = now.addingTimeInterval(4000); s.quotaRead.failed = true
    #expect(s.quotaRead.state(at: now.addingTimeInterval(30)) == .cached)
    #expect(s.quotaRead.state(at: now.addingTimeInterval(4000)) == .expired)
    #expect(s.quotaRead.sampledAt == now)
  }
  @Test func futureSourceTimeIsUnavailable() {
    #expect(MobileSourceRead(sampledAt: now.addingTimeInterval(600), lastSuccessAt: now).state(at: now) == .unavailable)
  }
  @Test func missingAndExpiredResetCreditsStayHidden() {
    let unknown = MobileResetCredits(availableCount: 3, nearestExpiry: nil, read: .init())
    #expect(!unknown.isDisplayable(at: now))
    let dated = MobileResetCredits(availableCount: 3, nearestExpiry: now, read: sample().quotaRead)
    #expect(!dated.isDisplayable(at: now))
    #expect(dated.availableCount == 3)
  }
  @Test func unsupportedAndMalformedFilesAreRejected() throws {
    var s = sample(); s.schemaVersion = 99
    #expect(throws: MobileSnapshotError.self) { try s.validate(now: now) }
    s = sample(); s.windows.append(s.windows[0])
    #expect(throws: MobileSnapshotError.self) { try s.validate(now: now) }
    s = sample(); s.windows[0].usedPercent = 101
    #expect(throws: MobileSnapshotError.self) { try s.validate(now: now) }
    #expect(throws: MobileSnapshotError.self) { try MobileAccountSnapshot.decode(Data(repeating: 32, count: 131_073)) }
  }
  @Test func sourceSelectionIsStickyAndNeverAggregatesAccounts() throws {
    let a = sample(); let b = sample(device: "mac-b", account: "anonymous-b", offset: 30)
    #expect(try MobileSnapshotSelection.select([a, b], deviceID: nil, previous: nil) == nil)
    #expect(try MobileSnapshotSelection.select([a, b], deviceID: "mac-a", previous: nil) == a)
    #expect(throws: MobileSnapshotError.self) { try MobileSnapshotSelection.select([b], deviceID: "mac-a", previous: a) }
  }
  @Test func delayedICloudFileCannotUndoAnAccountSwitch() throws {
    let old = sample(); let changed = sample(account: "anonymous-b", offset: 30)
    #expect(try MobileSnapshotSelection.select([old], deviceID: "mac-a", previous: changed) == changed)
    #expect(try MobileSnapshotSelection.select([changed], deviceID: "mac-a", previous: old)?.account?.id == "anonymous-b")
  }
  @Test func logoutTombstone() throws {
    var tombstone = sample(offset: 60)
    tombstone.account = nil; tombstone.windows = []; tombstone.quotaRead = .init()
    try tombstone.validate(now: now.addingTimeInterval(60))
    #expect(try MobileSnapshotSelection.select([tombstone], deviceID: "mac-a", previous: sample())?.account == nil)
    tombstone.windows = sample().windows
    #expect(throws: MobileSnapshotError.self) { try tombstone.validate(now: now.addingTimeInterval(60)) }
  }
}
