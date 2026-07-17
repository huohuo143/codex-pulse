import AppKit

@MainActor
final class AppWindowRouter {
  static let shared = AppWindowRouter()

  private var openMainAction: (() -> Void)?

  private init() {}

  func register(openMain: @escaping () -> Void) {
    openMainAction = openMain
  }

  func ensureMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.title == AppInfo.appName }) {
      window.makeKeyAndOrderFront(nil)
      return
    }
    openMainAction?()
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first(where: { $0.title == AppInfo.appName })?.makeKeyAndOrderFront(nil)
    }
  }
}
