import Foundation

public struct CodexRadarPublicJudgement: Equatable, Decodable, Sendable {
  public var updatedAt: Date
  public var kind: String
  public var level: String?
  public var headline: String
  public var summary: String

  public init(
    updatedAt: Date,
    kind: String,
    level: String?,
    headline: String,
    summary: String
  ) {
    self.updatedAt = updatedAt
    self.kind = kind
    self.level = level
    self.headline = headline
    self.summary = summary
  }

  public var levelLabel: String {
    switch level {
    case "very_high": "极高概率"
    case "high": "高概率"
    case "medium_high": "中高概率"
    case "medium": "中等概率"
    case "medium_low": "中低概率"
    case "low": "低概率"
    case "very_low": "极低概率"
    default: "最新研判"
    }
  }
}

enum CodexRadarPublicPageParser {
  static func decode(_ data: Data, now: Date) throws -> CodexRadarPublicJudgement {
    guard let html = String(data: data, encoding: .utf8),
          let sectionStart = html.range(of: #"<section class="reset-judgement""#)
    else {
      throw CodexRadarError.invalidPayload
    }

    let tail = html[sectionStart.lowerBound...]
    guard let sectionEnd = tail.range(of: "</section>") else {
      throw CodexRadarError.invalidPayload
    }
    let section = String(tail[..<sectionEnd.upperBound])

    guard let updateText = capture(#"\u91cd\u7f6e\u96f7\u8fbe\s*<em>([^<]+)</em>"#, in: section),
          let updatedAt = parseUpdateDate(updateText, now: now)
    else {
      throw CodexRadarError.invalidPayload
    }

    let articlePattern = #"<article\b[^>]*reset-judgement-card[^>]*>.*?</article>"#
    let articles = matches(articlePattern, in: section)
    guard let hardResetArticle = articles.first(where: { article in
      cleanText(capture(#"<span[^>]*>(.*?)</span>"#, in: article) ?? "") == "硬重置"
    }) else {
      throw CodexRadarError.invalidPayload
    }

    let kind = cleanText(capture(#"<span[^>]*>(.*?)</span>"#, in: hardResetArticle) ?? "硬重置")
    let headline = cleanText(capture(#"<strong[^>]*>(.*?)</strong>"#, in: hardResetArticle) ?? "")
    let summary = cleanText(capture(#"<p[^>]*>(.*?)</p>"#, in: hardResetArticle) ?? "")
    guard headline.isEmpty == false, summary.isEmpty == false else {
      throw CodexRadarError.invalidPayload
    }

    return CodexRadarPublicJudgement(
      updatedAt: updatedAt,
      kind: kind,
      level: levelCode(from: headline),
      headline: headline,
      summary: summary
    )
  }

  private static func levelCode(from headline: String) -> String? {
    let label = headline.components(separatedBy: "·").first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return switch label {
    case "极高": "very_high"
    case "高": "high"
    case "中高": "medium_high"
    case "中": "medium"
    case "中低": "medium_low"
    case "低": "low"
    case "极低": "very_low"
    default: nil
    }
  }

  private static func parseUpdateDate(_ text: String, now: Date) -> Date? {
    guard let match = regex(#"(\d{1,2})\u6708(\d{1,2})\u65e5\s*(\d{1,2}):(\d{2})"#)
      .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      match.numberOfRanges == 5,
      let month = integerCapture(1, match: match, text: text),
      let day = integerCapture(2, match: match, text: text),
      let hour = integerCapture(3, match: match, text: text),
      let minute = integerCapture(4, match: match, text: text)
    else { return nil }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    var year = calendar.component(.year, from: now)
    var components = DateComponents(
      calendar: calendar,
      timeZone: calendar.timeZone,
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute
    )
    guard var date = calendar.date(from: components) else { return nil }
    if date > now.addingTimeInterval(48 * 60 * 60) {
      year -= 1
      components.year = year
      date = calendar.date(from: components) ?? date
    }
    return date
  }

  private static func integerCapture(
    _ index: Int,
    match: NSTextCheckingResult,
    text: String
  ) -> Int? {
    guard let range = Range(match.range(at: index), in: text) else { return nil }
    return Int(text[range])
  }

  private static func capture(_ pattern: String, in text: String) -> String? {
    guard let match = regex(pattern).firstMatch(
      in: text,
      range: NSRange(text.startIndex..., in: text)
    ), match.numberOfRanges > 1,
    let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }

  private static func matches(_ pattern: String, in text: String) -> [String] {
    regex(pattern).matches(
      in: text,
      range: NSRange(text.startIndex..., in: text)
    ).compactMap { match in
      Range(match.range, in: text).map { String(text[$0]) }
    }
  }

  private static func regex(_ pattern: String) -> NSRegularExpression {
    // Patterns are fixed app constants; a construction failure is a programming error.
    try! NSRegularExpression(
      pattern: pattern,
      options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
  }

  private static func cleanText(_ html: String) -> String {
    let withoutTags = regex(#"<[^>]+>"#)
      .stringByReplacingMatches(
        in: html,
        range: NSRange(html.startIndex..., in: html),
        withTemplate: ""
      )
    return withoutTags
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
