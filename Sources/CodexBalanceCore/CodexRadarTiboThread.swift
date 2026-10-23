import Foundation

enum CodexRadarTiboThread {
  static func readerURL(for post: CodexRadarTiboPost) -> URL? {
    guard let url = post.url, url.scheme == "https", url.host == "x.com",
          url.path == "/thsottiaux/status/\(post.id)",
          !post.id.isEmpty, post.id.allSatisfy(\.isNumber) else { return nil }
    return URL(string: "https://r.jina.ai/https://x.com/thsottiaux/status/\(post.id)")
  }

  static func validated(_ data: Data, for post: CodexRadarTiboPost) throws -> String {
    guard readerURL(for: post) != nil, data.count <= 100_000,
          let text = String(data: data, encoding: .utf8),
          text.components(separatedBy: .newlines).contains("URL Source: https://x.com/thsottiaux/status/\(post.id)"),
          !post.originalText.isEmpty, text.contains(post.originalText),
          let start = text.range(of: "Markdown Content:") else { throw CodexRadarError.invalidPayload }
    let context = String(text[start.upperBound...].prefix(6000))
    guard context.contains(post.originalText) else { throw CodexRadarError.invalidPayload }
    return context
  }

  static func enrich(_ posts: [CodexRadarTiboPost], previous: [CodexRadarTiboPost], activeDeadlineID: String? = nil,
                     activeEvidenceIDs: [String] = [], at now: Date = Date(),
                     fetcher: CodexRadarService.ThreadFetcher) async -> [CodexRadarTiboPost] {
    var result = posts
    let latest = Array(posts.indices.sorted {
      if posts[$0].publishedAt != posts[$1].publishedAt {
        return (posts[$0].publishedAt ?? .distantPast) > (posts[$1].publishedAt ?? .distantPast)
      }
      return posts[$0].id > posts[$1].id
    }.prefix(6))
    // Recheck the pending announcement and its deadline even after unrelated
    // posts arrive. Two priority slots leave room for other recent threads.
    var seen = Set<String>()
    let priorityIDs = ([activeDeadlineID].compactMap { $0 } + activeEvidenceIDs)
      .filter { seen.insert($0).inserted }.prefix(2)
    let priority = priorityIDs.compactMap { id in posts.firstIndex { $0.id == id } }
    let candidates = priority + latest.filter { !priority.contains($0) }
    for i in candidates {
      if let cached = previous.first(where: { $0.id == posts[i].id && $0.originalText == posts[i].originalText }) {
        result[i].threadContext = cached.threadContext
        result[i].threadContextCheckedAt = cached.threadContextCheckedAt
        result[i].threadContextAttemptedAt = cached.threadContextAttemptedAt
      }
    }

    // Rotate non-priority threads by their last attempt so one failure cannot
    // starve the remaining replies. Legacy caches have no timestamp and are due.
    let rotated = candidates.filter { !priority.contains($0) }.sorted {
      let left = result[$0].threadContextAttemptedAt ?? .distantPast
      let right = result[$1].threadContextAttemptedAt ?? .distantPast
      return left == right ? candidates.firstIndex(of: $0)! < candidates.firstIndex(of: $1)! : left < right
    }
    var requests = 0
    for i in priority + rotated {
      guard readerURL(for: posts[i]) != nil else { continue }
      if let attempted = result[i].threadContextAttemptedAt,
         attempted <= now, now.timeIntervalSince(attempted) < CodexRadarService.refreshInterval { continue }
      guard requests < 3 else { break }
      requests += 1
      result[i].threadContextAttemptedAt = now
      if let context = try? await fetcher(posts[i]), !context.isEmpty {
        result[i].threadContext = context
        result[i].threadContextCheckedAt = now
      }
      // A failed supplementary read keeps the last verified relationship and
      // its original timestamp; it never pretends the cached thread is fresh.
    }
    return result
  }
}
