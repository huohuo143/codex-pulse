import AppKit
import CodexBalanceCore
import SwiftUI
import WebKit

/// Owned by DashboardStore. WebKit alone stores this app's X login locally.
/// No browser-profile extraction, cookie export or background login is performed.
@MainActor
final class LocalXTiboSource: NSObject, WKNavigationDelegate {
  private lazy var webView: WKWebView = {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 760), configuration: configuration)
    view.navigationDelegate = self
    return view
  }()
  private var window: NSWindow?
  private var collecting = false
  private var activeNavigation: WKNavigation?
  private var navigationFinished = false
  private var navigationFailed = false

  func show() {
    if window == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
      window.title = "X · Tibo 发帖与回复"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: XBrowserView(webView: webView) { [weak self] in
        self?.webView.load(URLRequest(url: XTiboTimeline.profileURL))
      })
      window.center(); self.window = window
    }
    if webView.url == nil { webView.load(URLRequest(url: XTiboTimeline.profileURL)) }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func fetch(knownPostIDs: [String] = []) async throws -> Data {
    guard !collecting, window?.isVisible != true else { throw XTiboTimeline.ReadError.busy }
    collecting = true
    defer { collecting = false }
    navigationFinished = false; navigationFailed = false
    activeNavigation = webView.load(URLRequest(url: XTiboTimeline.profileURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
    let startedAt = Date()
    let deadline = startedAt.addingTimeInterval(40)
    let earliestCompletion = startedAt.addingTimeInterval(20)
    var nextScrollAt = startedAt
    var posts: [XTiboTimeline.Post] = []
    var seen = Set<String>()
    var scrolls = 0
    var previousCount = 0
    var unchanged = 0
    while Date() < deadline {
      try Task.checkCancellation()
      if window?.isVisible == true { throw XTiboTimeline.ReadError.busy }
      try await Task.sleep(for: .seconds(1))
      if navigationFailed { throw XTiboTimeline.ReadError.unavailable }
      guard navigationFinished else { continue }
      let raw = try await evaluate(Self.collectionScript)
      guard let data = raw.data(using: .utf8),
            let page = try? JSONDecoder().decode(XTiboTimeline.Page.self, from: data) else { continue }
      if page.requiresLogin { throw XTiboTimeline.ReadError.loginRequired }
      guard XTiboTimeline.isProfileURL(URL(string: page.pageURL)) else { continue }
      if let batch = try? XTiboTimeline.posts(from: data, at: Date()) {
        posts += batch.filter { seen.insert($0.url).inserted }
      }
      if posts.isEmpty { continue }
      if posts.count == previousCount { unchanged += 1 } else { unchanged = 0 }
      if posts.count >= 150 { break }
      // Background WebKit may hydrate the rest of a timeline after its first
      // articles. Give each scroll time to load before declaring it exhausted.
      if Date() >= earliestCompletion, unchanged >= 6,
         (scrolls >= 8 || Date() >= nextScrollAt) { break }
      previousCount = posts.count
      if scrolls < 8, Date() >= nextScrollAt {
        _ = try await evaluate("window.scrollBy(0, Math.max(600, window.innerHeight * 0.8)); 'scrolled'")
        scrolls += 1
        nextScrollAt = Date().addingTimeInterval(3)
      }
    }
    // X can virtualize a background profile down to its first few articles.
    // Read missing recent originals at their own public URLs before using mirrors.
    let originalsDeadline = startedAt.addingTimeInterval(90)
    for id in knownPostIDs.prefix(10) {
      guard Date() < originalsDeadline, posts.count < 150 else { break }
      guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }),
            let url = URL(string: "https://x.com/thsottiaux/status/\(id)"),
            !seen.contains(url.absoluteString) else { continue }
      try Task.checkCancellation()
      if window?.isVisible == true { throw XTiboTimeline.ReadError.busy }
      navigationFinished = false; navigationFailed = false
      activeNavigation = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12))
      let postDeadline = min(Date().addingTimeInterval(12), originalsDeadline)
      while Date() < postDeadline {
        try Task.checkCancellation()
        if window?.isVisible == true { throw XTiboTimeline.ReadError.busy }
        try await Task.sleep(for: .milliseconds(500))
        if navigationFailed { break }
        guard navigationFinished else { continue }
        let raw = try await evaluate(Self.collectionScript)
        guard let data = raw.data(using: .utf8), let page = try? JSONDecoder().decode(XTiboTimeline.Page.self, from: data) else { continue }
        if page.requiresLogin { throw XTiboTimeline.ReadError.loginRequired }
        guard URL(string: page.pageURL) == url else { continue }
        if let batch = try? XTiboTimeline.posts(from: data, at: Date()) {
          posts += batch.filter { seen.insert($0.url).inserted }
        }
        if seen.contains(url.absoluteString) { break }
      }
    }
    guard !posts.isEmpty else { throw XTiboTimeline.ReadError.empty }
    return try XTiboTimeline.feedHTML(posts: Array(posts.prefix(150)), checkedAt: Date())
  }

  private func evaluate(_ script: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      webView.evaluateJavaScript(script) { value, error in
        if let error { continuation.resume(throwing: error) }
        else if let text = value as? String { continuation.resume(returning: text) }
        else { continuation.resume(throwing: XTiboTimeline.ReadError.unavailable) }
      }
    }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if navigation === activeNavigation { navigationFinished = true }
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    if navigation === activeNavigation { navigationFailed = true }
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    if navigation === activeNavigation { navigationFailed = true }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
    guard let url = navigationAction.request.url, url.scheme == "https",
          let host = url.host?.lowercased(),
          host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" || host.hasSuffix(".twitter.com")
    else { return .cancel }
    return .allow
  }

  static let collectionScript = #"""
  (() => {
    const url = new URL(location.href);
    const isTiboPage = /^(www\.)?(x|twitter)\.com$/.test(url.hostname) && /^\/thsottiaux(?:\/with_replies|\/status\/[0-9]+)?\/?$/i.test(url.pathname);
    const signedIn = !!document.querySelector('[data-testid="SideNav_AccountSwitcher_Button"]');
    const loginForm = !!document.querySelector('input[autocomplete="username"],input[type="password"]');
    const requiresLogin = /\/i\/(?:flow\/login|jf\/onboarding)|\/login/.test(url.pathname) || loginForm;
    const posts = [];
    if (isTiboPage) for (const article of document.querySelectorAll('article[data-testid="tweet"]')) {
      const time = article.querySelector('time[datetime]');
      const anchor = time && time.closest('a[href]');
      const text = article.querySelector('[data-testid="tweetText"]');
      const mediaKind = article.querySelector('[data-testid="videoPlayer"]') ? 'video'
        : article.querySelector('[data-testid="tweetPhoto"]') ? 'image' : null;
      if (!anchor || (!text && !mediaKind)) continue;
      const link = new URL(anchor.href, location.origin);
      if (!/^\/thsottiaux\/status\/[0-9]+$/i.test(link.pathname)) continue;
      posts.push({url: 'https://x.com' + link.pathname, date: time.getAttribute('datetime'), text: text ? text.innerText : '', mediaKind});
      if (posts.length >= 150) break;
    }
    return JSON.stringify({pageURL: location.href, requiresLogin: requiresLogin || (!signedIn && !!document.querySelector('a[href="/login"]')), posts});
  })()
  """#
}

private struct XBrowserView: View {
  let webView: WKWebView
  let returnToTibo: () -> Void
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("如 X 要求登录，请自行登录；登录状态仅由本机 WebKit 保存。")
        Spacer()
        Button("返回 Tibo 发帖与回复", action: returnToTibo)
      }.font(.caption).padding(12)
      Text("完成后关闭此窗口，后台按北京时间分时段每 3–20 分钟优先读取 X（16:00–21:00 暂停）。窗口使用中、登录失效或读取失败时自动使用备用网站。")
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
      XWebView(webView: webView)
    }
  }
}
private struct XWebView: NSViewRepresentable {
  let webView: WKWebView
  func makeNSView(context: Context) -> WKWebView { webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
