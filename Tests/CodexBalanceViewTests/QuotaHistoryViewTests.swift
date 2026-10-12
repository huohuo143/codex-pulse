import AppKit
import SwiftUI
import Testing
import CodexBalanceCore
@testable import CodexBalance

@Suite("Quota history interface", .serialized)
struct QuotaHistoryViewTests {
  @MainActor @Test func switchingAccountImmediatelyClearsDisplayedHistory() {
    let store = DashboardStore(startServices: false)
    let now = Date()
    store.quotaHistory = [.init(recordedAt: now, remainingPercent: 50, resetsAt: now.addingTimeInterval(1000), windowMinutes: 10080)]
    store.quotaForecast = .init(generatedAt: now, currentRemainingPercent: 50)
    store.prepareAccount("another-account")
    #expect(store.quotaHistory.isEmpty)
    #expect(store.quotaForecast == nil)
  }

  @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"] != nil))
  func renderHistoryWithGapsAndEmptyState() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = DashboardStore(startServices: false)
    let now = Date()
    let reset = now.addingTimeInterval(2 * 86_400)
    for scheme in [ColorScheme.light, .dark] {
      for empty in [false, true] {
        store.quotaHistory = empty ? [] : (0..<90).map { index in
          let gap: Double = index < 45 ? 4 * 86_400 : 0
          return .init(recordedAt: now.addingTimeInterval(-Double(90 - index) * 1800 - gap),
            remainingPercent: index < 45 ? 85 - Double(index) : 95 - Double(index - 45),
            resetsAt: index < 45 ? now.addingTimeInterval(-86_400) : reset, windowMinutes: 10080)
        }
        let view = QuotaHistoryView().environmentObject(store).environment(\.colorScheme, scheme)
          .padding(20).frame(width: 640, height: 420)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let name = "quota-history-\(scheme == .dark ? "dark" : "light")-\(empty ? "empty" : "data").png"
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name))
        window.close()
      }
    }
  }
}
