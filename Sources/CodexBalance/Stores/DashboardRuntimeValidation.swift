import CodexBalanceCore
import Foundation

extension DashboardStore {
  func recordRuntimeEvent(_ name: String, lag: Double = 0) {
    guard PulsePreferences.isIsolated else { return }
    let metrics: [String: Double] = [
      "mainTimerLagSeconds": lag,
      "parsedFiles": Double(status?.readerDiagnostics?.parsedFiles ?? 0),
      "logBytesRead": Double(status?.readerDiagnostics?.bytesRead ?? 0),
      "aggregations": Double(status?.readerDiagnostics?.aggregations ?? 0),
      "analysisGeneration": Double(analysisGeneration),
      "quotaSuccessUnix": status?.quotaRead?.lastSuccessAt?.timeIntervalSince1970 ?? 0,
      "radarAttemptUnix": codexRadarSnapshot?.syncState?.lastAttemptAt?.timeIntervalSince1970 ?? 0,
      "radarSuccessUnix": codexRadarSnapshot?.syncState?.lastSuccessAt?.timeIntervalSince1970 ?? 0,
      "radarFailures": Double(codexRadarSnapshot?.syncState?.consecutiveFailures ?? 0)
    ]
    let event = PulseRuntimeEvent(name: name, metrics: metrics, labels: ["version": AppInfo.version,
      "quotaSource": status?.quotaRead?.source ?? "unavailable", "quotaState": quotaStatusLabel])
    Task { await PulseRuntimeRecorder.shared.record(event) }
  }
}
