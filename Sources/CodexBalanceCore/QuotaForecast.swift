import Foundation

public struct QuotaSnapshot: Codable, Equatable, Sendable {
  public var recordedAt: Date
  public var remainingPercent: Double
  public var resetsAt: Date
  public var windowMinutes: Double

  public init(recordedAt: Date, remainingPercent: Double, resetsAt: Date, windowMinutes: Double) {
    self.recordedAt = recordedAt
    self.remainingPercent = remainingPercent
    self.resetsAt = resetsAt
    self.windowMinutes = windowMinutes
  }
}

public enum QuotaRiskLevel: String, Codable, CaseIterable, Sendable {
  case healthy
  case caution
  case critical
  case insufficientData
}

public enum ForecastConfidence: String, Codable, CaseIterable, Sendable {
  case low
  case medium
  case high
}

public struct QuotaForecast: Equatable, Sendable {
  public var generatedAt: Date
  public var currentRemainingPercent: Double?
  public var resetsAt: Date?
  public var ratePerHour: Double?
  public var earliestExhaustion: Date?
  public var estimatedExhaustion: Date?
  public var latestExhaustion: Date?
  public var expectedRemainingAtReset: Double?
  public var balancedDailyPercent: Double?
  public var risk: QuotaRiskLevel
  public var confidence: ForecastConfidence
  public var sampleCount: Int
  public var dataSpanHours: Double
  public var reason: String?

  public var ratePerDay: Double? { ratePerHour.map { $0 * 24 } }
  public var isUsable: Bool { ratePerHour != nil && estimatedExhaustion != nil }

  public init(
    generatedAt: Date,
    currentRemainingPercent: Double? = nil,
    resetsAt: Date? = nil,
    ratePerHour: Double? = nil,
    earliestExhaustion: Date? = nil,
    estimatedExhaustion: Date? = nil,
    latestExhaustion: Date? = nil,
    expectedRemainingAtReset: Double? = nil,
    balancedDailyPercent: Double? = nil,
    risk: QuotaRiskLevel = .insufficientData,
    confidence: ForecastConfidence = .low,
    sampleCount: Int = 0,
    dataSpanHours: Double = 0,
    reason: String? = nil
  ) {
    self.generatedAt = generatedAt
    self.currentRemainingPercent = currentRemainingPercent
    self.resetsAt = resetsAt
    self.ratePerHour = ratePerHour
    self.earliestExhaustion = earliestExhaustion
    self.estimatedExhaustion = estimatedExhaustion
    self.latestExhaustion = latestExhaustion
    self.expectedRemainingAtReset = expectedRemainingAtReset
    self.balancedDailyPercent = balancedDailyPercent
    self.risk = risk
    self.confidence = confidence
    self.sampleCount = sampleCount
    self.dataSpanHours = dataSpanHours
    self.reason = reason
  }
}

private struct QuotaHistoryEnvelope: Codable {
  static let currentSchemaVersion = 1
  var schemaVersion: Int
  var snapshots: [QuotaSnapshot]
}

public final class QuotaHistoryStore: @unchecked Sendable {
  public static let expectedWindowMinutes = 7.0 * 24.0 * 60.0
  public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodexSuanliMeter/quota-history-v1.json")

  private let url: URL
  private let fileManager: FileManager
  private let lock = NSLock()
  private var loaded = false
  private var cached: [QuotaSnapshot] = []

  public init(url: URL = QuotaHistoryStore.defaultURL, fileManager: FileManager = .default) {
    self.url = url
    self.fileManager = fileManager
  }

  public func snapshots() -> [QuotaSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    loadIfNeeded()
    return cached
  }

