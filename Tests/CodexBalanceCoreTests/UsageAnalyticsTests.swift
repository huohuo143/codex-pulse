import Foundation
import Testing
@testable import CodexBalanceCore

@Suite
struct UsageAnalyticsTests {
  @Test
  func analyzerComparesSevenDayPeriodsAndComputesEfficiency() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
    let daily = (0..<30).map { index in
      TokenBucket(
        key: "day-\(index + 1)",
        label: "D\(index + 1)",
        totalTokens: index < 16 ? 9_000_000 : (index < 23 ? 100_000 : 150_000),
        calls: 2
      )
    }
    let models = [
      ModelHourlyBucket(hourKey: "1", model: "gpt-5.6", totalTokens: 700_000, inputTokens: 600_000, cachedInputTokens: 360_000, outputTokens: 100_000, calls: 7),
      ModelHourlyBucket(hourKey: "2", model: "gpt-5.6-terra", totalTokens: 350_000, inputTokens: 300_000, cachedInputTokens: 90_000, outputTokens: 50_000, calls: 3)
    ]
    let stats = TokenStats(
      monthTokens: 1_500_000,
      modelHourly: models,
      daily: daily,
      monthTopProjects: [TokenProjectBucket(projectName: "Project A", totalTokens: 900_000, calls: 6)]
    )

    let result = UsageAnalyzer.analyze(stats: stats, now: now, calendar: utcCalendar)

    #expect(result.recent7Tokens == 1_050_000)
    #expect(result.previous7Tokens == 700_000)
    #expect(abs((result.sevenDayChangePercent ?? 0) - 50) < 0.001)
    #expect(abs((result.cacheHitRate ?? 0) - 0.5) < 0.001)
    #expect(result.averageTokensPerCall == 105_000)
    #expect(result.topModel == "gpt-5.6")
    #expect(result.insights.contains { $0.id == "trend-up" })
  }

  @Test
  func analyzerDetectsRobustDailyAnomaly() {
    var daily = (1...13).map {
      TokenBucket(key: "day-\($0)", label: "D\($0)", totalTokens: 100_000)
    }
    daily.append(TokenBucket(key: "day-14", label: "D14", totalTokens: 500_000))
    let result = UsageAnalyzer.analyze(stats: TokenStats(daily: daily))

    #expect(result.anomalies.count == 1)
    #expect(result.anomalies.first?.dayKey == "day-14")
    #expect(result.anomalies.first?.multiple == 5)
  }

  @Test
  func projectBudgetProjectsMonthEndRisk() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-16T00:00:00Z"))
    let project = TokenProjectBucket(projectName: "Rice App", projectPath: "/work/rice", totalTokens: 600_000, calls: 12)
    let budget = ProjectBudget(projectName: "Rice App", projectPath: "/work/rice", monthlyTokenLimit: 1_000_000)
    let result = UsageAnalyzer.analyze(
      stats: TokenStats(monthTokens: 600_000, monthTopProjects: [project]),
      budgets: [budget],
      now: now,
      calendar: utcCalendar
    )
    let row = try #require(result.projectBudgets.first)

    #expect(row.usedTokens == 600_000)
    #expect(row.projectedMonthTokens > 1_000_000)
    #expect(row.risk == .caution)
  }

  @Test
  func budgetStoreRoundTripsAndQuarantinesCorruption() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("budgets.json")
    let store = ProjectBudgetStore(url: url)
    let budget = ProjectBudget(projectName: "BPH33", projectPath: "/work/BPH33", monthlyTokenLimit: 2_000_000)

    try store.upsert(budget)
    let loaded = try #require(store.load().first)
    #expect(loaded.id == budget.id)
    #expect(loaded.monthlyTokenLimit == budget.monthlyTokenLimit)
    _ = try store.remove(id: budget.id)
    #expect(store.load().isEmpty)

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: url)
    #expect(store.load().isEmpty)
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(quarantined.contains { $0.contains("corrupt-") })
  }

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
}
