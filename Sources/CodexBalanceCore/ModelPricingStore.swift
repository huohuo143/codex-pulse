import Foundation
import CryptoKit

public struct PricingDocument: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var verifiedAt: String
  public var models: [PricingRecord]
  public func validated() throws -> PricingDocument {
    guard schemaVersion == 1, ISO8601DateFormatter().date(from: verifiedAt) != nil,
          !models.isEmpty, models.count <= 500 else { throw PricingImportError.invalidDocument }
    var names = Set<String>()
    for row in models {
      guard !row.model.isEmpty, row.model == row.model.lowercased(),
            URL(string: row.sourceURL)?.scheme == "https",
            [row.input, row.cachedInput, row.output, row.longContextInputMultiplier, row.longContextOutputMultiplier].compactMap({ $0 })
              .allSatisfy({ $0.isFinite && $0 >= 0 }),
            row.longContextThresholdInputTokens.map({ $0 > 0 }) ?? true,
            row.longContextInputMultiplier >= 1, row.longContextOutputMultiplier >= 1 else {
        throw PricingImportError.invalidRate(row.model)
      }
      for key in [row.model] + row.aliases {
        guard !key.isEmpty, key == key.lowercased(), names.insert(key).inserted else {
          throw PricingImportError.duplicateModel(key)
        }
      }
    }
    return self
  }
  public var catalog: ModelPricingCatalog {
    var rates: [String: ModelPricing] = [:]
    for row in models {
      let price = ModelPricing(input: row.input, cachedInput: row.cachedInput, output: row.output,
        longContextThresholdInputTokens: row.longContextThresholdInputTokens,
        longContextInputMultiplier: row.longContextInputMultiplier, longContextOutputMultiplier: row.longContextOutputMultiplier)
      for key in [row.model] + row.aliases { rates[key] = price }
    }
    return ModelPricingCatalog(rates: rates)
  }
}

public struct PricingRecord: Codable, Equatable, Sendable {
  public var model: String
  public var aliases: [String]
  public var input: Double
  public var cachedInput: Double?
  public var output: Double
  public var longContextThresholdInputTokens: Int?
  public var longContextInputMultiplier: Double
  public var longContextOutputMultiplier: Double
  public var sourceURL: String
}

public enum PricingImportError: LocalizedError {
  case invalidDocument, invalidRate(String), duplicateModel(String)
  public var errorDescription: String? {
    switch self {
    case .invalidDocument: "价格表格式或核验日期无效（需要 schemaVersion 1）。"
    case .invalidRate(let model): "模型 \(model) 的价格、来源或长上下文规则无效。"
    case .duplicateModel(let model): "模型或别名重复：\(model)。"
    }
  }
}

/// Versioned, local-only configuration. A failed import never replaces the last
/// usable file. UI previews the validated merge before calling install().
public final class ModelPricingStore: @unchecked Sendable {
  public static let shared = ModelPricingStore()
  private let lock = NSLock()
  private let url: URL
  private var cachedSnapshot: (catalog: ModelPricingCatalog, version: String, description: String)?
  private var document: PricingDocument
  private var imported = false
  private let baseline: PricingDocument

  public init(url: URL = PulsePaths.support.appendingPathComponent("model-prices-imported-v1.json")) {
    self.url = url
    let file = Bundle.main.url(forResource: "model-prices-v1", withExtension: "json")
      ?? Bundle.module.url(forResource: "model-prices-v1", withExtension: "json")
    let loaded = file.flatMap { try? Data(contentsOf: $0) }
      .flatMap { try? JSONDecoder().decode(PricingDocument.self, from: $0).validated() }
    // Missing packaged data is explicit: every model remains unpriced.
    baseline = loaded ?? PricingDocument(schemaVersion: 1, verifiedAt: "1970-01-01T00:00:00Z", models: [])
    document = baseline
    if let data = try? Data(contentsOf: url),
       let candidate = try? JSONDecoder().decode(PricingDocument.self, from: data).validated() {
      document = candidate
      imported = true
    }
  }

  public func snapshot() -> (catalog: ModelPricingCatalog, version: String, description: String) {
    lock.lock(); defer { lock.unlock() }
    if let cachedSnapshot { return cachedSnapshot }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(document)) ?? Data()
    let version = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let result = (document.catalog, version, "\(imported ? "本机导入" : "内置官方价格") · 核验 \(document.verifiedAt.prefix(10))")
    cachedSnapshot = result
    return result
  }

  public func preview(data: Data) throws -> (document: PricingDocument, summary: String) {
    guard data.count <= 1_048_576 else { throw PricingImportError.invalidDocument }
    let incoming = try JSONDecoder().decode(PricingDocument.self, from: data).validated()
    lock.lock(); let previous = document; lock.unlock()
    let keys = Set(incoming.models.map(\.model))
    let merged = try PricingDocument(schemaVersion: 1, verifiedAt: incoming.verifiedAt,
      models: previous.models.filter { !keys.contains($0.model) } + incoming.models).validated()
    let details = incoming.models.map { row in
      let old = previous.models.first { $0.model == row.model }
      let before = old.map { "\($0.input)/\($0.cachedInput.map { String($0) } ?? "未公布")/\($0.output)" } ?? "未计价"
      return "\(row.model)：\(before) → \(row.input)/\(row.cachedInput.map { String($0) } ?? "未公布")/\(row.output)"
    }
    return (merged, "单位：USD / 百万 Token（输入 / 缓存输入 / 输出）\n" + details.joined(separator: "\n"))
  }

  public func install(_ candidate: PricingDocument) throws {
    let valid = try candidate.validated()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(valid)
    lock.lock(); defer { lock.unlock() }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: url.path) {
      let previous = try Data(contentsOf: url)
      let backup = url.deletingLastPathComponent().appendingPathComponent("model-prices-before-import-\(UUID().uuidString).json")
      try previous.write(to: backup, options: .atomic)
    }
    try data.write(to: url, options: .atomic)
    document = valid
    cachedSnapshot = nil
    imported = true
  }
}
