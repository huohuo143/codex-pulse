import AppKit
import CodexBalanceCore
import UniformTypeIdentifiers

extension DashboardStore {
  func exportQuotaHistoryCSV(period: QuotaHistoryPeriod) {
    let now = Date()
    let points = QuotaHistoryTrend.points(snapshots: quotaHistory, period: period, now: now)
    guard !points.isEmpty else { exportMessage = "所选范围暂无额度采样"; return }
    let panel = NSSavePanel()
    panel.title = "导出官方额度历史"
    panel.prompt = "导出"
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "codex-quota-\(period.rawValue)d-\(Int(now.timeIntervalSince1970)).csv"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try QuotaHistoryTrend.makeCSV(points: points, generatedAt: now).write(to: url, atomically: true, encoding: .utf8)
      exportMessage = "已导出 \(points.count) 个额度样本：\(url.lastPathComponent)"
    } catch {
      exportMessage = "额度历史导出失败：\(error.localizedDescription)"
    }
  }
}
