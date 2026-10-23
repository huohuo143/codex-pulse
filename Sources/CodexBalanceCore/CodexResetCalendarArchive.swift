import Foundation

/// Owned by CodexRadarService's actor; independent from the scoring archive.
struct CodexResetCalendarArchive: Sendable {
  private(set) var snapshot = CodexResetCalendarSnapshot()
  private let url: URL?
  private let historicalEvents: [CodexResetCalendarEvent]
  private let historicalTotals: [CodexResetMonthlyTotal]
  private var loaded = false
  private var loadFailure: String?

  init(url: URL?, historicalEvents: [CodexResetCalendarEvent] = [], historicalTotals: [CodexResetMonthlyTotal] = []) {
    self.url = url; self.historicalEvents = historicalEvents
    self.historicalTotals = historicalTotals
  }

  mutating func load() {
    guard !loaded else { return }
    loaded = true
    if let url, FileManager.default.fileExists(atPath: url.path) {
      do {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 8 * 1024 * 1024 else { throw CodexRadarError.invalidPayload }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode(CodexResetCalendarSnapshot.self, from: data)
        guard stored.schemaVersion == 1,
          stored.events.allSatisfy({ CodexResetCalendarDates.date($0.day) != nil })
        else { throw CodexRadarError.invalidPayload }
        snapshot = stored
      } catch {
        loadFailure = "历史缓存无法读取，已保留原文件：\(error.localizedDescription)"
        snapshot.failureMessage = loadFailure
      }
    }
    let previous = snapshot.events
    let previousTotals = snapshot.monthlyTotals
    for total in historicalTotals where !snapshot.monthlyTotals.contains(where: { $0.month == total.month }) {
      snapshot.monthlyTotals.append(total)
    }
    snapshot.monthlyTotals.sort { $0.month > $1.month }
    for event in historicalEvents {
      let existing = snapshot.events.filter { eventsMatch($0, event) }
      // Online corrections and old user caches take precedence over bundled
      // history. Only an older bundled entry may be replaced by a newer revision.
      guard existing.isEmpty || existing.allSatisfy({
        $0.historicalCatalogRevision.map { $0 < (event.historicalCatalogRevision ?? 0) } ?? false
      }) else { continue }
      merge(event)
    }
    if snapshot.events != previous || snapshot.monthlyTotals != previousTotals { persist() }
  }

  mutating func update(json: Data?, html: Data?, at now: Date) {
    load()
    snapshot.lastAttemptAt = now
    var succeeded = false
    var pageSucceeded = false
    var events: [CodexResetCalendarEvent] = []
    if let html, let parsed = try? CodexResetCalendarParser.page(html, now: now) {
      events += parsed.events
      let months = Dictionary(uniqueKeysWithValues: parsed.monthlyTotals.map { ($0.month, $0) })
      snapshot.monthlyTotals = (snapshot.monthlyTotals.filter { months[$0.month] == nil } + parsed.monthlyTotals)
        .sorted { $0.month > $1.month }
      succeeded = true
      pageSucceeded = true
    }
    // The structured completion observation is authoritative for the current
    // event's occurrence date and evidence role, after the HTML history.
    if let json, let event = CodexResetCalendarParser.completion(json, now: now) {
      events.append(event); succeeded = true
    }
    for event in events { merge(event) }
    if succeeded { snapshot.lastSuccessAt = now }
    snapshot.failureMessage = loadFailure ?? (pageSucceeded ? nil : (succeeded
      ? "历史网页未同步，已更新最新完成记录；其余显示本机历史。"
      : "日历更新失败，保留已收录历史；公开源暂不可用或格式已变化。"))
    if succeeded { persist() }
  }

  private func eventsMatch(_ old: CodexResetCalendarEvent, _ event: CodexResetCalendarEvent) -> Bool {
    let sharesSource = !Set(old.aliases + [old.id]).isDisjoint(with: event.aliases + [event.id])
    let sharesChallenge = old.challengeDay != nil && old.challengeDay == event.challengeDay
      && old.kind == event.kind && old.day.prefix(7) == event.day.prefix(7)
    // One post can confirm both an immediate reset and a banked credit. Shared
    // post aliases only identify the same action within the same kind; a stable
    // event ID still permits an explicit classification correction.
    let stableEventID = old.id == event.id && !old.id.hasPrefix("x:")
    return stableEventID || (old.kind == event.kind && (sharesSource || sharesChallenge))
  }

  private mutating func merge(_ event: CodexResetCalendarEvent) {
    let matches = snapshot.events.indices.filter { eventsMatch(snapshot.events[$0], event) }
    var replacement = event
    replacement.aliases = Array(Set(event.aliases + matches.flatMap { snapshot.events[$0].aliases })).sorted()
    // A less precise HTML card must not erase an already recorded occurrence
    // date, exact time, or official completion link on a later refresh.
    for index in matches {
      let old = snapshot.events[index]
      if event.usesConfirmationDate && !old.usesConfirmationDate && old.historicalCatalogRevision == nil {
        replacement.day = old.day; replacement.usesConfirmationDate = false; replacement.occurredAt = old.occurredAt
      }
      replacement.completionURL = replacement.completionURL ?? old.completionURL
      replacement.confirmedAt = replacement.confirmedAt ?? old.confirmedAt
      replacement.evidenceURL = replacement.evidenceURL ?? old.evidenceURL
      replacement.corroborationURLs = replacement.corroborationURLs ?? old.corroborationURLs
      if replacement.publishedAt == nil {
        replacement.publishedAt = old.publishedAt
        replacement.publicationURL = old.publicationURL
      }
    }
    for index in matches.reversed() { snapshot.events.remove(at: index) }
    snapshot.events.append(replacement)
    snapshot.events.sort { $0.day == $1.day ? $0.id < $1.id : $0.day > $1.day }
  }

  private mutating func persist() {
    guard loadFailure == nil, let url else { return }
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(snapshot).write(to: url, options: .atomic)
    } catch { snapshot.failureMessage = "历史缓存保存失败：\(error.localizedDescription)" }
  }
}
