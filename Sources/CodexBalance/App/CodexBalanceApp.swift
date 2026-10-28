import CodexBalanceCore
import SwiftUI

@main
struct CodexBalanceApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = DashboardStore(startServices: !S3DualScreenContract.isCandidateBuild)

  var body: some Scene {
    WindowGroup(AppInfo.appName, id: "main") {
      if S3DualScreenContract.isCandidateBuild {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            Text("小悟 S3 双屏 · 沙箱候选版").font(.title2).bold()
            S3SandboxSettingsView()
          }.padding(24)
        }.frame(width: 880, height: 880)
      } else {
        ContentView()
        .environmentObject(store)
        .defaultAppStorage(PulsePreferences.shared)
      }
    }
    .windowResizability(.contentSize)
    .commands {
      if PulsePreferences.isIsolated {
        CommandMenu("运行验收") {
          Button("模拟休眠后恢复") {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
          }
        }
      }
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

        Button("打开重置日历") {
          store.showResetCalendar()
        }
        .keyboardShortcut("4", modifiers: .command)

        Divider()

        Button("刷新全部数据") {
          store.refreshAll()
        }
        .keyboardShortcut("r", modifiers: .command)

        Button("导出用量 CSV…") {
          store.exportUsageCSV()
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(store.isExporting || !store.hasUsageData)

        Button("复制用量摘要") {
          store.copyUsageSummary()
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])

        Divider()

        Button("检查版本更新…") {
          store.checkForAppUpdate()
          store.showSettings()
        }
        .disabled(store.appUpdateIsChecking)

        Divider()

        Button(store.floatingPanelEnabled ? "收起为悬浮框" : "悬浮框设置…") {
          store.requestCompactPanel()
        }
        .keyboardShortcut("1", modifiers: [.command, .shift])
      }
    }

    MenuBarExtra {
      MenuBarStatusView()
        .environmentObject(store)
    } label: {
      Label(store.menuBarTitle, systemImage: "gauge.with.dots.needle.50percent")
    }
    .menuBarExtraStyle(.window)
  }
}
