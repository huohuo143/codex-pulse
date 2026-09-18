import Foundation

struct CodexRadarTiboHistory: Codable, Sendable {
  var resetAt: Date?
  var posts: [CodexRadarTiboPost]
  var lastAttemptAt: Date? = nil
  var lastSuccessAt: Date? = nil
  var feedUpdatedAt: Date? = nil
  var feedFingerprint: String? = nil
  var consecutiveFailures: Int? = nil
}

enum CodexRadarTiboHistoryStore {
  static var defaultURL: URL? {
    PulsePaths.support.appendingPathComponent("codex-radar-tibo-history.json")
  }

  static func load(from url: URL) -> CodexRadarTiboHistory? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(CodexRadarTiboHistory.self, from: data)
  }

  static func save(_ history: CodexRadarTiboHistory, to url: URL) {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(history)
      try data.write(to: url, options: .atomic)
    } catch {
      // The live snapshot remains usable even if optional history persistence fails.
    }
  }

}
