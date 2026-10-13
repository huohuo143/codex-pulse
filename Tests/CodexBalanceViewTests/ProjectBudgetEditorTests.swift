import AppKit
import Foundation
import SwiftUI
import Testing
import CodexBalanceCore
@testable import CodexBalance

@Suite("Project budget editor", .serialized)
struct ProjectBudgetEditorTests {
  @Test func invalidInputCannotReachStorage() {
    for text in ["", "0", "-100", "1.5", "1e6", "2,00"] {
      var form = ProjectBudgetEditorState(limitText: text)
      var attemptedSave = false
      let shouldDismiss = form.save { _ in
        attemptedSave = true
        return .success(())
      }
      #expect(!shouldDismiss)
      #expect(!attemptedSave)
      #expect(form.limitText == text)
    }
  }

  @Test func failedSaveRetainsInputAndAllowsRetry() {
    var form = ProjectBudgetEditorState(limitText: "2,000,000")
    let failedDismiss = form.save { value in
      #expect(value == 2_000_000)
      return .failure(CocoaError(.fileWriteNoPermission))
    }
    #expect(!failedDismiss)
    #expect(form.limitText == "2,000,000")
    #expect(form.saveError?.hasPrefix("预算保存失败：") == true)
    let successfulDismiss = form.save { value in
      #expect(value == 2_000_000)
      return .success(())
    }
    #expect(successfulDismiss)
    #expect(form.saveError == nil)
  }

  @MainActor @Test func storeReturnsWriteFailureWithoutReplacingExistingBudget() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // A regular file where a directory is required fails deterministically, even under a privileged test runner.
    let blocker = root.appendingPathComponent("not-a-directory")
    let sentinel = Data("fixture: retain this file".utf8)
    try sentinel.write(to: blocker)
    let storage = ProjectBudgetStore(url: blocker.appendingPathComponent("budgets.json"))
    let store = DashboardStore(startServices: false)
    let existing = ProjectBudget(projectName: "Fixture", monthlyTokenLimit: 100)
    store.projectBudgets = [existing]

    let result = store.setProjectBudget(project: .init(projectName: "Fixture"), monthlyTokenLimit: 200, storage: storage)

    guard case .failure = result else { Issue.record("A failed budget write must report failure"); return }
    #expect(store.projectBudgets.first?.monthlyTokenLimit == 100)
    #expect(store.budgetMessage?.hasPrefix("预算保存失败：") == true)
    #expect(try Data(contentsOf: blocker) == sentinel)
  }

  @MainActor @Test func storeReportsSuccessOnlyAfterBudgetIsPersisted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ProjectBudgetStore(url: root.appendingPathComponent("budgets.json"))
    let store = DashboardStore(startServices: false)

    try store.setProjectBudget(project: .init(projectName: "Fixture"), monthlyTokenLimit: 2_000_000, storage: storage).get()

    #expect(storage.load().first?.monthlyTokenLimit == 2_000_000)
    #expect(store.projectBudgets.first?.monthlyTokenLimit == 2_000_000)
  }

  @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"] != nil))
  func renderValidationAndSaveFailure() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = TokenProjectBucket(projectName: "示例项目", projectPath: "/example/project")
    for scheme in [ColorScheme.light, .dark] {
      let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
      let backgroundLevel = scheme == .dark ? 0.13 : 0.96
      let background = NSColor(srgbRed: backgroundLevel, green: backgroundLevel, blue: backgroundLevel, alpha: 1)
      for state in ["valid", "invalid", "failed"] {
        var form = ProjectBudgetEditorState(limitText: state == "invalid" ? "-100" : "2,000,000")
        if state == "failed" { _ = form.save { _ in .failure(CocoaError(.fileWriteNoPermission)) } }
        let view = ProjectBudgetEditor(project: project, form: form) { _ in .success(()) }
          .environment(\.colorScheme, scheme)
          .preferredColorScheme(scheme)
          .frame(width: 420, height: 320)
          .background(Color(nsColor: background))
        _ = NSApplication.shared
        var bitmap: NSBitmapImageRep?
        appearance.performAsCurrentDrawingAppearance {
          let host = NSHostingView(rootView: view)
          host.appearance = appearance
          let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
          window.isReleasedWhenClosed = false
          window.appearance = appearance
          window.backgroundColor = background
          window.isOpaque = true
          window.contentView = host
          host.layoutSubtreeIfNeeded()
          RunLoop.current.run(until: Date().addingTimeInterval(0.05))
          host.layoutSubtreeIfNeeded()
          bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
          if let bitmap { host.cacheDisplay(in: host.bounds, to: bitmap) }
          window.close()
        }
        let rep = try #require(bitmap)
        let file = folder.appendingPathComponent("project-budget-\(scheme == .dark ? "dark" : "light")-\(state).png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: file)
      }
    }
    print("VISUAL_PROJECT_BUDGET rendered=6 output=\(folder.path)")
  }
}
