import Foundation

public enum CodexUsageCSVExporter {
  public static func makeCSV(
    stats: TokenStats,
    cnyRate: Double?,
    generatedAt: Date = Date()
  ) -> String {
    var rows: [[String]] = [
      ["Codex 脉动用量导出"],
      ["生成时间", ISO8601DateFormatter().string(from: generatedAt)],
      ["说明", "金额为 API 等价预估，不是 ChatGPT/Codex 订阅实际账单"],
      [],
      ["汇总", "Token", "USD", "CNY"],
      summaryRow("滚动24小时", tokens: stats.rolling24HoursTokens, estimate: stats.cost24Hours, cnyRate: cnyRate),
      summaryRow("近7天", tokens: stats.last7DaysTokens, estimate: stats.cost7Days, cnyRate: cnyRate),
      summaryRow("本月", tokens: stats.monthTokens, estimate: stats.costMonth, cnyRate: cnyRate),
      [],
      ["小时", "Token", "Input", "Cached input", "Output", "Reasoning output", "Calls"]
    ]

    rows.append(contentsOf: stats.hourly.map {
      [
        $0.label,
        String($0.totalTokens),
        String($0.inputTokens),
        String($0.cachedInputTokens),
        String($0.outputTokens),
        String($0.reasoningOutputTokens),
        String($0.calls)
      ]
    })
    rows.append([])
    rows.append(["模型", "Token", "Input", "Cached input", "Output", "Calls"])

    let groupedModels: [String: [ModelHourlyBucket]] = Dictionary(grouping: stats.modelHourly, by: \.model)
    var modelRows: [[String]] = []
    for (model, buckets) in groupedModels {
      let totalTokens = buckets.reduce(0) { $0 + $1.totalTokens }
      let inputTokens = buckets.reduce(0) { $0 + $1.inputTokens }
      let cachedTokens = buckets.reduce(0) { $0 + $1.cachedInputTokens }
      let outputTokens = buckets.reduce(0) { $0 + $1.outputTokens }
      let calls = buckets.reduce(0) { $0 + $1.calls }
      modelRows.append([
        model,
        String(totalTokens),
        String(inputTokens),
        String(cachedTokens),
        String(outputTokens),
        String(calls)
      ])
    }
    modelRows.sort { (Int($0[1]) ?? 0) > (Int($1[1]) ?? 0) }
    rows.append(contentsOf: modelRows)

    rows.append([])
    rows.append(["工作类型", "Token", "Input", "Output", "Reasoning output", "Calls"])
    rows.append(contentsOf: stats.categoryBreakdown
      .filter { $0.totalTokens > 0 }
      .sorted { $0.totalTokens > $1.totalTokens }
      .map {
        [
          $0.category.label,
          String($0.totalTokens),
          String($0.inputTokens),
          String($0.outputTokens),
          String($0.reasoningOutputTokens),
          String($0.calls)
        ]
      })

    rows.append([])
    rows.append(["最近调用时间", "模型", "项目", "Token", "Input", "Cached input", "Output"])
    rows.append(contentsOf: stats.recentUsageEvents.map {
      [
        ISO8601DateFormatter().string(from: $0.timestamp),
        $0.model,
        $0.projectName,
        String($0.totalTokens),
        String($0.inputTokens),
        String($0.cachedInputTokens),
        String($0.outputTokens)
      ]
    })

    return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
  }

  private static func summaryRow(
    _ label: String,
    tokens: Int,
    estimate: CostEstimate,
    cnyRate: Double?
  ) -> [String] {
    [
      label,
      String(tokens),
      String(format: "%.6f", estimate.usd),
      cnyRate.map { String(format: "%.6f", estimate.usd * $0) } ?? ""
    ]
  }

  private static func escape(_ value: String) -> String {
    guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
      return value
    }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
