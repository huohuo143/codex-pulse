import Foundation

/// Independent, bounded detail document. No raw sessions, account credentials or project names.
public struct MobileDetailSnapshot: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var publishedAt: Date
  public var device: MobileDevice
  public var accountID: String?
  public var sourceTimeZone = ""
  public var usageSampledAt: Date?
  public var usageValidUntil: Date?
  public var usage: MobileUsage?
  public var history: [MobileHistoryPoint] = []
  public var forecast: MobileForecast?
  public var credits: [MobileCreditBatch] = []
  public var creditsRead: MobileSourceRead?
  public var radar: MobileRadar?
  public var calendar: [MobileCalendarEvent] = []
  public var calendarReadAt: Date?
  public var calendarFailed = false
  public var monthlyResets: [MobileMetric] = []
  public var health: [MobileMetric] = []
  public var healthAt: Date?
  public init(publishedAt: Date, device: MobileDevice, accountID: String?) {
    self.publishedAt = publishedAt; self.device = device; self.accountID = accountID
  }
  public static let maximumBytes = 4 * 1024 * 1024
  public func matches(_ snapshot: MobileAccountSnapshot) -> Bool {
    device.id == snapshot.device.id && accountID == snapshot.account?.id
  }
  public func validate(now: Date = Date()) throws {
    guard schemaVersion == 1 else { throw MobileSnapshotError.unsupportedVersion }
    guard !device.id.isEmpty, device.id.count <= 100, device.name.count <= 160,
      publishedAt <= now.addingTimeInterval(300), (accountID?.count ?? 0) <= 128,
      history.count <= 10000, calendar.count <= 4000, credits.count <= 1000,
      health.count <= 30, monthlyResets.count <= 120, sourceTimeZone.count <= 100 else { throw MobileSnapshotError.invalidData }
    guard accountID != nil || (history.isEmpty && forecast == nil && credits.isEmpty) else { throw MobileSnapshotError.invalidData }
    guard [usageSampledAt,calendarReadAt,healthAt].compactMap({$0}).allSatisfy({$0 <= now.addingTimeInterval(300)}),
      Set(history.map(\.date)).count == history.count, Set(calendar.map(\.id)).count == calendar.count,
      Set(credits.map(\.id)).count == credits.count else { throw MobileSnapshotError.invalidData }
    for row in credits {
      guard row.count > 0, row.grantedAt <= now.addingTimeInterval(300), row.expiresAt.map({$0 >= row.grantedAt}) != false else { throw MobileSnapshotError.invalidData }
    }
    if let f=forecast {
      guard f.generatedAt <= now.addingTimeInterval(300), f.summary.count <= 4000, f.risk.count <= 80, f.confidence.count <= 80,
        [f.hourlyRate,f.balancedDaily].compactMap({$0}).allSatisfy({$0.isFinite && $0 >= 0}) else { throw MobileSnapshotError.invalidData }
    }
    for row in history {
      guard row.remaining.isFinite, (0...100).contains(row.remaining), row.resetAt > row.date,
        row.date <= now.addingTimeInterval(300) else { throw MobileSnapshotError.invalidData }
    }
    if let usage {
      guard [usage.today, usage.week, usage.month, usage.rolling].allSatisfy({ $0 >= 0 }),
        usage.hourly.count <= 744, usage.daily.count <= 366, usage.monthly.count <= 120,
        usage.projects.count <= 100, usage.budgets.count <= 100, usage.devices.count <= 100,
        usage.models.count <= 200, usage.categories.count <= 50, usage.analysis.count <= 50, usage.costs.count <= 10, usage.cnyRate.map({$0.isFinite && $0 > 0}) != false else { throw MobileSnapshotError.invalidData }
      for list in [usage.models,usage.categories,usage.projects,usage.budgets,usage.devices,usage.analysis,usage.costs] {
        guard Set(list.map(\.id)).count == list.count else { throw MobileSnapshotError.invalidData }
      }
      for list in [usage.hourly,usage.daily,usage.monthly] {
        guard Set(list.map(\.key)).count == list.count else { throw MobileSnapshotError.invalidData }
      }
      for row in usage.hourly + usage.daily + usage.monthly {
        guard row.tokens >= 0, row.input >= 0, row.cached >= 0, row.output >= 0,
          row.key.count <= 80, row.label.count <= 80 else { throw MobileSnapshotError.invalidData }
      }
      for row in usage.models + usage.categories + usage.analysis + usage.projects + usage.budgets + usage.devices + usage.costs {
        guard row.id.count <= 160, row.label.count <= 180, row.note.count <= 500,
          [row.value,row.secondary,row.tertiary].compactMap({$0}).allSatisfy(\.isFinite) else { throw MobileSnapshotError.invalidData }
      }
      for row in usage.projects + usage.budgets {
        guard row.label == "项目 · " + row.id.prefix(8), row.id.count == 64,
          row.id.allSatisfy({ $0.isHexDigit }), row.note.isEmpty else { throw MobileSnapshotError.invalidData }
      }
    }
    for event in calendar {
      guard event.id.count <= 180, event.title.count <= 300, event.summary.count <= 4000,
        MobileCalendarDates.date(event.day) != nil, event.links.count <= 8,
        event.links.allSatisfy(Self.safeURL) else { throw MobileSnapshotError.invalidData }
    }
    if let radar {
      guard radar.title.count <= 300, radar.summary.count <= 8000,
        radar.links.count <= 12, radar.links.allSatisfy(Self.safeURL) else { throw MobileSnapshotError.invalidData }
    }
  }
  public static func safeURL(_ value: String) -> Bool {
    guard let url = URL(string: value) else { return false }
    return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
  }
  public func encoded() throws -> Data {
    try validate()
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(self)
    guard data.count <= Self.maximumBytes else { throw MobileSnapshotError.tooLarge }
    return data
  }
  public static func decode(_ data: Data, now: Date = Date()) throws -> Self {
    guard data.count <= maximumBytes else { throw MobileSnapshotError.tooLarge }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let result = try decoder.decode(Self.self, from: data); try result.validate(now: now); return result
  }
  public static func select(_ candidates: [Self], for snapshot: MobileAccountSnapshot, previous: Self?) -> Self? {
    (candidates + [previous].compactMap { $0 }).filter { $0.matches(snapshot) }.max { $0.publishedAt < $1.publishedAt }
  }
}

