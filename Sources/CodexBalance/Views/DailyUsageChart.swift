import CodexBalanceCore
import SwiftUI

enum DailyUsageChartSupport {
  static let maximumDays = 30

  static func visibleRows(_ rows: [TokenBucket]) -> [TokenBucket] {
    Array(rows.suffix(maximumDays))
  }

  static func dateLabel(for row: TokenBucket) -> String {
    row.label
  }

  static func compactTokens(for row: TokenBucket) -> String {
    HourlyTokenTooltipFormatter.compact(row.totalTokens)
  }
}

struct DailyUsageChart: View {
  let data: DeviceUsageTrendData
  let palette: DashboardPalette

  @State private var hoveredPointID: DeviceUsageTrendPoint.ID?

  private let barAreaHeight: CGFloat = 96
  private let slotWidth: CGFloat = 40
  private let slotSpacing: CGFloat = 6
  private let tooltipWidth: CGFloat = 300

  var body: some View {
    let maximum = max(1, data.points.map(\.totalTokens).max() ?? 1)

    VStack(alignment: .leading, spacing: 8) {
      DeviceUsageLegend(data: data, palette: palette)

      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: true) {
          HStack(alignment: .top, spacing: slotSpacing) {
            ForEach(Array(data.points.enumerated()), id: \.element.id) { index, point in
              daySlot(
                point,
                index: index,
                count: data.points.count,
                maximum: maximum
              )
              .id(point.id)
            }
          }
          .padding(.horizontal, 4)
        }
        .scrollIndicators(.visible)
        .onAppear {
          scrollToLatest(proxy: proxy, pointID: data.points.last?.id)
        }
        .onChange(of: data.points.last?.id) { _, pointID in
          scrollToLatest(proxy: proxy, pointID: pointID)
        }
      }
      .frame(height: data.tooltipHeight + barAreaHeight + 30)
      .accessibilityLabel("最近 30 天多设备 Token 趋势")
    }
  }

  private func daySlot(
    _ point: DeviceUsageTrendPoint,
    index: Int,
    count: Int,
    maximum: Int
  ) -> some View {
    let isHovered = hoveredPointID == point.id
    let barHeight = point.totalTokens > 0
      ? max(3, barAreaHeight * CGFloat(point.totalTokens) / CGFloat(maximum))
      : 2

    return VStack(spacing: 5) {
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
          .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.primary.opacity(isHovered ? 0.24 : 0.12))
            .frame(height: barHeight)
        }
      }
      .frame(height: barAreaHeight)
      .overlay(alignment: .bottom) {
        if isHovered {
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .stroke(Color.primary.opacity(0.72), lineWidth: 1)
            .frame(height: barHeight)
        }
      }
      .shadow(color: isHovered ? Color.primary.opacity(0.22) : .clear, radius: 5, y: 1)

      Text(point.label)
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .foregroundStyle(DashboardColors.subtleText)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(height: 12)
    }
    .frame(width: slotWidth)
    .contentShape(Rectangle())
    .onHover { isInside in
      hoveredPointID = isInside ? point.id : (hoveredPointID == point.id ? nil : hoveredPointID)
    }
    .help("\(point.label) · 合计 \(BalanceFormatters.exactNumber(point.totalTokens)) Token · \(point.totalCalls) 次调用")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(point.label)
    .accessibilityValue(DeviceUsageTrendAccessibility.value(for: point))
    .accessibilityHint("横向滚动可查看最近 30 天，悬停显示多设备合计和明细")
    .overlay(alignment: tooltipAlignment(index: index, count: count)) {
      if isHovered {
        DeviceUsageTrendTooltip(point: point, palette: palette)
          .frame(width: tooltipWidth)
          .allowsHitTesting(false)
          .transition(.opacity.combined(with: .scale(scale: 0.96)))
      }
    }
    .zIndex(isHovered ? 2 : 0)
    .animation(.easeOut(duration: 0.12), value: isHovered)
  }

  private func tooltipAlignment(index: Int, count: Int) -> Alignment {
    if index <= 1 { return .topLeading }
    if index >= count - 2 { return .topTrailing }
    return .top
  }

  private func scrollToLatest(proxy: ScrollViewProxy, pointID: DeviceUsageTrendPoint.ID?) {
    guard let pointID else { return }
    DispatchQueue.main.async {
      proxy.scrollTo(pointID, anchor: .trailing)
    }
  }
}