  @discardableResult
  public func record(window: LimitWindow, at recordedAt: Date, now: Date = Date()) -> [QuotaSnapshot] {
    guard abs(window.windowMinutes - Self.expectedWindowMinutes) <= 60,
          window.inferredReset == false,
          let resetsAt = window.resetsAt,
          resetsAt > recordedAt,
          (0...100).contains(window.remainingPercent) else {
      return snapshots()
    }

    let incoming = QuotaSnapshot(
      recordedAt: recordedAt,
      remainingPercent: window.remainingPercent,
      resetsAt: resetsAt,
      windowMinutes: window.windowMinutes
    )

    lock.lock()
    defer { lock.unlock() }
    loadIfNeeded()

    if let latest = cached.max(by: { $0.recordedAt < $1.recordedAt }) {
      if incoming.recordedAt < latest.recordedAt.addingTimeInterval(-60) {
        return cached
      }
      let elapsed = incoming.recordedAt.timeIntervalSince(latest.recordedAt)
      let remainingChanged = abs(incoming.remainingPercent - latest.remainingPercent) >= 0.1
      let resetChanged = abs(incoming.resetsAt.timeIntervalSince(latest.resetsAt)) > 300
      if elapsed < 300, !remainingChanged, !resetChanged {
        return cached
      }
      if abs(elapsed) < 1,
         abs(incoming.remainingPercent - latest.remainingPercent) < 0.001,
         !resetChanged {
        return cached
      }
    }

    cached.append(incoming)
    cached = pruned(cached, now: now)
    persist()
    return cached
  }

  private func loadIfNeeded() {
    guard !loaded else { return }
    loaded = true
    guard fileManager.fileExists(atPath: url.path) else { return }
    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let envelope = try decoder.decode(QuotaHistoryEnvelope.self, from: data)
      guard envelope.schemaVersion == QuotaHistoryEnvelope.currentSchemaVersion else { return }
      cached = pruned(envelope.snapshots, now: Date())
    } catch {
      quarantineCorruptFile()
      cached = []
    }
  }

  private func pruned(_ snapshots: [QuotaSnapshot], now: Date) -> [QuotaSnapshot] {
    let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
    return Array(
      snapshots
        .filter { $0.recordedAt >= cutoff && $0.recordedAt <= now.addingTimeInterval(5 * 60) }
        .sorted { $0.recordedAt < $1.recordedAt }
        .suffix(10_000)
    )
  }

  private func persist() {
    do {
      try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let envelope = QuotaHistoryEnvelope(
        schemaVersion: QuotaHistoryEnvelope.currentSchemaVersion,
        snapshots: cached
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(envelope).write(to: url, options: [.atomic])
    } catch {
      // History is additive telemetry. A write failure must never block live quota display.
    }
  }

  private func quarantineCorruptFile() {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let target = url.deletingPathExtension()
      .appendingPathExtension("corrupt-(formatter.string(from: Date())).json")
    try? fileManager.moveItem(at: url, to: target)
  }
}

public enum QuotaForecaster {
  private struct WindowRate {
    var rate: Double
    var weight: Double
  }

