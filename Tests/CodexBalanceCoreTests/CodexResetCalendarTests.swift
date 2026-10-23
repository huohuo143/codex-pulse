import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Tibo historical reset calendar")
struct CodexResetCalendarTests {
  private let now = ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z")!
  private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/" + name))
  }
  private func event(_ id: String, day: String = "2026-10-07", kind: CodexResetKind = .hardReset) -> CodexResetCalendarEvent {
    .init(id: id, kind: kind, day: day, confirmation: .official, title: id, summary: "fixture")
  }

  @Test func offlineCalendarSurvivesReevaluationAndTenMinuteThrottleWithoutSourceSuccess() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let calendarURL = folder.appendingPathComponent("calendar.json")
    var archive = CodexResetCalendarArchive(url: calendarURL,
      historicalEvents: CodexResetCalendarHistory.events(asOf: now),
      historicalTotals: CodexResetCalendarHistory.monthlyTotals(asOf: now))
    archive.load()
    let date = now
    let service = CodexRadarService(fetcher: { throw CodexRadarError.server(503) },
      publicPageFetcher: { throw CodexRadarError.server(503) }, now: { date },
      historyURL: folder.appendingPathComponent("tibo.json"), calendarHistoryURL: calendarURL,
      minimumFetchInterval: 600)
    let offline = try await service.current(force: true)
    let reevaluated = try #require(await service.reevaluate())
    let throttled = try await service.current(force: true)
    for value in [offline, reevaluated, throttled] {
      #expect(value.resetCalendar?.events.count == 33)
      #expect(value.resetCalendar?.monthlyTotals.count == 3)
      #expect(value.resetCalendar?.lastSuccessAt == nil)
      #expect(value.syncState?.lastSuccessAt == nil)
    }
  }

  @Test func completeMonthTotalsAreOfflineOnlyAndNeverInventDatesOrReplaceOnlineCorrections() throws {
    let totals = CodexResetCalendarHistory.monthlyTotals(asOf: now)
    #expect(Set(totals.map(\.month)) == Set(["2026-07", "2026-08", "2026-09"]))
    #expect(totals.allSatisfy { $0.verifiedOn == "2026-10-23" && $0.sourceURL != nil })
    #expect(CodexResetCalendarHistory.monthlyTotals(asOf: CodexResetCalendarDates.date("2026-09-15")!).map(\.month) == ["2026-07", "2026-08"])
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("calendar.json")
    let events = CodexResetCalendarHistory.events(asOf: now)
    var archive = CodexResetCalendarArchive(url: url, historicalEvents: events, historicalTotals: totals)
    archive.load()
    #expect(archive.snapshot.lastSuccessAt == nil)
    #expect(archive.snapshot.monthlyTotals.count == 3)
    #expect(archive.snapshot.events.filter { $0.day >= "2026-07-01" && $0.day < "2026-10-01" }.count == 20)
    var corrected = archive.snapshot
    corrected.monthlyTotals[0].hardResets = 42
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(corrected).write(to: url)
    var restart = CodexResetCalendarArchive(url: url, historicalEvents: events, historicalTotals: totals)
    restart.load()
    #expect(restart.snapshot.monthlyTotals[0].hardResets == 42)
    #expect(restart.snapshot.events.count == events.count)
    #expect(restart.snapshot.lastSuccessAt == nil)
    let legacy = Data(#"{"month":"2026-08","hardResets":9,"resetCards":1}"#.utf8)
    #expect(try JSONDecoder().decode(CodexResetMonthlyTotal.self, from: legacy).verifiedOn == nil)
  }

  @Test func mondayGridHandlesLeapYearsAndYearBoundaries() throws {
    for month in ["2024-02-01", "2026-12-01", "2027-01-01", "2026-02-01"] {
      let first = try #require(CodexResetCalendarDates.date(month))
      let cells = CodexResetCalendarDates.cells(in: first)
      #expect(cells.count == 42)
      #expect(CodexResetCalendarDates.calendar.component(.weekday, from: cells[0]) == 2)
      #expect(Set(cells.map(CodexResetCalendarDates.day)).count == 42)
      #expect(cells.contains { CodexResetCalendarDates.day($0) == month })
    }
    #expect(CodexResetCalendarDates.date("2024-02-29") != nil)
    #expect(CodexResetCalendarDates.date("2026-02-29") == nil)
    #expect(CodexResetCalendarDates.date("2026-13-01") == nil)
    #expect(CodexResetCalendarDates.day(ISO8601DateFormatter().date(from: "2026-12-31T16:00:00Z")!) == "2027-01-01")
  }

  @Test func readsConfirmedCardsWithoutUsingPTChallengeDatesOrAnnouncementTimes() throws {
    let page = try CodexResetCalendarParser.page(fixture("codex-reset-calendar-20261018.html"), now: now)
    #expect(page.events.count == 6)
    #expect(page.events.filter { $0.kind == .hardReset }.count == 5)
    #expect(page.events.filter { $0.kind == .resetCard }.count == 1)
    let day8 = try #require(page.events.first { $0.challengeDay == 8 })
    #expect(day8.day == "2026-10-13")
    #expect(day8.publishedAt != day8.confirmedAt)
    #expect(day8.occurredAt == nil)
    #expect(day8.usesConfirmationDate)
    #expect(day8.announcementURL?.lastPathComponent == "2109812216212099456")
    #expect(day8.completionURL?.lastPathComponent == "2109873287853707513")
    let community = try #require(page.events.first { $0.challengeDay == 13 })
    #expect(community.confirmation == .community)
    #expect(community.completionURL == nil)
    let card = try #require(page.events.first { $0.kind == .resetCard })
    #expect(card.day == "2026-10-08")
    #expect(card.confirmedAt == ISO8601DateFormatter().date(from: "2026-10-08T03:44:55Z"))
    #expect(page.monthlyTotals.first { $0.month == "2026-10" }?.hardResets == 6)
  }

  @Test func structuredCompletionRetainsDatePrecisionAndEvidenceRole() throws {
    let data = try fixture("codex-reset-completion-20261018.json")
    let result = try #require(CodexResetCalendarParser.completion(data, now: now))
    #expect(result.day == "2026-10-18")
    #expect(!result.usesConfirmationDate)
    #expect(result.occurredAt == nil)
    #expect(result.confirmation == .community)
    #expect(result.completionURL == nil)
    #expect(result.announcementURL != nil)
    #expect(result.dateExplanation == "具体时分未知")
  }

  @Test func ignoresAnnouncementsUnrelatedProductsFutureDatesAndWrongAuthors() throws {
    let body = "<article><span class='t28-event-type reset'>已确认重置 · Day 2</span><h3>重置完成</h3><p>完成确认</p><time datetime='2026-10-07T03:00:00Z'></time><a href='https://x.com/thsottiaux/status/12345'>原帖</a></article>"
    for altered in [body.replacingOccurrences(of: "已确认重置", with: "预告重置"),
      body.replacingOccurrences(of: "完成确认</p>", with: "当前未见完成确认</p>"),
      body.replacingOccurrences(of: "thsottiaux", with: "someone"),
      body.replacingOccurrences(of: "2026-10-07", with: "2026-11-07")] {
      let page = try CodexResetCalendarParser.page(Data(("<section id='tibo-challenge'>" + altered + "</section>").utf8), now: now)
      #expect(page.events.isEmpty)
    }
    #expect(throws: CodexRadarError.self) { try CodexResetCalendarParser.page(Data("changed markup".utf8), now: now) }
  }

  @Test func mergesBothSourcesPreservesHistoryAcrossResetAndOfflineRestart() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("calendar.json")
    var archive = CodexResetCalendarArchive(url: url)
    archive.update(json: try fixture("codex-reset-completion-20261018.json"),
      html: try fixture("codex-reset-calendar-20261018.html"), at: now)
    #expect(archive.snapshot.events.count == 6)
    #expect(archive.snapshot.events.first { $0.challengeDay == 13 }?.usesConfirmationDate == false)
    #expect(archive.snapshot.events.first { $0.challengeDay == 13 }?.publicationURL?.lastPathComponent == "2111492673890824348")
    #expect(archive.snapshot.events.first { $0.challengeDay == 13 }?.publishedAt != nil)
    var restarted = CodexResetCalendarArchive(url: url)
    restarted.update(json: nil, html: nil, at: now.addingTimeInterval(3600))
    #expect(restarted.snapshot.events == archive.snapshot.events)
    #expect(restarted.snapshot.lastSuccessAt == now)
    #expect(restarted.snapshot.failureMessage != nil)
    restarted.update(json: nil, html: try fixture("codex-reset-calendar-20261018.html"), at: now.addingTimeInterval(7200))
    #expect(restarted.snapshot.events.count == 6)
    #expect(restarted.snapshot.events.first { $0.challengeDay == 13 }?.usesConfirmationDate == false)
  }

  @Test func sourceCorrectionMovesDateWithoutDuplicatingAndSameDayEventsStaySeparate() throws {
    let base = try fixture("codex-reset-completion-20261018.json")
    var archive = CodexResetCalendarArchive(url: nil)
    archive.update(json: base, html: nil, at: now)
    let corrected = Data(String(decoding: base, as: UTF8.self).replacingOccurrences(of: "\"occurred_on\": \"2026-10-18\"", with: "\"occurred_on\": \"2026-10-17\"").utf8)
    archive.update(json: corrected, html: nil, at: now)
    #expect(archive.snapshot.events.count == 1)
    #expect(archive.snapshot.events.first?.day == "2026-10-17")
    let other = Data(String(decoding: corrected, as: UTF8.self)
      .replacingOccurrences(of: "2111492738025959922", with: "9999999999999999999")
      .replacingOccurrences(of: "codex-speed-window-2026-10-18-codex", with: "other-action")
      .replacingOccurrences(of: "Day 13", with: "Another").utf8)
    archive.update(json: other, html: nil, at: now)
    #expect(archive.snapshot.events.count == 2)
  }

  @Test func corruptAndFutureVersionCachesArePreserved() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for data in [Data("broken".utf8), Data("{\"schemaVersion\":99,\"events\":[],\"monthlyTotals\":[]}".utf8)] {
      let url = folder.appendingPathComponent("calendar.json")
      try data.write(to: url)
      var archive = CodexResetCalendarArchive(url: url)
      archive.update(json: try fixture("codex-reset-completion-20261018.json"), html: nil, at: now)
      #expect(try Data(contentsOf: url) == data)
      #expect(archive.snapshot.failureMessage?.contains("已保留原文件") == true)
      #expect(archive.snapshot.events.count == 1)
    }
  }

  @Test func calendarParsingFailureDoesNotBreakExistingRadarAndOldHistory() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let radar = try fixture("codex-radar-current.json")
    let legacyPage = try fixture("codex-radar-tibo-20261007.html")
    #expect(try CodexResetCalendarParser.page(legacyPage, now: now).monthlyTotals.count == 7)
    let page = Data(String(decoding: legacyPage, as: UTF8.self)
      .replacingOccurrences(of: "data-month=", with: "data-legacy-month=").utf8)
    let service = CodexRadarService(fetcher: { radar }, publicPageFetcher: { page }, now: { self.now },
      historyURL: folder.appendingPathComponent("old-history.json"))
    let snapshot = try await service.current(force: true)
    #expect(snapshot.tiboFeed?.posts.isEmpty == true) // October 7 statuses are outside seven-day retention.
    #expect(snapshot.syncState?.lastSuccessAt != nil)
    #expect(snapshot.resetCalendar?.failureMessage != nil)
  }

  @Test func regressedSourceCannotOverwriteCalendarTotals() async throws {
    let base = try fixture("codex-radar-current.json")
    let first = try fixture("codex-radar-tibo-20261007.html")
    let second = Data(String(decoding: first, as: UTF8.self)
      .replacingOccurrences(of: "2026-10-07T00:12:10+08:00", with: "2026-10-06T00:12:10+08:00")
      .replacingOccurrences(of: "<strong>1</strong><small>次</small>", with: "<strong>0</strong><small>次</small>").utf8)
    let pages = CalendarPageSequence([first, second])
    let service = CodexRadarService(fetcher: { base }, publicPageFetcher: { await pages.next() }, now: { self.now })
    let fresh = try await service.current(force: true)
    let stale = try await service.current(force: true)
    #expect(fresh.resetCalendar?.monthlyTotals.first { $0.month == "2026-10" }?.hardResets == 1)
    #expect(stale.resetCalendar?.monthlyTotals == fresh.resetCalendar?.monthlyTotals)
    #expect(stale.resetCalendar?.failureMessage != nil)
  }

  @Test func reviewedHistoryContainsOnlySupportedDatesAndKeepsEvidenceLimits() throws {
    let history = CodexResetCalendarHistory.events(asOf: now)
    #expect(history.count == 33)
    #expect(history.filter { $0.day < "2026-10-01" }.count == 32)
    #expect(Set(history.map { String($0.day.prefix(7)) }) == Set(["2026-04", "2026-05", "2026-06", "2026-07", "2026-08", "2026-09", "2026-10"]))
    #expect(history.allSatisfy { $0.occurredAt == nil && $0.completionURL == nil })
    #expect(history.filter { $0.day == "2026-06-18" }.map(\.kind).count == 2)
    #expect(Set(history.filter { $0.day == "2026-06-18" }.map(\.kind)) == Set([.hardReset, .resetCard]))
    #expect(history.first { $0.day == "2026-05-17" }?.usesConfirmationDate == true)
    #expect(!history.contains { ["2026-05-16", "2026-07-10", "2026-09-22"].contains($0.day) })
    #expect(history.first { $0.day == "2026-06-18" && $0.kind == .hardReset }?.confirmation == .community)
    #expect(history.filter { $0.confirmation == .publicArchive }.count == 32)
    #expect(CodexResetCalendarHistory.events(asOf: CodexResetCalendarDates.date("2026-06-01")!).count == 6)
  }

  @Test func backfillUpgradesOldCacheOnceAndIsAvailableOnFirstOfflineLaunch() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("calendar.json")
    var old = CodexResetCalendarArchive(url: url)
    old.update(json: try fixture("codex-reset-completion-20261018.json"),
      html: try fixture("codex-reset-calendar-20261018.html"), at: now)
    let history = CodexResetCalendarHistory.events(asOf: now)
    var upgraded = CodexResetCalendarArchive(url: url, historicalEvents: history)
    upgraded.load()
    #expect(upgraded.snapshot.events.count == 39)
    #expect(upgraded.snapshot.lastSuccessAt == now)
    var restarted = CodexResetCalendarArchive(url: url, historicalEvents: history)
    restarted.update(json: nil, html: nil, at: now.addingTimeInterval(3600))
    #expect(restarted.snapshot.events == upgraded.snapshot.events)
    #expect(restarted.snapshot.lastSuccessAt == now)
    var firstOffline = CodexResetCalendarArchive(url: folder.appendingPathComponent("first.json"), historicalEvents: history)
    firstOffline.update(json: nil, html: nil, at: now)
    #expect(firstOffline.snapshot.events.count == 33)
    #expect(firstOffline.snapshot.lastSuccessAt == nil)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("first.json").path))
  }

  @Test func catalogRevisionAndLiveCorrectionDoNotResurrectOldDates() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("calendar.json")
    var seed = event("historical-event", day: "2026-06-04")
    seed.usesConfirmationDate = false; seed.historicalCatalogRevision = 1
    var first = CodexResetCalendarArchive(url: url, historicalEvents: [seed]); first.load()
    var revised = seed; revised.day = "2026-06-05"; revised.historicalCatalogRevision = 2
    var updated = CodexResetCalendarArchive(url: url, historicalEvents: [revised]); updated.load()
    #expect(updated.snapshot.events.count == 1)
    #expect(updated.snapshot.events.first?.day == "2026-06-05")
    let completion = Data(String(decoding: try fixture("codex-reset-completion-20261018.json"), as: UTF8.self)
      .replacingOccurrences(of: "codex-speed-window-2026-10-18-codex", with: "historical-event")
      .replacingOccurrences(of: "2026-10-18", with: "2026-06-06").utf8)
    updated.update(json: completion, html: nil, at: now)
    #expect(updated.snapshot.events.count == 1)
    #expect(updated.snapshot.events.first?.day == "2026-06-06")
    #expect(updated.snapshot.events.first?.historicalCatalogRevision == nil)
    var latest = revised; latest.day = "2026-06-07"; latest.historicalCatalogRevision = 3
    var restarted = CodexResetCalendarArchive(url: url, historicalEvents: [latest]); restarted.load()
    #expect(restarted.snapshot.events.first?.day == "2026-06-06")
    #expect(restarted.snapshot.events.count == 1)
  }

  @Test func oldEventSchemaDecodesWithoutBackfillMetadataAndCorruptCacheIsUntouched() throws {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(event("old"))
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(CodexResetCalendarEvent.self, from: data)
    #expect(decoded.evidenceURL == nil && decoded.historicalCatalogRevision == nil)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let corrupt = Data("original corrupt cache".utf8); try corrupt.write(to: url)
    var archive = CodexResetCalendarArchive(url: url, historicalEvents: CodexResetCalendarHistory.events(asOf: now))
    archive.load()
    #expect(archive.snapshot.events.count == 33)
    #expect(archive.snapshot.failureMessage?.contains("已保留原文件") == true)
    #expect(try Data(contentsOf: url) == corrupt)
  }

  @Test func twoActionsInOnePostStaySeparateAcrossRefreshAndLegacyIDs() throws {
    let post = "<time datetime='2026-06-18T00:10:10Z'></time><a href='https://x.com/thsottiaux/status/2067399435009622521'>原帖</a>"
    let hard = "<article><span class='t28-event-type'>已确认重置</span><h3>硬重置已完成</h3><p>已经完成</p>" + post + "</article>"
    let card = "<article><span class='t28-event-type'>产品改进</span><h3>额外重置卡</h3><p>已发放一张重置卡</p>" + post + "</article>"
    let page = Data(("<section id='tibo-challenge'>" + hard + card + "</section>").utf8)
    let parsed = try CodexResetCalendarParser.page(page, now: now)
    #expect(parsed.events.count == 2 && Set(parsed.events.map(\.id)).count == 2)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("calendar.json")
    var legacy = parsed.events[0]; legacy.id = "x:2067399435009622521"
    legacy.aliases = [legacy.id]; legacy.corroborationURLs = nil
    var stored = CodexResetCalendarSnapshot(); stored.events = [legacy]
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(stored).write(to: url)
    var archive = CodexResetCalendarArchive(url: url)
    archive.update(json: nil, html: page, at: now)
    archive.update(json: nil, html: page, at: now)
    #expect(archive.snapshot.events.count == 2)
    #expect(Set(archive.snapshot.events.map(\.id)).count == 2)
    #expect(Set(archive.snapshot.events.map(\.kind)) == Set([.hardReset, .resetCard]))
  }

  @Test func expandedCatalogRetainsUnknownTimesAndExcludesUnconfirmedAnnouncements() throws {
    let history = CodexResetCalendarHistory.events(asOf: now)
    for day in ["2026-04-01", "2026-04-08", "2026-04-10", "2026-04-21", "2026-07-10", "2026-07-15", "2026-07-16", "2026-07-22", "2026-08-13", "2026-08-30", "2026-09-04", "2026-09-05", "2026-09-10"] {
      #expect(!history.contains { $0.day == day })
    }
    let additions = history.filter { $0.id.hasPrefix("public-history:") }
    #expect(additions.count == 16)
    #expect(additions.allSatisfy { $0.usesConfirmationDate && $0.occurredAt == nil && $0.publishedAt != nil && $0.publicationURL == $0.evidenceURL && $0.corroborationURLs?.isEmpty == false })
    #expect(history.first { $0.evidenceURL?.lastPathComponent == "2086188036493344823" }?.day == "2026-08-09")
    #expect(history.first { $0.evidenceURL?.lastPathComponent == "2092316228497063958" }?.day == "2026-08-26")
    #expect(history.filter { $0.aliases.contains("x:2067399435009622521") }.count == 2)
  }

  @Test func upgradesPreviousBackfillWithoutDuplicates() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("calendar.json")
    let history = CodexResetCalendarHistory.events(asOf: now)
    let old = history.filter { !$0.id.hasPrefix("public-history:") }.map { value in
      var value = value; value.historicalCatalogRevision = 1; value.evidenceURL = nil; value.corroborationURLs = nil
      return value
    }
    #expect(old.count == 17)
    var before = CodexResetCalendarArchive(url: url, historicalEvents: old); before.load()
    var after = CodexResetCalendarArchive(url: url, historicalEvents: history); after.load()
    #expect(after.snapshot.events.count == 33)
    #expect(after.snapshot.events.allSatisfy { $0.historicalCatalogRevision == 3 })
    var again = CodexResetCalendarArchive(url: url, historicalEvents: history); again.load()
    #expect(again.snapshot.events == after.snapshot.events)
    #expect(again.snapshot.lastSuccessAt == nil)
  }
}

private actor CalendarPageSequence {
  var pages: [Data]
  init(_ pages: [Data]) { self.pages = pages }
  func next() -> Data { pages.removeFirst() }
}
