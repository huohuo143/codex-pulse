import AppKit
import CodexBalanceCore
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

extension DashboardStore {
  @discardableResult
  func saveCreditExpiry(batch: CreditExpiryBatch, confirmed: Bool,
    persist: (@Sendable (CreditExpiryLedger) async throws -> Void)? = nil) async -> Bool {
    // Claim the write before suspending so rapid submissions cannot each save
    // a snapshot that omits the other submission.
    guard !isSavingCreditExpiry else { return false }
    guard creditExpiryStorageIssue == nil else {
      expiryMessage = creditExpiryStorageIssue?.localizedDescription
      return false
    }
    let account = status?.accountScope
    let cleanSource = batch.record.source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !confirmed || (account?.isEmpty == false && !cleanSource.isEmpty) else {
      expiryMessage = "确认前需要读取当前账户，并填写到期日来源"; return false
    }
    guard let date = CreditExpiryBatch.localDate(batch.expiryDate),
      !batch.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      batch.grantedCredits.map({ $0.isFinite && $0 > 0 }) ?? true else {
      expiryMessage = "请填写名称、有效日期和正确的发放数量"; return false
    }
    var saved = batch
    saved.title = batch.title.trimmingCharacters(in: .whitespacesAndNewlines)
    saved.record = CreditExpiryRecord(expiresAt: date, source: cleanSource,
      confirmedAt: confirmed ? Date() : nil, accountScope: confirmed ? account : nil)
    var ledger = creditExpiry
    ledger.upsert(saved)
    let updatedLedger = ledger
    isSavingCreditExpiry = true
    expiryMessage = "正在保存这一笔记录…"
    defer { isSavingCreditExpiry = false }
    do {
      if let persist {
        try await persist(updatedLedger)
      } else {
        let storage = creditExpiryStore
        try await Task.detached(priority: .utility) { try storage.save(updatedLedger) }.value
      }
      creditExpiry = updatedLedger
      expiryMessage = confirmed && status?.accountScope != account
        ? "已保存到提交时的账户；当前账户已变化，请重新核对"
        : (confirmed ? "已保存当前账户的这一笔记录" : "已保存这一笔，等待核实")
      writeWidgetSnapshotFile()
      return true
    } catch {
      await updateCreditExpiryReadIssue()
      expiryMessage = "记录保存失败：\(error.localizedDescription)"
      return false
    }
  }

  func reloadCreditExpiry() async -> CreditExpiryLedger? {
    guard !isSavingCreditExpiry else { return nil }
    isSavingCreditExpiry = true
    expiryMessage = "正在重新读取到期记录…"
    defer { isSavingCreditExpiry = false }
    let storage = creditExpiryStore
    let read = await Task.detached(priority: .utility) { storage.loadResult() }.value
    creditExpiryStorageIssue = read.issue
    creditExpiryRecovery = read.recovery
    guard read.issue == nil else { expiryMessage = read.issue?.localizedDescription; return nil }
    creditExpiry = read.ledger
    expiryMessage = "已重新读取到期记录"
    writeWidgetSnapshotFile()
    return read.ledger
  }

  func restoreCreditExpiryBackup() async -> CreditExpiryLedger? {
    guard !isSavingCreditExpiry else { return nil }
    isSavingCreditExpiry = true
    expiryMessage = "正在恢复上次有效记录…"
    defer { isSavingCreditExpiry = false }
    let storage = creditExpiryStore
    do {
      let result = try await Task.detached(priority: .utility) { try storage.restorePrevious() }.value
      creditExpiry = result.ledger
      creditExpiryStorageIssue = nil
      creditExpiryRecovery = nil
      expiryMessage = "已恢复备份中的 \(result.ledger.batches.count) 笔记录"
        + (result.preservedOriginalURL == nil ? "" : "；原文件已单独保留")
      writeWidgetSnapshotFile()
      return result.ledger
    } catch {
      await updateCreditExpiryReadIssue()
      expiryMessage = "恢复未完成：\(error.localizedDescription)"
      return nil
    }
  }

  private func updateCreditExpiryReadIssue() async {
    let storage = creditExpiryStore
    let read = await Task.detached(priority: .utility) { storage.loadResult() }.value
    creditExpiryStorageIssue = read.issue
    creditExpiryRecovery = read.recovery
  }

  func openCreditExpiryFolder() {
    NSWorkspace.shared.selectFile(creditExpiryStore.url.path,
      inFileViewerRootedAtPath: creditExpiryStore.url.deletingLastPathComponent().path)
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
    guard hasUsageData else { operationFeedback = .init(.information, "用量首次统计中，请稍后复制"); return }
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
    if pasteboard.setString(lines.joined(separator: "\n"), forType: .string) {
      operationFeedback = .init(.success, "用量摘要已复制")
    } else {
      operationFeedback = .init(.failure, "复制失败，请重试")
    }
  }

  func exportUsageCSV() {
    guard hasUsageData else { operationFeedback = .init(.information, "用量首次统计中，请稍后导出"); return }
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
    writeExport(csv, to: url, successMessage: "已导出：\(url.lastPathComponent)")
  }

  @discardableResult
  func writeExport(_ content: String, to url: URL, successMessage: String, failurePrefix: String = "导出失败") -> Bool {
    do {
      try content.write(to: url, atomically: true, encoding: .utf8)
      operationFeedback = .init(.success, successMessage)
      return true
    } catch {
      operationFeedback = .init(.failure, "\(failurePrefix)：\(error.localizedDescription)")
      return false
    }
  }
}
