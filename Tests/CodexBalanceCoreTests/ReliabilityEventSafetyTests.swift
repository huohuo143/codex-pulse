import Darwin
import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Reliability event storage protection")
struct ReliabilityEventSafetyTests {
  @Test func futureEventFormatIsNeverDowngraded() throws {
    let f = try EventSafetyFixture()
    defer { f.clean() }
    let future = Data(#"{"schemaVersion":99,"events":[],"futureField":{"mustKeep":true}}"#.utf8)
    try future.write(to: f.url)
    #expect(f.store.load().isEmpty)
    #expect(throws: (any Error).self) { _ = try f.store.append(f.event) }
    #expect(try Data(contentsOf: f.url) == future)
  }

  @Test func readingCorruptEventsDoesNotMoveOrReplaceTheOriginal() throws {
    let f = try EventSafetyFixture()
    defer { f.clean() }
    let corrupt = Data("original malformed event history".utf8)
    try corrupt.write(to: f.url)
    #expect(f.store.load().isEmpty)
    #expect((try? Data(contentsOf: f.url)) == corrupt)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path) == ["events.json"])
  }

  @Test func corruptEventsAreNotOverwrittenWhenPreservationFails() throws {
    let f = try EventSafetyFixture()
    defer { f.clean() }
    let corrupt = Data("must preserve even when quarantine fails".utf8)
    try corrupt.write(to: f.url)
    let store = ReliabilityEventStore(url: f.url, fileManager: FailedEventPreservationFileManager())
    #expect(throws: (any Error).self) { _ = try store.append(f.event) }
    #expect(try Data(contentsOf: f.url) == corrupt)
  }

  @Test(arguments: [0, 2, 99])
  func futureHeaderIsRecognizedBeforeDecodingUnknownFields(version: Int) throws {
    let f = try EventSafetyFixture()
    defer { f.clean() }
    let bytes = Data("{\"schemaVersion\":\(version),\"futureContent\":{\"private\":true}}".utf8)
    try bytes.write(to: f.url)
    #expect(f.store.loadResult().issue == .unsupportedVersion(version))
    #expect(throws: ReliabilityEventStorageIssue.unsupportedVersion(version)) { _ = try f.store.append(f.event) }
    #expect(throws: ReliabilityEventStorageIssue.unsupportedVersion(version)) { _ = try f.store.rebuildAfterPreservingCorruption() }
    #expect(try Data(contentsOf: f.url) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path) == ["events.json"])
  }

  @Test(arguments: ["link", "dangling", "oversized", "pipe", "directory", "parent-link"])
  func unsafePathsAreRejectedWithoutChangingTheirTargets(kind: String) throws {
    let f = try EventSafetyFixture()
    defer { f.clean() }
    let outside = f.root.appendingPathComponent("outside.json")
    let sentinel = Data(#"{"schemaVersion":1,"events":[]}"#.utf8)
    try sentinel.write(to: outside)
    var target = f.url
    switch kind {
    case "link": try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
    case "dangling": try FileManager.default.createSymbolicLink(at: target, withDestinationURL: f.root.appendingPathComponent("absent"))
    case "oversized": try Data(repeating: 32, count: LocalRecordFile.maximumSize + 1).write(to: target)
    case "pipe":
      #expect(mkfifo(target.path, 0o600) == 0)
      let pipe = target
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
        let fd = open(pipe.path, O_WRONLY | O_NONBLOCK)
        if fd >= 0 { _ = close(fd) }
      }
    case "directory": try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    default:
      let link = f.root.appendingPathComponent("linked-parent")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root)
      target = link.appendingPathComponent(outside.lastPathComponent)
    }
    let store = ReliabilityEventStore(url: target)
    let started = Date()
    #expect(store.loadResult().issue == .unreadableRecord)
    #expect(throws: ReliabilityEventStorageIssue.unreadableRecord) { _ = try store.append(f.event) }
    #expect(throws: ReliabilityEventStorageIssue.unreadableRecord) { _ = try store.rebuildAfterPreservingCorruption() }
    #expect(Date().timeIntervalSince(started) < 0.3)
    #expect(try Data(contentsOf: outside) == sentinel)
  }

  @Test func explicitRebuildPreservesEachOriginalAndCanRecordNewEvents() throws {
    let f = try EventSafetyFixture()
    defer { f.clean() }
    var copies: [URL] = []
    for value in ["first malformed bytes", "second malformed bytes"] {
      let bytes = Data(value.utf8)
      try bytes.write(to: f.url)
      let copy = try f.store.rebuildAfterPreservingCorruption()
      copies.append(copy)
      #expect(try Data(contentsOf: copy) == bytes)
      #expect(f.store.loadResult().issue == nil)
      #expect(f.store.load().isEmpty)
      _ = try f.store.append(f.event)
      #expect(f.store.load().count == 1)
    }
    #expect(Set(copies).count == 2)
    #expect(try Data(contentsOf: copies[0]) == Data("first malformed bytes".utf8))
    #expect(throws: ReliabilityEventStorageIssue.notCorrupt) { _ = try f.store.rebuildAfterPreservingCorruption() }
  }

