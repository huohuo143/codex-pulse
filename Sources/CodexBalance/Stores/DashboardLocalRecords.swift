import AppKit
import CodexBalanceCore
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

extension DashboardStore {
  func saveCreditExpiry(batch: CreditExpiryBatch, confirmed: Bool) {
    let cleanSource = batch.record.source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !confirmed || (status?.accountScope != nil && !cleanSource.isEmpty) else {
      expiryMessage = "确认前需要读取当前账户，并填写到期日来源"; return
    }
    guard let date = CreditExpiryBatch.localDate(batch.expiryDate),
      !batch.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      batch.grantedCredits.map({ $0.isFinite && $0 > 0 }) ?? true else {
      expiryMessage = "请填写名称、有效日期和正确的发放数量"; return
    }
    var saved = batch
    saved.record = CreditExpiryRecord(expiresAt: date, source: cleanSource,
      confirmedAt: confirmed ? Date() : nil, accountScope: confirmed ? status?.accountScope : nil)
    Task {
      do {
        let storage = creditExpiryStore
        var ledger = creditExpiry
        ledger.upsert(saved)
        let updatedLedger = ledger
        try await Task.detached(priority: .utility) { try storage.save(updatedLedger) }.value
        creditExpiry = updatedLedger; expiryMessage = confirmed ? "已保存当前账户的这一笔记录" : "已保存这一笔，等待核实"
        writeWidgetSnapshotFile()
      } catch { expiryMessage = "记录保存失败：\(error.localizedDescription)" }
    }
  }

  func importModelPrices() {
    let panel = NSOpenPanel()
    panel.title = "导入模型价格表"
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        let preview = try await Task.detached(priority: .utility) {
          try ModelPricingStore.shared.preview(data: Data(contentsOf: url))
        }.value
        let alert = NSAlert()
        alert.messageText = "核对价格更新"
        alert.informativeText = preview.summary
        alert.addButton(withTitle: "应用价格表")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try await Task.detached(priority: .utility) { try ModelPricingStore.shared.install(preview.document) }.value
        pricingMessage = ModelPricingStore.shared.snapshot().description
        refresh(forceFull: true)
      } catch { pricingMessage = "导入未应用：\(error.localizedDescription)" }
    }
  }

  func copyUsageSummary() {
    guard hasUsageData else { exportMessage = "用量首次统计中，请稍后复制"; return }
    let stats = tokenStats
    let weeklyText = weekly.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--"
    var lines = [
      "Codex 脉动 · \(Date().formatted(date: .abbreviated, time: .shortened))",
      "7天剩余额度：\(weeklyText)",
      "滚动24h：\(BalanceFormatters.compactNumber(stats.rolling24HoursTokens)) Token",
      "近7天：\(BalanceFormatters.compactNumber(stats.last7DaysTokens)) Token",
      "本月：\(BalanceFormatters.compactNumber(stats.monthTokens)) Token",
      "按当前价格表折算：\(stats.costMonth.displayUSD) · \(stats.costMonth.coverageLabel)",
      "额度状态：\(quotaStatusLabel)"
    ]
    if stats.costMonth.isPartial { lines.append("未计价模型：" + stats.costMonth.unpricedModels.joined(separator: ", ")) }
    if let top = stats.categoryBreakdown.max(by: { $0.totalTokens < $1.totalTokens }), top.totalTokens > 0 {
      lines.append("主要工作类型：\(top.category.label)（\(BalanceFormatters.compactNumber(top.totalTokens)) Token）")
    }
    if let probability = codexRadarSnapshot?.probability24hPercent {
      let level = codexRadarSnapshot?.latestLevelLabel ?? "研判中"
      lines.append("Codex 24h 重置概率：\(probability)%（\(level)）")
      lines.append(CodexRadarService.attributionText)
    }
    if let forecast = quotaForecast {
      if let rate = forecast.ratePerDay {
        lines.append("额度节奏：\(String(format: "%.1f", rate)) 个百分点/天")
      }
      if let exhaustion = forecast.estimatedExhaustion {
        lines.append("预计耗尽：\(exhaustion.formatted(date: .abbreviated, time: .shortened))")
      } else if let reason = forecast.reason {
        lines.append("额度预测：\(reason)")
      }
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    exportMessage = "用量摘要已复制"
  }

  func exportUsageCSV() {
    guard hasUsageData else { exportMessage = "用量首次统计中，请稍后导出"; return }
    let panel = NSSavePanel()
    panel.title = "导出 Codex 用量"
    panel.prompt = "导出"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.commaSeparatedText]
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmm"
    panel.nameFieldStringValue = "codex-usage-\(formatter.string(from: Date())).csv"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let csv = CodexUsageCSVExporter.makeCSV(
      stats: tokenStats,
      cnyRate: exchangeRate?.rate,
      generatedAt: Date()
    )
    do {
      try csv.write(to: url, atomically: true, encoding: .utf8)
      exportMessage = "已导出：\(url.lastPathComponent)"
    } catch {
      exportMessage = "导出失败：\(error.localizedDescription)"
    }
  }

}
