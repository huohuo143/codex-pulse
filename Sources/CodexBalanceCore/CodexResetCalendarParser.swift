import Foundation

enum CodexResetCalendarParser {
  struct Page {
    var events: [CodexResetCalendarEvent]
    var monthlyTotals: [CodexResetMonthlyTotal]
  }

  static func completion(_ data: Data, now: Date) -> CodexResetCalendarEvent? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let event = root["completion_observation"] as? [String: Any],
      event["status"] as? String == "completed",
      let id = event["event_id"] as? String,
      let rawKind = event["kind"] as? String,
      ["direct_reset", "banked_reset", "reset_card"].contains(rawKind),
      let level = event["confirmation_level"] as? String,
      ["official_confirmed", "official", "stationmaster_confirmed"].contains(level),
      let day = event["occurred_on"] as? String,
      CodexResetCalendarDates.date(day) != nil, day <= CodexResetCalendarDates.day(now),
      event["timezone"] as? String == "Asia/Shanghai"
    else { return nil }
    let title = event["title_zh"] as? String ?? "已完成重置"
    let announcement = verifiedURL(event["announcement_url"] as? String)
    let official = verifiedURL(event["official_completion_url"] as? String)
    let occurred = (event["occurred_at"] as? String).flatMap(date)
    // An exact timestamp must agree with the source's date, precision, and now.
    let exact = ["second", "minute", "exact"].contains(event["time_precision"] as? String ?? "")
      ? occurred.flatMap { $0 <= now && CodexResetCalendarDates.day($0) == day ? $0 : nil } : nil
    return .init(id: id,
      aliases: [event["announcement_event_id"] as? String, postID(announcement), postID(official)].compactMap { $0 },
      kind: rawKind == "direct_reset" ? .hardReset : .resetCard, day: day,
      usesConfirmationDate: false, occurredAt: exact,
      confirmedAt: (event["official_confirmation_published_at"] as? String).flatMap(date),
      confirmation: level == "stationmaster_confirmed" ? .community : .official,
      title: title, summary: event["evidence_zh"] as? String ?? event["source"] as? String ?? "",
      announcementURL: announcement, completionURL: official, challengeDay: challengeDay(title))
  }

  static func page(_ data: Data, now: Date) throws -> Page {
    guard data.count <= 4 * 1024 * 1024, let html = String(data: data, encoding: .utf8) else {
      throw CodexRadarError.invalidPayload
    }
    let challenge = section("tibo-challenge", in: html)
    let rows = matches(#"<div\b[^>]*\bdata-month\s*=\s*["'][^"']+["'][^>]*>.*?</div>"#, html)
    guard challenge != nil || !rows.isEmpty else { throw CodexRadarError.invalidPayload }
    let events = matches(#"<article\b[^>]*>.*?</article>"#, challenge ?? "").compactMap { article($0, now: now) }
    let totals = rows.compactMap { row -> CodexResetMonthlyTotal? in
      guard let month = attribute("data-month", row), CodexResetCalendarDates.date(month + "-01") != nil,
        let direct = capture(#"class\s*=\s*["'][^"']*monthly-count-direct[^"']*["'][^>]*>\s*<strong\b[^>]*>(\d+)"#, row).flatMap(Int.init),
        let cards = capture(#"class\s*=\s*["'][^"']*monthly-count-card[^"']*["'][^>]*>\s*<strong\b[^>]*>(\d+)"#, row).flatMap(Int.init)
      else { return nil }
      return .init(month: month, hardResets: direct, resetCards: cards)
    }
    // Deduplicate month rows before constructing a keyed collection.
    var seen = Set<String>()
    return Page(events: events, monthlyTotals: totals.filter { seen.insert($0.month).inserted })
  }

  private static func article(_ html: String, now: Date) -> CodexResetCalendarEvent? {
    let type = text(capture(#"<span\b[^>]*class\s*=\s*["'][^"']*t28-event-type[^"']*["'][^>]*>(.*?)</span>"#, html) ?? "")
    let title = text(capture(#"<h3\b[^>]*>(.*?)</h3>"#, html) ?? "")
    let summary = matches(#"<p\b[^>]*>.*?</p>"#, html).map(text).joined(separator: " ")
    let hard = type.contains("已确认重置")
    let card = title.contains("重置卡") && ["确认已到", "已到所有账号", "已发放", "发放完成"].contains(where: summary.contains)
    guard hard || card, !summary.contains("尚未确认完成"), !summary.contains("当前未见完成确认"),
      !summary.contains("未核实完成"), !title.isEmpty else { return nil }
    let links = matches(#"<a\b[^>]*>.*?</a>"#, html).compactMap { element -> (URL, String)? in
      guard let url = verifiedURL(attribute("href", element)) else { return nil }
      return (url, text(element))
    }
    guard let first = links.first else { return nil }
    let times = matches(#"<time\b[^>]*>.*?</time>"#, html).compactMap { attribute("datetime", $0).flatMap(date) }
    guard let published = times.first, published <= now else { return nil }
    let community = (type + title + summary).contains("社区反馈") || title.contains("站长确认")
    let completionLink = links.first(where: { $0.1.contains("完成确认") })?.0
    let explicitConfirmation = confirmationDate(in: summary, year: CodexResetCalendarDates.calendar.component(.year, from: published))
    let confirmed = explicitConfirmation ?? (times.count > 1 ? times.last : (community ? nil : published))
    let day = CodexResetCalendarDates.day(confirmed ?? published)
    guard day <= CodexResetCalendarDates.day(now), confirmed.map({ $0 <= now }) ?? true else { return nil }
    return .init(id: postID(first.0)! + (hard ? ":hardReset" : ":resetCard"), aliases: links.compactMap { postID($0.0) },
      kind: hard ? .hardReset : .resetCard, day: day, publishedAt: published, confirmedAt: confirmed,
      confirmation: community ? .community : .official, title: title, summary: summary,
      announcementURL: completionLink != nil || community || card ? first.0 : nil,
      completionURL: completionLink ?? (community || card ? nil : first.0),
      sourceURL: URL(string: "https://codexradar.com/#tibo-challenge")!, challengeDay: challengeDay(type))
  }

  private static func confirmationDate(in text: String, year: Int) -> Date? {
    guard let month = capture(#"北京时间\s*(\d{1,2})月"#, text),
      let day = capture(#"北京时间\s*\d{1,2}月(\d{1,2})日"#, text),
      let clock = capture(#"北京时间\s*\d{1,2}月\d{1,2}日\s*(\d{2}:\d{2}:\d{2})"#, text)
    else { return nil }
    return date(String(format: "%04d-%02d-%02dT", year, Int(month)!, Int(day)!) + clock + "+08:00")
  }

  private static func challengeDay(_ text: String) -> Int? { capture(#"\bDay\s*(\d+)\b"#, text).flatMap(Int.init) }
  private static func section(_ id: String, in html: String) -> String? {
    capture("<section\\b[^>]*\\bid\\s*=\\s*[\"']" + id + "[\"'][^>]*>(.*?)</section>", html)
  }
  private static func verifiedURL(_ raw: String?) -> URL? {
    guard let raw, let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
      ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(url.host?.lowercased() ?? ""),
      url.pathComponents.count == 4, url.pathComponents[1].lowercased() == "thsottiaux",
      url.pathComponents[2] == "status", url.pathComponents[3].allSatisfy(\.isNumber)
    else { return nil }
    return URL(string: "https://x.com/thsottiaux/status/" + url.pathComponents[3])
  }
  private static func postID(_ url: URL?) -> String? { url.map { "x:" + $0.lastPathComponent } }
  private static func date(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
  private static func attribute(_ name: String, _ html: String) -> String? {
    capture("\\b" + name + #"\s*=\s*["']([^"']*)["']"#, html)
  }
  private static func capture(_ pattern: String, _ html: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
      let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
      let range = Range(match.range(at: 1), in: html) else { return nil }
    return String(html[range])
  }
  private static func matches(_ pattern: String, _ html: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
    return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
      Range($0.range, in: html).map { String(html[$0]) }
    }
  }
  private static func text(_ html: String) -> String {
    var result = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    for (entity, value) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&nbsp;", " ")] {
      result = result.replacingOccurrences(of: entity, with: value)
    }
    return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
