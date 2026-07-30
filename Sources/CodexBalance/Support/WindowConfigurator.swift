import AppKit
import CodexBalanceCore

@MainActor
enum WindowConfigurator {
  // 额度环使用横向长方形，给 Token 单位和重置明细留出清晰的字号空间。
  static let compactSize = NSSize(width: 300, height: 310)
  static let miniCompactSize = NSSize(width: 248, height: 258)
  static let expandedSize = NSSize(width: 680, height: 860)

  static func compactSize(
    for mode: CompactSizeMode,
    style: CompactStyle = .rings,
    toolCount: Int = 2,
    ringOrientation: CompactRingOrientation = .horizontal,
    metrics: Set<FloatingPanelMetric> = FloatingPanelMetric.defaults
  ) -> NSSize {
    let metrics = metrics.isEmpty ? FloatingPanelMetric.defaults : metrics
    let isMini = mode == .mini
    let showsWeekly = metrics.contains(.weeklyQuota)
    let showsFiveHour = metrics.contains(.fiveHourQuota)
    let showsRolling = metrics.contains(.rolling24Tokens)
    let showsRadar = metrics.contains(.resetRadar)
    let showsResetCredits = metrics.contains(.resetCredits)

    switch style {
    case .rings:
      var heights: [CGFloat] = []
      if ringOrientation == .horizontal {
        if showsWeekly || showsFiveHour { heights.append(isMini ? 116 : 148) }
        else if showsRolling { heights.append(isMini ? 72 : 92) }
        if showsWeekly && showsFiveHour && showsRolling { heights.append(isMini ? 44 : 54) }
      } else {
        if showsWeekly { heights.append(isMini ? 116 : 148) }
        if showsFiveHour { heights.append(isMini ? 116 : 148) }
        if showsRolling { heights.append(isMini ? 44 : 54) }
      }
      if showsRadar { heights.append(isMini ? 24 : 28) }
      if showsResetCredits { heights.append(isMini ? 86 : 90) }

      let padding = isMini ? CGFloat(20) : CGFloat(28)
      let spacing = isMini ? CGFloat(6) : CGFloat(8)
      let height = max(isMini ? 64 : 76, padding + heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
      let width: CGFloat
      if ringOrientation == .vertical {
        width = isMini ? 204 : 236
      } else if (showsWeekly && showsFiveHour) || ((showsWeekly || showsFiveHour) && showsRolling) {
        width = isMini ? 248 : 300
      } else if showsWeekly || showsFiveHour {
        width = isMini ? 160 : 190
      } else {
        width = isMini ? 218 : 260
      }
      return NSSize(width: width, height: height)
    case .circle:
      return mode == .mini ? NSSize(width: 144, height: 144) : NSSize(width: 176, height: 176)
    case .square:
      let height = isMini
        ? max(CGFloat(104), CGFloat(52 + metrics.count * 27))
        : max(CGFloat(128), CGFloat(62 + metrics.count * 32))
      return NSSize(width: isMini ? 148 : 180, height: height)
    case .pill:
      let width = isMini
        ? max(CGFloat(168), CGFloat(70 + metrics.count * 57))
        : max(CGFloat(198), CGFloat(82 + metrics.count * 66))
      return NSSize(width: width, height: isMini ? 56 : 68)
    case .bars:
      let quotaProgressCount = [showsWeekly, showsFiveHour].filter { $0 }.count
      let height = isMini
        ? max(CGFloat(64), CGFloat(30 + metrics.count * 21 + quotaProgressCount * 8))
        : max(CGFloat(78), CGFloat(34 + metrics.count * 25 + quotaProgressCount * 10))
      return NSSize(width: isMini ? 238 : 286, height: height)
    case .barsQuad:
      let quotaProgressCount = [showsWeekly, showsFiveHour].filter { $0 }.count
      let height = isMini
        ? max(CGFloat(76), CGFloat(32 + metrics.count * 24 + quotaProgressCount * 8))
        : max(CGFloat(92), CGFloat(38 + metrics.count * 29 + quotaProgressCount * 10))
      return NSSize(width: isMini ? 248 : 300, height: height)
    case .badge:
      let width = isMini
        ? max(CGFloat(138), CGFloat(55 + metrics.count * 75))
        : max(CGFloat(158), CGFloat(65 + metrics.count * 85))
      return NSSize(width: width, height: isMini ? 42 : 50)
    case .badgeQuad:
      let width = isMini
        ? max(CGFloat(148), CGFloat(60 + metrics.count * 78))
        : max(CGFloat(168), CGFloat(70 + metrics.count * 88))
      return NSSize(width: width, height: isMini ? 42 : 50)
    }
  }

  static func configure(
    _ window: NSWindow,
    compact: Bool,
    compactSizeMode: CompactSizeMode = .standard,
    compactStyle: CompactStyle = .rings,
    toolCount: Int = 2,
    ringOrientation: CompactRingOrientation = .horizontal,
    metrics: Set<FloatingPanelMetric> = FloatingPanelMetric.defaults,
    keepPosition: Bool = true
  ) {
    window.title = AppInfo.appName
    // Keep the custom borderless presentation, but preserve the standard
    // Close command so the main window can be dismissed while MenuBarExtra
    // and background automation continue running.
    window.styleMask = [.borderless, .closable, .resizable]
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = !compact
    window.level = compact ? .floating : .normal
    window.collectionBehavior = compact
      ? [.canJoinAllSpaces, .fullScreenAuxiliary]
      : [.managed, .participatesInCycle]
    window.isMovable = true
    // Dragging is handled by WindowDragSurface. Letting NSWindow also treat the
    // SwiftUI hosting background as draggable can swallow the view's drag
    // events in a borderless window.
    window.isMovableByWindowBackground = false
    let resolvedCompactSize = compactSize(
      for: compactSizeMode,
      style: compactStyle,
      toolCount: toolCount,
      ringOrientation: ringOrientation,
      metrics: metrics
    )
    window.minSize = compact ? resolvedCompactSize : NSSize(width: 640, height: 760)
    window.maxSize = compact ? resolvedCompactSize : NSSize(width: 820, height: 980)

    let targetSize = compact ? resolvedCompactSize : expandedSize
    let origin = keepPosition ? window.frame.origin : topRightOrigin(for: targetSize, window: window)
    window.setFrame(NSRect(origin: origin, size: targetSize), display: true, animate: true)
  }

  private static func topRightOrigin(for size: NSSize, window: NSWindow) -> NSPoint {
    let screen = window.screen ?? NSScreen.main
    guard let visible = screen?.visibleFrame else {
      return NSPoint(x: 80, y: 80)
    }
    return NSPoint(
      x: visible.maxX - size.width - 18,
      y: visible.maxY - size.height - 18
    )
  }
}

/// 自动避让：把浮窗挪到四个角落中「被其他窗口覆盖最少」的那个。
/// 只用 CGWindowList 的窗口边界（现代 macOS 上无需屏幕录制权限；窗口标题才需要，这里不读标题）。
@MainActor
enum WindowAutoPlacer {
  private static let margin: CGFloat = 18

