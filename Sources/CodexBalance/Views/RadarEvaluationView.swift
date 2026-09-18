import CodexBalanceCore
import SwiftUI

struct RadarEvaluationView: View {
  let summary: RadarEvaluationSummary
  let message: String?
  let save: (RadarVerifiedOutcome) -> Void
  @AppStorage("radarEvaluationExpanded") private var expanded = false
  @State private var selected = ""
  @State private var occurred = true
  @State private var eventAt = Date()
  @State private var source = ""
  @State private var verified = false

  var body: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("雷达结果对照").font(.headline)
          Spacer()
          Text(summary.brierScore.map { String(format: "Brier %.3f · n = %d", $0, summary.sampleCount) } ?? "暂无已核实样本 · n = 0")
            .font(.caption).foregroundStyle(DashboardColors.subtleText)
        }
        Text("仅统计已核实且完整结束的 24h 窗口。未知结果不计分；分数越低，概率预测与结果越一致。")
          .font(.caption).foregroundStyle(DashboardColors.subtleText)
        DisclosureGroup("本机标注结果（已归档 \(summary.forecasts.count) 条）", isExpanded: $expanded) {
          VStack(alignment: .leading, spacing: 10) {
            Picker("选择预测", selection: $selected) {
              Text("请选择实际归档的预测").tag("")
              ForEach(summary.forecasts.prefix(300)) { row in
                Text("\(row.predictedAt.formatted(date: .numeric, time: .shortened)) · \(Int(row.probability * 100))%" + (summary.outcomes[row.id]?.verified == true ? " · 已核实" : ""))
                  .tag(row.id)
              }
            }
            Toggle("该 24h 窗口发生过全局硬重置", isOn: $occurred)
            if occurred { DatePicker("事件时间", selection: $eventAt) }
            TextField("核实来源或链接", text: $source)
            Toggle("已核对完整 24h 窗口及来源", isOn: $verified)
            Button("保存本机结果") {
              let now = Date()
              save(RadarVerifiedOutcome(forecastID: selected, occurred: occurred, eventAt: occurred ? eventAt : nil,
                observedThrough: now, source: source, recordedAt: now, verified: verified))
            }.disabled(selected.isEmpty || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let message { Text(message).font(.caption) }
            Text("BANKED reset 属于可储存权益，不作为这里的全局硬重置事件。")
              .font(.caption).foregroundStyle(DashboardColors.subtleText)
          }.padding(.top, 8)
        }
      }
    }
  }
}
