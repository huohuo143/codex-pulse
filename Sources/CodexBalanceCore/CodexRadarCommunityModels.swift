import Foundation

public struct CodexRadarResetEstimate: Equatable, Decodable, Sendable {
  public var probability24h: Double
  public var level: String
  public var summary: String
  public var updatedAt: Date
  public var evaluatedAt: Date?
  public var evidenceUpdatedAt: Date?
  public var validUntil: Date?
  public var signals: [String]
  public var methodology: String

  public var probability24hPercent: Int {
    Int((min(1, max(0, probability24h)) * 100).rounded())
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
    default: "研判中"
    }
  }
}

public struct CodexRadarTiboFeed: Equatable, Decodable, Sendable {
  public var updatedAt: Date?
  public var posts: [CodexRadarTiboPost]
}

public struct CodexRadarTiboPost: Equatable, Codable, Identifiable, Sendable {
  public var id: String
  public var url: URL?
  public var publishedAt: Date?
  public var relevance: String
  public var relevanceLabel: String
  public var originalText: String
  public var translationZh: String?
  public var analysisZh: String?

  public var isReply: Bool {
    originalText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@")
  }

  public var kindLabel: String { isReply ? "Reply" : "Post" }

  public var isStrongResetSignal: Bool {
    ["official", "direct", "high"].contains(relevance.lowercased())
  }

  public var isResetRelevantForDisplay: Bool {
    if ["official", "direct", "high", "medium"].contains(relevance.lowercased()) {
      return true
    }
    let text = [originalText, translationZh ?? ""]
      .joined(separator: " ")
      .lowercased()
    let mentionsReset = text.contains("usage reset")
      || text.contains("reset usage")
      || text.contains("重置额度")
      || text.contains("额度重置")
    let mentionsRelease = text.contains("tomorrow")
      || text.contains("明天")
      || text.contains("soon")
      || text.contains("很快")
      || text.contains("ship")
      || text.contains("发布")
    let mentionsSupply = text.contains("too cheap to meter")
      || text.contains("无需计量")
      || text.contains("unmetered")
      || text.contains("more capacity")
      || text.contains("更多容量")
      || text.contains("高供给")
    return mentionsReset || mentionsRelease || mentionsSupply
  }
}

public struct CodexRadarStationInsights: Equatable, Decodable, Sendable {
  public var schema: Int?
  public var mode: String?
  public var generatedAt: Date?
  public var sourceUpdatedAt: Date?
  public var recommendations: [CodexRadarRecommendationGroup]

  public static func decode(from data: Data) throws -> CodexRadarStationInsights {
    try CodexRadarCommunityCodec.decoder().decode(Self.self, from: data)
  }
}

public struct CodexRadarRecommendationGroup: Equatable, Decodable, Identifiable, Sendable {
  public var key: String
  public var title: String
  public var rule: String?
  public var items: [CodexRadarRecommendation]

  public var id: String { key }
}

public struct CodexRadarRecommendation: Equatable, Decodable, Identifiable, Sendable {
  public var model: String
  public var effort: String
  public var iq: Double
  public var passed: Int?
  public var samples: Int?
  public var averageCostUsd: Double?
  public var averageDurationMinutes: Double?
  public var combinedCostIndex: Double?
  public var rule: String?
  public var slot: String?

  public var id: String { "\(model)|\(effort)|\(slot ?? "")" }
  public var modelLabel: String { CodexRadarModelLabel.short(model) }
  public var effortLabel: String { CodexRadarModelLabel.effort(effort) }
}

public struct CodexRadarEfficiencySnapshot: Equatable, Decodable, Sendable {
  public var schema: Int?
  public var type: String?
  public var source: String?
  public var sourceUpdatedAt: Date?
  public var models: Int?
  public var points: [CodexRadarEfficiencyPoint]

  public static func decode(from data: Data) throws -> CodexRadarEfficiencySnapshot {
    try CodexRadarCommunityCodec.decoder().decode(Self.self, from: data)
  }
}

public struct CodexRadarEfficiencyPoint: Equatable, Decodable, Identifiable, Sendable {
  public var model: String
  public var effort: String
  public var iq: Double
  public var passed: Int?
  public var validTasks: Int?
  public var averagePriceUsd: Double?
  public var averageMinutes: Double?
  public var totalRuns: Int?
  public var latestGradedAt: Date?

  public var id: String { "\(model)|\(effort)" }
  public var modelLabel: String { CodexRadarModelLabel.short(model) }
  public var effortLabel: String { CodexRadarModelLabel.effort(effort) }
}

public enum CodexRadarModelLabel {
  public static func short(_ model: String) -> String {
    switch model.lowercased() {
    case "gpt-5.6-sol": "Sol"
    case "gpt-5.6-terra": "Terra"
    case "gpt-5.6-luna": "Luna"
    case "gpt-5.5": "5.5"
    default:
      model
        .replacingOccurrences(of: "gpt-", with: "", options: .caseInsensitive)
        .capitalized
    }
  }

  public static func effort(_ effort: String) -> String {
    switch effort.lowercased() {
    case "low": "low"
    case "medium": "medium"
    case "high": "high"
    case "xhigh": "xhigh"
    case "max": "max"
    case "ultra": "ultra"
    default: effort
    }
  }
}

enum CodexRadarCommunityCodec {
  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractional.date(from: text) { return date }
      if let date = ISO8601DateFormatter().date(from: text) { return date }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported Codex Radar date"
      )
    }
    return decoder
  }
}
