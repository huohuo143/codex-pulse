import AppKit
import SwiftUI
import Testing
import CodexBalanceCore
@testable import CodexBalance

@Suite("Tibo freshness visual acceptance", .serialized)
@MainActor
struct TiboFreshnessViewTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"] != nil))
  func renderFreshExpiredFailedAndPendingStates() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = DashboardStore(startServices: false)
    store.floatingPanelMetrics = [.weeklyQuota, .resetRadar]
    store.compactStyle = .rings
    store.compactSizeMode = .standard
    let now = Date()
    let selectedModes = ProcessInfo.processInfo.environment["CODEX_PULSE_TIBO_RENDER_STATES"]?.split(separator: ",").map(String.init)
    for mode in ["fresh", "expired", "failed", "pending", "deadline", "completed", "new-cycle"] where selectedModes?.contains(mode) != false {
      var snapshot = try JSONDecoder().decode(CodexRadarSnapshot.self, from: Data("{}".utf8))
      let success = now.addingTimeInterval(mode == "expired" ? -720 : -60)
      snapshot.syncState = .init(lastAttemptAt: success, lastSuccessAt: success)
      var analysis = try JSONDecoder().decode(CodexRadarTiboAnalysis.self, from:
        Data(#"{"state":"announced","kind":"hard_reset","summaryZh":"明确预告了重置，实际完成待确认。","timingZh":"","evidenceIDs":[]}"#.utf8))
      analysis.analyzedAt = mode == "pending" ? success.addingTimeInterval(-1) : success
      if mode == "deadline" {
        let local = BalanceFormatters.beijingDeadline(now.addingTimeInterval(3600))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now.addingTimeInterval(3600))
        let stamp = String(format: "%04d-%02d-%02dT%02d:%02d:00", c.year!, c.month!, c.day!, c.hour!, c.minute!)
        let json: [String: String] = ["localDateTime": stamp, "sourceTimeZone": "北京时间", "evidenceID": "synthetic", "sourceQuote": "验收示例：重置最晚于北京时间 \(local) 到账。"]
        analysis.deadline = try JSONDecoder().decode(CodexRadarTiboDeadline.self, from: JSONSerialization.data(withJSONObject: json))
      }
      if mode == "completed" {
        analysis.state = .completed; analysis.completedAt = now.addingTimeInterval(-3600)
        analysis.summaryZh = "验收示例：Tibo 已确认重置到账。"
      }
      if mode == "new-cycle" {
        analysis.state = .completed; analysis.completedAt = now.addingTimeInterval(-86401)
      }
      snapshot.tiboAnalysis = analysis
      snapshot.tiboAnalysisAttemptAt = success
      if mode == "failed" { snapshot.tiboAnalysisFailure = "GPT-6 Astra 分析未完成，下一轮再试。" }
      store.codexRadarSnapshot = snapshot
      for scheme in [ColorScheme.light, .dark] {
        let card = CodexRadarView(snapshot: snapshot, palette: .mintDawn, isLoading: false,
          nextSyncAt: success.addingTimeInterval(600), statusMessage: "验收示例", refresh: {})
        try render(card.environment(\.colorScheme, scheme), size: .init(width: 640, height: 730),
          to: folder.appendingPathComponent("tibo-main-\(mode)-\(scheme).png"))
        let styles: [CompactStyle] = ["deadline", "completed", "new-cycle"].contains(mode) ? CompactStyle.allCases : [.rings]
        for style in styles {
          for sizeMode in [CompactSizeMode.standard, .mini] {
            store.compactStyle = style; store.compactSizeMode = sizeMode
            let size = WindowConfigurator.compactSize(for: sizeMode, style: style, metrics: store.floatingPanelMetrics)
            try render(CompactDashboardView().environmentObject(store).environment(\.colorScheme, scheme)
              .environment(\.dashboardAppearance, store.appearance), size: size,
              to: folder.appendingPathComponent("tibo-floating-\(mode)-\(style.rawValue)-\(sizeMode.rawValue)-\(scheme).png"))
          }
        }
      }
    }
    print("VISUAL_TIBO_FRESHNESS deadline-and-completion-all-styles output=\(folder.path)")
  }

  private func render<V: View>(_ view: V, size: NSSize, to url: URL) throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    host.frame = NSRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    #expect(rep.pixelsWide >= Int(size.width))
    try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    window.close()
  }
}
