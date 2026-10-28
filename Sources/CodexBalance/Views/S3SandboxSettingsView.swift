import CodexBalanceCore
import SwiftUI

struct S3SandboxSettingsView: View {
  @StateObject private var model: S3SandboxStore
  @State private var device = ""
  @State private var templateA = ""
  @State private var templateB = ""
  @State private var credential = ""
  @State private var sandboxConfirmed = false
  @State private var widthA = "400"
  @State private var heightA = "300"
  @State private var widthB = "400"
  @State private var heightB = "300"
  @State private var monochromeB = false

  init(model: S3SandboxStore = S3SandboxStore()) { _model = StateObject(wrappedValue: model) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("A 屏显示额度与用量，B 屏显示重置预告与七日曲线。本版本仅发送明确标注的示例数据。")
      HStack {
        Link("打开众创中心", destination: S3DualScreenContract.origin.appendingPathComponent("developer"))
        Link("平台硬件规范", destination: S3DualScreenContract.origin.appendingPathComponent("backend/developer/v1/hardware"))
        Spacer()
        Text("沙箱候选 \(S3DualScreenContract.candidateVersion)").font(.caption).foregroundStyle(.secondary)
      }
      TextField("平台分配的沙箱设备 ID", text: $device).disabled(model.connected || model.isBusy)
      HStack {
        TextField("A 屏已配置的模板 ID", text: $templateA)
        TextField("B 屏已配置的模板 ID", text: $templateB)
      }.disabled(model.connected || model.isBusy)
      dimensions("A 屏 · 黑白", width: $widthA, height: $heightA)
      dimensions("B 屏 · 三/四色", width: $widthB, height: $heightB)
      Toggle("B 屏使用纯黑白降级", isOn: $monochromeB).disabled(model.connected || model.isBusy)
      Text("400×300 为布局预设，请按测试设备规格修改。文字至少 18px；A 屏间隔 10 分钟，B 屏间隔至少 15 分钟。")
        .font(.caption).foregroundStyle(.secondary)
      Toggle("我确认该设备属于此应用的沙箱，以上模板已经由平台配置", isOn: $sandboxConfirmed)
        .disabled(model.connected || model.isBusy)
      HStack {
        Button("应用沙箱配置") {
          model.configure(target: .init(deviceID: device, templateA: templateA, templateB: templateB, confirmedSandbox: sandboxConfirmed),
            a: .init(width: Int(widthA) ?? 0, height: Int(heightA) ?? 0, monochrome: true),
            b: .init(width: Int(widthB) ?? 0, height: Int(heightB) ?? 0, monochrome: monochromeB))
          credential = ""
        }.disabled(model.isBusy)
        Spacer()
      }
      SecureField("本次沙箱 Token（仅保留到断开或退出）", text: $credential)
        .textContentType(.password).disabled(model.connected || model.isBusy)
      HStack {
        Button("连接测试设备") { model.connect(credential); credential = "" }
          .disabled(model.isBusy || model.connected || credential.isEmpty)
        Button("断开连接") { model.disconnect(); credential = "" }.disabled(!model.connected && !model.isBusy)
        if model.isBusy { ProgressView().controlSize(.small) }
      }
      Text("沙箱凭据由你直接填入，不写入偏好、导出文件或日志。平台未提供设备与模板时，可以先导出示例资料。")
        .font(.caption).foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: 12) {
        preview("A 屏 · 额度与用量", image: model.previewA, screen: .a)
        preview("B 屏 · 重置与趋势", image: model.previewB, screen: .b)
      }
      HStack {
        Button("刷新示例预览") { model.refreshPreviews() }.disabled(model.isBusy)
        Button("导出双屏示例资料") { model.exportWithPanel() }.disabled(model.isBusy)
      }
      Text(model.statusMessage).font(.callout).textSelection(.enabled)
      Text("推送成功仅表示平台受理。实机显示、模板安装及正式发布分别验证；Mac 退出后不会更新画面。")
        .font(.caption).foregroundStyle(.secondary)
      Text("本地画面为模板设计参考；线上按平台实际安装的模板渲染，需联调核对。")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onAppear {
      device = model.target.deviceID; templateA = model.target.templateA; templateB = model.target.templateB
      widthA = String(model.profileA.width); heightA = String(model.profileA.height)
      widthB = String(model.profileB.width); heightB = String(model.profileB.height); monochromeB = model.profileB.monochrome
    }
  }
  private func dimensions(_ title: String, width: Binding<String>, height: Binding<String>) -> some View {
    HStack {
      Text(title).frame(width: 135, alignment: .leading)
      TextField("宽（像素）", text: width).frame(width: 90)
      Text("×")
      TextField("高（像素）", text: height).frame(width: 90)
    }.disabled(model.connected || model.isBusy)
  }
  private func preview(_ title: String, image: NSImage?, screen: S3Screen) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.callout).bold()
      if let image { Image(nsImage: image).resizable().interpolation(.none).scaledToFit().border(Color.secondary.opacity(0.4)) }
      Button("推送 \(screen.rawValue) 屏示例") { model.push(screen) }.disabled(!model.canPush)
      if let receipt = model.receipts[screen] {
        Text("平台已受理 · \(EInkFormat.date(receipt.acceptedAt))").font(.caption)
        Text("任务 \(receipt.taskID)").font(.caption).textSelection(.enabled)
      } else { Text("尚未获得平台受理回执").font(.caption).foregroundStyle(.secondary) }
    }.frame(maxWidth: .infinity, alignment: .topLeading)
  }
}
