import Foundation

/// Reviewed date-level history from the public RSS and the site's historical
/// methodology note. Monthly totals are never expanded into invented dates.
enum CodexResetCalendarHistory {
  private struct Catalog: Decodable {
    var revision: Int
    var events: [CodexResetCalendarEvent]
    var monthlyTotals: [CodexResetMonthlyTotal]?
  }

  private static func catalog() -> Catalog? {
    #if SWIFT_PACKAGE
    let bundledURL = Bundle.main.url(forResource: "codex-reset-history", withExtension: "json")
      ?? Bundle.module.url(forResource: "codex-reset-history", withExtension: "json")
    #else
    let bundledURL = Bundle.main.url(forResource: "codex-reset-history", withExtension: "json")
    #endif
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    guard let url = bundledURL,
      let data = try? Data(contentsOf: url),
      let catalog = try? decoder.decode(Catalog.self, from: data), catalog.revision > 0,
      catalog.events.allSatisfy({ CodexResetCalendarDates.date($0.day) != nil })
    else { return nil }
    return catalog
  }

  static func monthlyTotals(asOf now: Date) -> [CodexResetMonthlyTotal] {
    let month = String(CodexResetCalendarDates.day(now).prefix(7))
    return (catalog()?.monthlyTotals ?? []).filter {
      CodexResetCalendarDates.date($0.month + "-01") != nil && $0.month < month
        && $0.hardResets >= 0 && $0.resetCards >= 0
    }
  }

  static func events(asOf now: Date) -> [CodexResetCalendarEvent] {
    guard let catalog = catalog() else { return [] }
    let today = CodexResetCalendarDates.day(now)
    return catalog.events.filter { $0.day <= today }.map {
      var event = $0
      event.aliases = Array(Set(event.aliases + [event.id])).sorted()
      event.historicalCatalogRevision = catalog.revision
      return event
    }
  }
}
