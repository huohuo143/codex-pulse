import Foundation

public enum ToolID: String, CaseIterable, Codable, Identifiable, Sendable {
  case codex

  public var id: String { rawValue }
  public var displayName: String { "Codex" }
}

public struct LimitWindow: Equatable, Codable, Sendable {
  public var usedPercent: Double
  public var remainingPercent: Double
  public var windowMinutes: Double
  public var resetsAt: Date?
  public var inferredReset: Bool

  public init(
    usedPercent: Double,
    remainingPercent: Double,
    windowMinutes: Double,
    resetsAt: Date?,
    inferredReset: Bool = false
  ) {
    self.usedPercent = usedPercent
    self.remainingPercent = remainingPercent
    self.windowMinutes = windowMinutes
    self.resetsAt = resetsAt
    self.inferredReset = inferredReset
  }
}

public struct TokenUsage: Equatable, Codable, Sendable {
  public var totalTokens: Int
  public var inputTokens: Int
  public var cachedInputTokens: Int
  public var outputTokens: Int
  public var reasoningOutputTokens: Int
  public var lastTotalTokens: Int
  public var lastInputTokens: Int
  public var lastCachedInputTokens: Int
  public var lastOutputTokens: Int
  public var lastReasoningOutputTokens: Int

  public init(
    totalTokens: Int = 0,
    inputTokens: Int = 0,
    cachedInputTokens: Int = 0,
    outputTokens: Int = 0,
    reasoningOutputTokens: Int = 0,
    lastTotalTokens: Int = 0,
    lastInputTokens: Int = 0,
    lastCachedInputTokens: Int = 0,
    lastOutputTokens: Int = 0,
    lastReasoningOutputTokens: Int = 0
  ) {
    self.totalTokens = totalTokens
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
    self.reasoningOutputTokens = reasoningOutputTokens
    self.lastTotalTokens = lastTotalTokens
    self.lastInputTokens = lastInputTokens
    self.lastCachedInputTokens = lastCachedInputTokens
    self.lastOutputTokens = lastOutputTokens
    self.lastReasoningOutputTokens = lastReasoningOutputTokens
  }
}

public enum TokenUsageCategory: String, CaseIterable, Codable, Identifiable, Sendable {
  case coding
  case presentation
  case imageDesign
  case videoProduction
  case documents
  case manuscript
  case dataAnalysis
  case lifeScience
  case webDevelopment
  case systemOperations
  case research
  case general
  case other

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .coding: "编程/APP".coreL10n
    case .presentation: "PPT/演示".coreL10n
    case .imageDesign: "图片/视觉".coreL10n
    case .videoProduction: "视频制作".coreL10n
    case .documents: "文档/表格".coreL10n
    case .manuscript: "论文/写作".coreL10n
    case .dataAnalysis: "数据分析".coreL10n
    case .lifeScience: "生物科研".coreL10n
    case .webDevelopment: "网站开发".coreL10n
    case .systemOperations: "系统/运维".coreL10n
    case .research: "文献/检索".coreL10n
    case .general: "通用问答".coreL10n
    case .other: "其他".coreL10n
    }
  }
}

public struct RateLimitEvent: Identifiable, Equatable, Codable, Sendable {
  public var id: String { "\(limitID)-\(timestamp.timeIntervalSince1970)" }
  public var timestamp: Date
  public var sourceName: String
  public var sourcePath: String
  public var limitID: String
  public var limitName: String
  public var planType: String?
  public var primary: LimitWindow?
  public var secondary: LimitWindow?
  public var reachedType: String?
  public var model: String
  public var usage: TokenUsage
  public var usageCategory: TokenUsageCategory
  public var projectName: String
  public var projectPath: String

  /// Codex has used both `secondary` and `primary` for the seven-day window.
  /// Identify each quota by its official duration because the API slot can
  /// change between versions.
  public var sevenDayWindow: LimitWindow? {
    window(matching: 7.0 * 24.0 * 60.0, toleranceMinutes: 60.0)
  }

  public var fiveHourWindow: LimitWindow? {
    window(matching: 5.0 * 60.0, toleranceMinutes: 15.0)
  }

  private func window(matching expectedMinutes: Double, toleranceMinutes: Double) -> LimitWindow? {
    return [secondary, primary]
      .compactMap { $0 }
      .filter { abs($0.windowMinutes - expectedMinutes) <= toleranceMinutes }
      .min { abs($0.windowMinutes - expectedMinutes) < abs($1.windowMinutes - expectedMinutes) }
  }

