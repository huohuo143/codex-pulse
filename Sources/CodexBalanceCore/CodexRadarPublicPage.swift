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

struct CodexRadarPublicPageSnapshot: Equatable, Sendable {
  var judgement: CodexRadarPublicJudgement
  var eventKind: String?
  var eventStatus: String?
  var confirmation: String?
  var resetAt: Date?
  var tiboFeed: CodexRadarTiboFeed
  var feedFingerprint: String? = nil
}

enum CodexRadarPublicPageParser {
  static func decode(_ data: Data, now: Date) throws -> CodexRadarPublicPageSnapshot {
    guard let html = String(data: data, encoding: .utf8) else {
      throw CodexRadarError.invalidPayload
    }

    if let sectionStart = html.range(of: #"<section class="reset-judgement""#) {
      return try decodeJudgementSection(in: html, from: sectionStart, now: now)
    }

    if let sectionStart = html.range(of: #"<section class="desktop-tibo-radar""#) {
      return try decodeTiboOnlySection(in: html, from: sectionStart)
    }

    throw CodexRadarError.invalidPayload
  }

  private static func decodeJudgementSection(
    in html: String,
    from sectionStart: Range<String.Index>,
    now: Date
  ) throws -> CodexRadarPublicPageSnapshot {

    let tail = html[sectionStart.lowerBound...]
    guard let sectionEnd = tail.range(of: "</section>") else {
      throw CodexRadarError.invalidPayload
    }
    let section = String(tail[..<sectionEnd.upperBound])
    let openingTag = capture(#"(<section\b[^>]*reset-judgement[^>]*>)"#, in: section) ?? ""

    let updatedAt = attribute("data-reset-radar-updated-at", in: openingTag)
      .flatMap(parseISO8601Date)
      ?? capture(#"\u91cd\u7f6e\u96f7\u8fbe\s*<em>([^<]+)</em>"#, in: section)
        .flatMap { parseUpdateDate($0, now: now) }
    guard let updatedAt
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

    let postPattern = #"<li\b[^>]*reset-tibo-post[^>]*>.*?</li>"#
    let advertisedIDs = postIDs(in: openingTag)
    let postElements = matches(postPattern, in: section)
    let posts = postElements.compactMap(parsePost)
    guard posts.count == postElements.count,
          advertisedIDs.isEmpty || Set(posts.map(\.id)) == advertisedIDs
    else {
      throw CodexRadarError.invalidPayload
    }
    let postsUpdatedAt = attribute("data-tibo-posts-updated-at", in: openingTag)
      .flatMap(parseISO8601Date)
      ?? posts.compactMap(\.publishedAt).max()

    return CodexRadarPublicPageSnapshot(
      judgement: CodexRadarPublicJudgement(
        updatedAt: updatedAt,
        kind: kind,
        level: levelCode(from: headline),
        headline: headline,
        summary: summary
      ),
      eventKind: attribute("data-reset-radar-event-kind", in: openingTag),
      eventStatus: attribute("data-reset-radar-event-status", in: openingTag),
      confirmation: attribute("data-reset-radar-confirmation", in: openingTag),
      resetAt: nil,
      tiboFeed: CodexRadarTiboFeed(updatedAt: postsUpdatedAt, posts: posts),
      feedFingerprint: attribute("data-tibo-posts-fingerprint", in: openingTag)
    )
  }

  private static func decodeTiboOnlySection(
    in html: String,
    from sectionStart: Range<String.Index>
  ) throws -> CodexRadarPublicPageSnapshot {
    let tail = html[sectionStart.lowerBound...]
    guard let sectionEnd = tail.range(of: "</section>") else {
      throw CodexRadarError.invalidPayload
    }
    let section = String(tail[..<sectionEnd.upperBound])
    let openingTag = capture(#"(<section\b[^>]*desktop-tibo-radar[^>]*>)"#, in: section) ?? ""
    let postPattern = #"<li\b[^>]*reset-tibo-post[^>]*>.*?</li>"#
    let advertisedIDs = postIDs(in: openingTag)
    let postElements = matches(postPattern, in: section)
    let posts = postElements.compactMap(parsePost)
    guard posts.count == postElements.count,
          advertisedIDs.isEmpty || Set(posts.map(\.id)) == advertisedIDs
    else {
      throw CodexRadarError.invalidPayload
    }
    let postsUpdatedAt = attribute("data-tibo-posts-updated-at", in: openingTag)
      .flatMap(parseISO8601Date)
      ?? posts.compactMap(\.publishedAt).max()
    guard let postsUpdatedAt, posts.isEmpty == false else {
      throw CodexRadarError.invalidPayload
    }

    return CodexRadarPublicPageSnapshot(
      judgement: CodexRadarPublicJudgement(
        updatedAt: postsUpdatedAt,
        kind: "Tibo 动态",
        level: nil,
        headline: "根据 Tibo 公开动态本地估算",
        summary: "已读取 Tibo 最新公开 Posts / Replies；重置概率由 App 本地规则计算。"
      ),
      eventKind: nil,
      eventStatus: nil,
      confirmation: nil,
      resetAt: nil,
      tiboFeed: CodexRadarTiboFeed(updatedAt: postsUpdatedAt, posts: posts),
      feedFingerprint: attribute("data-tibo-posts-fingerprint", in: openingTag)
    )
  }

  private static func parsePost(_ html: String) -> CodexRadarTiboPost? {
    guard let id = attribute("data-tibo-post-id", in: html), id.isEmpty == false else {
      return nil
    }
    let relevance = attribute("data-reset-relevance", in: html) ?? "unknown"
    let relevanceLabel = classText("reset-tibo-post-relevance", in: html)
      ?? relevanceLabel(for: relevance)
    let original = classText("reset-tibo-post-original", in: html)
      .map { stripPrefix("英文原文", from: $0) } ?? ""
    guard original.isEmpty == false else { return nil }

    guard let urlText = attribute("href", in: html),
          let url = URL(string: urlText),
          isVerifiedTiboURL(url, postID: id)
    else { return nil }

    return CodexRadarTiboPost(
      id: id,
      url: url,
      publishedAt: capture(#"<time\b[^>]*datetime="([^"]+)""#, in: html)
        .flatMap(parseISO8601Date),
      relevance: relevance,
      relevanceLabel: relevanceLabel,
      originalText: original,
      translationZh: classText("reset-tibo-post-translation", in: html)
        .map { stripPrefix("中文翻译", from: $0) },
      analysisZh: classText("reset-tibo-post-analysis", in: html)
        .map { stripPrefix("模型语境解读 · 非官方", from: $0) }
    )
  }

  private static func postIDs(in openingTag: String) -> Set<String> {
    Set(
      (attribute("data-tibo-post-ids", in: openingTag) ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
    )
  }

  private static func isVerifiedTiboURL(_ url: URL, postID: String) -> Bool {
    guard url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased(),
          host == "x.com" || host == "www.x.com"
    else { return false }
    let components = url.pathComponents.filter { $0 != "/" }
    return components.count == 3
      && components[0].lowercased() == "thsottiaux"
      && components[1].lowercased() == "status"
      && components[2] == postID
  }

  private static func classText(_ className: String, in html: String) -> String? {
    capture(
      #"<([a-z0-9]+)\b[^>]*class="[^"]*\#(NSRegularExpression.escapedPattern(for: className))[^"]*"[^>]*>(.*?)</\1>"#,
      in: html,
      group: 2
    ).map(cleanText)
  }

  private static func stripPrefix(_ prefix: String, from value: String) -> String {
    guard value.hasPrefix(prefix) else { return value }
    return String(value.dropFirst(prefix.count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func relevanceLabel(for relevance: String) -> String {
    switch relevance.lowercased() {
    case "official", "direct", "high": "直接相关"
    case "medium": "相关"
    case "indirect": "间接相关"
    case "none": "无重置信号"
    default: "待研判"
    }
  }

  private static func attribute(_ name: String, in html: String) -> String? {
    capture(
      #"\#(NSRegularExpression.escapedPattern(for: name))="([^"]*)""#,
      in: html
    )
  }

  private static func parseISO8601Date(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
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

  private static func capture(
    _ pattern: String,
    in text: String,
    group: Int = 1
  ) -> String? {
    guard let match = regex(pattern).firstMatch(
      in: text,
      range: NSRange(text.startIndex..., in: text)
    ), match.numberOfRanges > group,
    let range = Range(match.range(at: group), in: text)
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
      .replacingOccurrences(of: "&#x27;", with: "'")
      .replacingOccurrences(of: "&#X27;", with: "'")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "速蹬窗口", with: "重置窗口")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
