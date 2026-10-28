import CodexBalanceCore
import SwiftUI

struct LocalCodexSetupView: View {
  @EnvironmentObject private var store: DashboardStore
  @State private var capabilities: LocalCodexCapabilities?
  @State private var preferences = TiboAnalysisPreferences.load()
  @State private var checking = false
  private let preferredModels = [("gpt-6-astra", "GPT-6 Astra"), ("gpt-6.1-sol", "GPT-6.1 Sol")]

  private var otherModels: [LocalCodexModel] {
    (capabilities?.models ?? []).filter { model in !preferredModels.contains { $0.0 == model.model } }
  }

  private var selectedModel: LocalCodexModel? {
    let models = capabilities?.models ?? []
    return preferences.model.isEmpty ? models.first(where: \.isDefault) ?? models.first
      : models.first { $0.model == preferences.model }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("读取本机当前登录的 Codex 账号和本地会话；不需要开发者账号，也不需要填写密码或复制令牌。仅在浏览器登录 ChatGPT 不等于已登录本机 Codex。")
        .font(.caption).fixedSize(horizontal: false, vertical: true)
      HStack {
        Label(capabilities?.loginLabel ?? "尚未检测本机 Codex",
          systemImage: capabilities?.signedIn == true ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
          .foregroundStyle(capabilities?.signedIn == true ? Color.green : Color.secondary)
        Spacer()
        Button(checking ? "检测中…" : "检测本机账号与模型") { inspect() }.disabled(checking)
      }.font(.caption)
      if let capabilities, !capabilities.installed {
        Link("获取 Codex", destination: URL(string: "https://developers.openai.com/codex/")!)
      }
      Text("灵活额度、Full reset 数量与到期时间，读取当前账号的官方数据和本地记录；Tibo 公告和内置月历不会增加个人权益。缺少数据时显示不可用。本地 Token 不包含没有本机记录的网页活动。")
        .font(.caption).foregroundStyle(.secondary)
      Divider()
      Toggle("启用 Tibo 模型分析", isOn: $preferences.enabled)
      Text("启用后，按北京时间分时段（3–20 分钟）将读取到的 Tibo 公开帖子与回复提交给所选模型，会消耗当前账号额度；API Key 登录按 API 计费。关闭后仍读取动态，不推断是否存在预告。")
        .font(.caption).foregroundStyle(.secondary)
      Picker("分析模型", selection: $preferences.model) {
        Text("自动使用当前账号默认模型").tag("")
        ForEach(preferredModels, id: \.0) { id, name in
          let available = capabilities?.models.contains(where: { $0.model == id }) == true
          Text(name + (available ? "" : capabilities == nil ? "（请先检测）" : "（当前账号不可用）"))
            .tag(id).disabled(!available)
        }
        ForEach(otherModels) { model in Text(model.displayName).tag(model.model) }
        if !preferences.model.isEmpty, !preferredModels.contains(where: { $0.0 == preferences.model }),
           capabilities?.models.contains(where: { $0.model == preferences.model }) != true {
          Text(preferences.model + "（待检测可用性）").tag(preferences.model)
        }
      }
      Picker("推理强度", selection: $preferences.effort) {
        Text("模型默认").tag("auto")
        ForEach(selectedModel?.supportedReasoningEfforts.map(\.reasoningEffort) ?? [], id: \.self) {
          Text(effortLabel($0)).tag($0)
        }
        if preferences.effort != "auto", selectedModel?.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == preferences.effort }) != true {
          Text(preferences.effort + "（待检测）").tag(preferences.effort)
        }
      }
      Text("GPT-6 Astra 与 GPT-6.1 Sol 的可选推理档位以当前账号返回的能力为准；切换模型后，档位列表会同步更新。")
        .font(.caption).foregroundStyle(.secondary)
      if preferences.enabled, let capabilities {
        switch Result(catching: { try preferences.selection(from: capabilities) }) {
        case .failure(let error): Text(error.localizedDescription).font(.caption).foregroundStyle(.orange)
        case .success: EmptyView()
        }
      }
      Divider()
      Picker("Tibo 动态来源", selection: $preferences.usesX) {
        Text("多公开源（默认，无需 X 登录）").tag(false)
        Text("X 官网优先，三个网站备用").tag(true)
      }
      Text(preferences.usesX
        ? "按北京时间分时段（3–20 分钟）优先读取 X 的发帖与回复。X 要求登录、访问失败或未加载出已知较新动态时，自动启用三个备用网站；下一轮继续尝试 X。界面显示本轮实际来源。"
        : "北京时间 16:00–21:00 暂停，其余时段按 3–20 分钟间隔交叉读取 Codex Radar、Tibo Reset、Did Codex Reset，按原帖去重。仅使用原文和发布时间，预告由所选模型分析。公开源仍可能延迟或遗漏。")
        .font(.caption).foregroundStyle(.secondary)
      Button("打开 X / 登录并查看 Tibo") { store.xTiboSource.show() }
      Text("X 登录状态仅由本机浏览器组件保存，不从其他浏览器提取 Cookie，不随安装包分发。模型分析不接触 X 登录凭据。")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onChange(of: preferences) { value in
      value.save()
      store.reevaluateCodexRadar()
    }
    .onChange(of: preferences.model) { _ in
      if preferences.effort != "auto", let selectedModel,
         !selectedModel.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == preferences.effort }) {
        preferences.effort = "auto"
      }
    }
    .task { if store.servicesEnabled, capabilities == nil { inspect() } }
  }
  private func effortLabel(_ value: String) -> String {
    let names = ["none": "无", "minimal": "最低", "low": "低", "medium": "中", "high": "高",
      "xhigh": "超高", "max": "最高", "ultra": "极高"]
    return names[value].map { "\($0)（\(value)）" } ?? value
  }
  private func inspect() {
    guard !checking else { return }
    checking = true
    Task {
      capabilities = await LocalCodexCapabilities.inspect()
      checking = false
    }
  }
}
