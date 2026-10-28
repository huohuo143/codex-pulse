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
    let resetIDs = CodexRadarTiboAttention.previewPosts(posts, at: now, limit: 1)
      .filter { CodexRadarTiboAttention.isResetDayAnnouncement($0.originalText)
        && $0.publishedAt.map { $0 <= now && $0 > now.addingTimeInterval(-86400) } == true }.map(\.id)
    let priorityIDs = ([activeDeadlineID].compactMap { $0 } + resetIDs + activeEvidenceIDs)
      .filter { seen.insert($0).inserted }.prefix(2)
    let priority = priorityIDs.compactMap { id in posts.firstIndex { $0.id == id } }
    let focused = CodexRadarTiboAttention.previewPosts(posts, at: now, limit: posts.count)
      .filter { CodexRadarTiboAttention.label(for: $0) != nil
        && $0.publishedAt.map { $0 <= now && $0 > now.addingTimeInterval(-86400) } == true }
      .compactMap { post in posts.firstIndex { $0.id == post.id } }
    var candidateSet = Set<Int>()
    let candidates = (priority + focused + latest).filter { candidateSet.insert($0).inserted }
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
      let leftFocused = focused.contains($0), rightFocused = focused.contains($1)
      if leftFocused != rightFocused { return leftFocused }
      let left = result[$0].threadContextAttemptedAt ?? .distantPast
      let right = result[$1].threadContextAttemptedAt ?? .distantPast
      return left == right ? candidates.firstIndex(of: $0)! < candidates.firstIndex(of: $1)! : left < right
    }
    var requests = 0
    for i in priority + rotated {
      guard readerURL(for: posts[i]) != nil else { continue }
      if let attempted = result[i].threadContextAttemptedAt,
         attempted <= now, now.timeIntervalSince(attempted) < CodexRadarRefreshPolicy.tiboPollingInterval(at: now) { continue }
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
