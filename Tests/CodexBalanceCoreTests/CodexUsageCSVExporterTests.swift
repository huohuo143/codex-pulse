import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Usage CSV export boundaries")
struct CodexUsageCSVExporterTests {
  @Test
  func hourlyDatesCrossYearBoundaryWithoutDependingOnDisplayLabels() throws {
    let before = try date("2025-12-31T23:00:00Z")
    let after = try date("2026-01-01T23:00:00Z")
    let stats = TokenStats(hourly: [
      TokenBucket(key: hourKey(before), label: "23时", totalTokens: 10),
      TokenBucket(key: hourKey(after), label: "23时", totalTokens: 20),
      TokenBucket(key: "unknown", label: "23时", totalTokens: 30),
      TokenBucket(key: String(Int.max), label: "23时", totalTokens: 40)
    ])
    let rows = records(CodexUsageCSVExporter.makeCSV(stats: stats, cnyRate: nil, generatedAt: after))
    let hours = try section("小时开始(UTC，本机)", in: rows)

    #expect(hours[0] == ["2025-12-31T23:00:00Z", "10", "0", "0", "0", "0", "0", hourKey(before)])
    #expect(hours[1][0] == "2026-01-01T23:00:00Z")
    #expect(hours[2][0].isEmpty)
    #expect(hours[2].last == "unknown")
    #expect(hours[3][0].isEmpty)
    #expect(hours[3].last == String(Int.max))
    #expect(rows.contains(["生成时间", "2026-01-01T23:00:00Z"]))
  }

