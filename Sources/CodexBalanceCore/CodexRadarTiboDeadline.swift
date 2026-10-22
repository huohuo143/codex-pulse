import Foundation

/// A quoted, explicit reset deadline. The model extracts local components;
/// Foundation, not the model, converts them to an absolute instant.
public struct CodexRadarTiboDeadline: Codable, Equatable, Sendable {
  public var localDateTime: String
  public var sourceTimeZone: String
  public var evidenceID: String
  public var sourceQuote: String

  public var timeZone: TimeZone? {
    switch sourceTimeZone.uppercased() {
    case "PST": return TimeZone(secondsFromGMT: -8 * 3600)
    case "PDT": return TimeZone(secondsFromGMT: -7 * 3600)
    case "PT", "PACIFIC TIME": return TimeZone(identifier: "America/Los_Angeles")
    case "UTC", "GMT": return TimeZone(secondsFromGMT: 0)
    case "BJT", "北京时间": return TimeZone(secondsFromGMT: 8 * 3600)
    default:
      if sourceTimeZone.contains("/") { return TimeZone(identifier: sourceTimeZone) }
      let raw = sourceTimeZone.uppercased().replacingOccurrences(of: "UTC", with: "").replacingOccurrences(of: "GMT", with: "")
      guard raw.range(of: #"^[+-][0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil,
            let hours = Int(raw.dropFirst().prefix(2)), let minutes = Int(raw.suffix(2)),
            hours <= 14, minutes < 60, hours < 14 || minutes == 0 else { return nil }
      return TimeZone(secondsFromGMT: (raw.first == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }
  }

  public var timeZoneClarification: String? {
    guard sourceTimeZone.uppercased() == "PST", let date,
          TimeZone(identifier: "America/Los_Angeles")?.secondsFromGMT(for: date) == -7 * 3600 else { return nil }
    return "按原文 PST（UTC−8）换算；若作者泛指当时 PT/PDT，则为北京时间 \(BalanceFormatters.beijingDeadline(date.addingTimeInterval(-3600), compact: true))。"
  }

  public var date: Date? {
    guard let zone = timeZone,
          localDateTime.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
    let values = localDateTime.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
    guard values.count == 6, (2000...2200).contains(values[0]) else { return nil }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
    let parts = DateComponents(year: values[0], month: values[1], day: values[2], hour: values[3], minute: values[4], second: values[5])
    guard let provisional = calendar.date(from: parts) else { return nil }
    let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: provisional)
    guard actual.year == parts.year, actual.month == parts.month, actual.day == parts.day,
          actual.hour == parts.hour, actual.minute == parts.minute, actual.second == parts.second else { return nil }
    // A repeated local hour is ambiguous unless the post states a fixed offset
    // such as PST or PDT. A skipped spring-forward hour is invalid as well.
    let start = calendar.startOfDay(for: provisional).addingTimeInterval(-1)
    guard let first = calendar.nextDate(after: start, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .first),
          let last = calendar.nextDate(after: start, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .last),
          first == last else { return nil }
    return first
  }

  func isGrounded(in post: CodexRadarTiboPost) -> Bool {
    guard evidenceID == post.id, !sourceQuote.isEmpty, sourceQuote.count <= 1500,
          post.originalText.contains(sourceQuote), !sourceTimeZone.isEmpty,
          sourceQuote.range(of: "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: sourceTimeZone) + "(?![A-Za-z])", options: [.regularExpression, .caseInsensitive]) != nil,
          let date, let published = post.publishedAt, date >= published, let timeZone else { return false }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
    for (word, offset) in [("tomorrow", 1), ("today", 0)] {
      if sourceQuote.range(of: "\\b\(word)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
        guard let expected = calendar.date(byAdding: .day, value: offset, to: published),
              calendar.isDate(date, inSameDayAs: expected) else { return false }
      }
    }
    return true
  }
}

public extension CodexRadarSnapshot {
  func tiboDeadline(at now: Date) -> CodexRadarTiboDeadline? {
    guard tiboHasAnnouncement(at: now),
          let deadline = tiboAnalysis?.deadline, deadline.date != nil else { return nil }
    return deadline
  }
}
