import Charts
import Combine
import CodexBalanceCore
import SwiftUI

struct QuotaHistoryView: View {
  @EnvironmentObject private var store: DashboardStore
  @State private var period: QuotaHistoryPeriod = .week
  @State private var hoveredAt: Date?
  @State private var points: [QuotaHistoryPoint] = []
  @State private var plottedPoints: [QuotaHistoryPoint] = []
  @State private var chartTime = Date()
  private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

  var body: some View {
      PanelCard {
        VStack(alignment: .leading, spacing: 12) {
          header(points: points)
          if points.isEmpty {
            VStack(spacing: 8) {
              Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(store.palette.weekly)
              Text("所选时间内暂无官方额度样本").font(.system(size: 13, weight: .semibold))
              Text("读取官方 7 天额度后自动记录；关闭 App 期间不会补造数据。")
                .font(.caption).foregroundStyle(DashboardColors.subtleText)
            }
            .frame(maxWidth: .infinity, minHeight: 170)
          } else {
            chart(points: plottedPoints, now: chartTime)
            sampleDetail(points: points)
          }
          Text("仅当前账户本机采样。周期变化、额度上调或超过 90 分钟无采样时断线；历史数值不代表实时余额。")
            .font(.system(size: 10)).foregroundStyle(DashboardColors.subtleText)
        }
      }
    .onAppear { refreshPoints() }
    .onChange(of: period) { _ in hoveredAt = nil; refreshPoints() }
    .onChange(of: store.quotaHistory) { _ in refreshPoints() }
    .onReceive(clock) { _ in refreshPoints() }
  }

  private func refreshPoints() {
    chartTime = Date()
    points = QuotaHistoryTrend.points(snapshots: store.quotaHistory, period: period, now: chartTime)
    plottedPoints = QuotaHistoryTrend.displayPoints(points)
  }

  private func header(points: [QuotaHistoryPoint]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("官方额度历史").font(.system(size: 15, weight: .bold))
          Text("7 天剩余额度 · \(points.count) 个采样点")
            .font(.system(size: 10)).foregroundStyle(DashboardColors.subtleText)
        }
        Spacer()
        Button { store.exportQuotaHistoryCSV(period: period) } label: {
          Label("导出样本", systemImage: "square.and.arrow.up")
        }
        .disabled(points.isEmpty)
        .help("导出所选时间范围内的官方额度采样")
      }
      Picker("额度历史时间范围", selection: $period) {
        ForEach(QuotaHistoryPeriod.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 290)
    }
  }

  private func chart(points: [QuotaHistoryPoint], now: Date) -> some View {
    Chart(points) { point in
      LineMark(x: .value("采样时间", point.snapshot.recordedAt),
        y: .value("剩余额度", point.snapshot.remainingPercent), series: .value("分段", point.segment))
        .foregroundStyle(store.palette.weekly)
        .interpolationMethod(.linear)
      PointMark(x: .value("采样时间", point.snapshot.recordedAt),
        y: .value("剩余额度", point.snapshot.remainingPercent))
        .foregroundStyle(store.palette.weekly)
        .symbolSize(10)
    }
    .chartYScale(domain: 0...100)
    .chartXScale(domain: now.addingTimeInterval(-period.duration)...now)
    .chartYAxis {
      AxisMarks(values: [0, 25, 50, 75, 100]) { value in
        AxisGridLine()
        AxisValueLabel { if let amount = value.as(Int.self) { Text("\(amount)%") } }
      }
    }
    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
    .chartOverlay { proxy in
      GeometryReader { geometry in
        Rectangle().fill(.clear).contentShape(Rectangle())
          .onContinuousHover { phase in
            switch phase {
            case .active(let location):
              let plot = geometry[proxy.plotAreaFrame]
              guard plot.contains(location), let date: Date = proxy.value(atX: location.x - plot.minX) else {
                hoveredAt = nil; return
              }
              let nearest = QuotaHistoryTrend.nearestPoint(to: date, in: self.points)?.id
              if hoveredAt != nearest { hoveredAt = nearest }
            case .ended: hoveredAt = nil
            }
          }
      }
    }
    .frame(height: 190)
    .accessibilityLabel("官方7天剩余额度历史，\(points.count)个样本")
  }

  private func sampleDetail(points: [QuotaHistoryPoint]) -> some View {
    let selected = hoveredAt.flatMap { date in
      QuotaHistoryTrend.nearestPoint(to: date, in: points)
    } ?? points.last
    return VStack(alignment: .leading, spacing: 4) {
      if let row = selected?.snapshot {
        Text("\(hoveredAt == nil ? "末次采样" : "采样时间") \(row.recordedAt.formatted(date: .abbreviated, time: .shortened)) · 剩余 \(row.remainingPercent, specifier: "%.1f")%")
          .font(.system(size: 11, weight: .semibold)).monospacedDigit()
        Text("当时的官方重置时间：\(row.resetsAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.system(size: 10)).foregroundStyle(DashboardColors.subtleText)
      }
    }
    .frame(height: 38, alignment: .topLeading)
  }
}
