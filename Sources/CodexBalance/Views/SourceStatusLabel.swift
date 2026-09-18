import CodexBalanceCore
import SwiftUI

struct SourceStatusLabel: View {
  let metadata: SourceReadMetadata?
  var resetAt: Date? = nil
  var compact = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let state = metadata?.state(at: context.date, resetAt: resetAt) ?? .unavailable
      HStack(spacing: 4) {
        Image(systemName: state == .fresh ? "checkmark.circle" : "clock.badge.exclamationmark")
        Text(state.label)
        if !compact, let date = metadata?.lastSuccessAt {
          Text("· 成功读取")
          Text(date, style: .time)
        }
      }
      .font(.system(size: compact ? 9 : 10, weight: .medium))
      .foregroundStyle(state == .fresh ? Color.secondary : Color.orange)
      .lineLimit(1)
      .help("来源：\(metadata?.source ?? "尚无已验证数据")；界面更新时间不代表官方读取成功。")
    }
  }
}
