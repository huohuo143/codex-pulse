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
                     fetcher: CodexRadarService.ThreadFetcher) async -> [CodexRadarTiboPost] {
    var result = posts
    let candidates = posts.indices.sorted { (posts[$0].publishedAt ?? .distantPast) > (posts[$1].publishedAt ?? .distantPast) }.prefix(6)
    // An announced deadline remains relevant when ordinary new posts arrive.
    // Preserve its verified context without widening the network request budget.
    if let id = activeDeadlineID, let i = posts.firstIndex(where: { $0.id == id }),
       let cached = previous.first(where: { $0.id == id && $0.originalText == posts[i].originalText }) {
      result[i].threadContext = cached.threadContext
    }
    var requests = 0
    for i in candidates {
      guard readerURL(for: posts[i]) != nil else { continue }
      if let cached = previous.first(where: { $0.id == posts[i].id && $0.originalText == posts[i].originalText }),
         let context = cached.threadContext {
        result[i].threadContext = context
      } else if requests < 3 {
        requests += 1
        result[i].threadContext = try? await fetcher(posts[i])
      }
    }
    return result
  }
}
