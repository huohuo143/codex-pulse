import AppKit
import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var store: DashboardStore
  @Environment(\.openWindow) private var openWindow
  @State private var configuredWindow: NSWindow?
  @State private var lastManualMove: Date?
  private let dodgeTimer = Timer.publish(every: 45, on: .main, in: .common).autoconnect()

  var body: some View {
    Group {
      if store.isCompact {
        CompactDashboardView()
          .frame(
            width: compactWindowSize.width,
            height: compactWindowSize.height
          )
      } else {
        ExpandedDashboardView()
          .frame(width: WindowConfigurator.expandedSize.width, height: WindowConfigurator.expandedSize.height)
      }
    }
    .background(WindowAccessor { window in
      guard configuredWindow !== window else { return }
      configuredWindow = window
      WindowConfigurator.configure(
        window,
        compact: store.isCompact,
        compactSizeMode: store.compactSizeMode,
        compactStyle: store.compactStyle,
        toolCount: store.enabledToolCount,
        ringOrientation: store.compactRingOrientation,
        metrics: store.floatingPanelMetrics,
        keepPosition: false
      )
      store.syncWindowPresentation()
      autoDodgeIfNeeded(force: true)
    })
    .preferredColorScheme(store.themeMode.preferredColorScheme)
    .opacity(store.isWindowVisible ? 1 : 0)
    .environment(\.dashboardAppearance, store.appearance)
    .tint(store.palette.weekly)
    .onAppear {
      AppWindowRouter.shared.register { openWindow(id: "main") }
      store.startAutoRefresh()
    }
    .onDisappear {
      store.endWindowDrag()
    }
    .onChange(of: store.isCompact) { isCompact in
      if let configuredWindow {
        WindowConfigurator.configure(
          configuredWindow,
          compact: isCompact,
          compactSizeMode: store.compactSizeMode,
          compactStyle: store.compactStyle,
          toolCount: store.enabledToolCount,
          ringOrientation: store.compactRingOrientation,
          metrics: store.floatingPanelMetrics,
          keepPosition: false
        )
        autoDodgeIfNeeded(force: true)
      }
    }
    .onChange(of: store.compactSizeMode) { compactSizeMode in
      if let configuredWindow, store.isCompact {
        WindowConfigurator.configure(
          configuredWindow,
          compact: true,
          compactSizeMode: compactSizeMode,
          compactStyle: store.compactStyle,
          toolCount: store.enabledToolCount,
          ringOrientation: store.compactRingOrientation,
          metrics: store.floatingPanelMetrics,
          keepPosition: false
        )
      }
    }
    .onChange(of: store.compactStyle) { compactStyle in
      if let configuredWindow, store.isCompact {
        WindowConfigurator.configure(
          configuredWindow,
          compact: true,
          compactSizeMode: store.compactSizeMode,
          compactStyle: compactStyle,
          toolCount: store.enabledToolCount,
          ringOrientation: store.compactRingOrientation,
          metrics: store.floatingPanelMetrics,
          keepPosition: true
        )
      }
    }
    .onChange(of: store.enabledToolCount) { _ in
      if let configuredWindow, store.isCompact {
        WindowConfigurator.configure(
          configuredWindow,
          compact: true,
          compactSizeMode: store.compactSizeMode,
          compactStyle: store.compactStyle,
          toolCount: store.enabledToolCount,
          ringOrientation: store.compactRingOrientation,
          metrics: store.floatingPanelMetrics,
          keepPosition: true
        )
      }
    }
    .onChange(of: store.compactRingOrientation) { ringOrientation in
      if let configuredWindow, store.isCompact, store.compactStyle == .rings {
        WindowConfigurator.configure(
          configuredWindow,
          compact: true,
          compactSizeMode: store.compactSizeMode,
          compactStyle: store.compactStyle,
          toolCount: store.enabledToolCount,
          ringOrientation: ringOrientation,
          metrics: store.floatingPanelMetrics,
          keepPosition: false
        )
      }
    }
    .onChange(of: store.floatingPanelMetrics) { metrics in
      if let configuredWindow, store.isCompact {
        WindowConfigurator.configure(
          configuredWindow,
          compact: true,
          compactSizeMode: store.compactSizeMode,
          compactStyle: store.compactStyle,
          toolCount: store.enabledToolCount,
          ringOrientation: store.compactRingOrientation,
          metrics: metrics,
          keepPosition: true
        )
      }
    }
    .onChange(of: store.autoDodgeEnabled) { enabled in
      if enabled { autoDodgeIfNeeded(force: true) }
    }
    .onReceive(NotificationCenter.default.publisher(for: .codexWindowManualDragBegan)) { notification in
      guard let window = notification.object as? NSWindow,
            window === configuredWindow
      else { return }
      store.beginWindowDrag()
    }
    .onReceive(NotificationCenter.default.publisher(for: .codexWindowManualDragEnded)) { notification in
      guard let window = notification.object as? NSWindow,
            window === configuredWindow
      else { return }
      store.endWindowDrag()
      lastManualMove = Date()
    }
    .onReceive(dodgeTimer) { _ in
      autoDodgeIfNeeded(force: false)
    }
  }

  /// 自动避让：把折叠浮窗挪到「被其他窗口覆盖最少」的角落。
  /// force=true（启动/开关切换/收起时）立即执行；定时触发则尊重用户手动拖动（10 分钟内不打扰）。
  private func autoDodgeIfNeeded(force: Bool) {
    guard store.autoDodgeEnabled,
          store.isWindowVisible,
          store.isCompact,
          let window = configuredWindow
    else { return }
    if !force,
       let lastManualMove,
       Date().timeIntervalSince(lastManualMove) < 600 {
      return
    }
    let size = WindowConfigurator.compactSize(
      for: store.compactSizeMode,
      style: store.compactStyle,
      toolCount: store.enabledToolCount,
      ringOrientation: store.compactRingOrientation,
      metrics: store.floatingPanelMetrics
    )
    guard let origin = WindowAutoPlacer.bestCornerOrigin(for: size, window: window) else { return }
    let current = window.frame.origin
    guard abs(current.x - origin.x) > 2 || abs(current.y - origin.y) > 2 else { return }
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.28
      window.animator().setFrameOrigin(origin)
    })
  }

  private var compactWindowSize: NSSize {
    WindowConfigurator.compactSize(
      for: store.compactSizeMode,
      style: store.compactStyle,
      toolCount: store.enabledToolCount,
      ringOrientation: store.compactRingOrientation,
      metrics: store.floatingPanelMetrics
    )
  }
}
