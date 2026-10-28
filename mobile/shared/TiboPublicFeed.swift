import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public post discovery only. Third-party classifications and deadlines are not imported.
public enum TiboPublicSource: String, Codable, CaseIterable, Sendable {
  case codexradar, tiboreset, didcodexreset
  public var url: URL {
    switch self {
    case .codexradar: URL(string: "https://codexradar.com/")!
    case .tiboreset: URL(string: "https://tiboreset.com/")!
    case .didcodexreset: URL(string: "https://didcodexreset.com/api/status.json")!
    }
  }
  public var label: String {
    switch self { case .codexradar: "Codex Radar"; case .tiboreset: "Tibo Reset"; case .didcodexreset: "Did Codex Reset" }
  }
}

public struct TiboPublicPost: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var url: String
  public var publishedAt: Date
  public var originalText: String
  public var sources: [TiboPublicSource]
}

public struct TiboSourceCheck: Codable, Equatable, Sendable, Identifiable {
  public var source: TiboPublicSource
  public var checkedAt: Date
  public var succeeded: Bool
  public var latestPostAt: Date?
  public var retryNotBefore: Date?
  public var id: String { source.rawValue }
  public init(source: TiboPublicSource, checkedAt: Date, succeeded: Bool, latestPostAt: Date? = nil, retryNotBefore: Date? = nil) {
    self.source=source; self.checkedAt=checkedAt; self.succeeded=succeeded
    self.latestPostAt=latestPostAt; self.retryNotBefore=retryNotBefore
  }
}

public struct TiboPublicFeed: Codable, Equatable, Sendable {
  public var posts: [TiboPublicPost]
  public var checks: [TiboSourceCheck]
  public var latestPostAt: Date? { posts.map(\.publishedAt).max() }
  public var succeeded: Bool { checks.contains { $0.succeeded } }
  public var statusText: String {
    let count=checks.filter(\.succeeded).count
    return count == 0 ? "公开来源读取失败，保留上次动态" : "已检查 \(count)/\(checks.count) 个公开来源；收录可能延迟"
  }
  public init(posts: [TiboPublicPost] = [], checks: [TiboSourceCheck] = []) { self.posts=posts; self.checks=checks }
  public func merging(previous: TiboPublicFeed?, at now: Date) -> TiboPublicFeed {
    .init(posts: TiboPublicFeedParser.merge(posts + (previous?.posts ?? []), at: now), checks: checks)
  }
}

public struct TiboPublicFeedBundle: Codable, Sendable {
  public var format = "codex-pulse-tibo-multisource-v1"
  public var feed: TiboPublicFeed
  public var primaryHTML: String?
  public init(feed: TiboPublicFeed, primaryHTML: String?) { self.feed=feed; self.primaryHTML=primaryHTML }
}