  public init(
    timestamp: Date,
    sourceName: String,
    sourcePath: String,
    limitID: String,
    limitName: String,
    planType: String? = nil,
    primary: LimitWindow? = nil,
    secondary: LimitWindow? = nil,
    reachedType: String? = nil,
    model: String = "unknown",
    usage: TokenUsage = TokenUsage(),
    usageCategory: TokenUsageCategory = .other,
    projectName: String = "未知项目".coreL10n,
    projectPath: String = ""
  ) {
    self.timestamp = timestamp
    self.sourceName = sourceName
    self.sourcePath = sourcePath
    self.limitID = limitID
    self.limitName = limitName
    self.planType = planType
    self.primary = primary
    self.secondary = secondary
    self.reachedType = reachedType
    self.model = model
    self.usage = usage
    self.usageCategory = usageCategory
    self.projectName = projectName
    self.projectPath = projectPath
  }
}

/// One read-only Full reset credit returned by a Codex account source.
/// The backend's opaque redemption identifier is intentionally not decoded or stored.
public struct RateLimitResetCredit: Identifiable, Equatable, Decodable, Sendable {
  public var id: String {
    let granted = Int64(grantedAt.timeIntervalSince1970)
    let expires = expiresAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "none"
    return "\(granted)-\(expires)-\(title)"
  }

  public var title: String
  public var status: String
  public var resetType: String
  public var grantedAt: Date
  public var expiresAt: Date?

  public var isAvailable: Bool { status.lowercased() == "available" }

  public init(
    title: String = "Full reset",
    status: String = "available",
    resetType: String = "codexRateLimits",
    grantedAt: Date,
    expiresAt: Date?
  ) {
    self.title = title
    self.status = status
    self.resetType = resetType
    self.grantedAt = grantedAt
    self.expiresAt = expiresAt
  }

  private enum CodingKeys: String, CodingKey {
    case title
    case status
    case resetType
    case grantedAt
    case expiresAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Full reset"
    status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
    resetType = try container.decodeIfPresent(String.self, forKey: .resetType) ?? "unknown"
    grantedAt = try Self.decodeDate(from: container, forKey: .grantedAt)
    expiresAt = try Self.decodeDateIfPresent(from: container, forKey: .expiresAt)
  }

