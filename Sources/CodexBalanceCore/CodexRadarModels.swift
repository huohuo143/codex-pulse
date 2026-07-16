import Foundation

public struct CodexRadarSnapshot: Equatable, Decodable, Sendable {
  public var schemaVersion: String?
  public var service: String?
  public var type: String?
  public var monitoredAt: Date?
  public var timezone: String?
  public var windowOpen: Bool?
  public var status: String?
  public var recommendedAction: String?
  public var window: CodexRadarWindow?
  public var prediction: CodexRadarPrediction?
  public var tiboPresence: CodexRadarTiboPresence?
  public var links: CodexRadarLinks?
  public var publicJudgement: CodexRadarPublicJudgement?

  public var probability24hPercent: Int? {
    prediction?.probability24h.map { Int((min(1, max(0, $0)) * 100).rounded()) }
  }

  public var latestUpdate: Date? {
    [publicJudgement?.updatedAt, prediction?.updatedAt, monitoredAt]
      .compactMap { $0 }
      .max()
  }

  public var probabilityUpdate: Date? {
    prediction?.updatedAt ?? monitoredAt
  }

  public var latestLevelLabel: String {
    if publicJudgementIsNewer, let label = publicJudgement?.levelLabel {
      return label
    }
    return prediction?.levelLabel ?? publicJudgement?.levelLabel ?? "研判中"
  }

  public var latestSummary: String? {
    if publicJudgementIsNewer, let summary = publicJudgement?.summary {
      return summary
    }
    return prediction?.summary ?? publicJudgement?.summary
  }

  public var publicJudgementIsNewer: Bool {
    guard let publicUpdate = publicJudgement?.updatedAt else { return false }
    guard let probabilityUpdate else { return true }
    return publicUpdate > probabilityUpdate
  }

  public static func decode(from data: Data) throws -> CodexRadarSnapshot {
    try CodexRadarCodec.decode(data)
  }
}

public struct CodexRadarWindow: Equatable, Decodable, Sendable {
  public var open: Bool?
  public var status: String?
  public var action: String?
  public var message: String?
  public var title: String?
  public var scope: String?
  public var openedAt: Date?
  public var closedAt: Date?
  public var sourceURL: String?

  private enum CodingKeys: String, CodingKey {
    case open, status, action, message, title, scope, openedAt, closedAt
    case sourceURL = "sourceUrl"
  }
}

public struct CodexRadarPrediction: Equatable, Decodable, Sendable {
  public var level: String?
  public var probability24h: Double?
  public var probability48h: Double?
  public var summary: String?
  public var summaryEn: String?
  public var updatedAt: Date?

  private enum CodingKeys: String, CodingKey {
    case level, summary, summaryEn, updatedAt
    case probability24h = "probability24H"
    case probability48h = "probability48H"
  }

