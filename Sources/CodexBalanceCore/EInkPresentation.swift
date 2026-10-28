import Foundation

/// An explicit allowlist for cloud display. Never serialize CodexWidgetSnapshot to a cloud service.
public struct EInkPresentation: Codable, Equatable, Sendable {
  public let generatedAt: Date
  public let isSample: Bool
  public let remainingPercent: Double?
  public let quotaSampledAt: Date?
  public let quotaState: DataFreshnessState
  public let resetsAt: Date?
  public let tokens24h: Int?
  public let usageSampledAt: Date?
  public let resetCredits: Int?
  public let radarState: String
  public let radarDeadline: Date?
  public let completionUntil: Date?
  public let radarCheckedAt: Date?
  public let radarHealthy: Bool
  public let history: [CodexWidgetQuotaPoint]

  public init(snapshot: CodexWidgetSnapshot, at now: Date = Date(), isSample: Bool = false) {
    let value = snapshot.effective(at: now)
    generatedAt = now; self.isSample = isSample
    remainingPercent = value.remainingPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
    quotaSampledAt = snapshot.quotaRead?.sampledAt
    quotaState = snapshot.quotaRead?.state(at: now, resetAt: snapshot.resetsAt) ?? .unavailable
    resetsAt = value.resetsAt
    tokens24h = value.usageState(at: now).canDisplayValue ? max(0, value.rolling24HoursTokens) : nil
    usageSampledAt = value.usageUpdatedAt
    resetCredits = value.resetCreditsAvailable.map { max(0, $0) }
    radarCheckedAt = value.radarCheckedAt
    radarHealthy = value.radarIsStale != true && value.radarSyncStatus == "刷新正常"
    // Only fixed status labels leave the app; no arbitrary model summary or quoted posts.
    if value.radarAnnouncementActive == true {
      radarState = "重置已预告"; radarDeadline = value.radarDeadlineAt; completionUntil = nil
    } else if let until = value.radarCompletionUntil, until > now {
      radarState = "重置已落地"; radarDeadline = nil; completionUntil = until
    } else {
      let allowed = ["等待新重置", "等待数据", "动态已过期", "动态已更新", "暂无重置预告"]
      radarState = allowed.contains(value.radarLevel ?? "") ? value.radarLevel! : "等待数据"
      radarDeadline = nil; completionUntil = nil
    }
    history = (value.quotaHistory?.first { $0.days == 7 }?.visiblePoints(at: now) ?? [])
      .sorted { $0.recordedAt < $1.recordedAt }
  }

  /// Only changes to the reset event, never the ticking countdown or sample time, bypass ten minutes.
  public var attentionKey: String {
    "\(radarState)|\(radarDeadline?.timeIntervalSince1970 ?? 0)|\(completionUntil?.timeIntervalSince1970 ?? 0)"
  }

  public static func sample(at now: Date = Date()) -> Self {
    var snapshot = CodexWidgetSnapshot.preview
    let metadata = SourceReadMetadata(source: "示例", sampledAt: now, lastAttemptAt: now, lastSuccessAt: now)
    snapshot.updatedAt = now; snapshot.quotaRead = metadata; snapshot.resetCreditsRead = metadata
    snapshot.remainingPercent = 85; snapshot.rolling24HoursTokens = 360_000_000
    snapshot.usageUpdatedAt = now; snapshot.usageValidUntil = now.addingTimeInterval(1800)
    snapshot.resetsAt = now.addingTimeInterval(6 * 86400 + 10 * 3600)
    snapshot.resetCreditsAvailable = 1; snapshot.resetCredits = []
    snapshot.radarAnnouncementActive = false; snapshot.radarLevel = "重置已落地"
    snapshot.radarCompletionUntil = now.addingTimeInterval(10 * 3600 + 57 * 60)
    snapshot.radarLastSuccessAt = now; snapshot.radarCheckedAt = now; snapshot.radarSyncStatus = "刷新正常"
    let points = sampleQuotaHistory(at: now)
    snapshot.quotaHistory = [.init(days: 7, sampleCount: points.count, points: points)]
    return Self(snapshot: snapshot, at: now, isSample: true)
  }

