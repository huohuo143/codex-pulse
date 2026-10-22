import Darwin
import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Daily summary archive safety")
struct DailySummarySafetyTests {
  @Test(arguments: ["empty", "invalid", "directory", "link"])
  func incompleteOrUnsafeSummaryDoesNotCountAsComplete(kind: String) throws {
    let f = try DailySummaryFixture()
    defer { f.clean() }
    switch kind {
    case "empty": try Data().write(to: f.target)
    case "invalid": try Data("truncated summary".utf8).write(to: f.target)
    case "directory": try FileManager.default.createDirectory(at: f.target, withIntermediateDirectories: true)
    default:
      let other = f.root.appendingPathComponent("unrelated.md")
      try f.markdown.write(to: other, atomically: true, encoding: .utf8)
      try FileManager.default.createSymbolicLink(at: f.target, withDestinationURL: other)
    }
    #expect(!f.archive.hasDailySummary(for: f.now))
  }

  @Test func linkedDirectoryCannotRedirectSummaryWrites() throws {
    let f = try DailySummaryFixture()
    defer { f.clean() }
    let other = f.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: f.directory)
    try FileManager.default.createSymbolicLink(at: f.directory, withDestinationURL: other)
    #expect(throws: (any Error).self) { _ = try f.archive.archiveDailySummary(f.markdown, now: f.now) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
  }

  @Test func validSameDaySummaryIsNotOverwrittenByLaterCalls() throws {
    let f = try DailySummaryFixture()
    defer { f.clean() }
    _ = try f.archive.archiveDailySummary(f.markdown, now: f.now)
    let original = try Data(contentsOf: f.target)
    let updated = f.markdown.replacingOccurrences(of: "1234", with: "9876")
    _ = try f.archive.archiveDailySummary(updated, now: f.now)
    #expect(try Data(contentsOf: f.target) == original)
  }

  @Test func failedPreservationStopsIncompleteSummaryReplacement() throws {
    let f = try DailySummaryFixture()
    defer { f.clean() }
    let original = Data("incomplete report that must remain recoverable".utf8)
    try original.write(to: f.target)
    let archive = LocalAutomationArchive(root: f.archiveRoot, fileManager: FailedSummaryCopyFileManager(), calendar: f.calendar)
    #expect(throws: (any Error).self) { _ = try archive.archiveDailySummary(f.markdown, now: f.now) }
    #expect(try Data(contentsOf: f.target) == original)
  }

  @Test(arguments: ["empty", "binary", "missing-field", "duplicate-field"])
  func incompleteReportsArePreservedBeforeRegeneration(kind: String) throws {
    let f = try DailySummaryFixture()
    defer { f.clean() }
    let original: Data
    switch kind {
    case "empty": original = Data()
    case "binary": original = Data([0xff, 0xfe, 0x00])
    case "missing-field": original = Data(f.markdown.replacingOccurrences(of: "- 本月 Token：5678", with: "").utf8)
    default: original = Data((f.markdown + "\n- 本月 Token：duplicate").utf8)
    }
    try original.write(to: f.target)
    #expect(!f.archive.hasDailySummary(for: f.now))
    let result = try f.archive.archiveDailySummary(f.markdown, now: f.now)
    #expect(!result.alreadyPresent)
    #expect(try Data(contentsOf: #require(result.preservedOriginalURL)) == original)
    #expect(try Data(contentsOf: result.outputURL) == Data(f.markdown.utf8))
    #expect(f.archive.hasDailySummary(for: f.now))
    let repeated = try f.archive.archiveDailySummary(f.markdown, now: f.now)
    #expect(repeated.alreadyPresent && repeated.preservedOriginalURL == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).count == 2)
  }

  @Test(arguments: ["oversized", "pipe", "dangling"])
  func unsafeExistingReportsStopWithoutReplacingTheEntry(kind: String) throws {
    let f = try DailySummaryFixture()
    defer { f.clean() }
    if kind == "oversized" {
      try Data(repeating: 32, count: LocalAutomationArchive.maximumDailySummarySize + 1).write(to: f.target)
    } else if kind == "pipe" {
      #expect(mkfifo(f.target.path, 0o600) == 0)
      let target = f.target
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
        let fd = open(target.path, O_WRONLY | O_NONBLOCK)
        if fd >= 0 { _ = close(fd) }
      }
    } else {
      try FileManager.default.createSymbolicLink(at: f.target, withDestinationURL: f.root.appendingPathComponent("missing.md"))
    }
    var before = stat(); #expect(lstat(f.target.path, &before) == 0)
    let started = Date()
    #expect(!f.archive.hasDailySummary(for: f.now))
    #expect(throws: DailySummaryArchiveError.unsafeArchive) { _ = try f.archive.archiveDailySummary(f.markdown, now: f.now) }
    #expect(Date().timeIntervalSince(started) < 0.3)
    var after = stat(); #expect(lstat(f.target.path, &after) == 0)
    #expect(before.st_ino == after.st_ino && before.st_mode == after.st_mode && before.st_size == after.st_size)
  }

  @Test func linkedArchiveRootIsRejectedBeforeWriting() throws {
    let f = try DailySummaryFixture()
    defer { f.clean() }
    let other = f.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: f.archiveRoot)
    try FileManager.default.createSymbolicLink(at: f.archiveRoot, withDestinationURL: other)
    #expect(!f.archive.hasDailySummary(for: f.now))
    #expect(throws: DailySummaryArchiveError.unsafeArchive) { _ = try f.archive.archiveDailySummary(f.markdown, now: f.now) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
  }

  @Test(arguments: ["empty", "missing-footer", "oversized"])
  func invalidNewOutputDoesNotChangeExistingSummary(kind: String) throws {
    let f = try DailySummaryFixture()
    defer { f.clean() }
    _ = try f.archive.archiveDailySummary(f.markdown, now: f.now)
    let original = try Data(contentsOf: f.target)
    let markdown: String
    switch kind {
    case "empty": markdown = ""
    case "missing-footer": markdown = f.markdown.components(separatedBy: "> 只包含")[0]
    default: markdown = f.markdown + String(repeating: "x", count: LocalAutomationArchive.maximumDailySummarySize)
    }
    #expect(throws: DailySummaryArchiveError.invalidSummary) { _ = try f.archive.archiveDailySummary(markdown, now: f.now) }
    #expect(try Data(contentsOf: f.target) == original)
  }

  @Test func externalChangeBeforeWriteIsNotOverwritten() throws {
    let f = try DailySummaryFixture()
    defer { f.clean() }
    try Data("incomplete".utf8).write(to: f.target)
    let replacement = Data(f.markdown.replacingOccurrences(of: "1234", with: "2468").utf8)
    let files = ChangedSummaryFileManager(target: f.target, replacement: replacement)
    let archive = LocalAutomationArchive(root: f.archiveRoot, fileManager: files, calendar: f.calendar)
    #expect(throws: DailySummaryArchiveError.changedOnDisk) { _ = try archive.archiveDailySummary(f.markdown, now: f.now) }
    #expect(try Data(contentsOf: f.target) == replacement)
  }

  @Test func unverifiableOriginalCopyStopsRepair() throws {
    let f = try DailySummaryFixture()
    defer { f.clean() }
    let original = Data("incomplete original".utf8); try original.write(to: f.target)
    let archive = LocalAutomationArchive(root: f.archiveRoot, fileManager: InvalidSummaryCopyFileManager(), calendar: f.calendar)
    #expect(throws: DailySummaryArchiveError.preservationFailed) { _ = try archive.archiveDailySummary(f.markdown, now: f.now) }
    #expect(try Data(contentsOf: f.target) == original)
  }

  @Test func changeDuringCopyIsPreservedWithoutOverwritingNewPrimary() throws {
    let f = try DailySummaryFixture()
    defer { f.clean() }
    let original = Data("incomplete original".utf8); try original.write(to: f.target)
    let files = ChangedSummaryCopyFileManager()
    let archive = LocalAutomationArchive(root: f.archiveRoot, fileManager: files, calendar: f.calendar)
    #expect(throws: DailySummaryArchiveError.changedOnDisk) { _ = try archive.archiveDailySummary(f.markdown, now: f.now) }
    #expect(try Data(contentsOf: f.target) == files.replacement)
    #expect(try Data(contentsOf: #require(files.preserved)) == original)
  }

  @Test func reportDayFollowsConfiguredCalendarTimeZone() throws {
    let f = try DailySummaryFixture()
    defer { f.clean() }
    let date = try #require(ISO8601DateFormatter().date(from: "2026-10-22T23:30:00Z"))
    let result = try f.archive.archiveDailySummary(f.markdown, now: date)
    #expect(result.outputURL.lastPathComponent == "codex-daily-summary-2026-10-22.md")
    #expect(f.archive.hasDailySummary(for: date))
    var shanghai = f.calendar; shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let nextDayArchive = LocalAutomationArchive(root: f.archiveRoot, calendar: shanghai)
    #expect(!nextDayArchive.hasDailySummary(for: date))
  }
}

