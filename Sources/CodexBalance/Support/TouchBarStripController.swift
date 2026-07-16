import AppKit
import CodexBalanceCore

/// Touch Bar 显示 7 天剩余额度与滚动 24h 消耗；无 Touch Bar 的 Mac 会安全空转。
@MainActor
final class TouchBarStripController: NSObject, NSTouchBarDelegate {
  static let shared = TouchBarStripController()

  nonisolated static let trayIdentifier = NSTouchBarItem.Identifier("dev.codex.balance-dashboard.codex.strip")
  nonisolated static let panelIdentifier = NSTouchBarItem.Identifier("dev.codex.balance-dashboard.codex.panel")

  struct ToolData {
    var color24h: NSColor
    var color7d: NSColor
    var percent7d: Double?
    var reset7d: Date?
    var tokens24h: Int
    var cost24hUSD: Double
  }

  private typealias SetPresenceFunc = @convention(c) (CFString, DarwinBoolean) -> Void
  private let setPresence: SetPresenceFunc?
  private let trayButton = NSButton(title: "C --", target: nil, action: nil)
  private var trayWidthConstraint: NSLayoutConstraint?
  private var trayItem: NSCustomTouchBarItem?
  private var panelTouchBar: NSTouchBar?
  private let panelView = CodexTouchBarView()
  private var installed = false
  var onOpenPanel: (() -> Void)?

  override private init() {
    if let handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY),
       let symbol = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier") {
      setPresence = unsafeBitCast(symbol, to: SetPresenceFunc.self)
    } else {
      setPresence = nil
    }
    super.init()
    trayButton.target = self
    trayButton.action = #selector(handleTrayTap)
    trayButton.bezelStyle = .rounded
    trayButton.font = .monospacedDigitSystemFont(ofSize: 13, weight: .heavy)
    trayButton.translatesAutoresizingMaskIntoConstraints = false
    trayWidthConstraint = trayButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 82)
    trayWidthConstraint?.isActive = true
    panelView.onOpenPanel = { [weak self] in self?.onOpenPanel?() }
  }

  var isSupported: Bool { setPresence != nil }

  func setEnabled(_ enabled: Bool) {
    guard isSupported else { return }
    if enabled { installIfNeeded(); presentPanel() }
    else { dismissPanel(); uninstall() }
  }

  func setPanelStyle(_ style: TouchBarPanelStyle) {
    panelView.style = style
    panelView.needsDisplay = true
  }

  func updateSessions(_ sessions: [RecentSessionChip]) {
    panelView.sessions = sessions
    panelView.invalidateIntrinsicContentSize()
    panelView.needsDisplay = true
  }

  func update(codex: ToolData?) {
    guard installed else { return }
    panelView.data = codex
    let percent = codex?.percent7d.map { "\(Int($0.rounded()))%" } ?? "--"
    let text = "C \(percent) · 24h \(compact(codex?.tokens24h ?? 0))"
    trayButton.attributedTitle = NSAttributedString(string: text, attributes: [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .heavy),
      .foregroundColor: codex?.color7d ?? NSColor.secondaryLabelColor
    ])
    trayWidthConstraint?.constant = max(82, ceil(trayButton.attributedTitle.size().width) + 20)
    panelView.needsDisplay = true
  }

  nonisolated func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
    guard identifier == Self.panelIdentifier else { return nil }
    return MainActor.assumeIsolated {
      let item = NSCustomTouchBarItem(identifier: identifier)
      item.view = panelView
      return item
    }
  }

  private func makePanelTouchBar() -> NSTouchBar {
    let bar = NSTouchBar()
    bar.delegate = self
    bar.defaultItemIdentifiers = [Self.panelIdentifier]
    return bar
  }

  private func installIfNeeded() {
    guard !installed else { return }
    let item = NSCustomTouchBarItem(identifier: Self.trayIdentifier)
    item.view = trayButton
    let selector = NSSelectorFromString("addSystemTrayItem:")
    guard NSTouchBarItem.responds(to: selector) else { return }
    NSTouchBarItem.perform(selector, with: item)
    setPresence?(Self.trayIdentifier.rawValue as CFString, true)
    trayItem = item
    installed = true
  }

  private func uninstall() {
    guard installed, let trayItem else { installed = false; return }
    setPresence?(Self.trayIdentifier.rawValue as CFString, false)
    let selector = NSSelectorFromString("removeSystemTrayItem:")
    if NSTouchBarItem.responds(to: selector) { NSTouchBarItem.perform(selector, with: trayItem) }
    self.trayItem = nil
    installed = false
  }

  private func presentPanel() {
    guard installed else { return }
    if panelTouchBar == nil { panelTouchBar = makePanelTouchBar() }
    guard let panelTouchBar else { return }
    let modern = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
    let legacy = NSSelectorFromString("presentSystemModalFunctionBar:systemTrayItemIdentifier:")
    if NSTouchBar.responds(to: modern) { _ = NSTouchBar.perform(modern, with: panelTouchBar, with: Self.trayIdentifier.rawValue) }
    else if NSTouchBar.responds(to: legacy) { _ = NSTouchBar.perform(legacy, with: panelTouchBar, with: Self.trayIdentifier.rawValue) }
  }

  private func dismissPanel() {
    guard let panelTouchBar else { return }
    let selector = NSSelectorFromString("dismissSystemModalTouchBar:")
    if NSTouchBar.responds(to: selector) { _ = NSTouchBar.perform(selector, with: panelTouchBar) }
    self.panelTouchBar = nil
  }

  @objc private func handleTrayTap() { presentPanel() }

  private func compact(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
    return "\(value)"
  }
}