  private static func decodeDate(
    from container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> Date {
    if let date = try decodeDateIfPresent(from: container, forKey: key) { return date }
    throw DecodingError.keyNotFound(
      key,
      .init(codingPath: container.codingPath, debugDescription: "Missing reset-credit timestamp")
    )
  }

  private static func decodeDateIfPresent(
    from container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> Date? {
    if try container.decodeNil(forKey: key) { return nil }
    if let raw = try? container.decode(Double.self, forKey: key) {
      let seconds = raw > 10_000_000_000 ? raw / 1_000 : raw
      return Date(timeIntervalSince1970: seconds)
    }
    if let text = try? container.decode(String.self, forKey: key) {
      if let raw = Double(text) {
        let seconds = raw > 10_000_000_000 ? raw / 1_000 : raw
        return Date(timeIntervalSince1970: seconds)
      }
      let fractionalFormatter = ISO8601DateFormatter()
      fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractionalFormatter.date(from: text) { return date }
      if let date = ISO8601DateFormatter().date(from: text) { return date }
    }
    throw DecodingError.dataCorruptedError(
      forKey: key,
      in: container,
      debugDescription: "Unsupported reset-credit timestamp"
    )
  }
}

/// Account-level Full reset summary. `availableCount` remains authoritative because
/// the backend is allowed to omit or cap the detail list.
public struct RateLimitResetCreditsSummary: Equatable, Decodable, Sendable {
  public var availableCount: Int
  public var credits: [RateLimitResetCredit]?

  public init(availableCount: Int, credits: [RateLimitResetCredit]?) {
    self.availableCount = max(0, availableCount)
    self.credits = credits
  }

  private enum CodingKeys: String, CodingKey {
    case availableCount
    case credits
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    credits = try container.decodeIfPresent([RateLimitResetCredit].self, forKey: .credits)
    let returnedCount = try container.decodeIfPresent(Int.self, forKey: .availableCount)
    availableCount = max(0, returnedCount ?? credits?.filter(\.isAvailable).count ?? 0)
  }

  public var availableCredits: [RateLimitResetCredit] {
    (credits ?? [])
      .filter(\.isAvailable)
      .sorted {
        switch ($0.expiresAt, $1.expiresAt) {
        case let (lhs?, rhs?):
          if lhs == rhs { return $0.grantedAt < $1.grantedAt }
          return lhs < rhs
        case (_?, nil):
          return true
        case (nil, _?):
          return false
        case (nil, nil):
          return $0.grantedAt < $1.grantedAt
        }
      }
  }

  public var missingDetailCount: Int {
    max(0, availableCount - availableCredits.count)
  }
}

public struct TokenBucket: Identifiable, Equatable, Codable, Sendable {
  public var id: String { key }
  public var key: String
  public var label: String
  public var totalTokens: Int
  public var inputTokens: Int
  public var cachedInputTokens: Int
  public var outputTokens: Int
  public var reasoningOutputTokens: Int
  public var calls: Int
  // Kept only so schema 2/3 files remain decodable.
  public var cacheCreationInputTokens: Int
  public var cacheReadInputTokens: Int

  public init(
    key: String,
    label: String,
    totalTokens: Int = 0,
    inputTokens: Int = 0,
    cachedInputTokens: Int = 0,
    outputTokens: Int = 0,
    reasoningOutputTokens: Int = 0,
    calls: Int = 0,
    cacheCreationInputTokens: Int = 0,
    cacheReadInputTokens: Int = 0
  ) {
    self.key = key
    self.label = label
    self.totalTokens = totalTokens
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
    self.reasoningOutputTokens = reasoningOutputTokens
    self.calls = calls
    self.cacheCreationInputTokens = cacheCreationInputTokens
    self.cacheReadInputTokens = cacheReadInputTokens
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    key = try container.decode(String.self, forKey: .key)
    label = try container.decode(String.self, forKey: .label)
    totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
    inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
    cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
    outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
    reasoningOutputTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens) ?? 0
    calls = try container.decodeIfPresent(Int.self, forKey: .calls) ?? 0
    cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
    cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
  }
}

public struct ModelHourlyBucket: Identifiable, Equatable, Codable, Sendable {
  public var id: String { "\(hourKey)|\(model)" }
  public var hourKey: String
  public var model: String
  public var totalTokens: Int
  public var inputTokens: Int
  public var cachedInputTokens: Int
  public var outputTokens: Int
  public var reasoningOutputTokens: Int
  public var calls: Int

  public init(
    hourKey: String,
    model: String,
    totalTokens: Int = 0,
    inputTokens: Int = 0,
    cachedInputTokens: Int = 0,
    outputTokens: Int = 0,
    reasoningOutputTokens: Int = 0,
    calls: Int = 0
  ) {
    self.hourKey = hourKey
    self.model = model
    self.totalTokens = totalTokens
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
    self.reasoningOutputTokens = reasoningOutputTokens
    self.calls = calls
  }
}

public struct TokenUsageEvent: Identifiable, Equatable, Sendable {
  public var id: String { "\(sourceName)-\(timestamp.timeIntervalSince1970)-\(totalTokens)-\(model)" }
  public var timestamp: Date
  public var sourceName: String
  public var model: String
  public var totalTokens: Int
  public var inputTokens: Int
  public var cachedInputTokens: Int
  public var outputTokens: Int
  public var reasoningOutputTokens: Int
  public var category: TokenUsageCategory
  public var projectName: String
  public var projectPath: String

  public init(
    timestamp: Date,
    sourceName: String,
    model: String = "unknown",
    totalTokens: Int,
    inputTokens: Int,
    cachedInputTokens: Int = 0,
    outputTokens: Int,
    reasoningOutputTokens: Int,
    category: TokenUsageCategory = .other,
    projectName: String = "未知项目".coreL10n,
    projectPath: String = ""
  ) {
    self.timestamp = timestamp
    self.sourceName = sourceName
    self.model = model
    self.totalTokens = totalTokens
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
    self.reasoningOutputTokens = reasoningOutputTokens
    self.category = category
    self.projectName = projectName
    self.projectPath = projectPath
  }
}

public struct TokenProjectBucket: Identifiable, Equatable, Sendable {
  public var id: String { projectPath.isEmpty ? projectName : projectPath }
  public var projectName: String
  public var projectPath: String
  public var totalTokens: Int
  public var calls: Int

