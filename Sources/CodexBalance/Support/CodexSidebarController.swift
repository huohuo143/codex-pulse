import AppKit
import CodexBalanceCore
import CoreGraphics
import SwiftUI

/// One panel owned by Codex Pulse. It reads window geometry only.
@MainActor
final class CodexSidebarController {
  static let shared = CodexSidebarController()
  let model = SidebarModel()
  private var panel: NSPanel?
  private var preview: NSWindow?
  private var timer: Timer?
  private var previewPlacementCount = 0

  private var tracksPreview: Bool {
    PulsePreferences.isIsolated && CommandLine.arguments.contains("--sidebar-follow-preview")
  }

  func start() {
    guard panel == nil else { return }
    recordSidebarRequirement()
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 52, height: 300),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    let host = NSHostingView(rootView: SidebarStatusView(model: model)
      .padding(.bottom, 18).frame(width: 52, height: 300, alignment: .bottom))
    host.sizingOptions = []
    panel.contentView = host
    self.panel = panel
    model.tick(visible: true)
    let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updatePlacement() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    if PulsePreferences.isIsolated && CommandLine.arguments.contains("--sidebar-preview") {
      showPreview()
      if tracksPreview {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.testPreviewMove() }
      }
    }
  }

  /// An installation guard can use this local, non-account-specific marker
  /// even if the existing app has been moved or removed before an update.
  private func recordSidebarRequirement() {
    guard !PulsePreferences.isIsolated else { return }
    let required = Bundle.main.object(forInfoDictionaryKey: "CodexSidebarIntegrationVersion") as? Int ?? 1
    guard (1...999).contains(required) else { return }
    let path = PulsePaths.support.appendingPathComponent("sidebar-integration-required")
    let fm = FileManager.default
    if fm.fileExists(atPath: path.path) {
      guard let attributes = try? fm.attributesOfItem(atPath: path.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let data = try? Data(contentsOf: path),
            let text = String(data: data, encoding: .utf8),
            let previous = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            previous > 0 else { return }
      if previous >= required { return }
    }
    try? fm.createDirectory(at: PulsePaths.support, withIntermediateDirectories: true)
    try? Data("\(required)\n".utf8).write(to: path, options: .atomic)
  }

  func showPreview() {
    if preview == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 430),
                            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
      window.title = "Codex 侧栏状态 · 布局预览"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: CodexSidebarPreviewView(
        model: model, usesTrackedPanel: tracksPreview,
        movePreview: { [weak self] in self?.movePreviewForTesting() }))
      window.center()
      preview = window
    }
    preview?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    model.tick(visible: true)
  }

  private func movePreviewForTesting() {
    guard let preview else { return }
    preview.setFrameOrigin(NSPoint(x: preview.frame.origin.x + 40, y: preview.frame.origin.y - 30))
  }

  private func testPreviewMove() {
    guard let panel, panel.isVisible, let preview else {
      model.previewMoveResult = "模拟窗口未在前台，未执行"
      return
    }
    let initial = panel.frame.origin
    preview.setFrameOrigin(NSPoint(x: preview.frame.origin.x + 40, y: preview.frame.origin.y - 30))
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
      guard let self, let panel = self.panel else { return }
      let result = panel.frame.origin
      self.model.previewMoveResult = panel.isVisible && abs(result.x - initial.x - 40) < 1 &&
        abs(result.y - initial.y + 30) < 1 ? "移动后位置同步" : "未通过"
    }
  }

  private func updatePlacement() {
    guard let panel else { return }
    let visibility = model.visibility
    guard model.enabled && (visibility.quota || visibility.radar || visibility.credits || visibility.reset || visibility.apiUsage) else {
      panel.orderOut(nil)
      model.tick(visible: preview?.isVisible == true)
      return
    }
    let target = tracksPreview && preview?.isVisible == true ? NSRunningApplication.current : NSWorkspace.shared.frontmostApplication
    let identifier = tracksPreview ? Bundle.main.bundleIdentifier : "com.openai.codex"
    let windowOptions: CGWindowListOption = tracksPreview
      ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
    guard let app = target, app.bundleIdentifier == identifier,
          let windows = CGWindowListCopyWindowInfo(windowOptions, kCGNullWindowID) as? [[String: Any]] else {
      panel.orderOut(nil)
      if tracksPreview { model.previewTrackingStatus = "模拟窗口不在前台" }
      model.tick(visible: preview?.isVisible == true)
      return
    }
    let mainWindow = windows.first { item in
      guard let pid = item[kCGWindowOwnerPID as String] as? Int32, pid == app.processIdentifier,
            let layer = item[kCGWindowLayer as String] as? Int, layer == 0,
            let rect = Self.windowRect(item) else { return false }
      if tracksPreview {
        return (item[kCGWindowNumber as String] as? Int) == preview?.windowNumber
      }
      return rect.width >= 600 && rect.height >= 400
    }
    guard let mainWindow, let bounds = Self.windowRect(mainWindow), let primary = NSScreen.screens.first else {
      if tracksPreview { model.previewTrackingStatus = "未找到模拟窗口" }
      panel.orderOut(nil)
      model.tick(visible: preview?.isVisible == true)
      return
    }
    let frame = NSRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY + 55, width: 52, height: 300)
    if panel.frame != frame {
      panel.setFrame(frame, display: false)
      if tracksPreview { previewPlacementCount += 1 }
    }
    if !panel.isVisible { panel.orderFrontRegardless() }
    if tracksPreview { model.previewTrackingStatus = "面板已定位并显示，更新 \(previewPlacementCount) 次" }
    model.tick(visible: true)
  }

  private static func windowRect(_ item: [String: Any]) -> CGRect? {
    guard let bounds = item[kCGWindowBounds as String] as? [String: Any],
          let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
  }
}
