import CodexBalanceCore
import SwiftUI

struct FlexibleCreditsView: View {
  var balance: CodexFlexibleCreditBalance?
  var isLoading: Bool
  var tint: Color
  var expiryLabel: String = "暂无已确认到期日"
  var metadata: SourceReadMetadata? = nil

  var body: some View {
    PanelCard {
      HStack(spacing: 16) {
        ZStack {
          Circle().fill(tint.opacity(0.14))
          Image(systemName: "creditcard.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(tint)
        }
        .frame(width: 56, height: 56)

        VStack(alignment: .leading, spacing: 6) {
          Text("Codex 灵活额度")
            .font(.system(size: 15, weight: .bold))
          Text("ChatGPT/Codex 灵活额度 · 非 API 余额")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(DashboardColors.subtleText)
            .lineLimit(1)
          SourceStatusLabel(metadata: metadata, compact: true)
          Label(expiryLabel, systemImage: "calendar.badge.clock")
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(DashboardColors.subtleText)
            .lineLimit(1)
        }
        .layoutPriority(1)

        Spacer(minLength: 12)

        VStack(alignment: .trailing, spacing: 5) {
          Text(balanceText)
            .font(.system(size: 32, weight: .heavy, design: .rounded))
            .foregroundStyle(tint)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .fixedSize(horizontal: true, vertical: false)
            .contentTransition(.numericText())
          Text(creditCountText)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(DashboardColors.subtleText)
            .monospacedDigit()
            .lineLimit(1)
        }
        .layoutPriority(2)
      }
    }
  }

  private var balanceText: String {
    guard let balance else { return isLoading ? "US$--" : "US$--" }
    if balance.unlimited { return "无限" }
    guard let amount = balance.amountUSD else { return "US$--" }
    if amount.rounded() == amount { return String(format: "US$%.0f", amount) }
    return String(format: "US$%.2f", amount)
  }

  private var creditCountText: String {
    guard let credits = balance?.balanceCredits else {
      return isLoading ? "正在读取官方余额…" : "官方余额暂不可用"
    }
    return "\(Self.creditNumber.string(from: NSNumber(value: credits)) ?? "--") credits"
  }

  private static let creditNumber: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 2
    return formatter
  }()

}