  public init(projectName: String, projectPath: String = "", totalTokens: Int = 0, calls: Int = 0) {
    self.projectName = projectName
    self.projectPath = projectPath
    self.totalTokens = totalTokens
    self.calls = calls
  }
}

public struct TokenCategoryBucket: Identifiable, Equatable, Sendable {
  public var id: String { category.rawValue }
  public var category: TokenUsageCategory
  public var totalTokens: Int
  public var inputTokens: Int
  public var outputTokens: Int
  public var reasoningOutputTokens: Int
  public var calls: Int

  public init(
    category: TokenUsageCategory,
    totalTokens: Int = 0,
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    reasoningOutputTokens: Int = 0,
    calls: Int = 0
  ) {
    self.category = category
    self.totalTokens = totalTokens
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.reasoningOutputTokens = reasoningOutputTokens
    self.calls = calls
  }
}

public struct AccountTokenUsage: Equatable, Sendable {
  public var daily: [TokenBucket]
  public var monthly: [TokenBucket]
  public var updatedAt: Date?
  public var unavailableReason: String?

  public init(
    daily: [TokenBucket] = [],
    monthly: [TokenBucket] = [],
    updatedAt: Date? = nil,
    unavailableReason: String? = nil
  ) {
    self.daily = daily
    self.monthly = monthly
    self.updatedAt = updatedAt
    self.unavailableReason = unavailableReason
  }
}

public enum DeviceIdentity {
  public static func slug(from name: String) -> String {
    let lowered = name.lowercased()
      .replacingOccurrences(of: ".local", with: "")
      .replacingOccurrences(of: "的", with: "-")
    let mapped = lowered.map { ch -> Character in
      (ch.isLetter || ch.isNumber) ? ch : "-"
    }
    var slug = String(mapped)
    while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
    slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return slug.isEmpty ? "mac" : slug
  }

  public static func legacyFileName(deviceID: String) -> String { "\(deviceID)-codex.json" }
  public static func v2FileName(deviceID: String) -> String { "\(deviceID)-codex-v2.json" }
  public static func fileName(deviceID: String, app: ToolID) -> String { legacyFileName(deviceID: deviceID) }
}

public struct CodexDeviceTokenUsage: Identifiable, Equatable, Codable, Sendable {
  public var id: String { deviceID }
  public var schemaVersion: Int
  public var app: ToolID
  public var deviceID: String
  public var deviceName: String
  public var hostName: String
  public var updatedAt: Date
  public var todayTokens: Int
  public var monthTokens: Int
  public var sampleCount: Int
  public var hourly: [TokenBucket]
  public var modelHourly: [ModelHourlyBucket]
  public var daily: [TokenBucket]
  public var monthly: [TokenBucket]

  public init(
    schemaVersion: Int = 4,
    app: ToolID = .codex,
    deviceID: String,
    deviceName: String,
    hostName: String,
    updatedAt: Date,
    todayTokens: Int,
    monthTokens: Int,
    sampleCount: Int,
    hourly: [TokenBucket] = [],
    modelHourly: [ModelHourlyBucket] = [],
    daily: [TokenBucket],
    monthly: [TokenBucket]
  ) {
    self.schemaVersion = schemaVersion
    self.app = app
    self.deviceID = deviceID
    self.deviceName = deviceName
    self.hostName = hostName
    self.updatedAt = updatedAt
    self.todayTokens = todayTokens
    self.monthTokens = monthTokens
    self.sampleCount = sampleCount
    self.hourly = hourly
    self.modelHourly = modelHourly
    self.daily = daily
    self.monthly = monthly
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    app = try container.decodeIfPresent(ToolID.self, forKey: .app) ?? .codex
    deviceID = try container.decode(String.self, forKey: .deviceID)
    deviceName = try container.decode(String.self, forKey: .deviceName)
    hostName = try container.decodeIfPresent(String.self, forKey: .hostName) ?? ""
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    todayTokens = try container.decodeIfPresent(Int.self, forKey: .todayTokens) ?? 0
    monthTokens = try container.decodeIfPresent(Int.self, forKey: .monthTokens) ?? 0
    sampleCount = try container.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
    hourly = try container.decodeIfPresent([TokenBucket].self, forKey: .hourly) ?? []
    modelHourly = try container.decodeIfPresent([ModelHourlyBucket].self, forKey: .modelHourly) ?? []
    daily = try container.decodeIfPresent([TokenBucket].self, forKey: .daily) ?? []
    monthly = try container.decodeIfPresent([TokenBucket].self, forKey: .monthly) ?? []
  }
}

public struct ModelPricing: Equatable, Sendable {
  public var inputPerMillionUSD: Double
  public var cachedInputPerMillionUSD: Double
  public var outputPerMillionUSD: Double
  public var longContextThresholdInputTokens: Int?
  public var longContextInputMultiplier: Double
  public var longContextOutputMultiplier: Double

