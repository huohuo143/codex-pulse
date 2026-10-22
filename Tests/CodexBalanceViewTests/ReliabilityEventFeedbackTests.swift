import Foundation
import Testing
import CodexBalanceCore
@testable import CodexBalance

@MainActor @Suite("Reliability event recovery feedback", .serialized)
struct ReliabilityEventFeedbackTests {
  @Test func futureRecordsWarnInHealthAndDiagnosticsWithoutBeingReplaced() throws {
    let f = try EventFeedbackFixture()
    defer { f.clean() }
    let future = Data(#"{"schemaVersion":99,"futureSecret":"private-fixture"}"#.utf8)
    try future.write(to: f.url)
    let store = f.dashboard()
    #expect(store.reliabilityEventStorageIssue == .unsupportedVersion(99))
    store.runReliabilityCheck(manual: true, allowAutomation: false)
    #expect(store.reliabilityEventStorageMessage?.contains("暂不支持的版本（99）") == true)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .reliabilityEvents }?.level == .warning)
    #expect(store.reliabilityEvents.isEmpty)
    #expect(try Data(contentsOf: f.url) == future)
    let report = ReliabilityReportBuilder.diagnosticMarkdown(appVersion: "test",
      snapshot: store.reliabilitySnapshot, recentEvents: store.reliabilityEvents)
    #expect(report.contains("运行事件记录"))
    #expect(report.contains("暂不支持的版本（99）"))
    #expect(!report.contains("private-fixture"))
    #expect(!report.contains(f.root.path))
  }

  @Test func corruptReadPreservesCachedRowsUntilExplicitRebuild() throws {
    let f = try EventFeedbackFixture()
    defer { f.clean() }
    let originalEvent = f.event
    _ = try f.events.append(originalEvent)
    let store = f.dashboard()
    let corrupt = Data("damaged history must survive checks".utf8)
    try corrupt.write(to: f.url)
    store.runReliabilityCheck(manual: true, allowAutomation: false)
    #expect(store.reliabilityEventStorageIssue == .invalidRecord)
    #expect(store.reliabilityEvents.map(\.id) == [originalEvent.id])
    store.reloadReliabilityEvents()
    #expect(try Data(contentsOf: f.url) == corrupt)
    #expect(store.reliabilityEvents.map(\.id) == [originalEvent.id])
    store.rebuildReliabilityEvents()
    #expect(store.reliabilityEventStorageMessage == nil)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .reliabilityEvents }?.level == .healthy)
    #expect(store.reliabilityEvents.contains { $0.title == "运行事件记录已重建" })
    let copies = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.contains("corrupt-") }
    #expect(copies.count == 1)
    #expect(try Data(contentsOf: #require(copies.first)) == corrupt)
    let reopened = f.dashboard()
    #expect(reopened.reliabilityEventStorageIssue == nil)
    #expect(reopened.reliabilityEvents.map(\.id) == store.reliabilityEvents.map(\.id))
  }

  @Test func writeFailureStaysVisibleUntilSuccessfulRetry() throws {
    let f = try EventFeedbackFixture()
    defer { f.clean() }
    _ = try f.events.append(f.event)
    let original = try Data(contentsOf: f.url)
    let files = EventFeedbackFileManager()
    files.failWrites = true
    let store = f.dashboard(files: files)
    store.appendReliabilityEvent(f.event)
    #expect(store.reliabilityEventWriteFailed)
    #expect(store.reliabilityEventStorageMessage?.contains("未能写入") == true)
    #expect(try Data(contentsOf: f.url) == original)
    store.reloadReliabilityEvents()
    #expect(store.reliabilityEventWriteFailed)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .reliabilityEvents }?.level == .warning)
    files.failWrites = false
    store.appendReliabilityEvent(f.event)
    #expect(!store.reliabilityEventWriteFailed)
    #expect(store.reliabilityEventStorageMessage == nil)
    #expect(store.reliabilityEvents.count == 2)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .reliabilityEvents }?.level == .healthy)
  }

  @Test func preservationFailureKeepsOriginalAndRetryCanRebuild() throws {
    let f = try EventFeedbackFixture()
    defer { f.clean() }
    let original = Data("cannot discard original on failed copy".utf8)
    try original.write(to: f.url)
    let files = EventFeedbackFileManager()
    files.failCopies = true
    let store = f.dashboard(files: files)
    store.rebuildReliabilityEvents()
    #expect(store.reliabilityEventStorageIssue == .preservationFailed)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .reliabilityEvents }?.level == .warning)
    #expect(try Data(contentsOf: f.url) == original)
    files.failCopies = false
    store.reloadReliabilityEvents()
    #expect(store.reliabilityEventStorageIssue == .invalidRecord)
    store.rebuildReliabilityEvents()
    #expect(store.reliabilityEventStorageMessage == nil)
    #expect(store.reliabilityMessage?.contains("已保留原件并重建") == true)
  }

  @Test func staleRebuildActionCannotReplaceNewerFormat() throws {
    let f = try EventFeedbackFixture()
    defer { f.clean() }
    try Data("malformed".utf8).write(to: f.url)
    let store = f.dashboard()
    #expect(store.reliabilityEventStorageIssue == .invalidRecord)
    let future = Data(#"{"schemaVersion":99,"newExternalRecord":true}"#.utf8)
    try future.write(to: f.url)
    store.rebuildReliabilityEvents()
    #expect(store.reliabilityEventStorageIssue == .unsupportedVersion(99))
    #expect(try Data(contentsOf: f.url) == future)
    #expect(store.reliabilityEventStorageMessage?.contains("原文件未改动") == true)
  }
}

private struct EventFeedbackFixture {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  var url: URL { root.appendingPathComponent("events.json") }
  var events: ReliabilityEventStore { .init(url: url) }
  var event: ReliabilityEvent { .init(timestamp: Date(timeIntervalSince1970: 1_700_000_000),
    kind: .info, title: "isolated event", detail: "synthetic") }
  @MainActor func dashboard(files: FileManager = .default) -> DashboardStore {
    let store = DashboardStore(startServices: false,
      expiryStore: .init(url: root.appendingPathComponent("credit.json"), legacyURL: root.appendingPathComponent("legacy.json")),
      budgetStore: .init(url: root.appendingPathComponent("budgets.json")),
      eventStore: .init(url: url, fileManager: files))
    store.quotaHistoryStore = .init(url: root.appendingPathComponent("quota.json"))
    return store
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

private final class EventFeedbackFileManager: FileManager, @unchecked Sendable {
  var failWrites = false
  var failCopies = false
  override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil) throws {
    if failWrites { throw CocoaError(.fileWriteNoPermission) }
    try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
  }
  override func copyItem(at srcURL: URL, to dstURL: URL) throws {
    if failCopies { throw CocoaError(.fileWriteNoPermission) }
    try super.copyItem(at: srcURL, to: dstURL)
  }
}
