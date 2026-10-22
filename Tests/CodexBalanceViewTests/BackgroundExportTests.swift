import Foundation
import Testing
@testable import CodexBalance

@MainActor @Suite("Background export lifecycle", .serialized)
struct BackgroundExportTests {
  @Test func slowFormattingLeavesMainActorAvailable() async throws {
    let f = try ExportFixture(); defer { f.clean() }
    let work = ExportGate(); defer { work.release.signal() }
    let store = DashboardStore(startServices: false)
    let task = Task {
      await store.writeExport({ try work.pause(); return "列一,列二\n甲,乙\n" },
        to: f.output, title: "用量 CSV", successMessage: "完成")
    }
    try await waitUntilEntered(work)
    #expect(work.calls == 1)
    #expect(!work.ranOnMainThread)
    #expect(store.isExporting)
    #expect(store.exportProgressTitle == "用量 CSV")
    store.selectedSection = .settings
    #expect(store.selectedSection == .settings)
    #expect(!FileManager.default.fileExists(atPath: f.output.path))
    work.release.signal()
    #expect(await task.value)
    #expect(!store.isExporting)
    #expect(store.operationFeedback == .init(.success, "完成"))
    #expect(try String(contentsOf: f.output, encoding: .utf8) == "列一,列二\n甲,乙\n")
  }

  @Test func slowWritingRejectsOtherExportsButKeepsBrowsingAndRefreshState() async throws {
    let f = try ExportFixture(); defer { f.clean() }
    let work = ExportGate(); defer { work.release.signal() }
    let duplicate = ExportGate()
    let store = DashboardStore(startServices: false)
    store.isFullRefreshing = true
    let task = Task {
      await store.writeExport({ "immutable captured report" }, to: f.output, title: "额度历史", successMessage: "原导出完成",
        writer: { text, url in try work.pause(); try text.write(to: url, atomically: true, encoding: .utf8) })
    }
    try await waitUntilEntered(work)
    #expect(!work.ranOnMainThread)
    #expect(store.isExporting)
    #expect(await !store.writeExport({ duplicate.record(); return "must not run" }, to: f.output,
      title: "脱敏诊断报告", successMessage: "错误的第二次成功"))
    // Entry points must return before showing another native save panel.
    store.exportUsageCSV()
    store.exportQuotaHistoryCSV(period: .day)
    store.exportDiagnosticReport()
    #expect(duplicate.calls == 0)
    #expect(store.exportProgressTitle == "额度历史")
    #expect(store.operationFeedback == nil)
    store.selectedSection = .insights
    #expect(store.selectedSection == .insights)
    #expect(store.isFullRefreshing)
    work.release.signal()
    #expect(await task.value)
    #expect(store.isFullRefreshing)
    #expect(store.operationFeedback?.message == "原导出完成")
    #expect(try String(contentsOf: f.output, encoding: .utf8) == "immutable captured report")
  }

  @Test func formattingFailurePreservesExistingFileAndAllowsRetry() async throws {
    let f = try ExportFixture(); defer { f.clean() }
    let original = Data("original destination".utf8)
    try original.write(to: f.output)
    let writer = ExportGate()
    let store = DashboardStore(startServices: false)
    #expect(await !store.writeExport({ throw CocoaError(.fileReadCorruptFile) }, to: f.output,
      title: "用量 CSV", successMessage: "不可出现", writer: { _, _ in writer.record() }))
    #expect(writer.calls == 0)
    #expect(!store.isExporting)
    #expect(store.operationFeedback?.kind == .failure)
    #expect(try Data(contentsOf: f.output) == original)
    #expect(await store.writeExport({ "retry complete" }, to: f.output, title: "用量 CSV", successMessage: "重试完成"))
    #expect(try String(contentsOf: f.output, encoding: .utf8) == "retry complete")
    #expect(store.operationFeedback == .init(.success, "重试完成"))
  }

  @Test func failedDiagnosticExportDoesNotClearUnderlyingHealthWarning() async throws {
    let f = try ExportFixture(); defer { f.clean() }
    let original = Data("existing report".utf8); try original.write(to: f.output)
    let store = DashboardStore(startServices: false)
    store.reliabilityMessage = "备份失败，原文件未改动"
    store.dailySummaryMessage = "摘要归档失败"
    store.dailySummaryHealth = .failed
    #expect(await !store.writeExport({ "diagnostic" }, to: f.output,
      title: "脱敏诊断报告", successMessage: "不可出现", failurePrefix: "诊断报告导出失败",
      writer: { _, _ in throw CocoaError(.fileWriteNoPermission) }))
    #expect(!store.isExporting)
    #expect(store.operationFeedback?.message.hasPrefix("诊断报告导出失败：") == true)
    #expect(store.reliabilityMessage == "备份失败，原文件未改动")
    #expect(store.dailySummaryMessage == "摘要归档失败")
    #expect(store.dailySummaryHealth == .failed)
    #expect(try Data(contentsOf: f.output) == original)
  }

  @Test func atomicWriterKeepsUTF8AndLineBreaksWhenReplacingReport() async throws {
    let f = try ExportFixture(); defer { f.clean() }
    try Data("previous".utf8).write(to: f.output)
    let content = "中文,\"包含,逗号\",\"多行\r\n文本\"\n1,2,3\n"
    let store = DashboardStore(startServices: false)
    #expect(await store.writeExport({ content }, to: f.output, title: "用量 CSV", successMessage: "已导出"))
    #expect(try Data(contentsOf: f.output) == Data(content.utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path) == [f.output.lastPathComponent])
    #expect(!store.isExporting)
  }

  private func waitUntilEntered(_ gate: ExportGate) async throws {
    for _ in 0..<100 {
      if gate.calls > 0 { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Background worker did not start")
  }
}

private struct ExportFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  var output: URL { root.appendingPathComponent("export.csv") }
  init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

private final class ExportGate: @unchecked Sendable {
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var count = 0
  private var main = false
  var calls: Int { lock.withLock { count } }
  var ranOnMainThread: Bool { lock.withLock { main } }
  func record() { lock.withLock { count += 1; main = Thread.isMainThread } }
  func pause() throws {
    record()
    guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileWriteUnknown) }
  }
}
