import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Automatic backup file safety")
struct AutomationBackupSafetyTests {
  @Test(arguments: [LocalBackupHealthState.notChecked, .verified, .noData, .failed])
  func backupTaskOutcomeIsPartOfHealthAndDiagnostics(state: LocalBackupHealthState) throws {
    let f = try BackupSafetyFixture()
    defer { f.clean() }
    let snapshot = ReliabilityAuditor.audit(inputs: .init(lastQuotaRefresh: nil, hasOfficialQuota: false,
      lastUsageRefresh: nil, usageSampleCount: 0, radarUpdatedAt: nil, launchWatcherEnabled: false,
      quotaHistoryURL: f.root.appendingPathComponent("absent-history"),
      projectBudgetsURL: f.root.appendingPathComponent("absent-budgets"),
      widgetSnapshotURL: f.root.appendingPathComponent("absent-widget"),
      creditExpiryStore: .init(url: f.root.appendingPathComponent("absent-credits"), legacyURL: f.root.appendingPathComponent("absent-legacy")),
      localBackupHealth: state, automaticBackupsEnabled: true))
    let check = try #require(snapshot.checks.first { $0.id == .localBackup })
    let expected: ReliabilityHealthLevel = state == .failed ? .warning : (state == .notChecked ? .unknown : .healthy)
    #expect(check.level == expected)
    let report = ReliabilityReportBuilder.diagnosticMarkdown(appVersion: "test", snapshot: snapshot, recentEvents: [])
    #expect(report.contains("本地备份任务"))
    #expect(!report.contains(f.root.path))
  }

  @Test(arguments: ["link", "dangling-link", "oversized", "pipe"])
  func unsafeSourceFailsPromptlyWithoutChangingPreviousBackup(kind: String) throws {
    let f = try BackupSafetyFixture()
    defer { f.clean() }
    let before = try f.fingerprint()
    try Data("new current value".utf8).write(to: f.source)
    let unsafe = f.root.appendingPathComponent("unsafe.json")
    let release = try f.makeUnsafe(at: unsafe, kind: kind, linkedTo: f.source)
    defer { release() }
    let start = Date()
    #expect(throws: (any Error).self) { _ = try f.archive.backup(sourceURLs: [f.source, unsafe], now: f.now) }
    #expect(Date().timeIntervalSince(start) < 0.3)
    #expect(try f.fingerprint() == before)
  }

  @Test(arguments: ["saved-link", "manifest-link", "source-dangling-link", "saved-pipe", "manifest-pipe"])
  func unsafePathsNeverCountAsVerifiedBackup(kind: String) throws {
    let f = try BackupSafetyFixture()
    defer { f.clean() }
    let path = kind.hasPrefix("manifest") ? f.manifest : f.destination.appendingPathComponent(f.source.lastPathComponent)
    let outside = f.root.appendingPathComponent("outside.json")
    try Data(contentsOf: path).write(to: outside)
    let source: URL
    let release: () -> Void
    if kind == "source-dangling-link" {
      source = f.root.appendingPathComponent("missing-link.json")
      release = try f.makeUnsafe(at: source, kind: "dangling-link", linkedTo: outside)
    } else {
      source = f.source
      try FileManager.default.removeItem(at: path)
      release = try f.makeUnsafe(at: path, kind: kind.hasSuffix("pipe") ? "pipe" : "link", linkedTo: outside)
    }
    defer { release() }
    let start = Date()
    #expect(!f.archive.hasBackup(for: f.now, sourceURLs: [f.source, source]))
    #expect(Date().timeIntervalSince(start) < 0.3)
  }

