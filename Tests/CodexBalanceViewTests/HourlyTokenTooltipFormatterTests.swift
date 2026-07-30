import Testing
import CodexBalanceCore
@testable import CodexBalance

@Suite("Hourly token tooltip formatting")
struct HourlyTokenTooltipFormatterTests {
  @Test
  func appMetadataUsesCurrentMaintainer() {
    #expect(AppInfo.version == "2.10.2")
    #expect(AppInfo.author == "ZhangS")
    #expect(AppInfo.originalAuthor == "waytosea-oss")
  }

  @Test
  func dailyChartKeepsNewestThirtyRows() {
    let rows = (1...35).map {
      TokenBucket(key: "day-\($0)", label: "D\($0)", totalTokens: $0)
    }

    let visible = DailyUsageChartSupport.visibleRows(rows)

    #expect(visible.count == 30)
    #expect(visible.first?.key == "day-6")
    #expect(visible.last?.key == "day-35")
  }

  @Test
  func dailyChartHandlesEmptyAndSingleDayData() {
    #expect(DailyUsageChartSupport.visibleRows([]).isEmpty)

    let row = TokenBucket(key: "2026-07-21", label: "7/21", totalTokens: 12_345_678)
    let visible = DailyUsageChartSupport.visibleRows([row])

    #expect(visible == [row])
    #expect(DailyUsageChartSupport.dateLabel(for: row) == "7/21")
    #expect(DailyUsageChartSupport.compactTokens(for: row) == "12.35M")
  }

  @Test(arguments: [
    (0, "0"),
    (999_999, "999,999"),
    (1_000_000, "1M"),
    (12_345_678, "12.35M"),
    (99_999_999, "100M"),
    (100_000_000, "1亿"),
    (123_456_789, "1.23亿")
  ])
  func formatsTooltipThresholds(value: Int, expected: String) {
    #expect(HourlyTokenTooltipFormatter.compact(value) == expected)
  }

  @Test
  func removesTrailingZeroes() {
    #expect(HourlyTokenTooltipFormatter.compact(1_500_000) == "1.5M")
    #expect(HourlyTokenTooltipFormatter.compact(150_000_000) == "1.5亿")
  }
}
