import SidebarCore
import SwiftUI

struct SidebarVisibilityToggles: View {
  @ObservedObject var model: SidebarModel

  var body: some View {
    Toggle("七天额度", isOn: binding(\.quota))
    Toggle("Tibo 重置状态", isOn: binding(\.radar))
    Toggle("Credits 余额", isOn: binding(\.credits))
    Toggle("Full reset 次数", isOn: binding(\.reset))
    Toggle("API 用量与赠额", isOn: binding(\.apiUsage))
  }

  private func binding(_ key: WritableKeyPath<SidebarVisibility, Bool>) -> Binding<Bool> {
    Binding(get: { model.visibility[keyPath: key] }, set: { value in
      var next = model.visibility
      next[keyPath: key] = value
      model.setVisibility(next)
    })
  }
}

struct CodexSidebarSettingsView: View {
  @ObservedObject private var model = CodexSidebarController.shared.model

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle("启用 Codex 侧栏状态", isOn: $model.enabled)
        .font(.system(size: 12.5, weight: .bold))
      Text("在 Codex 窗口左下方显示；脉动运行时自动跟随。每项可单独显示或隐藏。")
        .font(.caption).foregroundStyle(DashboardColors.subtleText)
      SidebarVisibilityToggles(model: model)
      HStack {
        Text("彩色表示剩余，淡色空环表示已用；额度越低，颜色会依次变为黄、粉、红。")
          .font(.caption).foregroundStyle(DashboardColors.subtleText)
        Spacer()
        Button("查看布局预览", systemImage: "eye") { CodexSidebarController.shared.showPreview() }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
