import AppKit
import CodexBalanceCore
import SwiftUI
import Testing
@testable import CodexBalance

@Suite("Reset calendar desktop view", .serialized)
struct ResetCalendarViewTests {
  @MainActor @Test func navigationShowsCalendar() {
    let store = DashboardStore(startServices: false)
    // Selection participates in the same segmented navigation as existing pages.
    store.selectedSection = .resetCalendar
    #expect(store.selectedSection.title == "重置日历")
    #expect(DashboardSection.allCases.count == 5)
  }

  @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"] != nil))
  func renderCalendarAtMinimumWindowSizeInBothThemes() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let now = CodexResetCalendarDates.date("2026-10-18")!
    var snapshot = CodexResetCalendarSnapshot()
    snapshot.lastSuccessAt = now
    snapshot.monthlyTotals = [.init(month: "2026-10", hardResets: 7, resetCards: 2)]
    snapshot.events = [
      .init(id: "fixture-hard", kind: .hardReset, day: "2026-10-18", confirmation: .community,
        title: "重置完成 · 社区反馈确认", summary: "具体时分未知；同一天可以查看多条事件。"),
      .init(id: "fixture-card", kind: .resetCard, day: "2026-10-18", confirmation: .publicArchive,
        title: "重置卡发放完成", summary: "公开历史说明记载该批次已发放，实际时分未知。")
    ]
    snapshot.events[1].historicalCatalogRevision = 1
    snapshot.events[1].corroborationURLs = [URL(string: "https://resetcue.com/history")!]
    snapshot.events[1].evidenceURL = URL(string: "https://x.com/thsottiaux/status/2067399435009622521")!
    _ = NSApplication.shared
    for scheme in [ColorScheme.light, .dark] {
      let view = ScrollView { ResetCalendarView(snapshot: snapshot, tint: .teal, isLoading: false, refresh: {}, now: now).padding(20) }
        .environment(\.colorScheme, scheme).frame(width: 640, height: 760)
      let host = NSHostingView(rootView: view)
      let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host
      host.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("reset-calendar-\(scheme == .dark ? "dark" : "light")-640.png"))
      window.close()
    }
  }
}