public struct MobileMetric: Codable, Equatable, Sendable, Identifiable {
  public var id: String; public var label: String
  public var value: Double?; public var secondary: Double?; public var tertiary: Double?
  public var note: String
  public init(_ id: String, _ label: String, _ value: Double? = nil, secondary: Double? = nil, tertiary: Double? = nil, note: String = "") {
    self.id=id; self.label=label; self.value=value; self.secondary=secondary; self.tertiary=tertiary; self.note=note
  }
}
public struct MobileUsage: Codable, Equatable, Sendable {
  public var today = 0; public var week = 0; public var month = 0; public var rolling = 0
  public var hourly: [MobileTokenPoint] = []; public var daily: [MobileTokenPoint] = []; public var monthly: [MobileTokenPoint] = []
  public var models: [MobileMetric] = []; public var categories: [MobileMetric] = []
  public var projects: [MobileMetric] = []; public var budgets: [MobileMetric] = []; public var devices: [MobileMetric] = []
  public var analysis: [MobileMetric] = []; public var costs: [MobileMetric] = []
  public var cnyRate: Double?; public var rateDate: String?
  public init() {}
}
public struct MobileTokenPoint: Codable, Equatable, Sendable, Identifiable {
  public var key: String; public var label: String; public var tokens: Int; public var input: Int; public var cached: Int; public var output: Int
  public var id: String { key }
  public init(key: String, label: String, tokens: Int, input: Int, cached: Int, output: Int) {
    self.key=key; self.label=label; self.tokens=tokens; self.input=input; self.cached=cached; self.output=output
  }
}
public struct MobileHistoryPoint: Codable, Equatable, Sendable, Identifiable {
  public var date: Date; public var remaining: Double; public var resetAt: Date; public var segment: Int
  public var id: Date { date }
  public init(date: Date, remaining: Double, resetAt: Date, segment: Int) { self.date=date; self.remaining=remaining; self.resetAt=resetAt; self.segment=segment }
}
public struct MobileForecast: Codable, Equatable, Sendable {
  public var generatedAt: Date; public var resetAt: Date?; public var hourlyRate: Double?
  public var earliest: Date?; public var estimated: Date?; public var latest: Date?
  public var balancedDaily: Double?; public var risk: String; public var confidence: String; public var summary: String
  public init(generatedAt: Date, resetAt: Date?, hourlyRate: Double?, earliest: Date?, estimated: Date?, latest: Date?, balancedDaily: Double?, risk: String, confidence: String, summary: String) {
    self.generatedAt=generatedAt; self.resetAt=resetAt; self.hourlyRate=hourlyRate; self.earliest=earliest; self.estimated=estimated; self.latest=latest; self.balancedDaily=balancedDaily; self.risk=risk; self.confidence=confidence; self.summary=summary
  }
}
public struct MobileCreditBatch: Codable, Equatable, Sendable, Identifiable {
  public var grantedAt: Date; public var expiresAt: Date?; public var count: Int
  public var id: String { "\(grantedAt.timeIntervalSince1970)-\(expiresAt?.timeIntervalSince1970 ?? 0)" }
  public init(grantedAt: Date, expiresAt: Date?, count: Int) { self.grantedAt=grantedAt; self.expiresAt=expiresAt; self.count=count }
}
public struct MobileRadar: Codable, Equatable, Sendable {
  public var title: String; public var summary: String; public var sampledAt: Date?; public var checkedAt: Date?
  public var validUntil: Date?; public var deadline: Date?; public var completionUntil: Date?; public var healthy: Bool; public var links: [String]
  public init(title: String, summary: String, sampledAt: Date?, checkedAt: Date?, validUntil: Date?, deadline: Date?, completionUntil: Date?, healthy: Bool, links: [String]) {
    self.title=title; self.summary=summary; self.sampledAt=sampledAt; self.checkedAt=checkedAt; self.validUntil=validUntil; self.deadline=deadline; self.completionUntil=completionUntil; self.healthy=healthy; self.links=links
  }
  public func isCurrent(at now: Date) -> Bool {
    healthy && sampledAt.map { now.timeIntervalSince($0) <= 5400 && $0 <= now.addingTimeInterval(5) } == true && validUntil.map { $0 > now } != false
  }
  private func completionBoundary(at now: Date) -> Date? {
    guard let until=completionUntil, until.timeIntervalSince1970.isFinite,
      until.addingTimeInterval(-86400) <= now else { return nil }
    return until
  }
  public func displayCompletionUntil(at now: Date) -> Date? {
    completionBoundary(at:now).flatMap { $0 > now ? $0 : nil }
  }
  public func displayTitle(at now: Date) -> String {
    if let until=completionBoundary(at:now) {
      if now >= until { return "等待新重置" }
      return ["重置已落实","已完成重置"].contains(title) ? "重置已落地" : title
    }
    if completionUntil != nil { return "尚不能确认" }
    return isCurrent(at:now) ? title : "动态已过期"
  }
  public func hasAnnouncement(at now: Date) -> Bool {
    completionBoundary(at:now) == nil && isCurrent(at:now) && title.contains("预告")
  }
  public func displayDeadline(at now: Date) -> Date? { hasAnnouncement(at:now) ? deadline : nil }
}
public struct MobileCalendarEvent: Codable, Equatable, Sendable, Identifiable {
  public var id: String; public var day: String; public var kind: String; public var title: String; public var summary: String
  public var confirmation: String; public var precision: String; public var occurredAt: Date?; public var links: [String]
  public init(id: String, day: String, kind: String, title: String, summary: String, confirmation: String, precision: String, occurredAt: Date?, links: [String]) {
    self.id=id; self.day=day; self.kind=kind; self.title=title; self.summary=summary; self.confirmation=confirmation; self.precision=precision; self.occurredAt=occurredAt; self.links=links
  }
}
public enum MobileCalendarDates {
  public static var calendar: Calendar { var c=Calendar(identifier:.gregorian); c.timeZone=TimeZone(identifier:"Asia/Shanghai")!; c.firstWeekday=2; return c }
  public static func key(_ date: Date) -> String {
    let c=calendar.dateComponents([.year,.month,.day], from:date)
    return String(format:"%04d-%02d-%02d",c.year!,c.month!,c.day!)
  }
  public static func date(_ key: String) -> Date? {
    let p=key.split(separator:"-").compactMap { Int($0) }
    guard p.count==3, key.count==10, let d=calendar.date(from:DateComponents(year:p[0],month:p[1],day:p[2],hour:12)), self.key(d)==key else { return nil }; return d
  }
}
