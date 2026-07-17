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
  let rows: [TokenBucket]
  let tint: Color

  @State private var hoveredBucketID: TokenBucket.ID?

  private let chartHeight: CGFloat = 96
  private let barSpacing: CGFloat = 3
  private let tooltipWidth: CGFloat = 172

  var body: some View {
    GeometryReader { proxy in
      let maximum = max(1, rows.map(\.totalTokens).max() ?? 1)

      ZStack(alignment: .topLeading) {
        HStack(alignment: .bottom, spacing: barSpacing) {
          ForEach(rows) { row in
            hourSlot(row, maximum: maximum, chartHeight: proxy.size.height)
          }
        }

        if let selection = hoveredSelection {
          HourlyUsageTooltip(row: selection.row, tint: tint)
            .frame(width: tooltipWidth)
            .position(
              x: tooltipCenterX(
                index: selection.index,
                count: rows.count,
                chartWidth: proxy.size.width
              ),
              y: 28
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
          hoveredBucketID = bucketID(atX: location.x, chartWidth: proxy.size.width)
        case .ended:
          hoveredBucketID = nil
        }
      }
      .animation(.easeOut(duration: 0.12), value: hoveredBucketID)
    }
    .frame(height: chartHeight)
  }

  private func hourSlot(_ row: TokenBucket, maximum: Int, chartHeight: CGFloat) -> some View {
    let isHovered = hoveredBucketID == row.id
    let barHeight = max(3, chartHeight * CGFloat(row.totalTokens) / CGFloat(maximum))

    return ZStack(alignment: .bottom) {
      Color.clear
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(tint.opacity(row.totalTokens > 0 ? (isHovered ? 1 : 0.92) : (isHovered ? 0.34 : 0.16)))
        .frame(height: barHeight)
        .overlay {
          if isHovered {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .stroke(Color.primary.opacity(0.72), lineWidth: 1)
          }
        }
        .shadow(color: isHovered ? tint.opacity(0.42) : .clear, radius: 5, y: 1)
    }
    .frame(maxWidth: .infinity, minHeight: chartHeight, maxHeight: chartHeight, alignment: .bottom)
    .contentShape(Rectangle())
    .help("\(row.label) · \(BalanceFormatters.exactNumber(row.totalTokens)) Token")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.label)
    .accessibilityValue("\(BalanceFormatters.exactNumber(row.totalTokens)) Token")
    .accessibilityHint("悬停时显示紧凑单位和精确 Token 数")
  }

  private var hoveredSelection: (index: Int, row: TokenBucket)? {
    guard let hoveredBucketID,
          let index = rows.firstIndex(where: { $0.id == hoveredBucketID })
    else { return nil }
    return (index, rows[index])
  }

  private func bucketID(atX x: CGFloat, chartWidth: CGFloat) -> TokenBucket.ID? {
    guard !rows.isEmpty, chartWidth > 0 else { return nil }
    let normalizedX = min(max(0, x), chartWidth.nextDown)
    let index = min(rows.count - 1, Int(normalizedX / chartWidth * CGFloat(rows.count)))
    return rows[index].id
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

private struct HourlyUsageTooltip: View {
  let row: TokenBucket
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(row.label)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.secondary)
      Text("\(HourlyTokenTooltipFormatter.compact(row.totalTokens)) Token")
        .font(.system(size: 13, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
        .monospacedDigit()
      Text("精确值：\(BalanceFormatters.exactNumber(row.totalTokens))")
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .foregroundStyle(.primary.opacity(0.78))
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(tint.opacity(0.42), lineWidth: 1)
    }
    .shadow(color: Color.black.opacity(0.18), radius: 8, y: 4)
  }
}
