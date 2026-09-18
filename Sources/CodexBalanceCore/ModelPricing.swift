import Foundation

public struct ModelPricing: Equatable, Sendable {
  public var inputPerMillionUSD: Double
  public var cachedInputPerMillionUSD: Double?
  public var outputPerMillionUSD: Double
  public var longContextThresholdInputTokens: Int?
  public var longContextInputMultiplier: Double
  public var longContextOutputMultiplier: Double

  public init(
    input: Double,
    cachedInput: Double?,
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

public struct CostEstimate: Codable, Equatable, Sendable {
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
  public var hasEstimate: Bool { pricedTokens > 0 || unpricedTokens == 0 }
  public var coveragePercent: Double {
    let total = Double(pricedTokens) + Double(unpricedTokens)
    return total > 0 ? Double(pricedTokens) / total * 100 : 100
  }
  public var coverageLabel: String { "计价覆盖 \(Int(coveragePercent.rounded()))%" }
  public var displayUSD: String {
    hasEstimate ? String(format: "$%.2f", usd) + (isPartial ? "（部分）" : "") : "暂无法估算"
  }
}

public struct ModelPricingCatalog: Sendable {
  public static var current: ModelPricingCatalog { ModelPricingStore.shared.snapshot().catalog }
  public let rates: [String: ModelPricing]
  public init(rates: [String: ModelPricing]? = nil) {
    self.rates = rates ?? ModelPricingStore.shared.snapshot().catalog.rates
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
      if let cachedRate = rate.cachedInputPerMillionUSD {
        result.usd += Double(cached) / 1_000_000 * cachedRate * inputMultiplier
      } else if cached > 0 {
        result.unpricedTokens += cached
        unknown.insert(event.model)
      }
      result.usd += Double(max(0, event.outputTokens)) / 1_000_000 * rate.outputPerMillionUSD * outputMultiplier
      result.pricedTokens += max(0, event.totalTokens - (rate.cachedInputPerMillionUSD == nil ? cached : 0))
    }
    result.unpricedModels = unknown.sorted()
    return result
  }
}