  @Test(arguments: [false, true])
  func failedOrUnverifiablePreservationNeverClearsOriginal(corruptCopy: Bool) throws {
    let f = try EventSafetyFixture()
    defer { f.clean() }
    let original = Data("damaged events requiring explicit recovery".utf8)
    try original.write(to: f.url)
    let files: FileManager = corruptCopy ? InvalidEventCopyFileManager() : FailedEventPreservationFileManager()
    let store = ReliabilityEventStore(url: f.url, fileManager: files)
    #expect(throws: ReliabilityEventStorageIssue.preservationFailed) { _ = try store.rebuildAfterPreservingCorruption() }
    #expect(try Data(contentsOf: f.url) == original)
  }

  @Test(arguments: [false, true])
  func concurrentChangesBeforeWritingAreNotOverwritten(rebuild: Bool) throws {
    let f = try EventSafetyFixture()
    defer { f.clean() }
    let original = Data((rebuild ? "damaged" : #"{"schemaVersion":1,"events":[]}"#).utf8)
    let replacement = Data(#"{"schemaVersion":99,"externalNewData":true}"#.utf8)
    try original.write(to: f.url)
    let files = ChangedEventFileManager(url: f.url, data: replacement)
    let store = ReliabilityEventStore(url: f.url, fileManager: files)
    #expect(throws: ReliabilityEventStorageIssue.changedOnDisk) {
      if rebuild { _ = try store.rebuildAfterPreservingCorruption() }
      else { _ = try store.append(f.event) }
    }
    #expect(try Data(contentsOf: f.url) == replacement)
  }

  @Test func concurrentChangeDuringPreservationIsRetained() throws {
    let f = try EventSafetyFixture()
    defer { f.clean() }
    let original = Data("damaged original".utf8)
    try original.write(to: f.url)
    let files = ChangedEventCopyFileManager()
    let store = ReliabilityEventStore(url: f.url, fileManager: files)
    #expect(throws: ReliabilityEventStorageIssue.changedOnDisk) { _ = try store.rebuildAfterPreservingCorruption() }
    #expect(try Data(contentsOf: f.url) == files.replacement)
    let copy = try #require(files.preserved)
    #expect(try Data(contentsOf: copy) == original)
  }

  @Test func oversizedNewEventsCannotReplaceReadableHistory() throws {
    let f = try EventSafetyFixture()
    defer { f.clean() }
    _ = try f.store.append(f.event)
    let original = try Data(contentsOf: f.url)
    let event = ReliabilityEvent(kind: .info, title: "oversized", detail: String(repeating: "x", count: LocalRecordFile.maximumSize))
    #expect(throws: ReliabilityEventStorageIssue.recordTooLarge) { _ = try f.store.append(event) }
    #expect(try Data(contentsOf: f.url) == original)
  }

  @Test func duplicateIdentifiersAreReportedWithoutSilentlyDroppingRows() throws {
    let f = try EventSafetyFixture()
    defer { f.clean() }
    _ = try f.store.append(f.event)
    var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.url)) as? [String: Any])
    let rows = try #require(payload["events"] as? [[String: Any]])
    payload["events"] = rows + rows
    let bytes = try JSONSerialization.data(withJSONObject: payload)
    try bytes.write(to: f.url)
    #expect(f.store.loadResult().issue == .invalidRecord)
    #expect(throws: ReliabilityEventStorageIssue.invalidRecord) { _ = try f.store.append(f.event) }
    #expect(try Data(contentsOf: f.url) == bytes)
  }
}

private struct EventSafetyFixture {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  var url: URL { root.appendingPathComponent("events.json") }
  var store: ReliabilityEventStore { .init(url: url) }
  var event: ReliabilityEvent { .init(kind: .info, title: "Synthetic event", detail: "safe") }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

private final class FailedEventPreservationFileManager: FileManager, @unchecked Sendable {
  override func moveItem(at srcURL: URL, to dstURL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
  override func copyItem(at srcURL: URL, to dstURL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}

private final class InvalidEventCopyFileManager: FileManager, @unchecked Sendable {
  override func copyItem(at srcURL: URL, to dstURL: URL) throws { try Data("incomplete copy".utf8).write(to: dstURL) }
}

private final class ChangedEventFileManager: FileManager, @unchecked Sendable {
  let url: URL
  let data: Data
  init(url: URL, data: Data) { self.url = url; self.data = data; super.init() }
  override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil) throws {
    try data.write(to: self.url)
    try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
  }
}

private final class ChangedEventCopyFileManager: FileManager, @unchecked Sendable {
  let replacement = Data(#"{"schemaVersion":99,"changedDuringCopy":true}"#.utf8)
  var preserved: URL?
  override func copyItem(at srcURL: URL, to dstURL: URL) throws {
    try super.copyItem(at: srcURL, to: dstURL)
    preserved = dstURL
    try replacement.write(to: srcURL)
  }
}
