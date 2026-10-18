import Foundation

public enum CodexResetKind: String, Codable, CaseIterable, Sendable {
  case hardReset, resetCard
  public var title: String { self == .hardReset ? "硬重置" : "重置卡" }
  public var symbol: String { self == .hardReset ? "arrow.counterclockwise.circle.fill" : "ticket.fill" }
}

public enum CodexResetConfirmation: String, Codable, Sendable {
  case official, community, publicArchive
  public var title: String {
    switch self {
    case .official: "官方确认"
    case .community: "站长根据社区反馈确认"
    case .publicArchive: "公开来源历史记录"
    }
  }
}

public struct CodexResetCalendarEvent: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var aliases: [String]
  public var kind: CodexResetKind
  /// A civil date in Asia/Shanghai, never a fabricated midnight timestamp.
  public var day: String
  public var usesConfirmationDate: Bool
  public var occurredAt: Date?
  public var publishedAt: Date?
  public var publicationURL: URL?
  public var confirmedAt: Date?
  public var confirmation: CodexResetConfirmation
  public var title: String
  public var summary: String
  public var announcementURL: URL?
  public var completionURL: URL?
  public var sourceURL: URL
  public var challengeDay: Int?
  /// A reviewed public archive can have evidence without a verified official completion post.
  public var evidenceURL: URL?
  public var corroborationURLs: [URL]?
  public var historicalCatalogRevision: Int?

  public init(id: String, aliases: [String] = [], kind: CodexResetKind, day: String,
    usesConfirmationDate: Bool = true, occurredAt: Date? = nil, publishedAt: Date? = nil,
    confirmedAt: Date? = nil, confirmation: CodexResetConfirmation, title: String, summary: String,
    announcementURL: URL? = nil, completionURL: URL? = nil,
    sourceURL: URL = URL(string: "https://codexradar.com/#reset-radar")!, challengeDay: Int? = nil) {
    self.id = id; self.aliases = Array(Set(aliases + [id])).sorted(); self.kind = kind; self.day = day
    self.usesConfirmationDate = usesConfirmationDate; self.occurredAt = occurredAt
    self.publishedAt = publishedAt; self.confirmedAt = confirmedAt; self.confirmation = confirmation
    self.title = title; self.summary = summary; self.announcementURL = announcementURL
    self.completionURL = completionURL; self.sourceURL = sourceURL; self.challengeDay = challengeDay
    self.publicationURL = publishedAt == nil ? nil : (announcementURL ?? completionURL)
  }

  public var dateExplanation: String {
    usesConfirmationDate ? "按确认日期记录，实际发生时间未公布" : (occurredAt == nil ? "具体时分未知" : "实际发生时间")
  }
}

public struct CodexResetMonthlyTotal: Codable, Equatable, Identifiable, Sendable {
  public var month: String
  public var hardResets: Int
  public var resetCards: Int
  public var id: String { month }
  public init(month: String, hardResets: Int, resetCards: Int) {
    self.month = month; self.hardResets = hardResets; self.resetCards = resetCards
  }
}

public struct CodexResetCalendarSnapshot: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var events: [CodexResetCalendarEvent] = []
  public var monthlyTotals: [CodexResetMonthlyTotal] = []
  public var lastSuccessAt: Date?
  public var lastAttemptAt: Date?
  public var failureMessage: String?
  public init() {}
}

public enum CodexResetCalendarDates {
  public static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    calendar.firstWeekday = 2
    return calendar
  }
  public static func day(_ date: Date) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }
  public static func date(_ day: String) -> Date? {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, day.count == 10,
      let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
      self.day(date) == day else { return nil }
    return date
  }
  public static func month(_ date: Date) -> Date { calendar.dateInterval(of: .month, for: date)!.start }
  public static func cells(in month: Date) -> [Date] {
    let first = self.month(month)
    let offset = (calendar.component(.weekday, from: first) + 5) % 7
    return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: first) }
  }
}
