import CodexBalanceCore
import Foundation
import SwiftUI

enum HourlyTokenTooltipFormatter {
  static func compact(_ value: Int) -> String {
    let magnitude = abs(Double(value))
    if magnitude >= 100_000_000 {
      return scaled(value, divisor: 100_000_000, suffix: "亿")
    }
    if magnitude >= 1_000_000 {
      return scaled(value, divisor: 1_000_000, suffix: "M")
    }
    return BalanceFormatters.exactNumber(value)
  }

  private static func scaled(_ value: Int, divisor: Double, suffix: String) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    formatter.roundingMode = .halfUp
    let scaledValue = Double(value) / divisor
    return "\(formatter.string(from: NSNumber(value: scaledValue)) ?? String(format: "%.2f", scaledValue))\(suffix)"
  }
}

struct HourlyUsageChart: View {
  let data: DeviceUsageTrendData
  let palette: DashboardPalette

  @State private var hoveredPointID: DeviceUsageTrendPoint.ID?

  private let chartHeight: CGFloat = 96
  private let barSpacing: CGFloat = 3
  private let tooltipWidth: CGFloat = 300

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      DeviceUsageLegend(data: data, palette: palette)

      GeometryReader { proxy in
        let maximum = max(1, data.points.map(\.totalTokens).max() ?? 1)

        ZStack(alignment: .topLeading) {
          HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(data.points) { point in
              hourSlot(point, maximum: maximum, chartHeight: chartHeight)
            }
          }

          if let selection = hoveredSelection {
            DeviceUsageTrendTooltip(point: selection.point, palette: palette)
              .frame(width: tooltipWidth)
              .position(
                x: tooltipCenterX(
                  index: selection.index,
                  count: data.points.count,
                  chartWidth: proxy.size.width
                ),
                y: data.tooltipHeight / 2
              )
              .allowsHitTesting(false)
              .transition(.opacity.combined(with: .scale(scale: 0.96)))
              .zIndex(2)
          }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
          switch phase {
          case .active(let location):
            hoveredPointID = pointID(atX: location.x, chartWidth: proxy.size.width)
          case .ended:
            hoveredPointID = nil
          }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredPointID)
      }
      .frame(height: data.tooltipHeight + chartHeight)
    }
  }

  private func hourSlot(
    _ point: DeviceUsageTrendPoint,
    maximum: Int,
    chartHeight: CGFloat
  ) -> some View {
    let isHovered = hoveredPointID == point.id
    let barHeight = point.totalTokens > 0
      ? max(3, chartHeight * CGFloat(point.totalTokens) / CGFloat(maximum))
      : 2

    return VStack(spacing: 0) {
      Spacer(minLength: data.tooltipHeight)
      ZStack(alignment: .bottom) {
        Color.clear
        if point.totalTokens > 0 {
          VStack(spacing: 0) {
            ForEach(point.values) { value in
              if let bucket = value.bucket, bucket.totalTokens > 0 {
                DeviceUsageColorPalette.color(for: value.device.colorIndex, palette: palette)
                  .opacity(isHovered ? 1 : 0.90)
                  .frame(
                    height: barHeight * CGFloat(bucket.totalTokens) / CGFloat(point.totalTokens)
                  )
              }
            }
          }
          .frame(height: barHeight, alignment: .bottom)
          .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        } else {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.primary.opacity(isHovered ? 0.24 : 0.12))
            .frame(height: barHeight)
        }
      }
      .frame(height: chartHeight, alignment: .bottom)
      .overlay(alignment: .bottom) {
        if isHovered {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .stroke(Color.primary.opacity(0.72), lineWidth: 1)
            .frame(height: barHeight)
        }
      }
      .shadow(color: isHovered ? Color.primary.opacity(0.22) : .clear, radius: 5, y: 1)
    }
    .frame(maxWidth: .infinity, minHeight: data.tooltipHeight + chartHeight, alignment: .bottom)
    .contentShape(Rectangle())
    .help("\(point.label) · 合计 \(BalanceFormatters.exactNumber(point.totalTokens)) Token")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(point.label)
    .accessibilityValue(DeviceUsageTrendAccessibility.value(for: point))
    .accessibilityHint("悬停时显示多设备合计和各设备明细")
  }

  private var hoveredSelection: (index: Int, point: DeviceUsageTrendPoint)? {
    guard let hoveredPointID,
          let index = data.points.firstIndex(where: { $0.id == hoveredPointID })
    else { return nil }
    return (index, data.points[index])
  }

  private func pointID(atX x: CGFloat, chartWidth: CGFloat) -> DeviceUsageTrendPoint.ID? {
    guard !data.points.isEmpty, chartWidth > 0 else { return nil }
    let normalizedX = min(max(0, x), chartWidth.nextDown)
    let index = min(
      data.points.count - 1,
      Int(normalizedX / chartWidth * CGFloat(data.points.count))
    )
    return data.points[index].id
  }

  private func tooltipCenterX(index: Int, count: Int, chartWidth: CGFloat) -> CGFloat {
    guard count > 0 else { return chartWidth / 2 }
    let totalSpacing = barSpacing * CGFloat(max(0, count - 1))
    let slotWidth = max(0, (chartWidth - totalSpacing) / CGFloat(count))
    let naturalCenter = CGFloat(index) * (slotWidth + barSpacing) + slotWidth / 2
    let edgeInset = tooltipWidth / 2 + 4
    guard chartWidth > edgeInset * 2 else { return chartWidth / 2 }
    return min(max(naturalCenter, edgeInset), chartWidth - edgeInset)
  }
}