  /// 返回最优角落的 origin；nil 表示无法计算（保持原位）。
  static func bestCornerOrigin(for size: NSSize, window: NSWindow) -> NSPoint? {
    guard let screen = window.screen ?? NSScreen.main else { return nil }
    let visible = screen.visibleFrame

    // 其他 App 在屏的窗口边界（Cocoa 坐标）
    let others = onScreenWindowRects(excludingPID: ProcessInfo.processInfo.processIdentifier)

    let candidates: [NSPoint] = [
      NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin), // 右上
      NSPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin),              // 左上
      NSPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin),               // 右下
      NSPoint(x: visible.minX + margin, y: visible.minY + margin)                             // 左下
    ]

    var best: (origin: NSPoint, overlap: CGFloat)?
    for origin in candidates {
      let rect = NSRect(origin: origin, size: size)
      let overlap = others.reduce(CGFloat(0)) { $0 + $1.intersection(rect).area }
      if best == nil || overlap < best!.overlap {
        best = (origin, overlap)
      }
      if overlap == 0 { break } // 候选按优先级排列，遇到完全空白的角落直接用
    }
    return best?.origin
  }

  /// 读取所有在屏窗口的边界并转换为 Cocoa 坐标（原点左下）。
  private static func onScreenWindowRects(excludingPID pid: Int32) -> [NSRect] {
    guard let info = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] else {
      return []
    }

    // CGWindow 坐标原点在主屏左上；转 Cocoa 需要主屏高度
    let mainScreenHeight = NSScreen.screens.first?.frame.maxY ?? 0

    var rects: [NSRect] = []
    for item in info {
      guard let ownerPID = item[kCGWindowOwnerPID as String] as? Int32,
            ownerPID != pid,
            let layer = item[kCGWindowLayer as String] as? Int,
            layer == 0, // 只统计普通应用窗口，忽略菜单栏/Dock/悬浮层
            let boundsDict = item[kCGWindowBounds as String] as? [String: CGFloat],
            let x = boundsDict["X"], let y = boundsDict["Y"],
            let w = boundsDict["Width"], let h = boundsDict["Height"],
            w > 40, h > 40, // 忽略微型辅助窗口
            let alpha = item[kCGWindowAlpha as String] as? CGFloat, alpha > 0.05
      else { continue }
      let cocoaY = mainScreenHeight - y - h
      rects.append(NSRect(x: x, y: cocoaY, width: w, height: h))
    }
    return rects
  }
}

private extension NSRect {
  var area: CGFloat {
    isEmpty ? 0 : width * height
  }
}
