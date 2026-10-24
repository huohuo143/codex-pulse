import Foundation
import Testing
import CodexMobileCore
@testable import CodexBalanceCore

@Suite("Mobile snapshot publication")
struct MobileSnapshotPublisherTests {
  let now = Date(timeIntervalSince1970: 1_790_000_000)
  func status(scope: String? = "anonymous-local-scope", date: Date? = nil) -> CodexStatus {
    let date = date ?? now
    let event = RateLimitEvent(timestamp: date, sourceName: "Codex app-server", sourcePath: "/private/source",
      limitID: "codex", limitName: "Codex", planType: "pro",
      primary: .init(usedPercent: 34, remainingPercent: 66, windowMinutes: 90, resetsAt: date.addingTimeInterval(3600)),
      projectName: "Private Project", projectPath: "/private/project")
    var status = CodexStatus(generatedAt: date, codexHome: "/private/codex", sessionsRoot: "/private/sessions", main: event, limits: [event])
    status.accountScope = scope
    status.quotaRead = SourceReadMetadata(sampledAt: date, lastSuccessAt: date)
    return status
  }
  @Test func adapterExportsOnlyOfficialNumbersWithoutPrivatePaths() throws {
    let output = MobileSnapshotAdapter.make(status: status(), device: .init(id: "d", name: "Test Mac"))
    #expect(output.windows.count == 1)
    #expect(output.windows[0].durationMinutes == 90)
    #expect(output.account?.id != "anonymous-local-scope")
    let text = String(decoding: try output.encoded(), as: UTF8.self)
    #expect(!text.contains("/private"))
    #expect(!text.contains("Private Project"))
  }
  @Test func missingIdentityClearsAccountAndQuota() {
    let output = MobileSnapshotAdapter.make(status: status(scope: nil), device: .init(id: "d", name: "Mac"))
    #expect(output.account == nil)
    #expect(output.windows.isEmpty)
    #expect(output.resetCredits == nil)
  }
  @Test func localLogFallbackAndInferredResetAreNotExportedAsOfficial() {
    var value = status()
    value.main?.sourceName = "session log"; value.limits = [value.main!]
    #expect(MobileSnapshotAdapter.make(status: value, device: .init(id: "d", name: "Mac")).windows.isEmpty)
    value = status(); value.limits[0].primary?.inferredReset = true
    #expect(MobileSnapshotAdapter.make(status: value, device: .init(id: "d", name: "Mac")).windows[0].resetsAt == nil)
  }
  @Test func atomicPublicationPreservesLegacyAndRejectsOldAccountWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("legacy-device.json")
    try Data("untouched".utf8).write(to: legacy)
    let publisher = MobileSnapshotPublisher(root: root, deviceID: "test-device", deviceName: "Test Mac")
    let file = try #require(await publisher.publish(status()))
    _ = try await publisher.publish(status(scope: "new-account", date: now.addingTimeInterval(60)))
    _ = try await publisher.publish(status())
    let loaded = try MobileAccountSnapshot.decode(Data(contentsOf: file))
    #expect(loaded.publishedAt == now.addingTimeInterval(60))
    #expect(try String(contentsOf: legacy, encoding: .utf8) == "untouched")
    _ = try await publisher.publish(status(scope: nil, date: now.addingTimeInterval(120)))
    #expect(try MobileAccountSnapshot.decode(Data(contentsOf: file)).account == nil)
  }
  @Test func stablePollsAreCoalescedButFailuresPublishImmediately() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let publisher = MobileSnapshotPublisher(root: root, deviceID: "test", deviceName: "Test")
    let first = status()
    let file = try #require(await publisher.publish(first))
    var repeated = first; repeated.generatedAt = now.addingTimeInterval(10)
    repeated.quotaRead?.sampledAt = repeated.generatedAt
    repeated.quotaRead?.lastSuccessAt = repeated.generatedAt
    #expect(try await publisher.publish(repeated) == nil)
    repeated.quotaRead?.failure = "network_unavailable"
    #expect(try await publisher.publish(repeated) != nil)
    #expect(try MobileAccountSnapshot.decode(Data(contentsOf: file)).quotaRead.failed)
    repeated.generatedAt = now.addingTimeInterval(80)
    #expect(try await publisher.publish(repeated) != nil)
  }
}
