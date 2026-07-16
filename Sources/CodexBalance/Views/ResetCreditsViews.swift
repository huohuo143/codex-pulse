import CodexBalanceCore
import SwiftUI

struct CompactResetCreditsView: View {
  var summary: RateLimitResetCreditsSummary?
  var isLoading: Bool
  var tint: Color
  var mini: Bool

  private var visibleCredits: [RateLimitResetCredit] {
    Array((summary?.availableCredits ?? []).prefix(3))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: mini ? 4 : 5) {
      HStack(spacing: 6) {
        Text("Full reset 权益")
          .font(.system(size: mini ? 11 : 13, weight: .bold))
        Spacer(minLength: 4)
        Text(countText)
          .font(.system(size: mini ? 10.5 : 12, weight: .heavy, design: .rounded))
          .foregroundStyle(tint)
          .padding(.horizontal, mini ? 6 : 8)
          .padding(.vertical, mini ? 2 : 3)
          .background(tint.opacity(0.14), in: Capsule())
      }

      if let summary {
        if summary.availableCount == 0 {
          statusRow("暂无可用 Full reset")
        } else if visibleCredits.isEmpty {
          statusRow(summary.credits == nil ? "到期明细暂未返回" : "本次未返回到期明细")
        } else {
          ForEach(visibleCredits) { credit in
            creditRow(credit)
          }
          if summary.availableCount > visibleCredits.count {
            statusRow("另有 \(summary.availableCount - visibleCredits.count) 次，展开查看")
          }
        }
      } else {
        statusRow(isLoading ? "正在读取重置权益…" : "重置权益暂不可用")
      }
    }
    .padding(.horizontal, mini ? 8 : 10)
    .padding(.vertical, mini ? 6 : 8)
    .background(
      RoundedRectangle(cornerRadius: mini ? 9 : 11, style: .continuous)
        .fill(DashboardColors.faintFill)
        .overlay(
          RoundedRectangle(cornerRadius: mini ? 9 : 11, style: .continuous)
            .stroke(DashboardColors.border)
        )
    )
  }

  private var countText: String {
    guard let summary else { return "可用 -- 次" }
    return "可用 \(summary.availableCount) 次"
  }

  private func creditRow(_ credit: RateLimitResetCredit) -> some View {
    HStack(spacing: 5) {
      Text(credit.title)
        .lineLimit(1)
      Spacer(minLength: 4)
      Text(expiryText(credit))
        .foregroundStyle(expiryColor(credit))
        .monospacedDigit()
        .lineLimit(1)
    }
    .font(.system(size: mini ? 10 : 12, weight: .semibold, design: .rounded))
  }

  private func statusRow(_ text: String) -> some View {
    Text(text)
      .font(.system(size: mini ? 10 : 12, weight: .medium))
      .foregroundStyle(DashboardColors.subtleText)
      .lineLimit(1)
  }

  private func expiryText(_ credit: RateLimitResetCredit) -> String {
    guard let expiresAt = credit.expiresAt else { return "无到期时间" }
    let date = BalanceFormatters.resetExpiryDate(expiresAt)
    return expiresAt <= Date() ? "\(date) · 待刷新" : "\(date) 到期"
  }

  private func expiryColor(_ credit: RateLimitResetCredit) -> Color {
    if let expiresAt = credit.expiresAt, expiresAt <= Date() { return .orange }
    return DashboardColors.subtleText
  }
}

struct ExpandedResetCreditsView: View {
  var summary: RateLimitResetCreditsSummary?
  var isLoading: Bool
  var tint: Color

  var body: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("Full reset 权益")
              .font(.system(size: 15, weight: .bold))
            Text("账户每周重置权益；只读展示，不会自动消耗")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(DashboardColors.subtleText)
          }
          Spacer()
          Text(countText)
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(tint.opacity(0.14), in: Capsule())
        }

        Divider().overlay(DashboardColors.separator)

        if let summary {
          if summary.availableCount == 0 {
            emptyText("暂无可用 Full reset")
          } else if summary.availableCredits.isEmpty {
            emptyText(summary.credits == nil ? "官方仅返回了可用次数，尚未返回到期明细" : "本次未返回可用权益明细")
          } else {
            ForEach(summary.availableCredits) { credit in
              HStack(spacing: 12) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                  .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                  Text(credit.title).font(.system(size: 12, weight: .bold))
                  Text("获得于 \(BalanceFormatters.resetExpiryDateTime(credit.grantedAt))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DashboardColors.subtleText)
                }
                Spacer()
                Text(fullExpiryText(credit))
                  .font(.system(size: 11, weight: .semibold, design: .rounded))
                  .foregroundStyle(fullExpiryColor(credit))
                  .monospacedDigit()
              }
            }
            if summary.missingDetailCount > 0 {
              emptyText("另有 \(summary.missingDetailCount) 次权益未返回到期明细")
            }
          }
        } else {
          emptyText(isLoading ? "正在读取重置权益…" : "当前 Codex 接口未提供重置权益")
        }
      }
    }
  }

  private var countText: String {
    guard let summary else { return "可用 -- 次" }
    return "可用 \(summary.availableCount) 次"
  }

  private func emptyText(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(DashboardColors.subtleText)
  }

  private func fullExpiryText(_ credit: RateLimitResetCredit) -> String {
    guard let expiresAt = credit.expiresAt else { return "无到期时间" }
    let dateTime = BalanceFormatters.resetExpiryDateTime(expiresAt)
    return expiresAt <= Date() ? "\(dateTime) · 已到期，待刷新" : "\(dateTime) 到期"
  }

  private func fullExpiryColor(_ credit: RateLimitResetCredit) -> Color {
    if let expiresAt = credit.expiresAt, expiresAt <= Date() { return .orange }
    return DashboardColors.subtleText
  }
}
