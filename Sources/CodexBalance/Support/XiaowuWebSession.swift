import AppKit
import CodexBalanceCore
import SwiftUI
import WebKit

struct XiaowuHTTPResponse: Sendable {
  let status: Int
  let contentType: String
  let data: Data
}

@MainActor
protocol XiaowuCloudTransport: AnyObject {
  func request(path: String, method: String, body: Data?, contentType: String) async throws -> XiaowuHTTPResponse
}

/// The official site owns sign-in. Fetches run in its origin; cookies are never inspected or exported.
@MainActor
final class XiaowuWebSession: NSObject, XiaowuCloudTransport, WKNavigationDelegate {
  private lazy var webView: WKWebView = {
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .default()
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 760), configuration: configuration)
    view.navigationDelegate = self
    return view
  }()
  private var window: NSWindow?
  private var loaded = false

  func showLogin() { show(path: "/zh/login") }
  func showConfiguration() { show(path: "/zh/config") }

  private func show(path: String) {
    if window == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 800),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
      window.title = "小悟云 · 官方登录与设备配置"; window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: XiaowuBrowser(webView: webView))
      window.center(); self.window = window
    }
    loaded = false
    webView.load(URLRequest(url: XiaowuCloudContract.origin.appendingPathComponent(String(path.dropFirst()))))
    window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }

  func request(path: String, method: String, body: Data?, contentType: String) async throws -> XiaowuHTTPResponse {
    guard path.hasPrefix("/api/"), !path.hasPrefix("//"), ["GET", "POST"].contains(method),
      URL(string: path, relativeTo: XiaowuCloudContract.origin)?.host == XiaowuCloudContract.origin.host else {
      throw XiaowuCloudError.unsupported
    }
    if webView.url == nil {
      webView.load(URLRequest(url: XiaowuCloudContract.origin.appendingPathComponent("zh")))
    }
    let deadline = Date().addingTimeInterval(20)
    while !loaded, Date() < deadline {
      try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(200))
    }
    guard loaded, webView.url?.host == XiaowuCloudContract.origin.host else { throw XiaowuCloudError.unavailable }
    try Task.checkCancellation()
    let response: XiaowuHTTPResponse = try await withCheckedThrowingContinuation { continuation in
      webView.callAsyncJavaScript(Self.fetchScript,
        arguments: ["path": path, "method": method, "body64": body?.base64EncodedString() ?? "", "contentType": contentType],
        in: nil, in: .page) { result in
        switch result {
        case .failure: continuation.resume(throwing: XiaowuCloudError.unavailable)
        case .success(let raw):
          guard let object = raw as? [String: Any], let status = object["status"] as? Int,
            let contentType = object["contentType"] as? String, let text = object["body64"] as? String,
            let bytes = Data(base64Encoded: text), bytes.count <= 8*1024*1024 else {
            continuation.resume(throwing: XiaowuCloudError.unsupported); return
          }
          continuation.resume(returning: XiaowuHTTPResponse(status: status, contentType: contentType, data: bytes))
        }
      }
    }
    try Task.checkCancellation()
    return response
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loaded = false }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loaded = false }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
    guard let url = navigationAction.request.url, url.scheme == "https", url.host == XiaowuCloudContract.origin.host else { return .cancel }
    loaded = false
    return .allow
  }

  private static let fetchScript = #"""
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 20000);
  try {
    const options = {method, credentials:'include', cache:'no-store', redirect:'error', signal:controller.signal};
    if (method !== 'GET') {
      const raw = atob(body64); const bytes = new Uint8Array(raw.length);
      for (let i=0;i<raw.length;i++) bytes[i]=raw.charCodeAt(i);
      options.body = bytes; options.headers = {'Content-Type':contentType};
    }
    const response = await fetch(path, options);
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length > 8*1024*1024) throw new Error('Response too large');
    let binary = '';
    for (let i=0;i<bytes.length;i+=16384) binary += String.fromCharCode(...bytes.subarray(i,i+16384));
    return {status:response.status,contentType:response.headers.get('Content-Type')||'',body64:btoa(binary)};
  } finally { clearTimeout(timeout); }
  """#
}

private struct XiaowuBrowser: View {
  let webView: WKWebView
  var body: some View {
    VStack(spacing: 0) {
      Text("请在小悟官方页面自行登录、绑定设备。完成后回到 Codex 脉动，点击“读取绑定设备”。")
        .font(.callout).padding(12)
      XiaowuWebView(webView: webView)
    }
  }
}
private struct XiaowuWebView: NSViewRepresentable {
  let webView: WKWebView
  func makeNSView(context: Context) -> WKWebView { webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
