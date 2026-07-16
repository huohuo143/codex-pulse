import SwiftUI

@main
struct CodexBalanceApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = DashboardStore()

  var body: some Scene {
    WindowGroup(AppInfo.appName) {
      ContentView()
        .environmentObject(store)
    }
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .appSettings) {
        Button("设置…") {
          store.showSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
      }
      CommandMenu("仪表盘") {
        Button("打开概览") {
          store.showDashboard()
        }
        .keyboardShortcut("1", modifiers: .command)

        Button("打开趋势") {
          store.showTrends()
        }
        .keyboardShortcut("2", modifiers: .command)

        Button("打开分析") {
          store.showInsights()
        }
        .keyboardShortcut("3", modifiers: .command)

        Divider()

        Button("刷新全部数据") {
          store.refreshAll()
        }
        .keyboardShortcut("r", modifiers: .command)

        Button("导出用量 CSV…") {
          store.exportUsageCSV()
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])

        Button("复制用量摘要") {
          store.copyUsageSummary()
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])

        Divider()

        Button(store.floatingPanelEnabled ? "收起为悬浮框" : "悬浮框设置…") {
          store.requestCompactPanel()
        }
        .keyboardShortcut("1", modifiers: [.command, .shift])
      }
    }
  }
}
