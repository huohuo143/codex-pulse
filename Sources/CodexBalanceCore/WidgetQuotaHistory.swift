import Foundation

/// Display-only coordinates. Contains no account identifiers or source paths.
public struct CodexWidgetQuotaPoint: Codable, Equatable, Sendable, Identifiable {
  public var recordedAt: Date
  public var remainingPercent: Double
  public var segment: Int
  public var id: Date { recordedAt }

  public init(recordedAt: Date, remainingPercent: Double, segment: Int) {
    self.recordedAt = recordedAt
    self.remainingPercent = remainingPercent
    self.segment = segment
  }
}

public struct CodexWidgetQuotaHistory: Codable, Equatable, Sendable {
  public var days: Int
  public var sampleCount: Int
  public var points: [CodexWidgetQuotaPoint]

  public init(days: Int, sampleCount: Int, points: [CodexWidgetQuotaPoint]) {
    self.days = days
    self.sampleCount = sampleCount
    self.points = points
  }

  /// Re-evaluate the rolling range when WidgetKit displays a later timeline.
  /// Segment IDs survive filtering, so gaps and resets are never joined.
  public func visiblePoints(at now: Date) -> [CodexWidgetQuotaPoint] {
    guard [1, 7, 30].contains(days) else { return [] }
    let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
    return points.filter {
      $0.recordedAt >= cutoff && $0.recordedAt <= now
        && $0.remainingPercent.isFinite && (0...100).contains($0.remainingPercent)
    }
  }

  public static func preview(at now: Date) -> [CodexWidgetQuotaHistory] {
    [1, 7, 30].map { days in
      let points = (0...(days * 24)).map { index in
        CodexWidgetQuotaPoint(recordedAt: now.addingTimeInterval(Double(index - days * 24) * 3600),
          remainingPercent: 96 - Double(index % 72) * 1.1, segment: index / 72)
      }
      return Self(days: days, sampleCount: points.count, points: points)
    }
  }
}