  public static func forecast(
    snapshots: [QuotaSnapshot],
    current: QuotaSnapshot?,
    now: Date = Date()
  ) -> QuotaForecast {
    guard let current else {
      return QuotaForecast(generatedAt: now, reason: "暂无官方 7 天额度数据")
    }
    guard current.resetsAt > now else {
      return insufficient(current: current, now: now, reason: "等待新的官方额度周期")
    }
    guard now.timeIntervalSince(current.recordedAt) <= 30 * 60 else {
      return insufficient(current: current, now: now, reason: "额度数据超过 30 分钟未更新")
    }

    var rows = snapshots
      .filter {
        abs($0.resetsAt.timeIntervalSince(current.resetsAt)) <= 300
          && $0.recordedAt >= now.addingTimeInterval(-72 * 60 * 60)
          && $0.recordedAt <= now.addingTimeInterval(60)
      }
      .sorted { $0.recordedAt < $1.recordedAt }

    if !rows.contains(where: { abs($0.recordedAt.timeIntervalSince(current.recordedAt)) < 1 }) {
      rows.append(current)
      rows.sort { $0.recordedAt < $1.recordedAt }
    }

    // A material upward correction inside one reported reset window starts a new segment.
    if rows.count > 1 {
      var segmentStart = 0
      for index in 1..<rows.count where rows[index].remainingPercent - rows[index - 1].remainingPercent > 1.0 {
        segmentStart = index
      }
      rows = Array(rows.suffix(from: segmentStart))
    }
    rows = downsample(rows, interval: 15 * 60)

    let spanHours = rows.last.map { last in
      last.recordedAt.timeIntervalSince(rows.first?.recordedAt ?? last.recordedAt) / 3600
    } ?? 0
    let decline = max(0, (rows.first?.remainingPercent ?? current.remainingPercent) - current.remainingPercent)
    guard rows.count >= 4, spanHours >= 2, decline >= 0.5 else {
      return insufficient(
        current: current,
        now: now,
        sampleCount: rows.count,
        spanHours: spanHours,
        reason: "正在学习额度节奏（至少需要 4 个样本、2 小时和 0.5 个百分点变化）"
      )
    }

    let definitions: [(hours: Double, weight: Double)] = [(6, 0.50), (24, 0.35), (72, 0.15)]
    let windowRates = definitions.compactMap { definition -> WindowRate? in
      let subset = rows.filter { $0.recordedAt >= current.recordedAt.addingTimeInterval(-definition.hours * 3600) }
      guard subset.count >= 4,
            let first = subset.first,
            let last = subset.last,
            last.recordedAt.timeIntervalSince(first.recordedAt) >= 2 * 3600,
            let rate = theilSenRate(subset) else { return nil }
      return WindowRate(rate: rate, weight: definition.weight)
    }
    guard !windowRates.isEmpty else {
      return insufficient(
        current: current,
        now: now,
        sampleCount: rows.count,
        spanHours: spanHours,
        reason: "有效下降样本不足，暂不推断耗尽时间"
      )
    }

    let totalWeight = windowRates.reduce(0) { $0 + $1.weight }
    let centerRate = windowRates.reduce(0) { $0 + $1.rate * $1.weight } / totalWeight
    let intervalRates = pairwiseRates(rows)
    guard centerRate > 0, !intervalRates.isEmpty else {
      return insufficient(
        current: current,
        now: now,
        sampleCount: rows.count,
        spanHours: spanHours,
        reason: "当前额度基本稳定，暂不推断耗尽时间"
      )
    }

    let slowRate = max(0.0001, percentile(intervalRates, 0.25))
    let fastRate = max(centerRate, percentile(intervalRates, 0.75))
    let estimated = now.addingTimeInterval(current.remainingPercent / centerRate * 3600)
    let earliest = now.addingTimeInterval(current.remainingPercent / fastRate * 3600)
    let latest = now.addingTimeInterval(current.remainingPercent / slowRate * 3600)
    let hoursToReset = current.resetsAt.timeIntervalSince(now) / 3600
    let expectedAtReset = max(0, min(100, current.remainingPercent - centerRate * hoursToReset))
    let balancedDaily = hoursToReset > 0 ? current.remainingPercent / hoursToReset * 24 : nil
    let risk = riskLevel(
      remaining: current.remainingPercent,
      estimated: estimated,
      earliest: earliest,
      latest: latest,
      reset: current.resetsAt
    )
    let spread = (fastRate - slowRate) / centerRate
    let confidence: ForecastConfidence
    if spanHours >= 24, rows.count >= 12, spread <= 0.75 {
      confidence = .high
    } else if spanHours >= 6, rows.count >= 6 {
      confidence = .medium
    } else {
      confidence = .low
    }

    return QuotaForecast(
      generatedAt: now,
      currentRemainingPercent: current.remainingPercent,
      resetsAt: current.resetsAt,
      ratePerHour: centerRate,
      earliestExhaustion: earliest,
      estimatedExhaustion: estimated,
      latestExhaustion: latest,
      expectedRemainingAtReset: expectedAtReset,
      balancedDailyPercent: balancedDaily,
      risk: risk,
      confidence: confidence,
      sampleCount: rows.count,
      dataSpanHours: spanHours
    )
  }