  public var levelLabel: String {
    switch level?.lowercased() {
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

public struct CodexRadarTiboPresence: Equatable, Decodable, Sendable {
  public var handle: String?
  public var timezone: String?
  public var locationLabelZh: String?
  public var locationLabelEn: String?
  public var probability: Double?
  public var confidence: String?
  public var evidenceSummaryZh: String?
  public var evidenceSummaryEn: String?
  public var sourceURLs: [String]?
  public var shouldDisplay: Bool?
  public var safetyNoteZh: String?
  public var updatedAt: Date?
  public var observedAt: Date?
  public var staleAt: Date?
  public var latestActivityZh: String?
  public var latestActivityEn: String?
  public var latestActivityAt: Date?

  private enum CodingKeys: String, CodingKey {
    case handle, timezone, locationLabelZh, locationLabelEn, probability, confidence
    case evidenceSummaryZh, evidenceSummaryEn, shouldDisplay, safetyNoteZh
    case updatedAt, observedAt, staleAt
    case latestActivityZh, latestActivityEn, latestActivityAt
    case sourceURLs = "sourceUrls"
  }
}

public struct CodexRadarLinks: Equatable, Decodable, Sendable {
  public var html: String?
  public var rss: String?
  public var fullAPI: String?

  private enum CodingKeys: String, CodingKey {
    case html, rss
    case fullAPI = "fullApi"
  }
}

enum CodexRadarCodec {
  private struct DashboardPayload: Decodable {
    var generatedAt: Date?
    var refreshIntervalSeconds: Int?
    var platforms: [DashboardPlatform]
    var accountPosts: [String: DashboardAccountPost]?
  }

  private struct DashboardPlatform: Decodable {
    var id: String
    var name: String?
    var probability: Double
    var statusLabel: String?
    var summary: String?
    var summaryBlocks: [DashboardSummaryBlock]?
    var updatedAt: Date?
    var resetAt: Date?
  }

  private struct DashboardSummaryBlock: Decodable {
    var id: String?
    var text: String?
  }

  private struct DashboardAccountPost: Decodable {
    var id: String?
    var author: String?
    var handle: String?
    var text: String?
    var publishedAt: Date?
  }

  private struct Envelope: Decodable {
    var data: CodexRadarSnapshot?
    var current: CodexRadarSnapshot?
    var result: CodexRadarSnapshot?
  }

  static func decode(_ data: Data) throws -> CodexRadarSnapshot {
    if let dashboard = try? makeDecoder().decode(DashboardPayload.self, from: data),
       let snapshot = dashboardSnapshot(from: dashboard) {
      return snapshot
    }
    let decoder = makeDecoder()
    if let direct = try? decoder.decode(CodexRadarSnapshot.self, from: data),
       direct.prediction != nil || direct.tiboPresence != nil {
      return direct
    }
    let envelope = try makeDecoder().decode(Envelope.self, from: data)
    if let snapshot = envelope.data ?? envelope.current ?? envelope.result { return snapshot }
    throw CodexRadarError.invalidPayload
  }

  private static func dashboardSnapshot(from dashboard: DashboardPayload) -> CodexRadarSnapshot? {
    guard let platform = dashboard.platforms.first(where: { $0.id.lowercased() == "codex" }) else {
      return nil
    }

    let probability = platform.probability > 1
      ? platform.probability / 100
      : platform.probability
    let normalizedProbability = min(1, max(0, probability))
    let summary = platform.summary?.nilIfBlank
      ?? platform.summaryBlocks?
        .compactMap { $0.text?.nilIfBlank }
        .joined(separator: "；")
        .nilIfBlank
    let updatedAt = platform.updatedAt ?? dashboard.generatedAt
    let prediction = CodexRadarPrediction(
      level: dashboardLevel(statusLabel: platform.statusLabel, probability: normalizedProbability),
      probability24h: normalizedProbability,
      probability48h: nil,
      summary: summary,
      summaryEn: nil,
      updatedAt: updatedAt
    )

    let post = dashboard.accountPosts?["codex"]
    let presence = post.map {
      CodexRadarTiboPresence(
        handle: $0.handle ?? "@thsottiaux",
        timezone: "America/Los_Angeles",
        locationLabelZh: "旧金山湾区 / PT",
        locationLabelEn: "San Francisco Bay Area / PT",
        probability: nil,
        confidence: "public-timezone",
        evidenceSummaryZh: "公开动态未明确披露当前位置，因此采用默认 PT 时区；作息状态仅按当地时间推测。",
        evidenceSummaryEn: nil,
        sourceURLs: nil,
        shouldDisplay: true,
        safetyNoteZh: "仅展示粗粒度公开时区推测。",
        updatedAt: dashboard.generatedAt,
        observedAt: $0.publishedAt,
        staleAt: nil,
        latestActivityZh: $0.text,
        latestActivityEn: nil,
        latestActivityAt: $0.publishedAt
      )
    }

    return CodexRadarSnapshot(
      schemaVersion: "mini-program-dashboard-v1",
      service: "reset-radar-mini-program",
      type: "public-dashboard",
      monitoredAt: dashboard.generatedAt,
      timezone: "Asia/Shanghai",
      windowOpen: false,
      status: "prediction",
      recommendedAction: "wait",
      window: nil,
      prediction: prediction,
      tiboPresence: presence,
      links: CodexRadarLinks(
        html: "https://api.tangka.online/radar-api/dashboard",
        rss: nil,
        fullAPI: nil
      ),
      publicJudgement: nil
    )
  }

  private static func dashboardLevel(statusLabel: String?, probability: Double) -> String {
    let label = statusLabel ?? ""
    if label.contains("极高") { return "very_high" }
    if label.contains("中高") { return "medium_high" }
    if label.contains("中低") { return "medium_low" }
    if label.contains("高") { return "high" }
    if label.contains("中") { return "medium" }
    if label.contains("低") || label.contains("冷却") { return "low" }
    switch probability {
    case 0.85...: return "very_high"
    case 0.70...: return "high"
    case 0.55...: return "medium_high"
    case 0.40...: return "medium"
    case 0.25...: return "medium_low"
    default: return "low"
    }
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      if let raw = try? container.decode(Double.self) {
        let seconds = raw > 10_000_000_000 ? raw / 1_000 : raw
        return Date(timeIntervalSince1970: seconds)
      }
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

private extension String {
  var nilIfBlank: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