  /// Deterministic illustrative usage, never read from a person's account or used for real history.
  /// Equal anchors model idle periods; small drops model light use; sharp drops model busy sessions.
  private static func sampleQuotaHistory(at now: Date) -> [CodexWidgetQuotaPoint] {
    let cycles: [[(hour: Int, percent: Double)]] = [
      [(0,100), (4,98), (10,97), (18,97), (23,93), (27,91), (28,88),
       (29,57), (30,30), (33,28), (38,28), (43,23), (47,21), (48,10), (50,5), (52,4)],
      [(0,100), (3,99), (6,97), (14,97), (19,94), (23,90), (25,88),
       (26,64), (27,33), (30,31), (35,31), (40,26), (41,12), (43,4), (45,2)],
      [(0,100), (2,99), (9,96), (16,96), (21,93), (25,89), (28,88),
       (29,76), (30,45), (31,37), (35,36), (40,36), (43,31), (46,27), (47,13), (50,8)],
      [(0,100), (1,96), (3,94), (6,94), (9,92), (12,91), (15,91), (17,88), (18,85)]
    ]
    let count = cycles.reduce(0) { $0 + ($1.last?.hour ?? -1) + 1 }
    var points: [CodexWidgetQuotaPoint] = []; points.reserveCapacity(count)
    for (segment, anchors) in cycles.enumerated() {
      guard let last = anchors.last else { continue }
      var interval = 0
      for hour in 0...last.hour {
        while interval + 1 < anchors.count - 1 && hour > anchors[interval + 1].hour { interval += 1 }
        let start = anchors[interval], end = anchors[interval + 1]
        let fraction = Double(hour - start.hour) / Double(end.hour - start.hour)
        let percent = start.percent + (end.percent - start.percent) * fraction
        let date = now.addingTimeInterval(Double(points.count - (count - 1)) * 3600)
        // A new segment at each reset prevents the renderer from connecting depletion back to 100%.
        points.append(.init(recordedAt: date, remainingPercent: percent, segment: segment))
      }
    }
    return points
  }
}

public struct EInkScreenProfile: Codable, Equatable, Hashable, Sendable, Identifiable {
  public var width: Int
  public var height: Int
  public var colors: Int
  public var id: String { "\(width)x\(height)-\(colors)" }
  public var title: String { "\(width) × \(height)" }
  public init(width: Int = 400, height: Int = 300, colors: Int = 2) {
    self.width = width; self.height = height; self.colors = colors
  }
  public static let presets: [Self] = [.init(), .init(width: 648, height: 480), .init(width: 800, height: 480)]
  public var isValid: Bool { (400...1600).contains(width) && (300...1200).contains(height) && [2, 3, 4, 6].contains(colors) }
  public var canPublish: Bool { isValid && colors <= 4 }
  public var compatibilityNote: String {
    if !isValid { return "请输入宽 400–1600、高 300–1200 像素。" }
    if colors == 6 { return "六色、E6 与特殊机型的云端协议待验证；当前仅支持本地预览。" }
    return "布局已适配；设备连接与实机显示需逐型号验证。"
  }
  // Match upstream json_renderer.py's reserved status bar, footer and width-based image scaling.
  public var scale: Double { Double(width) / 400 }
  public var headerHeight: Int { Int(Double(height) * 0.12) }
  public var footerHeight: Int { Int(30 * min(scale, Double(height) / 300)) }
  public var imageBaseHeight: Int { max(1, Int(Double(height - headerHeight - footerHeight - 4) / scale)) }
  public var imageHeight: Int { Int(Double(imageBaseHeight) * scale) }
}

public enum EInkFormat {
  public static func date(_ date: Date?, full: Bool = false) -> String {
    guard let date else { return "—" }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = full ? "MM/dd HH:mm" : "HH:mm"
    return formatter.string(from: date)
  }
  public static func duration(until: Date?, at now: Date) -> String {
    guard let until else { return "—" }
    let minutes = max(0, Int(ceil(until.timeIntervalSince(now) / 60)))
    if minutes >= 1440 { return "\(minutes / 1440)天\(minutes % 1440 / 60)时" }
    return "\(minutes / 60)时\(minutes % 60)分"
  }
  public static func tokens(_ count: Int?) -> String {
    guard let count else { return "—" }
    if count >= 100_000_000 { return String(format: "%.1f亿", Double(count) / 100_000_000) }
    if count >= 10_000 { return String(format: "%.1f万", Double(count) / 10_000) }
    return String(count)
  }
}

public struct EInkSyncPolicy: Sendable {
  public private(set) var lastSuccess: Date?
  public private(set) var nextAttempt: Date?
  public private(set) var failures = 0
  public private(set) var attentionKey: String?
  public init() {}
  public func shouldPublish(_ value: EInkPresentation, at now: Date) -> Bool {
    if let nextAttempt, now < nextAttempt { return false }
    guard let lastSuccess else { return true }
    return value.attentionKey != attentionKey || now.timeIntervalSince(lastSuccess) >= 600
  }
  public mutating func succeeded(_ value: EInkPresentation, at now: Date) {
    lastSuccess = now; attentionKey = value.attentionKey; failures = 0; nextAttempt = nil
  }
  public mutating func failed(at now: Date) {
    failures = min(6, failures + 1)
    nextAttempt = now.addingTimeInterval(min(600, 30 * pow(2, Double(failures - 1))))
  }
}