  private static func insufficient(
    current: QuotaSnapshot,
    now: Date,
    sampleCount: Int = 0,
    spanHours: Double = 0,
    reason: String
  ) -> QuotaForecast {
    let hoursToReset = current.resetsAt.timeIntervalSince(now) / 3600
    return QuotaForecast(
      generatedAt: now,
      currentRemainingPercent: current.remainingPercent,
      resetsAt: current.resetsAt,
      balancedDailyPercent: hoursToReset > 0 ? current.remainingPercent / hoursToReset * 24 : nil,
      risk: .insufficientData,
      confidence: .low,
      sampleCount: sampleCount,
      dataSpanHours: spanHours,
      reason: reason
    )
  }

  private static func downsample(_ rows: [QuotaSnapshot], interval: TimeInterval) -> [QuotaSnapshot] {
    var buckets: [Int64: QuotaSnapshot] = [:]
    for row in rows {
      let key = Int64(floor(row.recordedAt.timeIntervalSince1970 / interval))
      if buckets[key]?.recordedAt ?? .distantPast < row.recordedAt { buckets[key] = row }
    }
    return buckets.values.sorted { $0.recordedAt < $1.recordedAt }
  }

  private static func theilSenRate(_ rows: [QuotaSnapshot]) -> Double? {
    let rates = pairwiseRates(rows)
    guard !rates.isEmpty else { return nil }
    return percentile(rates, 0.5)
  }

  private static func pairwiseRates(_ rows: [QuotaSnapshot]) -> [Double] {
    guard rows.count > 1 else { return [] }
    var result: [Double] = []
    for left in 0..<(rows.count - 1) {
      for right in (left + 1)..<rows.count {
        let elapsedHours = rows[right].recordedAt.timeIntervalSince(rows[left].recordedAt) / 3600
        guard elapsedHours >= 0.5 else { continue }
        let decline = rows[left].remainingPercent - rows[right].remainingPercent
        guard decline > 0 else { continue }
        result.append(decline / elapsedHours)
      }
    }
    return result.sorted()
  }

  private static func percentile(_ sortedValues: [Double], _ percentile: Double) -> Double {
    guard let first = sortedValues.first else { return 0 }
    guard sortedValues.count > 1 else { return first }
    let position = min(1, max(0, percentile)) * Double(sortedValues.count - 1)
    let lower = Int(floor(position))
    let upper = Int(ceil(position))
    guard lower != upper else { return sortedValues[lower] }
    let fraction = position - Double(lower)
    return sortedValues[lower] * (1 - fraction) + sortedValues[upper] * fraction
  }

  private static func riskLevel(
    remaining: Double,
    estimated: Date,
    earliest: Date,
    latest: Date,
    reset: Date
  ) -> QuotaRiskLevel {
    if remaining <= 5 || estimated <= reset.addingTimeInterval(-6 * 3600) { return .critical }
    if remaining <= 15 || estimated < reset || (earliest <= reset && latest >= reset) { return .caution }
    if earliest > reset { return .healthy }
    return .caution
  }
}

public enum QuotaAlertPreset: String, Codable, CaseIterable, Identifiable, Sendable {
  case standard
  case early
  case urgentOnly

  public var id: String { rawValue }
  public var thresholds: [Int] {
    switch self {
    case .standard: [30, 15, 5]
    case .early: [50, 30, 15]
    case .urgentOnly: [15, 5]
    }
  }
}

public enum QuotaAlertKind: Equatable, Sendable {
  case threshold(Int)
  case forecastCritical
  case resetCreditExpiring(title: String, expiresAt: Date)
}

public struct QuotaAlertCandidate: Equatable, Sendable {
  public var identifier: String
  public var kind: QuotaAlertKind

  public init(identifier: String, kind: QuotaAlertKind) {
    self.identifier = identifier
    self.kind = kind
  }
}

