import Foundation

public enum QuotaHistoryPeriod: Int, CaseIterable, Identifiable, Sendable {
  case day = 1
  case week = 7
  case month = 30

  public var id: Int { rawValue }
  public var title: String { self == .day ? "24 小时" : "\(rawValue) 天" }
  public var duration: TimeInterval { Double(rawValue) * 86_400 }
}

public struct QuotaHistoryPoint: Identifiable, Equatable, Sendable {
  public var id: Date { snapshot.recordedAt }
  public let snapshot: QuotaSnapshot
  public let segment: Int
}

/// Historical observations only: never interpolate across a reset, an upward
/// adjustment, or a long interval without an official observation.
public enum QuotaHistoryTrend {
  public static let maximumConnectedGap: TimeInterval = 90 * 60

  public static func points(
    snapshots: [QuotaSnapshot], period: QuotaHistoryPeriod, now: Date = Date()
  ) -> [QuotaHistoryPoint] {
    let cutoff = now.addingTimeInterval(-period.duration)
    var unique: [Date: QuotaSnapshot] = [:]
    for row in snapshots where row.recordedAt.timeIntervalSince1970.isFinite
      && row.resetsAt.timeIntervalSince1970.isFinite
      && row.remainingPercent.isFinite && (0...100).contains(row.remainingPercent)
      && row.windowMinutes.isFinite
      && abs(row.windowMinutes - QuotaHistoryStore.expectedWindowMinutes) <= 60
      && row.recordedAt >= cutoff && row.recordedAt <= now && row.resetsAt > row.recordedAt {
      unique[row.recordedAt] = row
    }
    let rows = unique.values.sorted { $0.recordedAt < $1.recordedAt }
    var segment = 0
    var previous: QuotaSnapshot?
    return rows.map { row in
      if let previous,
        abs(row.resetsAt.timeIntervalSince(previous.resetsAt)) > 300
          || row.remainingPercent > previous.remainingPercent + 0.1
          || row.recordedAt.timeIntervalSince(previous.recordedAt) > maximumConnectedGap {
        segment += 1
      }
      previous = row
      return QuotaHistoryPoint(snapshot: row, segment: segment)
    }
  }

  /// Publish only chart coordinates and segment IDs, scoped by the host to the
  /// active account. Raw observations and account identifiers stay in the app.
  public static func widgetHistory(snapshots: [QuotaSnapshot], now: Date = Date()) -> [CodexWidgetQuotaHistory] {
    QuotaHistoryPeriod.allCases.map { period in
      let samples = points(snapshots: snapshots, period: period, now: now)
      return CodexWidgetQuotaHistory(days: period.rawValue, sampleCount: samples.count,
        points: displayPoints(samples).map {
          CodexWidgetQuotaPoint(recordedAt: $0.snapshot.recordedAt,
            remainingPercent: $0.snapshot.remainingPercent, segment: $0.segment)
        })
    }
  }

  public static func makeCSV(points: [QuotaHistoryPoint], generatedAt: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    let locale = Locale(identifier: "en_US_POSIX")
    var lines = [
      "Codex 脉动官方额度历史",
      "生成时间,\(formatter.string(from: generatedAt))",
      "说明,仅当前账户本机记录的官方7天额度样本；时间为UTC；不包含账户标识或会话内容",
      "采样时间(UTC),剩余额度(%),官方重置时间(UTC),窗口(分钟),曲线分段"
    ]
    lines += points.map { point in
      let row = point.snapshot
      return [formatter.string(from: row.recordedAt),
        String(format: "%.3f", locale: locale, row.remainingPercent),
        formatter.string(from: row.resetsAt),
        String(format: "%.0f", locale: locale, row.windowMinutes), String(point.segment + 1)]
        .joined(separator: ",")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Preserve endpoints and extrema within each segment while bounding chart work.
  /// The original observations remain available for hover inspection and export.
  public static func displayPoints(_ points: [QuotaHistoryPoint]) -> [QuotaHistoryPoint] {
    guard points.count > 1200 else { return points }
    let stride = Int(ceil(Double(points.count) / 300))
    var output: [QuotaHistoryPoint] = []
    var start = 0
    while start < points.count {
      var end = start + 1
      while end < points.count, end - start < stride, points[end].segment == points[start].segment { end += 1 }
      let slice = points[start..<end]
      let low = slice.indices.min { points[$0].snapshot.remainingPercent < points[$1].snapshot.remainingPercent }!
      let high = slice.indices.max { points[$0].snapshot.remainingPercent < points[$1].snapshot.remainingPercent }!
      output += Set([start, low, high, end - 1]).sorted().map { points[$0] }
      start = end
    }
    return output
  }

  public static func nearestPoint(to date: Date, in points: [QuotaHistoryPoint]) -> QuotaHistoryPoint? {
    guard !points.isEmpty else { return nil }
    var lower = 0
    var upper = points.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if points[middle].snapshot.recordedAt < date { lower = middle + 1 } else { upper = middle }
    }
    if lower == 0 { return points[0] }
    if lower == points.count { return points.last }
    let earlier = points[lower - 1]
    let later = points[lower]
    return date.timeIntervalSince(earlier.snapshot.recordedAt) <= later.snapshot.recordedAt.timeIntervalSince(date) ? earlier : later
  }
}
