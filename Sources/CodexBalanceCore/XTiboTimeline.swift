import Foundation

public enum XTiboTimeline {
  public static let profileURL = URL(string: "https://x.com/thsottiaux/with_replies")!
  public struct Post: Codable, Equatable, Sendable {
    public var url: String
    public var date: String
    public var text: String
  }
  public struct Page: Codable, Sendable {
    public var pageURL: String
    public var requiresLogin: Bool
    public var posts: [Post]
  }
  public enum ReadError: Error, LocalizedError {
    case loginRequired, wrongPage, empty, busy, unavailable
    public var errorDescription: String? {
      switch self {
      case .loginRequired: "X 要求登录。请在设置中打开 X 并完成登录，或切回默认公开源。"
      case .wrongPage: "X 当前不在 Tibo 发帖与回复页面，请返回 Tibo 页面，或切回公开源。"
      case .empty: "X 没有返回可核验的最近动态，可能尚未加载或页面结构已变化；这不代表没有重置预告。"
      case .busy: "X 页面正在使用，请完成登录后关闭 X 窗口，下一轮会继续读取。"
      case .unavailable: "X 页面读取失败，请打开 X 检查登录或网络，也可切回默认公开源。"
      }
    }
  }
  public static func isProfileURL(_ url: URL?) -> Bool {
    guard let url, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
          ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(url.host?.lowercased() ?? "") else { return false }
    return ["/thsottiaux", "/thsottiaux/", "/thsottiaux/with_replies", "/thsottiaux/with_replies/"].contains(url.path.lowercased())
  }
  public static func posts(from data: Data, at now: Date) throws -> [Post] {
    guard data.count <= 1_000_000 else { throw ReadError.unavailable }
    let page = try JSONDecoder().decode(Page.self, from: data)
    if page.requiresLogin { throw ReadError.loginRequired }
    guard isProfileURL(URL(string: page.pageURL)), page.posts.count <= 200 else { throw ReadError.wrongPage }
    var seen = Set<String>()
    let formatter = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
    let valid = page.posts.filter { item in
      guard let url = URL(string: item.url), url.scheme == "https", url.host?.lowercased() == "x.com",
            url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
            url.path.range(of: #"^/thsottiaux/status/[0-9]+$"#, options: .regularExpression) != nil,
            let date = fractional.date(from: item.date) ?? formatter.date(from: item.date),
            date <= now, date >= now.addingTimeInterval(-7 * 86400),
            !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.text.count <= 30_000
      else { return false }
      return seen.insert(url.path).inserted
    }
    guard !valid.isEmpty else { throw ReadError.empty }
    return valid
  }
  /// Serialize only validated public Tibo articles into the existing, tested
  /// feed parser. Cookies, page chrome, other accounts and login forms never enter it.
  public static func feedHTML(posts: [Post], checkedAt: Date) throws -> Data {
    let page = Page(pageURL: profileURL.absoluteString, requiresLogin: false, posts: posts)
    let valid = try self.posts(from: JSONEncoder().encode(page), at: checkedAt)
    func escaped(_ value: String) -> String {
      value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
    let rows = valid.map { post in
      let id = URL(string: post.url)!.lastPathComponent
      return """
      <li class="reset-tibo-post" data-tibo-post-id="\(id)" data-reset-relevance="unknown">
      <a href="\(escaped(post.url))">Tibo</a><time datetime="\(escaped(post.date))"></time>
      <p class="reset-tibo-post-original">\(escaped(post.text))</p></li>
      """
    }.joined()
    return Data("""
    <section class="desktop-tibo-radar" data-tibo-posts-updated-at="\(ISO8601DateFormatter().string(from: checkedAt))">\(rows)</section>
    """.utf8)
  }
}
