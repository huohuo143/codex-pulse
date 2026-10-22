import AppKit
import CodexBalanceCore

extension DashboardStore {
  func updateProjectBudgetReadIssue(storage: ProjectBudgetStore? = nil) {
    let read = (storage ?? projectBudgetStore).loadResult()
    projectBudgetStorageIssue = read.issue
    projectBudgetRecovery = read.recovery
  }

  @discardableResult
  func reloadProjectBudgets() -> Bool {
    defer { runReliabilityCheck(allowAutomation: false) }
    let read = projectBudgetStore.loadResult()
    projectBudgetStorageIssue = read.issue
    projectBudgetRecovery = read.recovery
    guard read.issue == nil else { budgetMessage = read.issue?.localizedDescription; return false }
    projectBudgets = read.budgets
    budgetMessage = "已重新读取项目预算"
    lastAnalysisStats = nil
    updateUsageAnalysis()
    return true
  }

  @discardableResult
  func restoreProjectBudgetBackup() -> Bool {
    defer { runReliabilityCheck(allowAutomation: false) }
    do {
      let result = try projectBudgetStore.restorePrevious()
      projectBudgets = result.budgets
      projectBudgetStorageIssue = nil
      projectBudgetRecovery = nil
      projectBudgetWriteFailed = false
      budgetMessage = "已恢复备份中的 \(result.budgets.count) 个项目预算"
        + (result.preservedOriginalURL == nil ? "" : "；损坏原件已单独保留")
      lastAnalysisStats = nil
      updateUsageAnalysis()
      return true
    } catch {
      updateProjectBudgetReadIssue()
      recordProjectBudgetWriteFailure(error)
      budgetMessage = "预算恢复失败：\(error.localizedDescription)"
      return false
    }
  }

  func recordProjectBudgetWriteFailure(_ error: Error) {
    guard projectBudgetStorageIssue == nil else { return }
    if let issue = error as? ProjectBudgetStorageIssue,
      [.invalidRecord, .recordTooLarge, .alreadyValid].contains(issue) { return }
    projectBudgetWriteFailed = true
  }

  func openProjectBudgetFolder() {
    let url = projectBudgetStore.storageURL
    NSWorkspace.shared.activateFileViewerSelecting([
      FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
    ])
  }
}
