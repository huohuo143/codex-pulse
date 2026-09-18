import Foundation

public struct RadarArchivedForecast: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var predictedAt: Date
  public var probability: Double
  public var ruleVersion: String
  public var evidence: [String]
  public var sourceURLs: [String]
  public var windowEnd: Date { predictedAt.addingTimeInterval(86400) }
  public init(id: String = UUID().uuidString, predictedAt: Date, probability: Double, ruleVersion: String, evidence: [String], sourceURLs: [String]) {
    self.id = id; self.predictedAt = predictedAt; self.probability = probability
    self.ruleVersion = ruleVersion; self.evidence = evidence; self.sourceURLs = sourceURLs
  }
}

public struct RadarVerifiedOutcome: Codable, Equatable, Sendable {
  public var forecastID: String
  public var occurred: Bool
  public var eventAt: Date?
  public var observedThrough: Date
  public var source: String
  public var recordedAt: Date
  public var verified: Bool
  public init(forecastID: String, occurred: Bool, eventAt: Date?, observedThrough: Date, source: String, recordedAt: Date, verified: Bool) {
    self.forecastID = forecastID; self.occurred = occurred; self.eventAt = eventAt
    self.observedThrough = observedThrough; self.source = source; self.recordedAt = recordedAt; self.verified = verified
  }
}

public struct RadarEvaluationSummary: Sendable {
  public var forecasts: [RadarArchivedForecast] = []
  public var outcomes: [String: RadarVerifiedOutcome] = [:]
  public var sampleCount: Int = 0
  public var brierScore: Double? = nil
  public var pendingCount: Int = 0
  public init() {}
}

public enum RadarArchiveError: LocalizedError {
  case invalidPrediction, invalidOutcome, incompleteWindow
  public var errorDescription: String? {
    switch self {
    case .invalidPrediction: "预测必须是新版本实际生成的有限概率，且在 0–1 范围内"
    case .invalidOutcome: "请填写核实来源；发生时间必须位于所选预测的 24 小时窗口内"
    case .incompleteWindow: "24 小时窗口尚未结束，结果只能保存为待核实"
    }
  }
}

/// Append-only local ledgers. Corrections append a new outcome; unknown is never counted as false.
public actor RadarEvaluationArchive {
  public static let ruleVersion = "tibo-hard-reset-2117-v1"
  private let root: URL
  private let startedAt: Date
  private var forecasts: [RadarArchivedForecast] = []
  private var outcomes: [String: RadarVerifiedOutcome] = [:]
  private var loaded = false

  public init(root: URL = PulsePaths.support.appendingPathComponent("radar-evaluation-v1"), startedAt: Date = Date()) {
    self.root = root; self.startedAt = startedAt
  }

  public func observe(_ snapshot: CodexRadarSnapshot, now: Date = Date()) throws -> RadarEvaluationSummary {
    load()
    if snapshot.syncState?.isStale != true, let estimate = snapshot.localResetEstimate,
       let date = estimate.evaluatedAt, date >= startedAt, date <= now,
       !forecasts.contains(where: { $0.predictedAt == date && $0.ruleVersion == Self.ruleVersion }) {
      let forecast = RadarArchivedForecast(predictedAt: date, probability: estimate.probability24h,
        ruleVersion: Self.ruleVersion, evidence: estimate.signals,
        sourceURLs: snapshot.tiboFeed?.posts.compactMap { $0.url?.absoluteString } ?? [])
      try append(forecast, now: now)
    }
    return summary(now: now)
  }

  public func append(_ forecast: RadarArchivedForecast, now: Date = Date()) throws {
    load()
    guard forecast.probability.isFinite, (0...1).contains(forecast.probability),
          forecast.predictedAt >= startedAt, forecast.predictedAt <= now else { throw RadarArchiveError.invalidPrediction }
    guard !forecasts.contains(where: { $0.id == forecast.id }) else { return }
    try appendLine(forecast, file: "forecasts.jsonl")
    forecasts.append(forecast)
  }

  public func record(_ outcome: RadarVerifiedOutcome, now: Date = Date()) throws -> RadarEvaluationSummary {
    load()
    guard let forecast = forecasts.first(where: { $0.id == outcome.forecastID }),
          !outcome.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          outcome.observedThrough <= now, outcome.recordedAt <= now else { throw RadarArchiveError.invalidOutcome }
    if outcome.occurred {
      guard let event = outcome.eventAt, event >= forecast.predictedAt, event < forecast.windowEnd, event <= now else { throw RadarArchiveError.invalidOutcome }
    }
    if outcome.verified && (now < forecast.windowEnd || outcome.observedThrough < forecast.windowEnd || outcome.recordedAt < forecast.windowEnd) {
      throw RadarArchiveError.incompleteWindow
    }
    try appendLine(outcome, file: "outcomes.jsonl")
    outcomes[outcome.forecastID] = outcome
    return summary(now: now)
  }

  public func summary(now: Date = Date()) -> RadarEvaluationSummary {
    load()
    var result = RadarEvaluationSummary()
    result.forecasts = forecasts.sorted { $0.predictedAt > $1.predictedAt }
    result.outcomes = outcomes
    var score = 0.0
    for forecast in forecasts {
      guard let outcome = outcomes[forecast.id], outcome.verified, forecast.windowEnd <= now,
            outcome.observedThrough >= forecast.windowEnd, outcome.recordedAt >= forecast.windowEnd,
            !outcome.source.isEmpty,
            !outcome.occurred || outcome.eventAt.map({ $0 >= forecast.predictedAt && $0 < forecast.windowEnd }) == true
      else { result.pendingCount += 1; continue }
      result.sampleCount += 1
      score += pow(forecast.probability - (outcome.occurred ? 1 : 0), 2)
    }
    if result.sampleCount > 0 { result.brierScore = score / Double(result.sampleCount) }
    return result
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    forecasts = readLines(RadarArchivedForecast.self, file: "forecasts.jsonl")
    for row in readLines(RadarVerifiedOutcome.self, file: "outcomes.jsonl") { outcomes[row.forecastID] = row }
  }

  private func readLines<T: Decodable>(_ type: T.Type, file: String) -> [T] {
    guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
  }

  private func appendLine<T: Encodable>(_ value: T, file: String) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent(file)
    let data = try JSONEncoder().encode(value) + Data([10])
    if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .atomic) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
  }
}