public struct QuotaAlertLedger: Codable, Equatable, Sendable {
  public var sentKeys: Set<String>
  public var lastForecastCriticalAt: Date?
  public var lastForecastCycle: String?
  public var lastRisk: QuotaRiskLevel

  public init(
    sentKeys: Set<String> = [],
    lastForecastCriticalAt: Date? = nil,
    lastForecastCycle: String? = nil,
    lastRisk: QuotaRiskLevel = .insufficientData
  ) {
    self.sentKeys = sentKeys
    self.lastForecastCriticalAt = lastForecastCriticalAt
    self.lastForecastCycle = lastForecastCycle
    self.lastRisk = lastRisk
  }
}

public struct QuotaAlertEvaluation: Equatable, Sendable {
  public var candidates: [QuotaAlertCandidate]
  public var ledger: QuotaAlertLedger
}

public enum QuotaAlertEvaluator {
  public static func evaluate(
    remainingPercent: Double?,
    resetAt: Date?,
    forecast: QuotaForecast?,
    resetCredits: [RateLimitResetCredit],
    thresholds: [Int],
    thresholdAlertsEnabled: Bool,
    forecastAlertsEnabled: Bool,
    resetCreditAlertsEnabled: Bool,
    ledger initialLedger: QuotaAlertLedger,
    now: Date = Date()
  ) -> QuotaAlertEvaluation {
    var ledger = initialLedger
    var candidates: [QuotaAlertCandidate] = []
    let cycle = resetAt.map { String(Int64($0.timeIntervalSince1970 / 60)) } ?? "unknown"

    if thresholdAlertsEnabled, let remainingPercent, resetAt != nil {
      let crossed = thresholds
        .filter { remainingPercent <= Double($0) }
        .sorted()
      let unsent = crossed.filter { !ledger.sentKeys.contains("threshold.\(cycle).\($0)") }
      if let mostUrgent = unsent.first {
        for threshold in crossed { ledger.sentKeys.insert("threshold.\(cycle).\(threshold)") }
        candidates.append(QuotaAlertCandidate(
          identifier: "quota-threshold-\(cycle)-\(mostUrgent)",
          kind: .threshold(mostUrgent)
        ))
      }
    }

    if forecastAlertsEnabled, let forecast {
      if forecast.risk == .critical {
        let enteredCritical = ledger.lastRisk != .critical
        let newCycle = ledger.lastForecastCycle != cycle
        let cooldownElapsed = ledger.lastForecastCriticalAt.map { now.timeIntervalSince($0) >= 6 * 3600 } ?? true
        if enteredCritical || newCycle || cooldownElapsed {
          candidates.append(QuotaAlertCandidate(
            identifier: "quota-forecast-critical-\(cycle)-\(Int(now.timeIntervalSince1970 / (6 * 3600)))",
            kind: .forecastCritical
          ))
          ledger.lastForecastCriticalAt = now
          ledger.lastForecastCycle = cycle
        }
      }
      ledger.lastRisk = forecast.risk
    }

    if resetCreditAlertsEnabled {
      for credit in resetCredits where credit.isAvailable {
        guard let expiry = credit.expiresAt,
              expiry > now,
              expiry.timeIntervalSince(now) <= 24 * 3600 else { continue }
        let key = "credit.\(credit.id)"
        guard !ledger.sentKeys.contains(key) else { continue }
        ledger.sentKeys.insert(key)
        candidates.append(QuotaAlertCandidate(
          identifier: "quota-credit-\(Int64(expiry.timeIntervalSince1970))",
          kind: .resetCreditExpiring(title: credit.title, expiresAt: expiry)
        ))
      }
    }

    // Bound ledger growth while preserving the active cycle and recent credit keys.
    if ledger.sentKeys.count > 200 {
      ledger.sentKeys = Set(ledger.sentKeys.filter { $0.contains(cycle) }.suffix(100))
    }
    return QuotaAlertEvaluation(candidates: candidates, ledger: ledger)
  }
}
