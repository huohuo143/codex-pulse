import AppKit
import SwiftUI

extension Notification.Name {
  static let codexWindowManualDragBegan = Notification.Name("CodexWindowManualDragBegan")
  static let codexWindowManualDragEnded = Notification.Name("CodexWindowManualDragEnded")
}

/// A thin AppKit bridge that lets the window server own the complete drag loop.
///
/// Updating `NSWindow.frame` from a SwiftUI `DragGesture` causes the hosting view
/// to participate in every pointer sample. `performDrag(with:)` follows the
/// native macOS window-moving path and only reports back after the mouse is up.
struct WindowDragSurface: NSViewRepresentable {
  var help: String

  init(help: String = "拖动窗口") {
    self.help = help
  }

  func makeNSView(context: Context) -> NativeWindowDragView {
    let view = NativeWindowDragView()
    view.toolTip = help
    return view
  }

  func updateNSView(_ nsView: NativeWindowDragView, context: Context) {
    nsView.toolTip = help
  }
}

final class NativeWindowDragView: NSView {
  override var isOpaque: Bool { false }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    let contentView = window.contentView
    contentView?.wantsLayer = true
    let contentLayer = contentView?.layer
    let previousRasterization = contentLayer?.shouldRasterize ?? false
    let previousRasterizationScale = contentLayer?.rasterizationScale ?? 1
    NotificationCenter.default.post(
      name: .codexWindowManualDragBegan,
      object: window
    )
    // Cache the already rendered SwiftUI tree for the duration of the native
    // window move. This avoids recompositing gradients/materials for every
    // pointer sample while preserving the window server's native drag loop.
    contentLayer?.rasterizationScale = window.backingScaleFactor
    contentLayer?.shouldRasterize = true
    NSCursor.closedHand.push()
    defer {
      contentLayer?.shouldRasterize = previousRasterization
      contentLayer?.rasterizationScale = previousRasterizationScale
      contentView?.needsDisplay = true
      NSCursor.pop()
      NotificationCenter.default.post(
        name: .codexWindowManualDragEnded,
        object: window
      )
    }
    window.performDrag(with: event)
  }
}
