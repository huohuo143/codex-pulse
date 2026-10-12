import Foundation

public enum CodexUsageCSVExporter {
  public static func makeCSV(
    stats: TokenStats,
    cnyRate: Double?,
    generatedAt: Date = Date()
  ) -> String {
    let timestampFormatter = ISO8601DateFormatter()
    timestampFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    let validCNYRate = cnyRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    var rows: [[String]] = [
      ["Codex 脉动用量导出"],
      ["生成时间", timestampFormatter.string(from: generatedAt)],
      ["说明", "金额为 API 等价预估，不是 ChatGPT/Codex 订阅实际账单"],
      ["统计口径", "汇总、小时、日、模型和工作类型均为本机日志；模型和工作类型按本月统计；最近调用仅为保留记录"],
      ["时间口径", "时间戳使用 ISO 8601 UTC；日统计保留源日历日期，源时区未记录；小时分桶的边界与滚动24小时汇总可能不同；无法识别的小时键保留原值，时间留空"],
      ["设备口径", "设备区按设备ID取最新快照，可能包含本机；不再叠加到本机汇总。今日、本月均指设备快照生成时的期间，设备之间可能存在时区和同步时间差异"],
      ["人民币汇率(USD/CNY)", validCNYRate.map { decimal($0, places: 6) } ?? ""],
      [],
      ["汇总(本机)", "Token", "USD", "CNY", "计价覆盖率(%)", "未计价模型", "价格口径"],
      summaryRow("滚动24小时", tokens: stats.rolling24HoursTokens, estimate: stats.cost24Hours, cnyRate: validCNYRate),
      summaryRow("近7天", tokens: stats.last7DaysTokens, estimate: stats.cost7Days, cnyRate: validCNYRate),
      summaryRow("本月", tokens: stats.monthTokens, estimate: stats.costMonth, cnyRate: validCNYRate),
      [],
      ["小时开始(UTC，本机)", "Token", "Input", "Cached input", "Output", "Reasoning output", "Calls", "原始小时键"]
    ]

    rows.append(contentsOf: stats.hourly.map {
      [hourTimestamp(for: $0.key, formatter: timestampFormatter)] + tokenColumns($0) + [safeText($0.key)]
    })
    rows.append([])
    rows.append(["日期(本机)", "Token", "Input", "Cached input", "Output", "Reasoning output", "Calls"])
    rows.append(contentsOf: stats.daily.sorted { $0.key < $1.key }.map {
      [safeText($0.key)] + tokenColumns($0)
    })
    rows.append([])
    rows.append(["模型(本机，本月)", "Token", "Input", "Cached input", "Output", "Calls"])

    let groupedModels: [String: [ModelHourlyBucket]] = Dictionary(grouping: stats.modelHourly, by: \.model)
    var modelRows: [[String]] = []
    for (model, buckets) in groupedModels {
      let totalTokens = buckets.reduce(0) { $0 + $1.totalTokens }
      let inputTokens = buckets.reduce(0) { $0 + $1.inputTokens }
      let cachedTokens = buckets.reduce(0) { $0 + $1.cachedInputTokens }
      let outputTokens = buckets.reduce(0) { $0 + $1.outputTokens }
      let calls = buckets.reduce(0) { $0 + $1.calls }
      modelRows.append([
        safeText(model),
        String(totalTokens),
        String(inputTokens),
        String(cachedTokens),
        String(outputTokens),
        String(calls)
      ])
    }
    modelRows.sort {
      let lhs = Int($0[1]) ?? 0
      let rhs = Int($1[1]) ?? 0
      return lhs == rhs ? $0[0] < $1[0] : lhs > rhs
    }
    rows.append(contentsOf: modelRows)

    rows.append([])
    rows.append(["工作类型(本机，本月)", "Token", "Input", "Output", "Reasoning output", "Calls"])
    rows.append(contentsOf: stats.categoryBreakdown
      .filter { $0.totalTokens > 0 }
      .sorted { $0.totalTokens > $1.totalTokens }
      .map {
        [
          safeText($0.category.label),
          String($0.totalTokens),
          String($0.inputTokens),
          String($0.outputTokens),
          String($0.reasoningOutputTokens),
          String($0.calls)
        ]
      })

    rows.append([])
    rows.append(["最近调用时间(UTC，本机)", "模型", "项目", "Token", "Input", "Cached input", "Output"])
    rows.append(contentsOf: stats.recentUsageEvents.map {
      [
        timestampFormatter.string(from: $0.timestamp),
        safeText($0.model),
        safeText($0.projectName),
        String($0.totalTokens),
        String($0.inputTokens),
        String($0.cachedInputTokens),
        String($0.outputTokens)
      ]
    })

    // Synced snapshots may include the local device. Keep them separate from the
    // local totals and never sum repeated snapshots of the same device.
    let devices = latestDeviceSnapshots(stats.deviceUsage)
    rows.append([])
    rows.append(["设备", "设备ID", "快照时间(UTC)", "快照当日 Token", "快照当月 Token"])
    rows.append(contentsOf: devices.map {
      [
        safeText($0.deviceName),
        safeText($0.deviceID),
        timestampFormatter.string(from: $0.updatedAt),
        String($0.todayTokens),
        String($0.monthTokens)
      ]
    })
    rows.append([])
    rows.append(["设备逐日", "设备ID", "日期(源设备日历)", "Token"])
    for device in devices {
      rows.append(contentsOf: device.daily.sorted { $0.key < $1.key }.map {
        [safeText(device.deviceName), safeText(device.deviceID), safeText($0.key), String($0.totalTokens)]
      })
    }

    return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
  }

