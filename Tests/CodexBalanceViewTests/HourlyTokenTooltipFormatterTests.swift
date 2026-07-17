import Testing
@testable import CodexBalance

@Suite("Hourly token tooltip formatting")
struct HourlyTokenTooltipFormatterTests {
  @Test
  func appMetadataUsesCurrentMaintainer() {
    #expect(AppInfo.author == "ZhangS")
    #expect(AppInfo.originalAuthor == "waytosea-oss")
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
