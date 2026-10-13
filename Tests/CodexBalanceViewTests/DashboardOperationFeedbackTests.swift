import Foundation
import Testing
@testable import CodexBalance

@MainActor @Suite(.serialized)
struct DashboardOperationFeedbackTests {
  @Test func failedExportCanRetryWithoutMaskingRefreshState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let blocker = root.appendingPathComponent("blocker")
    try Data("preserve".utf8).write(to: blocker)
    let store = DashboardStore(startServices: false)
    store.isFullRefreshing = true
    #expect(!store.writeExport("a,b\n1,2", to: blocker.appendingPathComponent("export.csv"), successMessage: "成功"))
    #expect(store.operationFeedback?.kind == .failure)
    #expect(store.operationFeedback?.symbol == "exclamationmark.triangle.fill")
    #expect(store.isFullRefreshing)
    #expect(try String(contentsOf: blocker, encoding: .utf8) == "preserve")
    let output = root.appendingPathComponent("export.csv")
    #expect(store.writeExport("a,b\n1,2", to: output, successMessage: "已导出"))
    #expect(store.operationFeedback?.kind == .success)
    #expect(try String(contentsOf: output, encoding: .utf8) == "a,b\n1,2")
    store.operationFeedback = nil
    #expect(store.isFullRefreshing)
  }
}