  private static func tokenColumns(_ bucket: TokenBucket) -> [String] {
    [
      String(bucket.totalTokens),
      String(bucket.inputTokens),
      String(bucket.cachedInputTokens),
      String(bucket.outputTokens),
      String(bucket.reasoningOutputTokens),
      String(bucket.calls)
    ]
  }

  private static func hourTimestamp(for key: String, formatter: ISO8601DateFormatter) -> String {
    // SessionUsageAggregation stores floor(unixSeconds / 3600), not a display
    // label or a local yyyyMMddHH value. Unknown keys stay available in the last
    // column, without inventing a date or overflowing integer multiplication.
    guard let hour = Int(key) else { return "" }
    let seconds = Double(hour) * 3600
    guard (-62_135_596_800.0...253_402_300_799.0).contains(seconds) else { return "" }
    return formatter.string(from: Date(timeIntervalSince1970: seconds))
  }

  private static func latestDeviceSnapshots(_ snapshots: [CodexDeviceTokenUsage]) -> [CodexDeviceTokenUsage] {
    var latest: [String: CodexDeviceTokenUsage] = [:]
    for snapshot in snapshots {
      if let previous = latest[snapshot.deviceID],
         previous.updatedAt > snapshot.updatedAt
          || (previous.updatedAt == snapshot.updatedAt && previous.schemaVersion >= snapshot.schemaVersion) {
        continue
      }
      latest[snapshot.deviceID] = snapshot
    }
    return latest.values.sorted {
      $0.deviceName == $1.deviceName ? $0.deviceID < $1.deviceID : $0.deviceName < $1.deviceName
    }
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
      estimate.hasEstimate ? decimal(estimate.usd, places: 6) : "",
      estimate.hasEstimate ? (cnyRate.map { decimal(estimate.usd * $0, places: 6) } ?? "") : "",
      decimal(estimate.coveragePercent, places: 2),
      safeText(estimate.unpricedModels.joined(separator: "; ")),
      "按当前价格表折算"
    ]
  }

  private static func decimal(_ value: Double, places: Int) -> String {
    guard value.isFinite else { return "" }
    return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, value)
  }

  private static func safeText(_ value: String) -> String {
    // Quoting alone does not prevent Excel from interpreting a text cell as a
    // formula. Apply this only to text, so real numeric columns remain numbers.
    let ignoredPrefix = CharacterSet.whitespacesAndNewlines
      .union(.controlCharacters)
      .union(CharacterSet(charactersIn: "\u{FEFF}"))
    let firstSignificant = value.unicodeScalars.first { !ignoredPrefix.contains($0) }
    let startsWithControl = value.unicodeScalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? false
    if startsWithControl || firstSignificant.map({ "=+-@".unicodeScalars.contains($0) }) == true {
      return "'" + value
    }
    return value
  }

  private static func escape(_ value: String) -> String {
    guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
      return value
    }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
