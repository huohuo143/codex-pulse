import CodexBalanceCore
import SwiftUI

struct FloatingPanelMetricPicker: View {
  @EnvironmentObject private var store: DashboardStore

  private let columns = [
    GridItem(.flexible(), spacing: 8),
    GridItem(.flexible(), spacing: 8)
  ]

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
      ForEach(FloatingPanelMetric.allCases) { metric in
        let selected = store.showsFloatingPanelMetric(metric)
        Toggle(
          isOn: Binding(
            get: { store.showsFloatingPanelMetric(metric) },
            set: { store.setFloatingPanelMetric(metric, enabled: $0) }
          )
        ) {
          HStack(spacing: 8) {
            Image(systemName: metric.systemImage)
              .foregroundStyle(selected ? store.palette.weekly : DashboardColors.subtleText)
              .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
              Text(metric.title)
                .font(.system(size: 11.5, weight: .bold))
              Text(metric.subtitle)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(DashboardColors.subtleText)
                .lineLimit(2)
            }
          }
        }
        .toggleStyle(.checkbox)
        .disabled(selected && store.floatingPanelMetrics.count == 1)
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? store.palette.weekly.opacity(0.10) : DashboardColors.faintFill)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(selected ? store.palette.weekly.opacity(0.55) : DashboardColors.border, lineWidth: 1)
        )
        .accessibilityHint(selected && store.floatingPanelMetrics.count == 1 ? "悬浮框至少保留一项信息" : "")
      }
    }
  }
}
