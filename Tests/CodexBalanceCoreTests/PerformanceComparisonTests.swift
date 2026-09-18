import Foundation
import Darwin
import Testing
@testable import CodexBalanceCore

@Suite("Controlled before-after performance", .serialized)
struct PerformanceComparisonTests {
  @Test func benchmark() throws {
    for count in [100, 1000, 10000] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-perf-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let now = ISO8601DateFormatter().date(from: "2026-09-01T00:12:00Z")!
      let texts = (0..<50).map { event(at: now.addingTimeInterval(-Double($0) * 3600), total: 100, last: 100) }
      for i in 0..<count { try texts[i % 50].write(to: root.appendingPathComponent("\(i).jsonl"), atomically: true, encoding: .utf8) }
      let index = SessionFileIndex(roots: [root], watch: false)
      let reader = CodexStatusReader(sessionsRoot: root, fileIndex: index, preferLiveStatus: false)
      let cpuStart = cpuTime()
      let start = Date()
      let result = try reader.read(now: now)
      let cold = Date().timeIntervalSince(start) * 1000
      let coldCPU = cpuTime() - cpuStart
      #expect(result.scannedFiles == count)
      #expect(result.tokenStats.rolling24HoursTokens == count / 50 * 25 * 100)
      let beforeMetadata = index.metadataReadCount
      let warmCPUStart = cpuTime()
      var warm: [Double] = []
      for _ in 0..<5 {
        let t = Date(); let unchanged = try reader.read(now: now)
        warm.append(Date().timeIntervalSince(t) * 1000)
        #expect(unchanged.tokenStats == result.tokenStats)
      }
      let warmCPU = (cpuTime() - warmCPUStart) / 5
      let warmMetadata = (index.metadataReadCount - beforeMetadata) / 5
      let fast = Date(); _ = try reader.readFast(now: now)
      let fastMS = Date().timeIntervalSince(fast) * 1000
      var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
      print("BENCHMARK after files=\(count) cold_ms=\(cold) cold_cpu_s=\(coldCPU) warm_median_ms=\(warm.sorted()[2]) warm_cpu_s=\(warmCPU) warm_log_metadata_checks=\(warmMetadata) fast_ms=\(fastMS) peak_rss_bytes=\(usage.ru_maxrss)")
    }
  }
  private func cpuTime() -> Double {
    var info = rusage(); getrusage(RUSAGE_SELF, &info)
    return Double(info.ru_utime.tv_sec + info.ru_stime.tv_sec) + Double(info.ru_utime.tv_usec + info.ru_stime.tv_usec) / 1_000_000
  }
  private func event(at time: Date, total: Int, last: Int) -> String {
    let stamp = ISO8601DateFormatter().string(from: time)
    return "{\"timestamp\":\"\(stamp)\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":10,\"window_minutes\":300,\"resets_at\":2000000000}},\"info\":{\"total_token_usage\":{\"total_tokens\":\(total),\"input_tokens\":\(total),\"output_tokens\":0},\"last_token_usage\":{\"total_tokens\":\(last),\"input_tokens\":\(last),\"output_tokens\":0}}}}\n"
  }
}