  @Test func futureManifestCannotBeReplacedWhenAddingBackup() throws {
    let f = try BackupSafetyFixture()
    defer { f.clean() }
    let future = Data(#"{"schemaVersion":99,"futureBackupIndex":{"preserve":true}}"#.utf8)
    try future.write(to: f.manifest)
    let before = try f.fingerprint()
    try Data("new source".utf8).write(to: f.source)
    #expect(!f.archive.hasBackup(for: f.now, sourceURLs: [f.source]))
    #expect(throws: (any Error).self) { _ = try f.archive.backup(sourceURLs: [f.source], now: f.now) }
    #expect(try f.fingerprint() == before)
  }

  @Test(arguments: ["root", "backups", "day"])
  func linkedArchiveDirectoriesCannotRedirectBackupWrites(level: String) throws {
    let f = try BackupSafetyFixture()
    defer { f.clean() }
    let directory = level == "root" ? f.archiveRoot : (level == "backups" ? f.archiveRoot.appendingPathComponent("backups") : f.destination)
    let outside = f.root.appendingPathComponent("original-directory")
    try FileManager.default.moveItem(at: directory, to: outside)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
    let snapshot = try directoryFingerprint(outside)
    #expect(!f.archive.hasBackup(for: f.now, sourceURLs: [f.source]))
    #expect(throws: LocalBackupError.unsafeArchive) { _ = try f.archive.backup(sourceURLs: [f.source], now: f.now) }
    #expect(try directoryFingerprint(outside) == snapshot)
  }

  @Test(arguments: ["link", "directory", "oversized", "pipe"])
  func unsafeExistingTargetStopsBeforeAnyArchiveFileIsWritten(kind: String) throws {
    let f = try BackupSafetyFixture()
    defer { f.clean() }
    let target = f.destination.appendingPathComponent(f.source.lastPathComponent)
    try FileManager.default.removeItem(at: target)
    let release: () -> Void
    if kind == "directory" {
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
      release = {}
    } else { release = try f.makeUnsafe(at: target, kind: kind, linkedTo: f.source) }
    defer { release() }
    let before = try f.fingerprint()
    let second = f.root.appendingPathComponent("second.json")
    try Data("second new source".utf8).write(to: second)
    #expect(throws: LocalBackupError.unsafeArchive) { _ = try f.archive.backup(sourceURLs: [second, f.source], now: f.now) }
    #expect(try f.fingerprint() == before)
  }

  @Test(arguments: ["{damaged", #"{"schemaVersion":1,"files":{"../private":"abc"}}"#,
    #"{"schemaVersion":1,"files":{"history.json":"not-a-sha256"}}"#])
  func invalidManifestPreservesEveryExistingCopy(document: String) throws {
    let f = try BackupSafetyFixture()
    defer { f.clean() }
    try Data(document.utf8).write(to: f.manifest)
    let before = try f.fingerprint()
    #expect(!f.archive.hasBackup(for: f.now, sourceURLs: [f.source]))
    #expect(throws: LocalBackupError.invalidManifest) { _ = try f.archive.backup(sourceURLs: [f.source], now: f.now) }
    #expect(try f.fingerprint() == before)
  }

  @Test func manifestOutputLimitIsCheckedBeforeReplacingSavedFiles() throws {
    let f = try BackupSafetyFixture()
    defer { f.clean() }
    let digest = String(repeating: "a", count: 64)
    let files = Dictionary(uniqueKeysWithValues: (0..<6000).map { ("history-\($0).json", digest) })
    let compact = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "files": files])
    #expect(compact.count < 512 * 1024)
    try compact.write(to: f.manifest)
    let before = try f.fingerprint()
    try Data("new current source".utf8).write(to: f.source)
    #expect(throws: LocalBackupError.invalidManifest) { _ = try f.archive.backup(sourceURLs: [f.source], now: f.now) }
    #expect(try f.fingerprint() == before)
  }

  @Test func manifestChangedDuringPreparationIsNotOverwritten() throws {
    let f = try BackupSafetyFixture()
    defer { f.clean() }
    let primary = try Data(contentsOf: f.destination.appendingPathComponent(f.source.lastPathComponent))
    let replacement = Data(#"{"schemaVersion":99,"external":true}"#.utf8)
    let files = BackupManifestChangingFileManager(manifest: f.manifest, replacement: replacement)
    let archive = LocalAutomationArchive(root: f.archiveRoot, fileManager: files, calendar: f.calendar)
    try Data("changed source".utf8).write(to: f.source)
    #expect(throws: LocalBackupError.changedOnDisk) { _ = try archive.backup(sourceURLs: [f.source], now: f.now) }
    #expect(try Data(contentsOf: f.manifest) == replacement)
    #expect(try Data(contentsOf: f.destination.appendingPathComponent(f.source.lastPathComponent)) == primary)
  }

  @Test(arguments: [0, 8 * 1024 * 1024])
  func ordinaryFilesAtBothSizeBoundariesRemainSupported(size: Int) throws {
    let f = try BackupSafetyFixture()
    defer { f.clean() }
    let original = Data(repeating: 32, count: size)
    try original.write(to: f.source)
    let result = try f.archive.backup(sourceURLs: [f.source, f.root.appendingPathComponent("absent.json")], now: f.now)
    #expect(result.itemCount == 1)
    #expect(try Data(contentsOf: result.outputURL.appendingPathComponent(f.source.lastPathComponent)) == original)
    #expect(f.archive.hasBackup(for: f.now, sourceURLs: [f.source]))
  }
}

private struct BackupSafetyFixture {
  let root: URL
  let now = Date(timeIntervalSince1970: 1_792_670_400)
  var archiveRoot: URL { root.appendingPathComponent("automation") }
  var source: URL { root.appendingPathComponent("history.json") }
  var calendar: Calendar {
    var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }
  var archive: LocalAutomationArchive { .init(root: archiveRoot, calendar: calendar) }
  var destination: URL {
    let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
    return archiveRoot.appendingPathComponent("backups/\(formatter.string(from: now))")
  }
  var manifest: URL { destination.appendingPathComponent("backup-manifest-v1.json") }
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("original history".utf8).write(to: source)
    _ = try archive.backup(sourceURLs: [source], now: now)
  }
  func makeUnsafe(at url: URL, kind: String, linkedTo target: URL) throws -> () -> Void {
    switch kind {
    case "link": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    case "dangling-link": try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "does-not-exist")
    case "oversized": try Data(repeating: 32, count: 8 * 1024 * 1024 + 1).write(to: url)
    default:
      #expect(mkfifo(url.path, 0o600) == 0)
      // Release a legacy blocking reader after a bounded delay, so regressions
      // fail without hanging the entire test runner. Nonblocking code returns first.
      let finished = DispatchSemaphore(value: 0)
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
        let fd = open(url.path, O_WRONLY | O_NONBLOCK)
        if fd >= 0 { _ = close(fd) }
        finished.signal()
      }
      return { _ = finished.wait(timeout: .now() + 2) }
    }
    return {}
  }
  func fingerprint() throws -> [String: String] {
    try directoryFingerprint(archiveRoot)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

private func directoryFingerprint(_ root: URL) throws -> [String: String] {
    let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
    var values: [String: String] = [:]
    for p in paths {
      var info = stat(); guard lstat(p.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
      if info.st_mode & S_IFMT == S_IFREG { values[p.path] = SHA256.hash(data: try Data(contentsOf: p)).description }
      else { values[p.path] = "\(info.st_mode):\(info.st_ino)" }
    }
    return values
}

private final class BackupManifestChangingFileManager: FileManager, @unchecked Sendable {
  let manifest: URL
  let replacement: Data
  init(manifest: URL, replacement: Data) { self.manifest = manifest; self.replacement = replacement; super.init() }
  override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil) throws {
    try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    try replacement.write(to: manifest, options: .atomic)
  }
}