public enum TiboPublicFeedParser {
  public static let retention: TimeInterval = 7 * 86400
  public static let refreshInterval: TimeInterval = 600
  public enum ReadError: Error { case invalidData, unavailable }
  public static func parse(_ data: Data, source: TiboPublicSource, at now: Date) throws -> [TiboPublicPost] {
    guard data.count <= 4_000_000, let text=String(data:data,encoding:.utf8) else { throw ReadError.invalidData }
    var posts: [TiboPublicPost] = []
    switch source {
    case .codexradar:
      guard text.contains("desktop-tibo-radar") else { throw ReadError.invalidData }
      for row in matches(#"<li\b[^>]*data-tibo-post-id[^>]*>.*?</li>"#, text) {
        let original=classText("reset-tibo-post-original", row).replacingOccurrences(of:#"^英文原文\s*"#,with:"",options:.regularExpression)
        if let post=post(url:attribute("href",row), date:attribute("datetime",row), text:original, source:source, now:now), post.id == attribute("data-tibo-post-id",row) { posts.append(post) }
      }
    case .tiboreset:
      for row in matches(#"<li\b[^>]*class=["'][^"']*\blog-item\b[^"']*["'][^>]*>.*?</li>"#, text) {
        let link=capture(#"<a\b[^>]*class=["'][^"']*\blog-item-link\b[^"']*["'][^>]*>"#,row) ?? ""
        let url = attribute("href",link), statedDate = attribute("data-ago",row)
        let date = statedDate.isEmpty ? snowflakeDate(url).map { ISO8601DateFormatter().string(from:$0) } ?? "" : statedDate
        if let post=post(url:url,date:date,text:classText("log-item-text",row),source:source,now:now) { posts.append(post) }
      }
    case .didcodexreset:
      struct Payload: Decodable { var events: [Event] }
      struct Event: Decodable { struct Source: Decodable { var handle: String; var postId: String; var url: String }; var source: Source; var announcedAt: String; var text: String }
      let payload=try JSONDecoder().decode(Payload.self,from:data)
      guard payload.events.count <= 1000 else { throw ReadError.invalidData }
      for event in payload.events where event.source.handle.lowercased() == "thsottiaux" {
        if let post=post(url:event.source.url,date:event.announcedAt,text:event.text,source:source,now:now), post.id == event.source.postId { posts.append(post) }
      }
    }
    let result=merge(posts,at:now)
    guard !result.isEmpty else { throw ReadError.invalidData }
    return result
  }
  public static func merge(_ posts: [TiboPublicPost], at now: Date) -> [TiboPublicPost] {
    var result: [String:TiboPublicPost] = [:]
    for post in posts where post.publishedAt <= now.addingTimeInterval(60) && post.publishedAt >= now.addingTimeInterval(-retention) {
      guard post.url.range(of:#"^https://x\.com/thsottiaux/status/[0-9]{10,25}$"#,options:.regularExpression) != nil,
        post.url.split(separator:"/").last.map(String.init) == post.id, !post.originalText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, post.originalText.count <= 30_000 else { continue }
      if var existing=result[post.id] {
        // Keep the first source's wording; never splice two versions of a post.
        existing.sources=Array(Set(existing.sources+post.sources)).sorted { $0.rawValue < $1.rawValue }
        result[post.id]=existing
      } else { result[post.id]=post }
    }
    return Array(result.values.sorted { $0.publishedAt == $1.publishedAt ? $0.id > $1.id : $0.publishedAt > $1.publishedAt }.prefix(150))
  }
  private static func post(url: String, date: String, text: String, source: TiboPublicSource, now: Date) -> TiboPublicPost? {
    guard url.range(of:#"^https://x\.com/thsottiaux/status/[0-9]{10,25}$"#,options:.regularExpression) != nil,
      let published=isoDate(date), published <= now.addingTimeInterval(60), published >= now.addingTimeInterval(-retention),
      !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.count <= 30_000 else { return nil }
    return .init(id:String(url.split(separator:"/").last!),url:url,publishedAt:published,originalText:text,sources:[source])
  }
  static func isoDate(_ value: String) -> Date? {
    let f=ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds)
    return f.date(from:value) ?? ISO8601DateFormatter().date(from:value)
  }
  // Challenge rows can omit data-ago. X Snowflake IDs encode their creation
  // timestamp; use UInt64 rather than a floating-point conversion of the ID.
  // https://docs.x.com/fundamentals/x-ids
  // twitter-archive/snowflake IdWorker: epoch 1288834974657, timestamp << 22.
  private static func snowflakeDate(_ url: String) -> Date? {
    guard url.range(of:#"^https://x\.com/thsottiaux/status/[0-9]{18,20}$"#,options:.regularExpression) != nil,
          let id = url.split(separator:"/").last.flatMap({ UInt64($0) }) else { return nil }
    return Date(timeIntervalSince1970: Double((id >> 22) + 1_288_834_974_657) / 1000)
  }
  private static func matches(_ pattern: String, _ text: String) -> [String] {
    guard let re=try? NSRegularExpression(pattern:pattern,options:[.caseInsensitive,.dotMatchesLineSeparators]) else { return [] }
    return re.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { Range($0.range,in:text).map { String(text[$0]) } }
  }
  private static func capture(_ pattern: String, _ text: String, group: Int = 0) -> String? {
    guard let re=try? NSRegularExpression(pattern:pattern,options:[.caseInsensitive,.dotMatchesLineSeparators]),let m=re.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),let r=Range(m.range(at:group),in:text) else { return nil }; return String(text[r])
  }
  private static func attribute(_ key: String, _ text: String) -> String { clean(capture("\\b"+key+#"\s*=\s*["']([^"']*)["']"#,text,group:1) ?? "") }
  private static func classText(_ key: String, _ text: String) -> String { clean(capture(#"<p\b[^>]*class=["'][^"']*\b"#+key+#"\b[^"']*["'][^>]*>(.*?)</p>"#,text,group:1) ?? "") }
  private static func clean(_ value: String) -> String {
    var text=value.replacingOccurrences(of:#"<[^>]*>"#,with:"",options:.regularExpression)
    if let re=try? NSRegularExpression(pattern:#"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
      for match in re.matches(in:text,range:NSRange(text.startIndex...,in:text)).reversed() {
        guard let r=Range(match.range,in:text),let n=Range(match.range(at:1),in:text) else { continue }
        let code=String(text[n]); let number=code.hasPrefix("x") ? UInt32(code.dropFirst(),radix:16) : UInt32(code)
        if let number,let scalar=UnicodeScalar(number) { text.replaceSubrange(r,with:String(scalar)) }
      }
    }
    for (a,b) in [("&quot;","\""),("&apos;","'"),("&lt;","<"),("&gt;",">"),("&nbsp;"," "),("&amp;","&")] { text=text.replacingOccurrences(of:a,with:b) }
    return text.trimmingCharacters(in:.whitespacesAndNewlines)
  }
}

public actor TiboPublicFeedClient {
  public typealias Fetcher = @Sendable (TiboPublicSource) async throws -> Data
  private var retryDates: [TiboPublicSource:Date] = [:]
  private let fetcher: Fetcher
  public init(fetcher: @escaping Fetcher = TiboPublicFeedClient.download) { self.fetcher=fetcher }
  public func refresh(at now: Date = Date()) async -> TiboPublicFeedBundle {
    let fetcher=self.fetcher, retryDates=self.retryDates
    let results=await withTaskGroup(of:(TiboSourceCheck,[TiboPublicPost],String?).self) { group in
      for source in TiboPublicSource.allCases {
        group.addTask {
          if let retry=retryDates[source],retry > now { return (.init(source:source,checkedAt:now,succeeded:false,retryNotBefore:retry),[],nil) }
          do {
            let data=try await fetcher(source)
            let posts=try TiboPublicFeedParser.parse(data,source:source,at:now)
            return (.init(source:source,checkedAt:now,succeeded:true,latestPostAt:posts.first?.publishedAt),posts,source == .codexradar ? String(data:data,encoding:.utf8) : nil)
          } catch {
            return (.init(source:source,checkedAt:now,succeeded:false,retryNotBefore:(error as? RetryError)?.until),[],nil)
          }
        }
      }
      var results:[(TiboSourceCheck,[TiboPublicPost],String?)]=[]
      for await result in group { results.append(result) }; return results
    }.sorted { a,b in TiboPublicSource.allCases.firstIndex(of:a.0.source)! < TiboPublicSource.allCases.firstIndex(of:b.0.source)! }
    for result in results { retryDatesUpdate(result.0) }
    let feed=TiboPublicFeed(posts:TiboPublicFeedParser.merge(results.flatMap { $0.1 },at:now),checks:results.map { $0.0 })
    return .init(feed:feed,primaryHTML:results.compactMap { $0.2 }.first)
  }
  private func retryDatesUpdate(_ check: TiboSourceCheck) { retryDates[check.source]=check.retryNotBefore }
  private struct RetryError: Error { var until: Date }
  public static func download(_ source: TiboPublicSource) async throws -> Data {
    let config=URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest=15; config.timeoutIntervalForResource=20
    config.httpCookieStorage=nil; config.httpShouldSetCookies=false; config.urlCache=nil
    let session=URLSession(configuration:config); defer { session.invalidateAndCancel() }
    var request=URLRequest(url:source.url,cachePolicy:.reloadIgnoringLocalAndRemoteCacheData,timeoutInterval:15)
    request.setValue("no-cache",forHTTPHeaderField:"Cache-Control")
    request.setValue("CodexPulse-Tibo/1.0",forHTTPHeaderField:"User-Agent")
    let (data,response)=try await session.data(for:request)
    guard let response=response as? HTTPURLResponse,response.url?.host == source.url.host else { throw TiboPublicFeedParser.ReadError.unavailable }
    if response.statusCode == 429 || response.statusCode == 503 {
      let seconds=response.value(forHTTPHeaderField:"Retry-After").flatMap(Double.init) ?? 600
      throw RetryError(until:Date().addingTimeInterval(max(600,seconds)))
    }
    guard response.statusCode == 200,data.count <= 4_000_000 else { throw TiboPublicFeedParser.ReadError.unavailable }; return data
  }
}
