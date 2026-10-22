import Foundation
import Testing
@testable import CodexBalance

@MainActor @Suite(.serialized)
struct DashboardOperationFeedbackTests {
  @Test func failedExportCanRetryWithoutMaskingRefreshState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let blocker = root.appendingPathComponent("blocker")
    try Data("preserve".utf8).write(to: blocker)
    let store = DashboardStore(startServices: false)
    store.isFullRefreshing = true
    #expect(await !store.writeExport({ "a,b\n1,2" }, to: blocker.appendingPathComponent("export.csv"), title: "测试 CSV", successMessage: "成功"))
    #expect(store.operationFeedback?.kind == .failure)
    #expect(store.operationFeedback?.symbol == "exclamationmark.triangle.fill")
    #expect(store.isFullRefreshing)
    #expect(try String(contentsOf: blocker, encoding: .utf8) == "preserve")
    let output = root.appendingPathComponent("export.csv")
    #expect(await store.writeExport({ "a,b\n1,2" }, to: output, title: "测试 CSV", successMessage: "已导出"))
    #expect(store.operationFeedback?.kind == .success)
    #expect(try String(contentsOf: output, encoding: .utf8) == "a,b\n1,2")
    store.operationFeedback = nil
    #expect(store.isFullRefreshing)
  }
}
