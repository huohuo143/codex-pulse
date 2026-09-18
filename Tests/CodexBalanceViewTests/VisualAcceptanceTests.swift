import AppKit
import SwiftUI
import Testing
import CodexBalanceCore
@testable import CodexBalance

@Suite("App visual acceptance", .serialized)
struct VisualAcceptanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"] != nil))
  @MainActor func renderAllStylesAndWindowSizes() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = DashboardStore(startServices: false)
    let now = Date()
    let event = RateLimitEvent(timestamp: now, sourceName: "验收示例", sourcePath: "fixture", limitID: "codex", limitName: "Codex",
      primary: .init(usedPercent: 16, remainingPercent: 84, windowMinutes: 300, resetsAt: now.addingTimeInterval(7200)),
      secondary: .init(usedPercent: 32, remainingPercent: 68, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400)))
    let sample = SourceReadMetadata(source: "验收示例", sampledAt: now, lastAttemptAt: now, lastSuccessAt: now)
    let cost = CostEstimate(usd: 203.6, pricedTokens: 90_000_000, unpricedTokens: 10_000_000, unpricedModels: ["unknown-model"])
    var status = CodexStatus(codexHome: "fixture", sessionsRoot: "fixture", main: event, limits: [event],
      rateLimitResetCredits: .init(availableCount: 3, credits: (1...3).map { .init(grantedAt: now, expiresAt: now.addingTimeInterval(Double($0) * 86400)) }),
      flexibleCreditBalance: .init(hasCredits: true, balanceCredits: 2500),
      tokenStats: .init(rolling24HoursTokens: 120_000_000, todayTokens: 30_000_000, monthTokens: 950_000_000, last7DaysTokens: 420_000_000,
        sampleCount: 681, hourly: (0..<24).map { .init(key: "h\($0)", label: "\($0)时", totalTokens: ($0 % 5 + 1) * 10000) }, cost24Hours: cost, cost7Days: cost, costMonth: cost))
    status.quotaRead = sample; status.resetCreditsRead = sample; status.flexibleCreditRead = sample
    store.status = status; store.lastFullRefresh = now
    store.floatingPanelMetrics = Set(FloatingPanelMetric.allCases)
    store.quotaForecast = .init(generatedAt: now, currentRemainingPercent: 68, resetsAt: now.addingTimeInterval(86400),
      ratePerHour: 4, earliestExhaustion: now.addingTimeInterval(3600), estimatedExhaustion: now.addingTimeInterval(61200), latestExhaustion: now.addingTimeInterval(90000), risk: .critical)
    for scheme in [ColorScheme.light, .dark] {
      let tone = scheme == .light ? "light" : "dark"
      for size in [NSSize(width: 680, height: 860), NSSize(width: 640, height: 760)] {
        store.selectedSection = .overview
        try render(ExpandedDashboardView().environmentObject(store).environment(\.colorScheme, scheme).environment(\.dashboardAppearance, store.appearance).defaultAppStorage(PulsePreferences.shared),
          size: size, file: folder.appendingPathComponent("app-overview-\(tone)-\(Int(size.width)).png"))
      }
      for style in CompactStyle.allCases {
        store.compactStyle = style
        for mode in [CompactSizeMode.standard, .mini] {
          store.compactSizeMode = mode
          let size = WindowConfigurator.compactSize(for: mode, style: style, metrics: store.floatingPanelMetrics)
          try render(CompactDashboardView().environmentObject(store).environment(\.colorScheme, scheme).environment(\.dashboardAppearance, store.appearance),
            size: size, file: folder.appendingPathComponent("float-\(style.rawValue)-\(mode.rawValue)-\(tone).png"))
        }
      }
      for section in [DashboardSection.trends, .insights, .settings] {
        store.selectedSection = section
        try render(ExpandedDashboardView().environmentObject(store).environment(\.colorScheme, scheme).defaultAppStorage(PulsePreferences.shared),
          size: .init(width: 640, height: 760), file: folder.appendingPathComponent("app-\(section.rawValue)-\(tone).png"))
      }
    }
    print("VISUAL_APP rendered=42 output=\(folder.path)")
  }

  @MainActor private func render<V: View>(_ view: V, size: NSSize, file: URL) throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    #expect(rep.pixelsWide >= Int(size.width))
    #expect(rep.pixelsHigh >= Int(size.height))
    try #require(rep.representation(using: .png, properties: [:])).write(to: file)
    window.close()

  }
}
