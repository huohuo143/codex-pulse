import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Indexed statistics and expiry records", .serialized)
struct IncrementalExpiryTests {
  @Test func expiryMigrationAndAccountBinding() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CreditExpiryStore(url: root.appendingPathComponent("expiry.json"))
    var record = store.load()
    #expect(record.source.contains("历史记录"))
    #expect(!record.isConfirmed(for: "account-a"))
    record.source = "用户核对的购买凭据"
    record.confirmedAt = Date(); record.accountScope = "account-a"
    try store.save(record)
    #expect(store.load().isConfirmed(for: "account-a"))
    #expect(!store.load().isConfirmed(for: "account-b"))
    #expect(!store.load().isConfirmed(for: nil))
    #expect(AnonymousAccountScope.make(accountID: "a", salt: "one") != AnonymousAccountScope.make(accountID: "a", salt: "two"))
  }

  @Test func idlePollingPreservesChoiceAndRestoresActivity() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let now = start.addingTimeInterval(301)
    #expect(QuotaPollingPolicy.interval(selected: 5, windowVisible: false, lastActivity: nil, startedAt: start, now: now) == 120)
    #expect(QuotaPollingPolicy.interval(selected: 5, windowVisible: true, lastActivity: nil, startedAt: start, now: now) == 5)
    #expect(QuotaPollingPolicy.interval(selected: 10, windowVisible: false, lastActivity: now, startedAt: start, now: now) == 10)
  }

  @Test func indexedStatisticsMatchIndependentReference() throws {
    for count in [100, 1_000, 10_000] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-index-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let now = ISO8601DateFormatter().date(from: "2026-09-01T00:12:00Z")!
      let hours = (0..<50).map { now.addingTimeInterval(-Double($0) * 3600) }
      var expected24 = 0, expectedMonth = 0, expectedToday = 0
      let month = Calendar.current.dateInterval(of: .month, for: now)!
      let day = Calendar.current.dateInterval(of: .day, for: now)!
      let texts = hours.map { event(at: $0, total: 100, last: 100) }
      for index in 0..<count {
        let time = hours[index % hours.count]
        if time >= now.addingTimeInterval(-86400) { expected24 += 100 }
        if month.contains(time) { expectedMonth += 100 }
        if day.contains(time) { expectedToday += 100 }
        try texts[index % texts.count].write(to: root.appendingPathComponent("\(index).jsonl"), atomically: true, encoding: .utf8)
      }
      let fileIndex = SessionFileIndex(roots: [root], watch: false)
      let reader = CodexStatusReader(sessionsRoot: root, maxSessionFiles: 1_000, fileIndex: fileIndex, preferLiveStatus: false)
      let start = Date()
      let cold = try reader.read(now: now)
      let coldMS = Date().timeIntervalSince(start) * 1000
      #expect(cold.scannedFiles == count)
      #expect(cold.tokenStats.rolling24HoursTokens == expected24)
      #expect(cold.tokenStats.todayTokens == expectedToday)
      #expect(cold.tokenStats.monthTokens == expectedMonth)
      let diagnostics = reader.diagnostics
      let metadataCount = fileIndex.metadataReadCount
      let warmStart = Date()
      let unchanged = try reader.read(now: now)
      let warmMS = Date().timeIntervalSince(warmStart) * 1000
      #expect(unchanged.tokenStats == cold.tokenStats)
      #expect(reader.diagnostics == diagnostics)
      #expect(fileIndex.metadataReadCount == metadataCount)
      // An exact rolling boundary can invalidate statistics within the same hour without parsing files.
      let later = try reader.read(now: now.addingTimeInterval(1))
      let atBoundary = (0..<count).filter { $0 % 50 == 24 }.count * 100
      #expect(later.tokenStats.rolling24HoursTokens == expected24 - atBoundary)
      #expect(reader.diagnostics.parsedFiles == count)
      let file = root.appendingPathComponent("0.jsonl")
      let handle = try FileHandle(forWritingTo: file)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(event(at: now.addingTimeInterval(2), total: 300, last: 200).utf8))
      try handle.close()
      fileIndex.markChanged([file.path])
      let appended = try reader.read(now: now.addingTimeInterval(3))
      #expect(appended.tokenStats.monthTokens == expectedMonth + 200)
      #expect(reader.diagnostics.parsedFiles == count + 1)
      print("PERFORMANCE indexed files=\(count) cold_ms=\(coldMS) warm_ms=\(warmMS) parsed=\(reader.diagnostics.parsedFiles) bytes=\(reader.diagnostics.bytesRead) metadata=\(fileIndex.metadataReadCount) aggregations=\(reader.diagnostics.aggregations)")
    }
  }

  @Test func truncationRotationReconciliationAndFastRead() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let file = root.appendingPathComponent("session.jsonl")
    let index = SessionFileIndex(roots: [root], watch: false)
    let reader = CodexStatusReader(sessionsRoot: root, fileIndex: index, preferLiveStatus: false)
    try event(at: now, total: 100, last: 100).write(to: file, atomically: true, encoding: .utf8)
    #expect(try reader.read(now: now).tokenStats.todayTokens == 100)
    try event(at: now, total: 300, last: 300).write(to: file, atomically: true, encoding: .utf8)
    index.markChanged([file.path])
    #expect(try reader.read(now: now).tokenStats.todayTokens == 300)
    try "".write(to: file, atomically: false, encoding: .utf8)
    index.markChanged([file.path])
    #expect(try reader.read(now: now).tokenStats.todayTokens == 0)
    let another = root.appendingPathComponent("new.jsonl")
    try event(at: now, total: 400, last: 400).write(to: another, atomically: true, encoding: .utf8)
    // A dropped directory notification is repaired at the five-minute reconciliation.
    #expect(try reader.read(now: now.addingTimeInterval(301)).tokenStats.todayTokens == 400)
    let before = reader.diagnostics
    let scanCount = index.enumerationCount
    #expect(try reader.readFast(now: now).scannedFiles == 0)
    #expect(reader.diagnostics == before)
    #expect(index.enumerationCount == scanCount)
  }

  @Test func officialCacheDoesNotCrossAccounts() {
    let source = CodexAppServerRateLimitSource()
    source.useAccount("a")
    var data = LiveAccountRateLimitSnapshot.empty
    data.accountScope = "a"
    data.flexibleCreditBalance = CodexFlexibleCreditBalance(hasCredits: true, unlimited: false, balanceCredits: 100)
    _ = source.finishSnapshot(data, at: Date())
    source.useAccount("b")
    #expect(source.cachedSnapshot(now: Date()).flexibleCreditBalance == nil)
    #expect(source.finishSnapshot(data, at: Date()).flexibleCreditBalance == nil)
  }

  @Test func legacyCacheMigratesWithoutReparsingUnchangedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let logs = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let file = logs.appendingPathComponent("one.jsonl")
    try event(at: now, total: 100, last: 100).write(to: file, atomically: true, encoding: .utf8)
    let initialURL = root.appendingPathComponent("original-cache.plist")
    let initial = CodexStatusReader(sessionsRoot: logs, preferLiveStatus: false, persistentEventCacheURL: initialURL)
    #expect(try initial.read(now: now).tokenStats.todayTokens == 100)
    var data = try PropertyListSerialization.propertyList(from: Data(contentsOf: initialURL), format: nil) as! [String: Any]
    data["schemaVersion"] = 5
    var files = data["files"] as! [String: [String: Any]]
    for key in Array(files.keys) {
      files[key]?.removeValue(forKey: "identity"); files[key]?.removeValue(forKey: "prefix"); files[key]?.removeValue(forKey: "pendingBytes")
    }
    data["files"] = files
    try PropertyListSerialization.data(fromPropertyList: data, format: .binary, options: 0)
      .write(to: root.appendingPathComponent("session-event-cache-v5.plist"))
    let destination = root.appendingPathComponent("session-event-cache-v6.plist")
    let migrated = CodexStatusReader(sessionsRoot: logs, preferLiveStatus: false, persistentEventCacheURL: destination)
    #expect(try migrated.read(now: now).tokenStats.todayTokens == 100)
    #expect(migrated.diagnostics.parsedFiles == 0)
    #expect(FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func streamBoundsLongRecordsAndPreservesSplitUTF8() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("large.jsonl")
    let long = "{\"type\":\"response_item\",\"text\":\"" + String(repeating: "x", count: 12 * 1024 * 1024) + "\"}\n"
    try long.write(to: file, atomically: true, encoding: .utf8)
    var largestBatch = 0
    let streamed = try SessionLogStream.read(file: file, offset: 0, endOffset: long.utf8.count, pending: Data()) {
      largestBatch = max(largestBatch, $0.utf8.count)
    }
    #expect(streamed.bytesRead == long.utf8.count)
    #expect(largestBatch <= 4 * 8192 + 1)
    let context = Data("{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-6-astra\",\"cwd\":\"/tmp/水稻\"}}\n".utf8)
    let split = context.range(of: Data("水".utf8))!.lowerBound + 1
    try Data(context[..<split]).write(to: file)
    let now = Date()
    let reader = CodexStatusReader(sessionsRoot: root, preferLiveStatus: false)
    #expect(try reader.read(now: now).tokenStats.todayTokens == 0)
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
    try handle.write(contentsOf: Data(context[split...]) + Data(event(at: now, total: 100, last: 100).utf8)); try handle.close()
    let result = try reader.read(now: now)
    #expect(result.tokenStats.todayTokens == 100)
    #expect(result.tokenStats.costMonth.pricedTokens == 100)
  }

  @Test func pricesAndTokensUseIdenticalCalendarWindows() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = ISO8601DateFormatter().date(from: "2026-09-01T04:00:00Z")!
    let firstDay = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now))!
    let times = [firstDay.addingTimeInterval(-1), firstDay, now, now.addingTimeInterval(3600)]
    for (i, time) in times.enumerated() {
      let context = "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-6-astra\"}}\n"
      try (context + event(at: time, total: 100, last: 100)).write(to: root.appendingPathComponent("\(i).jsonl"), atomically: true, encoding: .utf8)
    }
    let reader = CodexStatusReader(sessionsRoot: root, preferLiveStatus: false)
    let stats = try reader.read(now: now).tokenStats
    #expect(stats.last7DaysTokens == 200)
    #expect(stats.cost7Days.pricedTokens == stats.last7DaysTokens)
    #expect(stats.todayTokens == 100)
    #expect(stats.monthTokens == 100)
    #expect(stats.costMonth.pricedTokens == stats.monthTokens)
    #expect(try reader.read(now: now.addingTimeInterval(3601)).tokenStats.todayTokens == 200)
  }

  @Test func liveDirectoryEventsDetectAppendsWithoutReconciliation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("live.jsonl")
    try Data("first\n".utf8).write(to: file)
    let index = SessionFileIndex(roots: [root], reconciliationInterval: 600, watch: true)
    #expect(index.read(at: Date()).first?.size == 6)
    // Drain the root-creation event before measuring an append in place.
    try await Task.sleep(for: .milliseconds(1500))
    _ = index.read(at: Date())
    let initialEnumerations = index.enumerationCount
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
    try handle.write(contentsOf: Data("second\n".utf8)); try handle.close()
    var detected = false
    for _ in 0..<40 {
      try await Task.sleep(for: .milliseconds(100))
      if index.read(at: Date()).first?.size == 13 { detected = true; break }
    }
    #expect(detected)
    #expect(index.enumerationCount == initialEnumerations)
  }

  private func event(at time: Date, total: Int, last: Int) -> String {
    let stamp = ISO8601DateFormatter().string(from: time)
    return "{\"timestamp\":\"\(stamp)\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":10,\"window_minutes\":300,\"resets_at\":2000000000}},\"info\":{\"total_token_usage\":{\"total_tokens\":\(total),\"input_tokens\":\(total),\"output_tokens\":0},\"last_token_usage\":{\"total_tokens\":\(last),\"input_tokens\":\(last),\"output_tokens\":0}}}}\n"
  }
}
