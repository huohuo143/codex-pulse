import Foundation
import CodexMobileCore

struct CodexRadarTiboHistory: Codable, Sendable {
  var resetAt: Date?
  var posts: [CodexRadarTiboPost]
  var lastAttemptAt: Date? = nil
  var lastSuccessAt: Date? = nil
  var feedUpdatedAt: Date? = nil
  var feedFingerprint: String? = nil
  var consecutiveFailures: Int? = nil
  // The scoring archive clears at a reset; the last public timeline does not
  // discard ordinary posts before the UI can display them.
  var latestPosts: [CodexRadarTiboPost]? = nil
  var retryNotBefore: Date? = nil
  var lastFailureMessage: String? = nil
  var recentSyncAttempts: [CodexRadarSyncAttempt]? = nil
  var analysis: CodexRadarTiboAnalysis? = nil
  var analysisLastAttemptAt: Date? = nil
  var analysisFailureMessage: String? = nil
  var latestAnnouncementAt: Date? = nil
  var announcementBoundaryVersion: Int? = nil
  var sourceID: String? = nil
  var readRoute: TiboReadRoute? = nil
  var sourceChecks: [TiboSourceCheck]? = nil

  mutating func retainRecent(at now: Date) {
    posts = CodexRadarTiboAnalyzer.retained(posts, at: now)
    latestPosts = latestPosts.map { CodexRadarTiboAnalyzer.retained($0, at: now) }
    let cutoff = now.addingTimeInterval(-CodexRadarTiboAnalyzer.retention)
    recentSyncAttempts = recentSyncAttempts?.filter { $0.completedAt >= cutoff }
    let retainedIDs = Set((posts + (latestPosts ?? [])).map(\.id))
    if analysis?.analyzedAt.map({ $0 < cutoff }) == true
      || analysis.map({ !Set($0.evidenceIDs).isSubset(of: retainedIDs) }) == true { analysis = nil }
    if analysisLastAttemptAt.map({ $0 < cutoff }) == true {
      analysisLastAttemptAt = nil; analysisFailureMessage = nil
    }
    recordAnnouncement(at: now)
  }

  mutating func recordAnnouncement(at now: Date) {
    let cutoff = now.addingTimeInterval(-CodexRadarTiboAnalyzer.retention)
    let anchoredDate = analysis?.announcementPublishedAt(in: posts + (latestPosts ?? []), at: now)
    if announcementBoundaryVersion != 1, let anchoredDate {
      // Previous releases took the latest timestamp from all model evidence.
      // Rebuild that boundary once from the actual announcement. If the source
      // is uncertain or unavailable, retain its boundary until it can be checked.
      latestAnnouncementAt = anchoredDate
      announcementBoundaryVersion = 1
    }
    latestAnnouncementAt = [latestAnnouncementAt, anchoredDate]
      .compactMap { $0 }.filter { $0 >= cutoff && $0 <= now }.max()
  }
}

struct CodexRadarSyncAttempt: Codable, Sendable {
  var startedAt: Date
  var completedAt: Date
  var succeeded: Bool
  var failureMessage: String?
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
