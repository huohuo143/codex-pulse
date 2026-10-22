import AppKit
import CodexBalanceCore
import UniformTypeIdentifiers

extension DashboardStore {
  func exportQuotaHistoryCSV(period: QuotaHistoryPeriod) {
    guard !isExporting else { return }
    let now = Date()
    let points = QuotaHistoryTrend.points(snapshots: quotaHistory, period: period, now: now)
    guard !points.isEmpty else { operationFeedback = .init(.information, "所选范围暂无额度采样"); return }
    let panel = NSSavePanel()
    panel.title = "导出官方额度历史"
    panel.prompt = "导出"
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "codex-quota-\(period.rawValue)d-\(Int(now.timeIntervalSince1970)).csv"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      await writeExport({ QuotaHistoryTrend.makeCSV(points: points, generatedAt: now) },
        to: url, title: "额度历史", successMessage: "已导出 \(points.count) 个额度样本：\(url.lastPathComponent)",
        failurePrefix: "额度历史导出失败")
    }
  }
}
