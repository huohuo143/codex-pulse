import CodexBalanceCore
import SwiftUI

struct DashboardSettingsView: View {
  @EnvironmentObject private var store: DashboardStore

  var body: some View {
    VStack(spacing: 14) {
      settingsSection("全局外观") {
        Picker("背景模式", selection: $store.themeMode) {
          ForEach(DashboardThemeMode.allCases) { mode in
            Label(mode.title, systemImage: mode.systemImage).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        Text(store.themeMode.subtitle)
          .font(.caption)
          .foregroundStyle(DashboardColors.subtleText)
        DashboardAppearancePicker(selection: $store.appearance, palette: store.palette)
        Picker("主题色", selection: $store.palette) {
          ForEach(DashboardPalette.allCases) { Text($0.title).tag($0) }
        }
        Text("视觉方案控制全局背景、卡片材质和圆角；主题色单独控制额度、Token 与强调色。")
          .font(.caption)
          .foregroundStyle(DashboardColors.subtleText)
      }

      settingsSection("悬浮框") {
        Toggle("启用悬浮框", isOn: $store.floatingPanelEnabled)
          .font(.system(size: 12.5, weight: .bold))
        HStack(alignment: .firstTextBaseline) {
          Text(store.floatingPanelEnabled
            ? "已启用：主界面可随时收起为桌面悬浮框。"
            : "已关闭：自动唤起时后台运行；手动打开显示普通主窗口，小组件继续可用。")
            .font(.caption)
            .foregroundStyle(DashboardColors.subtleText)
          Spacer()
          if store.floatingPanelEnabled, !store.isCompact {
            Button("立即显示", systemImage: "rectangle.on.rectangle") {
              store.showFloatingPanel()
            }
          } else if !store.floatingPanelEnabled, store.isWindowVisible {
            Button("隐藏当前窗口", systemImage: "eye.slash") {
              store.hideWindow()
            }
          }
        }

        Divider().overlay(DashboardColors.separator)
        Text("悬浮框显示信息")
          .font(.system(size: 12.5, weight: .bold))
        FloatingPanelMetricPicker()
        Text("可自由组合以上信息；为避免空白悬浮框，至少保留一项。Full reset 没有官方明细时会显示暂无可用数据。")
          .font(.caption)
          .foregroundStyle(DashboardColors.subtleText)

        Divider().overlay(DashboardColors.separator)
        Text("样式与尺寸")
          .font(.system(size: 12.5, weight: .bold))
        CompactStylePicker(selection: $store.compactStyle, palette: store.palette)
        Picker("尺寸", selection: $store.compactSizeMode) {
          ForEach(CompactSizeMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if store.compactStyle == .rings {
          Picker("额度环方向", selection: $store.compactRingOrientation) {
            ForEach(CompactRingOrientation.allCases) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
        }
        HStack {
          Text("背景透明度")
          Slider(value: $store.compactBackgroundOpacity, in: 0.30...0.94)
        }
        Toggle("自动避让其他窗口", isOn: $store.autoDodgeEnabled)
      }

      settingsSection("刷新与快捷操作") {
        Picker("本地额度刷新间隔", selection: $store.refreshIntervalOption) {
          ForEach(RefreshIntervalOption.allCases) { Text($0.title).tag($0) }
        }
        Text("建议使用 30s，避免频繁扫描本地日志影响滚动；Token 完整汇总自动节流到 5 分钟。Codex 雷达使用独立的固定 30 分钟同步，不受这里影响。")
          .font(.caption)
          .foregroundStyle(DashboardColors.subtleText)
        HStack {
          Button("立即刷新", systemImage: "arrow.clockwise") { store.refreshAll() }
          Button("复制用量摘要", systemImage: "doc.on.doc") { store.copyUsageSummary() }
        }
      }

      settingsSection("额度预测与提醒") {
        Toggle(isOn: Binding(
          get: { store.quotaAlertsEnabled },
          set: { store.setQuotaAlertsEnabled($0) }
        )) {
          VStack(alignment: .leading, spacing: 2) {
            Text("启用额度提醒")
              .font(.system(size: 12.5, weight: .bold))
            Text("首次开启时才申请 macOS 通知权限")
              .font(.caption)
              .foregroundStyle(DashboardColors.subtleText)
          }
        }

        HStack {
          Label(store.notificationAuthorization.label, systemImage: notificationStatusSymbol)
            .font(.caption)
            .foregroundStyle(notificationStatusColor)
          Spacer()
          if store.notificationAuthorization == .denied {
            Button("打开系统通知设置", systemImage: "gearshape") {
              store.openSystemNotificationSettings()
            }
          }
        }

        Picker("额度阈值预设", selection: $store.quotaAlertPreset) {
          ForEach(QuotaAlertPreset.allCases) { preset in
            Text(alertPresetTitle(preset)).tag(preset)
          }
        }
        .disabled(!store.quotaAlertsEnabled)

        VStack(alignment: .leading, spacing: 8) {
          Toggle("剩余额度进入阈值时提醒", isOn: $store.quotaThresholdAlertsEnabled)
          Toggle("预计在官方重置前耗尽时提醒", isOn: $store.quotaForecastAlertsEnabled)
          Toggle("Full reset 距到期不足 24 小时时提醒", isOn: $store.quotaResetCreditAlertsEnabled)
        }
        .disabled(!store.quotaAlertsEnabled)

        Text("每个额度周期的同一阈值只提醒一次；持续高风险每 6 小时最多重复一次。通知不包含账号、路径、项目或对话内容。")
          .font(.caption)
          .foregroundStyle(DashboardColors.subtleText)
      }

      ReliabilityAutomationSettingsView()

      AppUpdateSettingsView()

      settingsSection("macOS 桌面小组件") {
        Text("共 7 款：Codex 总览、7 天额度、重置雷达、Full reset 权益、Token 汇总、Token 趋势、项目与用途。")
          .font(.caption)
          .foregroundStyle(DashboardColors.subtleText)
        Toggle("显示 5 小时额度内环", isOn: $store.widgetShowsFiveHourQuota)
          .font(.system(size: 12.5, weight: .bold))
        Text("默认关闭。开启后，总览和额度小组件显示 7 天外环与橙色 5 小时内环；关闭时只显示 7 天额度环。")
          .font(.caption)
          .foregroundStyle(DashboardColors.subtleText)
        Label("右键桌面 → 编辑小组件 → 搜索“Codex 脉动”", systemImage: "rectangle.3.group.fill")
          .font(.system(size: 11, weight: .semibold))
        Text("总览组件复刻悬浮框核心信息；其余组件可按需要自由组合。")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(DashboardColors.subtleText)
      }

      settingsSection("Codex 重置雷达") {
        Text("直接读取“重置雷达”微信小程序使用的公开 dashboard 数据，只映射 Codex 的 24 小时概率、研判和 Tibo 动态；按数据时间戳防止旧结果覆盖新结果。不接入 Claude Code，不需要 API Key。")
          .font(.caption)
          .foregroundStyle(DashboardColors.subtleText)
        HStack {
          Button("立即同步重置雷达", systemImage: "arrow.clockwise") {
            store.refreshCodexRadar(force: true)
          }
          .disabled(store.codexRadarIsLoading)
          Spacer()
          Link("打开数据源", destination: CodexRadarService.siteURL)
        }
        Label(store.codexRadarStatusMessage, systemImage: "network")
          .font(.caption)
          .foregroundStyle(DashboardColors.subtleText)
        Text("\(CodexRadarService.publicSummaryModeText) · 每 30 分钟同步 · \(CodexRadarService.attributionText)")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(DashboardColors.subtleText)
      }

      settingsSection("自动启动") {
        Toggle(isOn: Binding(
          get: { store.launchWithCodexEnabled },
          set: { store.setLaunchWithCodexEnabled($0) }
        )) {
          Text("打开 Codex 时自动启动")
        }
        if let message = store.settingsMessage {
          Text(message)
            .font(.caption)
            .foregroundStyle(DashboardColors.subtleText)
        }
      }

      if store.touchBarSupported {
        settingsSection("Touch Bar") {
          Toggle("启用 Touch Bar 常驻", isOn: $store.touchBarEnabled)
          Picker("面板", selection: $store.touchBarStyle) {
            ForEach(TouchBarPanelStyle.allCases) { Text($0.title).tag($0) }
          }
          Toggle("显示最近 Codex 会话", isOn: $store.touchBarShowsSessions)
          Stepper("会话数量：\(store.touchBarSessionCount)", value: $store.touchBarSessionCount, in: 1...3)
        }
      }

      settingsSection("致谢") {
        creditRow(
          title: "最初源码与构思",
          author: AppInfo.originalAuthor,
          address: AppInfo.originalRepositoryURL
        )
        creditRow(
          title: "Codex 重置雷达",
          author: AppInfo.codexRadarAuthor,
          address: AppInfo.codexRadarURL
        )
        Text("感谢上述作者与公开项目为 Codex 脉动提供起点、思路与公开雷达数据。")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(DashboardColors.subtleText)
      }

      settingsSection("关于") {
        Text("\(AppInfo.appName) \(AppInfo.version)")
        Text("开发维护：\(AppInfo.author) · \(AppInfo.license)")
          .font(.caption)
          .foregroundStyle(DashboardColors.subtleText)
        Text("Bundle ID：dev.codex.balance-dashboard.codex")
          .font(.system(size: 11, design: .monospaced))
        HStack {
          referenceLink("OpenAI 模型价格", AppInfo.pricingURL)
          referenceLink("Codex rate card", AppInfo.rateCardURL)
          referenceLink("Frankfurter", AppInfo.exchangeRateURL)
          referenceLink("项目仓库", AppInfo.repositoryURL)
        }
      }
    }
    .foregroundStyle(DashboardColors.text)
  }

  private func settingsSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 12) {
        Text(title).font(.system(size: 15, weight: .bold))
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func referenceLink(_ title: String, _ address: String) -> some View {
    Link(title, destination: URL(string: address)!)
      .font(.caption)
  }

  private var notificationStatusSymbol: String {
    switch store.notificationAuthorization {
    case .authorized: "checkmark.circle.fill"
    case .denied: "exclamationmark.triangle.fill"
    case .notDetermined: "bell.badge"
    }
  }

  private var notificationStatusColor: Color {
    switch store.notificationAuthorization {
    case .authorized: .green
    case .denied: .orange
    case .notDetermined: DashboardColors.subtleText
    }
  }

  private func alertPresetTitle(_ preset: QuotaAlertPreset) -> String {
    switch preset {
    case .standard: "标准 · 30% / 15% / 5%"
    case .early: "提前 · 50% / 30% / 15%"
    case .urgentOnly: "仅紧急 · 15% / 5%"
    }
  }

  private func creditRow(title: String, author: String, address: String) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 12, weight: .bold))
        Text(author)
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(DashboardColors.subtleText)
      }
      Spacer()
      Link("访问", destination: URL(string: address)!)
        .font(.caption)
    }
  }
}