@MainActor
private final class CodexTouchBarView: NSView {
  var data: TouchBarStripController.ToolData?
  var style: TouchBarPanelStyle = .barsQuad
  var sessions: [RecentSessionChip] = []
  var onOpenPanel: (() -> Void)?
  private var sessionRects: [NSRect] = []
  private let openButton = NSButton(title: "⤢", target: nil, action: nil)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    allowedTouchTypes = [.direct]
    openButton.target = self
    openButton.action = #selector(openPanel)
    openButton.bezelStyle = .rounded
    openButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(openButton)
    NSLayoutConstraint.activate([
      openButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      openButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      openButton.widthAnchor.constraint(equalToConstant: 36)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize { NSSize(width: 920, height: 30) }

  @objc private func openPanel() {
    NSApp.activate(ignoringOtherApps: true)
    onOpenPanel?()
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor.black.setFill(); bounds.fill()
    sessionRects = []
    guard let data else { drawText("正在读取 Codex…", x: 56, color: .secondaryLabelColor); return }
    var x: CGFloat = 54
    let percent = data.percent7d.map { "\(Int($0.rounded()))%" } ?? "--"

    drawChip("C", x: x, color: data.color7d); x += 29
    switch style {
    case .barsQuad:
      drawText("7天 \(percent)", x: x, color: data.color7d); x += 72
      drawBar(x: x, width: 110, value: data.percent7d, color: data.color7d); x += 124
      drawText("24h \(compact(data.tokens24h))", x: x, color: data.color24h); x += 105
      drawText(String(format: "$%.2f", data.cost24hUSD), x: x, color: .white); x += 68
    case .bars:
      drawText("7天 \(percent)", x: x, color: data.color7d); x += 72
      drawBar(x: x, width: 180, value: data.percent7d, color: data.color7d); x += 194
    case .badgeQuad:
      drawText("7天 \(percent)   24h \(compact(data.tokens24h))", x: x, color: data.color7d, size: 16); x += 230
    case .badge:
      drawText("7天 \(percent)", x: x, color: data.color7d, size: 18); x += 105
    }

    if !sessions.isEmpty {
      separator(x: x); x += 12
      for session in sessions.prefix(3) where x < bounds.maxX - 90 {
        let width = min(130, bounds.maxX - x - 8)
        let rect = NSRect(x: x, y: 5, width: width, height: 20)
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        drawText(session.title, x: x + 8, color: session.isActive ? .systemGreen : .white, size: 10)
        sessionRects.append(rect)
        x += width + 6
      }
    }
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if sessionRects.contains(where: { $0.contains(point) }) { SessionAppLauncher.open(tool: .codex); return }
    super.mouseDown(with: event)
  }

  override func touchesEnded(with event: NSEvent) {
    for touch in event.touches(matching: .ended, in: self) where sessionRects.contains(where: { $0.contains(touch.location(in: self)) }) {
      SessionAppLauncher.open(tool: .codex); return
    }
    super.touchesEnded(with: event)
  }

  private func drawChip(_ text: String, x: CGFloat, color: NSColor) {
    let rect = NSRect(x: x, y: 5, width: 21, height: 20)
    color.setFill(); NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .black), .foregroundColor: NSColor.black])
    string.draw(at: NSPoint(x: rect.midX - string.size().width / 2, y: rect.midY - string.size().height / 2))
  }

  private func drawBar(x: CGFloat, width: CGFloat, value: Double?, color: NSColor) {
    let track = NSRect(x: x, y: 12, width: width, height: 6)
    color.withAlphaComponent(0.22).setFill(); NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
    let fill = NSRect(x: x, y: 12, width: width * max(0, min(1, (value ?? 0) / 100)), height: 6)
    color.setFill(); NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
  }

  private func drawText(_ text: String, x: CGFloat, color: NSColor, size: CGFloat = 12) {
    let string = NSAttributedString(string: text, attributes: [
      .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold),
      .foregroundColor: color
    ])
    string.draw(at: NSPoint(x: x, y: bounds.midY - string.size().height / 2))
  }

  private func separator(x: CGFloat) {
    NSColor.white.withAlphaComponent(0.16).setFill()
    NSRect(x: x, y: 5, width: 1, height: 20).fill()
  }

  private func compact(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
    return "\(value)"
  }
}
