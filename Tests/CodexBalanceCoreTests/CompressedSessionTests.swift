import Foundation
import Testing
@testable import CodexBalanceCore

struct CompressedSessionTests {
  private let now = ISO8601DateFormatter().date(from: "2026-10-22T10:00:00Z")!
  private let filename = "rollout-2026-10-22T09-00-00-019c6e27-e55b-73d1-87d8-4e01f1f75043.jsonl"

  private func home() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompressedSessionTests-\(UUID())")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    return root
  }

  private func record(total: Int = 100, last: Int = 100) -> Data {
    Data("""
    {"timestamp":"2026-10-22T09:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":1792666800}},"info":{"total_token_usage":{"total_tokens":\(total)},"last_token_usage":{"total_tokens":\(last),"input_tokens":\(last / 2),"output_tokens":\(last / 2)}}}}

    """.utf8)
  }

  // A standards-defined Zstd frame with a raw block, independent of the decoder.
  private func frame(_ data: Data) -> Data {
    var result = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
    for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8((data.count >> shift) & 255)) }
    var offset = 0
    repeat {
      let count = min(64 * 1024, data.count - offset)
      let block = (count << 3) | (offset + count == data.count ? 1 : 0)
      for shift in stride(from: 0, to: 24, by: 8) { result.append(UInt8((block >> shift) & 255)) }
      result.append(data[offset..<(offset + count)])
      offset += count
    } while offset < data.count
    return result
  }

  // Produced by upstream Zstandard 1.5.7 `zstd --check -c -`, from synthetic
  // Chinese turn_context + one 100-token event; uses compressed blocks/checksum.
  private var compressedFixture: Data {
    Data(base64Encoded: "KLUv/QRY5QcARhE5LXBFaQ4QA1U1OK5BAhVAOaRBs7xyKxHhwA6L5CY+XFVYxBCqfdSaWOSl9IO/Ji8ALAAqAK89PcIBwMRDAIaGCggJigbDmhPaQbHxfRNhHu2b9Rxowaf3Ard7jHKP7O8ZQv0oins9T28nH6McK7wD1VXdhxooCkMTxqKo8j1sqyM31o8Wc34gwMFoCPne4Sa9VGyO/DypCuwjt3SsqchrHIs8abJvx8zDUDUc5aM99KzGHvhoH5s15gSLOeds+Z7UsY8SOvbUcTlPUzXZR4asKJWz+vWj/UNw7GlO1YJlWZQHQbIPBwA2JQJusdT4cbrWOY47PGG4KYczPt6O9Q==")!
  }

  @Test func compressedOnlyLogContributesUsage() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    try frame(record()).write(to: root.appendingPathComponent("sessions/\(filename).zst"))
    let status = try CodexStatusReader(codexHome: root, preferLiveStatus: false).read(now: now)
    #expect(status.scannedFiles == 1)
    #expect(status.tokenStats.todayTokens == 100)
  }

  @Test func archivedOnlyLogContributesUsage() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
    try record().write(to: root.appendingPathComponent("archived_sessions/\(filename)"))
    #expect(try CodexStatusReader(codexHome: root, preferLiveStatus: false).read(now: now).tokenStats.todayTokens == 100)
  }

  @Test func compressionAndArchivingKeepTotalsStable() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    let plain = root.appendingPathComponent("sessions/\(filename)")
    let compressed = plain.appendingPathExtension("zst")
    let reader = CodexStatusReader(codexHome: root, preferLiveStatus: false)
    try record().write(to: plain)
    #expect(try reader.read(now: now).tokenStats.todayTokens == 100)
    try frame(record()).write(to: compressed)
    #expect(try reader.read(now: now).tokenStats.todayTokens == 100)
    try FileManager.default.removeItem(at: plain)
    #expect(try reader.read(now: now).tokenStats.todayTokens == 100)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
    let archive = root.appendingPathComponent("archived_sessions/\(filename).zst")
    try FileManager.default.copyItem(at: compressed, to: archive)
    #expect(try reader.read(now: now).tokenStats.todayTokens == 100)
    try FileManager.default.removeItem(at: compressed)
    #expect(try reader.read(now: now).tokenStats.todayTokens == 100)
  }

  @Test func compressedBlocksAndChecksumPreserveContext() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    try compressedFixture.write(to: root.appendingPathComponent("sessions/\(filename).zst"))
    let status = try CodexStatusReader(codexHome: root, preferLiveStatus: false).read(now: now)
    #expect(status.tokenStats.todayTokens == 100)
    #expect(status.tokenStats.recentUsageEvents.first?.projectPath == "/synthetic/中文项目")
    #expect(status.tokenStats.recentUsageEvents.first?.model == "gpt-5.4")
  }

  @Test func concatenatedFramesAndGrowingCompressedFileReparseSafely() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/\(filename).zst")
    let reader = CodexStatusReader(codexHome: root, preferLiveStatus: false)
    try compressedFixture.write(to: file)
    #expect(try reader.read(now: now).tokenStats.todayTokens == 100)
    let second = frame(record(total: 300, last: 200))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd(); try handle.write(contentsOf: second); try handle.close()
    let status = try reader.read(now: now)
    #expect(status.tokenStats.todayTokens == 300)
    #expect(status.tokenStats.sampleCount == 2)
    #expect(reader.diagnostics.parsedFiles == 2)
  }

  @Test func truncatedAndCorruptFramesNeverPublishPartialEvents() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/\(filename).zst")
    let reader = CodexStatusReader(codexHome: root, preferLiveStatus: false)
    try compressedFixture.write(to: file)
    #expect(try reader.read(now: now).tokenStats.todayTokens == 100)
    // Enough records to force multiple parser batches before the final failure.
    var many = Data()
    for _ in 0..<1200 { many.append(record(total: 300, last: 200)) }
    let broken = frame(many) + compressedFixture.dropLast()
    try broken.write(to: file, options: .atomic)
    #expect(try reader.read(now: now).tokenStats.todayTokens == 100)
    #expect(reader.diagnostics.unreadableFiles == 1)
    #expect(try CodexStatusReader(codexHome: root, preferLiveStatus: false).read(now: now).tokenStats.todayTokens == 0)
    var badChecksum = compressedFixture
    badChecksum[badChecksum.count - 1] ^= 0xff
    try badChecksum.write(to: file, options: .atomic)
    #expect(try reader.read(now: now).tokenStats.todayTokens == 100)
    try frame(record(total: 300, last: 300)).write(to: file, options: .atomic)
    #expect(try reader.read(now: now).tokenStats.todayTokens == 300)
    #expect(reader.diagnostics.unreadableFiles == 0)
  }

  @Test func unchangedCompressedFilesUsePersistentCache() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    try compressedFixture.write(to: root.appendingPathComponent("sessions/\(filename).zst"))
    let cache = root.appendingPathComponent("cache.plist")
    let first = CodexStatusReader(codexHome: root, preferLiveStatus: false, persistentEventCacheURL: cache)
    #expect(try first.read(now: now).tokenStats.todayTokens == 100)
    let reads = first.diagnostics.bytesRead
    #expect(try first.read(now: now).tokenStats.todayTokens == 100)
    #expect(first.diagnostics.bytesRead == reads)
    let restarted = CodexStatusReader(codexHome: root, preferLiveStatus: false, persistentEventCacheURL: cache)
    #expect(try restarted.read(now: now).tokenStats.todayTokens == 100)
    #expect(restarted.diagnostics.parsedFiles == 0)
  }

  @Test func unrelatedNamesAndDifferentSessionsDoNotMerge() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a/same.jsonl.zst", "b/same.jsonl.zst", filename + ".zst",
                 filename.replacingOccurrences(of: "75043", with: "75044") + ".zst"] {
      let file = root.appendingPathComponent("sessions/" + name)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try compressedFixture.write(to: file)
    }
    #expect(try CodexStatusReader(codexHome: root, preferLiveStatus: false).read(now: now).tokenStats.todayTokens == 400)
  }

  @Test func incompletePlainCopyDoesNotHideCompleteCompressedCopy() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/\(filename)")
    try record().write(to: file)
    try frame(record() + record(total: 300, last: 200)).write(to: file.appendingPathExtension("zst"))
    let status = try CodexStatusReader(codexHome: root, preferLiveStatus: false).read(now: now)
    #expect(status.tokenStats.todayTokens == 300)
    #expect(status.tokenStats.sampleCount == 2)
  }

  @Test func explicitRootRemainsScopedAndFutureArchiveIsDiscovered() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    let reader = CodexStatusReader(codexHome: root, preferLiveStatus: false)
    #expect(try reader.read(now: now).scannedFiles == 0)
    let archive = root.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    try compressedFixture.write(to: archive.appendingPathComponent(filename + ".zst"))
    #expect(try reader.read(now: now).tokenStats.todayTokens == 100)
    let scoped = CodexStatusReader(codexHome: root, sessionsRoot: root.appendingPathComponent("sessions"), preferLiveStatus: false)
    #expect(try scoped.read(now: now).tokenStats.todayTokens == 0)
  }

  @Test func compressedFileEventsUpdateOnlyChangedEntryAndDeletion() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/\(filename).zst")
    let index = SessionFileIndex(roots: [root], reconciliationInterval: 600, watch: false)
    #expect(index.read(at: now).isEmpty)
    let enumerations = index.enumerationCount
    try compressedFixture.write(to: file)
    index.markChanged([file.path])
    #expect(index.read(at: now).count == 1)
    #expect(index.enumerationCount == enumerations)
    try FileManager.default.removeItem(at: file)
    index.markChanged([file.path])
    #expect(index.read(at: now).isEmpty)
    #expect(index.enumerationCount == enumerations)
  }

  @Test func largeIgnoredRecordsAndSplitUnicodeStayBounded() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/large.jsonl.zst")
    let context = Data("{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"/synthetic/中文项目\"}}\n".utf8)
    let ignored = Data(("{\"message\":\"" + String(repeating: "中", count: 700_000) + "\"}\n").utf8)
    try frame(ignored + context + record()).write(to: file)
    var maximumBatch = 0
    _ = try SessionLogStream.read(file: file, offset: 0, endOffset: Int(file.resourceValues(forKeys: [.fileSizeKey]).fileSize!), pending: Data()) {
      maximumBatch = max(maximumBatch, $0.utf8.count)
    }
    #expect(maximumBatch < 256 * 1024)
    let status = try CodexStatusReader(codexHome: root, preferLiveStatus: false).read(now: now)
    #expect(status.tokenStats.todayTokens == 100)
    #expect(status.tokenStats.recentUsageEvents.first?.projectPath == "/synthetic/中文项目")
  }

  @Test func emptyValidFrameAndEmptyInvalidFileHaveNoUsage() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/empty.jsonl.zst")
    try frame(Data()).write(to: file)
    let size = try #require(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let result = try SessionLogStream.read(file: file, offset: 0, endOffset: size, pending: Data()) { _ in Issue.record("Unexpected content") }
    #expect(result.pending.isEmpty)
    try Data().write(to: file)
    #expect(throws: (any Error).self) {
      try SessionLogStream.read(file: file, offset: 0, endOffset: 0, pending: Data()) { _ in }
    }
  }

  @Test func failedReadRetriesWithoutMetadataChangeAndHealthRecovers() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/\(filename).zst")
    var corrupt = compressedFixture; corrupt[corrupt.count - 1] ^= 0xff
    try corrupt.write(to: file)
    let stamp = try #require(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    let index = SessionFileIndex(roots: [root], reconciliationInterval: 600, watch: false)
    let reader = CodexStatusReader(codexHome: root, fileIndex: index, preferLiveStatus: false)
    #expect(try reader.read(now: now).tokenStats.todayTokens == 0)
    #expect(reader.diagnostics.unreadableFiles == 1)
    let handle = try FileHandle(forWritingTo: file)
    try handle.write(contentsOf: compressedFixture); try handle.close()
    try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
    #expect(try reader.read(now: now.addingTimeInterval(30)).tokenStats.todayTokens == 0)
    #expect(try reader.read(now: now.addingTimeInterval(61)).tokenStats.todayTokens == 100)
    #expect(reader.diagnostics.unreadableFiles == 0)
  }

  @Test func healthDoesNotCallPartialAggregationComplete() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    var inputs = ReliabilityAuditor.Inputs(lastQuotaRefresh: now, hasOfficialQuota: true,
      lastUsageRefresh: now, usageSampleCount: 100, radarUpdatedAt: now, launchWatcherEnabled: false,
      quotaHistoryURL: root.appendingPathComponent("quota.json"), projectBudgetsURL: root.appendingPathComponent("budgets.json"),
      widgetSnapshotURL: root.appendingPathComponent("widget.json"), unreadableSessionFiles: 2)
    let failed = try #require(ReliabilityAuditor.audit(inputs: inputs, now: now).checks.first { $0.id == .tokenAggregation })
    #expect(failed.level == .warning)
    #expect(failed.detail.contains("2 个会话日志"))
    inputs.unreadableSessionFiles = 0
    #expect(ReliabilityAuditor.audit(inputs: inputs, now: now).checks.first { $0.id == .tokenAggregation }?.level == .healthy)
  }

  @Test func unicodeSplitBetweenFramesReassemblesWithoutReplacement() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/unicode.jsonl.zst")
    let context = Data("{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"/synthetic/中文项目\"}}\n".utf8)
    let split = try #require(context.range(of: Data("中".utf8))).lowerBound + 1
    try (frame(Data(context.prefix(split))) + frame(Data(context.dropFirst(split)) + record())).write(to: file)
    let status = try CodexStatusReader(codexHome: root, preferLiveStatus: false).read(now: now)
    #expect(status.tokenStats.todayTokens == 100)
    #expect(status.tokenStats.recentUsageEvents.first?.projectPath == "/synthetic/中文项目")
  }

  @Test func oversizedWindowAndTrailingGarbageAreRejected() throws {
    let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/bad.jsonl.zst")
    // Window descriptor requests 256 MiB, exceeding the decoder's 128 MiB cap.
    let oversized = Data([0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x90, 0x01, 0x00, 0x00])
    for data in [oversized, compressedFixture + Data("garbage".utf8)] {
      try data.write(to: file)
      #expect(throws: (any Error).self) {
        try SessionLogStream.read(file: file, offset: 0, endOffset: data.count, pending: Data()) { _ in }
      }
    }
  }
}