private struct DailySummaryFixture {
  let root: URL
  let now = Date(timeIntervalSince1970: 1_792_665_600)
  var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
  var archiveRoot: URL { root.appendingPathComponent("automation") }
  var directory: URL { archiveRoot.appendingPathComponent("daily-reports") }
  var target: URL {
    let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
    return directory.appendingPathComponent("codex-daily-summary-\(formatter.string(from: now)).md")
  }
  var archive: LocalAutomationArchive { .init(root: archiveRoot, calendar: calendar) }
  var markdown: String { ReliabilityReportBuilder.dailySummaryMarkdown(remainingPercent: 50, rolling24hTokens: 1234,
    monthTokens: 5678, projectedMonthTokens: 10000, quotaRisk: "comfortable", health: .healthy, generatedAt: now) }
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

private final class FailedSummaryCopyFileManager: FileManager, @unchecked Sendable {
  override func copyItem(at srcURL: URL, to dstURL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}

private final class ChangedSummaryFileManager: FileManager, @unchecked Sendable {
  let target: URL
  let replacement: Data
  init(target: URL, replacement: Data) { self.target = target; self.replacement = replacement; super.init() }
  override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil) throws {
    try replacement.write(to: target)
    try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
  }
}

private final class InvalidSummaryCopyFileManager: FileManager, @unchecked Sendable {
  override func copyItem(at srcURL: URL, to dstURL: URL) throws { try Data("bad copy".utf8).write(to: dstURL) }
}

private final class ChangedSummaryCopyFileManager: FileManager, @unchecked Sendable {
  let replacement = Data("externally changed report".utf8)
  var preserved: URL?
  override func copyItem(at srcURL: URL, to dstURL: URL) throws {
    try super.copyItem(at: srcURL, to: dstURL); preserved = dstURL
    try replacement.write(to: srcURL)
  }
}