  public init(
    input: Double,
    cachedInput: Double,
    output: Double,
    longContextThresholdInputTokens: Int? = nil,
    longContextInputMultiplier: Double = 1,
    longContextOutputMultiplier: Double = 1
  ) {
    inputPerMillionUSD = input
    cachedInputPerMillionUSD = cachedInput
    outputPerMillionUSD = output
    self.longContextThresholdInputTokens = longContextThresholdInputTokens
    self.longContextInputMultiplier = longContextInputMultiplier
    self.longContextOutputMultiplier = longContextOutputMultiplier
  }
}

public struct CostEstimate: Equatable, Sendable {
  public var usd: Double
  public var pricedTokens: Int
  public var unpricedTokens: Int
  public var unpricedModels: [String]

  public init(usd: Double = 0, pricedTokens: Int = 0, unpricedTokens: Int = 0, unpricedModels: [String] = []) {
    self.usd = usd
    self.pricedTokens = pricedTokens
    self.unpricedTokens = unpricedTokens
    self.unpricedModels = unpricedModels
  }

  public var isPartial: Bool { unpricedTokens > 0 }
}

public struct ModelPricingCatalog: Sendable {
  public static let current = ModelPricingCatalog()
  public let rates: [String: ModelPricing]

  public init(rates: [String: ModelPricing] = [
    "gpt-5.6-sol": ModelPricing(input: 5, cachedInput: 0.50, output: 30, longContextThresholdInputTokens: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
    "gpt-5.6": ModelPricing(input: 5, cachedInput: 0.50, output: 30, longContextThresholdInputTokens: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
    "gpt-5.6-terra": ModelPricing(input: 2.50, cachedInput: 0.25, output: 15, longContextThresholdInputTokens: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
    "gpt-5.6-luna": ModelPricing(input: 1, cachedInput: 0.10, output: 6),
    "gpt-5.5": ModelPricing(input: 5, cachedInput: 0.50, output: 30, longContextThresholdInputTokens: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
    "gpt-5.4": ModelPricing(input: 2.50, cachedInput: 0.25, output: 15, longContextThresholdInputTokens: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
    "gpt-5.4-pro": ModelPricing(input: 30, cachedInput: 30, output: 180, longContextThresholdInputTokens: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
    "gpt-5.4-mini": ModelPricing(input: 0.75, cachedInput: 0.075, output: 4.50),
    "gpt-5.3-codex": ModelPricing(input: 1.75, cachedInput: 0.175, output: 14),
    "gpt-5.2": ModelPricing(input: 1.75, cachedInput: 0.175, output: 14)
  ]) {
    self.rates = rates
  }

  public func estimate(events: [TokenUsageEvent]) -> CostEstimate {
    var result = CostEstimate()
    var unknown = Set<String>()
    for event in events {
      let model = event.model.lowercased()
      guard let rate = rates[model] else {
        result.unpricedTokens += event.totalTokens
        unknown.insert(event.model.isEmpty ? "unknown" : event.model)
        continue
      }
      let cached = min(max(0, event.cachedInputTokens), max(0, event.inputTokens))
      let uncached = max(0, event.inputTokens - cached)
      let isLongContext = rate.longContextThresholdInputTokens.map { event.inputTokens > $0 } ?? false
      let inputMultiplier = isLongContext ? rate.longContextInputMultiplier : 1
      let outputMultiplier = isLongContext ? rate.longContextOutputMultiplier : 1
      result.usd += Double(uncached) / 1_000_000 * rate.inputPerMillionUSD * inputMultiplier
      result.usd += Double(cached) / 1_000_000 * rate.cachedInputPerMillionUSD * inputMultiplier
      result.usd += Double(max(0, event.outputTokens)) / 1_000_000 * rate.outputPerMillionUSD * outputMultiplier
      result.pricedTokens += event.totalTokens
    }
    result.unpricedModels = unknown.sorted()
    return result
  }
}

public struct ExchangeRateSnapshot: Equatable, Codable, Sendable {
  public var base: String
  public var quote: String
  public var rate: Double
  public var rateDate: String
  public var fetchedAt: Date

  public init(base: String = "USD", quote: String = "CNY", rate: Double, rateDate: String, fetchedAt: Date) {
    self.base = base
    self.quote = quote
    self.rate = rate
    self.rateDate = rateDate
    self.fetchedAt = fetchedAt
  }
}

public struct TokenStats: Equatable, Sendable {
  public var rolling24HoursTokens: Int
  public var todayTokens: Int
  public var monthTokens: Int
  public var last7DaysTokens: Int
  public var sampleCount: Int
  public var hourly: [TokenBucket]
  public var modelHourly: [ModelHourlyBucket]
  public var daily: [TokenBucket]
  public var monthly: [TokenBucket]
  public var cost24Hours: CostEstimate
  public var cost7Days: CostEstimate
  public var costMonth: CostEstimate
  public var categoryBreakdown: [TokenCategoryBucket]
  public var todayTopProjects: [TokenProjectBucket]
  public var monthTopProjects: [TokenProjectBucket]
  public var recentUsageEvents: [TokenUsageEvent]
  public var accountUsage: AccountTokenUsage?
  public var deviceUsage: [CodexDeviceTokenUsage]

  public init(
    rolling24HoursTokens: Int = 0,
    todayTokens: Int = 0,
    monthTokens: Int = 0,
    last7DaysTokens: Int = 0,
    sampleCount: Int = 0,
    hourly: [TokenBucket] = [],
    modelHourly: [ModelHourlyBucket] = [],
    daily: [TokenBucket] = [],
    monthly: [TokenBucket] = [],
    cost24Hours: CostEstimate = CostEstimate(),
    cost7Days: CostEstimate = CostEstimate(),
    costMonth: CostEstimate = CostEstimate(),
    categoryBreakdown: [TokenCategoryBucket] = [],
    todayTopProjects: [TokenProjectBucket] = [],
    monthTopProjects: [TokenProjectBucket] = [],
    recentUsageEvents: [TokenUsageEvent] = [],
    accountUsage: AccountTokenUsage? = nil,
    deviceUsage: [CodexDeviceTokenUsage] = []
  ) {
    self.rolling24HoursTokens = rolling24HoursTokens
    self.todayTokens = todayTokens
    self.monthTokens = monthTokens
    self.last7DaysTokens = last7DaysTokens
    self.sampleCount = sampleCount
    self.hourly = hourly
    self.modelHourly = modelHourly
    self.daily = daily
    self.monthly = monthly
    self.cost24Hours = cost24Hours
    self.cost7Days = cost7Days
    self.costMonth = costMonth
    self.categoryBreakdown = categoryBreakdown
    self.todayTopProjects = todayTopProjects
    self.monthTopProjects = monthTopProjects
    self.recentUsageEvents = recentUsageEvents
    self.accountUsage = accountUsage
    self.deviceUsage = deviceUsage
  }
}

public struct CodexStatus: Equatable, Sendable {
  public var generatedAt: Date
  public var codexHome: String
  public var sessionsRoot: String
  public var scannedFiles: Int
  public var eventCount: Int
  public var main: RateLimitEvent?
  public var limits: [RateLimitEvent]
  public var trend: [RateLimitEvent]
  public var rateLimitResetCredits: RateLimitResetCreditsSummary?
  public var tokenStats: TokenStats
  public var recentEvents: [RateLimitEvent]

  public init(
    generatedAt: Date = Date(),
    codexHome: String,
    sessionsRoot: String,
    scannedFiles: Int = 0,
    eventCount: Int = 0,
    main: RateLimitEvent? = nil,
    limits: [RateLimitEvent] = [],
    trend: [RateLimitEvent] = [],
    rateLimitResetCredits: RateLimitResetCreditsSummary? = nil,
    tokenStats: TokenStats = TokenStats(),
    recentEvents: [RateLimitEvent] = []
  ) {
    self.generatedAt = generatedAt
    self.codexHome = codexHome
    self.sessionsRoot = sessionsRoot
    self.scannedFiles = scannedFiles
    self.eventCount = eventCount
    self.main = main
    self.limits = limits
    self.trend = trend
    self.rateLimitResetCredits = rateLimitResetCredits
    self.tokenStats = tokenStats
    self.recentEvents = recentEvents
  }
}