  @Test
  func dailyExportKeepsCompleteSourceCalendarDatesAndComponentCounts() throws {
    let stats = TokenStats(daily: [
      TokenBucket(key: "2026-01-01", label: "1/1", totalTokens: 12, inputTokens: 9,
        cachedInputTokens: 4, outputTokens: 3, reasoningOutputTokens: 2, calls: 1),
      TokenBucket(key: "2025-12-31", label: "12/31", totalTokens: 6, calls: 2)
    ])
    let rows = records(CodexUsageCSVExporter.makeCSV(stats: stats, cnyRate: nil))
    let days = try section("日期(本机)", in: rows)

    #expect(days == [
      ["2025-12-31", "6", "0", "0", "0", "0", "2"],
      ["2026-01-01", "12", "9", "4", "3", "2", "1"]
    ])
    #expect(rows.first { $0.first == "时间口径" }?.last?.contains("源时区未记录") == true)
  }

  @Test
  func devicesUseOneLatestSnapshotAndNeverInflateLocalTotals() throws {
    let latestDate = try date("2026-10-11T01:00:00Z")
    let latest = snapshot(id: "local", name: "Local Mac", at: latestDate, today: 10, month: 30)
    let stale = snapshot(id: "local", name: "Old Name", at: latestDate.addingTimeInterval(-3600), today: 999, month: 999)
    let remote = snapshot(id: "remote", name: "Remote Mac", at: latestDate.addingTimeInterval(-86400), today: 50, month: 80)
    let stats = TokenStats(rolling24HoursTokens: 12, monthTokens: 30, last7DaysTokens: 20,
      deviceUsage: [stale, remote, latest, latest])
    let rows = records(CodexUsageCSVExporter.makeCSV(stats: stats, cnyRate: nil))
    let summary = try section("汇总(本机)", in: rows)
    let devices = try section("设备", in: rows)
    let daily = try section("设备逐日", in: rows)

    #expect(summary.map { Array($0.prefix(2)) } == [["滚动24小时", "12"], ["近7天", "20"], ["本月", "30"]])
    #expect(devices == [
      ["Local Mac", "local", "2026-10-11T01:00:00Z", "10", "30"],
      ["Remote Mac", "remote", "2026-10-10T01:00:00Z", "50", "80"]
    ])
    #expect(daily == [["Local Mac", "local", "2026-10-10", "10"], ["Remote Mac", "remote", "2026-10-10", "50"]])
    #expect(rows.first { $0.first == "设备口径" }?.last?.contains("不再叠加到本机汇总") == true)
  }

  @Test(arguments: [
    "=HYPERLINK(\"https://example.com\",\"open\")", "+1+2", "-42", "@SUM(1)",
    " \t=1+1", "\tplain", "\r=1+1", "\n@SUM(1)", "\u{FEFF}=1+1"
  ])
  func externalTextCannotBecomeASpreadsheetFormula(_ text: String) throws {
    let now = try date("2026-10-11T01:00:00Z")
    let stats = TokenStats(
      rolling24HoursTokens: 42,
      modelHourly: [ModelHourlyBucket(hourKey: hourKey(now), model: text, totalTokens: 42, inputTokens: 30, outputTokens: 12, calls: 1)],
      cost24Hours: CostEstimate(usd: 1.25, pricedTokens: 42, unpricedModels: [text]),
      recentUsageEvents: [TokenUsageEvent(timestamp: now, sourceName: "fixture", model: text,
        totalTokens: 42, inputTokens: 30, outputTokens: 12, reasoningOutputTokens: 0, projectName: text)],
      deviceUsage: [snapshot(id: text, name: text, at: now, today: 42, month: 42)]
    )
    let rows = records(CodexUsageCSVExporter.makeCSV(stats: stats, cnyRate: 7.2))
    let summary = try section("汇总(本机)", in: rows)
    let models = try section("模型(本机，本月)", in: rows)
    let events = try section("最近调用时间(UTC，本机)", in: rows)
    let devices = try section("设备", in: rows)
    let daily = try section("设备逐日", in: rows)

    #expect(summary[0][5] == "'" + text)
    #expect(Array(summary[0][1...4]) == ["42", "1.250000", "9.000000", "100.00"])
    #expect(models[0] == ["'" + text, "42", "30", "0", "12", "1"])
    #expect(events[0][1] == "'" + text)
    #expect(events[0][2] == "'" + text)
    #expect(devices[0][0] == "'" + text)
    #expect(devices[0][1] == "'" + text)
    #expect(daily[0][0] == "'" + text)
    #expect(daily[0][1] == "'" + text)
  }

  @Test
  func ordinaryTextWithQuotesCommasAndNewlinesRoundTrips() throws {
    let name = "水稻,\"BPH33\"\n项目"
    let now = try date("2026-10-11T01:00:00Z")
    let stats = TokenStats(recentUsageEvents: [TokenUsageEvent(timestamp: now, sourceName: "fixture",
      model: "gpt-6-sol", totalTokens: 42, inputTokens: 30, outputTokens: 12,
      reasoningOutputTokens: 0, projectName: name)])
    let rows = records(CodexUsageCSVExporter.makeCSV(stats: stats, cnyRate: nil))
    let events = try section("最近调用时间(UTC，本机)", in: rows)

    #expect(events.count == 1)
    #expect(events[0][2] == name)
  }

  @Test
  func partialAndUnavailablePricesRemainExplicit() throws {
    let stats = TokenStats(rolling24HoursTokens: 100, monthTokens: 200,
      cost24Hours: CostEstimate(usd: 0.25, pricedTokens: 75, unpricedTokens: 25, unpricedModels: ["future-model"]),
      costMonth: CostEstimate(unpricedTokens: 200, unpricedModels: ["unknown"]))
    let rows = records(CodexUsageCSVExporter.makeCSV(stats: stats, cnyRate: nil))
    let summary = try section("汇总(本机)", in: rows)

    #expect(summary[0] == ["滚动24小时", "100", "0.250000", "", "75.00", "future-model", "按当前价格表折算"])
    #expect(summary[2] == ["本月", "200", "", "", "0.00", "unknown", "按当前价格表折算"])
    #expect(rows.first { $0.first == "说明" }?.last?.contains("不是 ChatGPT/Codex 订阅实际账单") == true)
  }

  @Test(arguments: [Double.nan, Double.infinity, -1, 0])
  func invalidExchangeRateLeavesCNYEmpty(_ rate: Double) throws {
    let stats = TokenStats(cost24Hours: CostEstimate(usd: 1.25, pricedTokens: 100))
    let rows = records(CodexUsageCSVExporter.makeCSV(stats: stats, cnyRate: rate))
    let summary = try section("汇总(本机)", in: rows)

    #expect(summary[0][2] == "1.250000")
    #expect(summary[0][3].isEmpty)
    #expect(rows.contains(["人民币汇率(USD/CNY)", ""]))
  }

  @Test
  func emptyStatsDoNotInventDailyOrDeviceRecords() throws {
    let rows = records(CodexUsageCSVExporter.makeCSV(stats: TokenStats(), cnyRate: nil))
    #expect(try section("日期(本机)", in: rows).isEmpty)
    #expect(try section("设备", in: rows).isEmpty)
    #expect(try section("设备逐日", in: rows).isEmpty)
  }

  private func date(_ value: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: value))
  }

  private func hourKey(_ date: Date) -> String {
    String(Int(floor(date.timeIntervalSince1970 / 3600)))
  }

  private func snapshot(id: String, name: String, at date: Date, today: Int, month: Int) -> CodexDeviceTokenUsage {
    CodexDeviceTokenUsage(deviceID: id, deviceName: name, hostName: "", updatedAt: date,
      todayTokens: today, monthTokens: month, sampleCount: 1,
      daily: [TokenBucket(key: "2026-10-10", label: "10/10", totalTokens: today)], monthly: [])
  }

  private func section(_ header: String, in rows: [[String]]) throws -> [[String]] {
    let index = try #require(rows.firstIndex { $0.first == header })
    return Array(rows.dropFirst(index + 1).prefix { !$0.isEmpty })
  }

  /// Parse CSV records so escaping tests assert the actual cell values rather
  /// than a substring that could also occur inside another quoted field.
  private func records(_ csv: String) -> [[String]] {
    let characters = Array(csv)
    var rows: [[String]] = []
    var row: [String] = []
    var cell = ""
    var quoted = false
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "\"" {
        if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
          cell.append("\"")
          index += 1
        } else {
          quoted.toggle()
        }
      } else if character == ",", !quoted {
        row.append(cell)
        cell = ""
      } else if character == "\n", !quoted {
        row.append(cell)
        rows.append(row == [""] ? [] : row)
        row = []
        cell = ""
      } else {
        cell.append(character)
      }
      index += 1
    }
    return rows
  }
}
