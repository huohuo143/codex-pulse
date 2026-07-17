import Foundation

public enum UsageAnalysisSeverity: String, Codable, Sendable {
  case positive
  case neutral
  case caution
  case critical
}

public struct UsageInsight: Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var detail: String
  public var severity: UsageAnalysisSeverity

  public init(id: String, title: String, detail: String, severity: UsageAnalysisSeverity) {
    self.id = id
    self.title = title
    self.detail = detail
    self.severity = severity
  }
}

public struct UsageAnomaly: Identifiable, Equatable, Sendable {
  public var id: String { dayKey }
  public var dayKey: String
  public var label: String
  public var totalTokens: Int
  public var baselineTokens: Int
  public var multiple: Double

  public init(dayKey: String, label: String, totalTokens: Int, baselineTokens: Int, multiple: Double) {
    self.dayKey = dayKey
    self.label = label
    self.totalTokens = totalTokens
    self.baselineTokens = baselineTokens
    self.multiple = multiple
  }
}

public enum ProjectBudgetRisk: String, Codable, Sendable {
  case healthy
  case caution
  case overBudget
  case noUsage
}

public struct ProjectBudget: Identifiable, Equatable, Codable, Sendable {
  public var id: String
  public var projectName: String
  public var projectPath: String
  public var monthlyTokenLimit: Int
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    projectName: String,
    projectPath: String = "",
    monthlyTokenLimit: Int,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    id = Self.identifier(projectName: projectName, projectPath: projectPath)
    self.projectName = projectName
    self.projectPath = projectPath
    self.monthlyTokenLimit = max(1, monthlyTokenLimit)
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static func identifier(projectName: String, projectPath: String) -> String {
    projectPath.isEmpty ? projectName : projectPath
  }
}

public struct ProjectBudgetStatus: Identifiable, Equatable, Sendable {
  public var id: String { budget.id }
  public var budget: ProjectBudget
  public var usedTokens: Int
  public var projectedMonthTokens: Int
  public var remainingTokens: Int
  public var progress: Double
  public var projectedProgress: Double
  public var risk: ProjectBudgetRisk

  public init(
    budget: ProjectBudget,
    usedTokens: Int,
    projectedMonthTokens: Int,
    remainingTokens: Int,
    progress: Double,
    projectedProgress: Double,
    risk: ProjectBudgetRisk
  ) {
    self.budget = budget
    self.usedTokens = usedTokens
    self.projectedMonthTokens = projectedMonthTokens
    self.remainingTokens = remainingTokens
    self.progress = progress
    self.projectedProgress = projectedProgress
    self.risk = risk
  }
}

public struct UsageAnalysis: Equatable, Sendable {
  public var recent7Tokens: Int
  public var previous7Tokens: Int
  public var sevenDayChangePercent: Double?
  public var averageDailyTokens: Int
  public var projectedMonthTokens: Int
  public var cacheHitRate: Double?
  public var outputInputRatio: Double?
  public var averageTokensPerCall: Int?
  public var topModel: String?
  public var topModelShare: Double?
  public var topProjectShare: Double?
  public var anomalies: [UsageAnomaly]
  public var insights: [UsageInsight]
  public var projectBudgets: [ProjectBudgetStatus]

  public init(
    recent7Tokens: Int = 0,
    previous7Tokens: Int = 0,
    sevenDayChangePercent: Double? = nil,
    averageDailyTokens: Int = 0,
    projectedMonthTokens: Int = 0,
    cacheHitRate: Double? = nil,
    outputInputRatio: Double? = nil,
    averageTokensPerCall: Int? = nil,
    topModel: String? = nil,
    topModelShare: Double? = nil,
    topProjectShare: Double? = nil,
    anomalies: [UsageAnomaly] = [],
    insights: [UsageInsight] = [],
    projectBudgets: [ProjectBudgetStatus] = []
  ) {
    self.recent7Tokens = recent7Tokens
    self.previous7Tokens = previous7Tokens
    self.sevenDayChangePercent = sevenDayChangePercent
    self.averageDailyTokens = averageDailyTokens
    self.projectedMonthTokens = projectedMonthTokens
    self.cacheHitRate = cacheHitRate
    self.outputInputRatio = outputInputRatio
    self.averageTokensPerCall = averageTokensPerCall
    self.topModel = topModel
    self.topModelShare = topModelShare
    self.topProjectShare = topProjectShare
    self.anomalies = anomalies
    self.insights = insights
    self.projectBudgets = projectBudgets
  }
}

public enum UsageAnalyzer {
  public static func analyze(
    stats: TokenStats,
    budgets: [ProjectBudget] = [],
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> UsageAnalysis {
    let days = Array(stats.daily.suffix(14))
    let recentDays = Array(days.suffix(7))
    let previousDays = Array(days.dropLast(min(7, days.count)).suffix(7))
    let recent7 = recentDays.reduce(0) { $0 + max(0, $1.totalTokens) }
    let previous7 = previousDays.reduce(0) { $0 + max(0, $1.totalTokens) }
    let change = previous7 > 0
      ? (Double(recent7 - previous7) / Double(previous7) * 100)
      : nil
    let averageDaily = recentDays.isEmpty ? 0 : recent7 / recentDays.count

    let monthProgress = elapsedMonthFraction(now: now, calendar: calendar)
    let projectedMonth = monthProgress > 0
      ? Int((Double(max(0, stats.monthTokens)) / monthProgress).rounded())
      : stats.monthTokens

    let input = stats.modelHourly.reduce(0) { $0 + max(0, $1.inputTokens) }
    let cached = stats.modelHourly.reduce(0) { $0 + min(max(0, $1.cachedInputTokens), max(0, $1.inputTokens)) }
    let output = stats.modelHourly.reduce(0) { $0 + max(0, $1.outputTokens) }
    let calls = stats.modelHourly.reduce(0) { $0 + max(0, $1.calls) }
    let modelTokens = Dictionary(grouping: stats.modelHourly, by: \.model)
      .mapValues { $0.reduce(0) { $0 + max(0, $1.totalTokens) } }
    let modelTotal = modelTokens.values.reduce(0, +)
    let topModelRow = modelTokens.max { lhs, rhs in lhs.value < rhs.value }

    let monthProjectsTotal = stats.monthTopProjects.reduce(0) { $0 + max(0, $1.totalTokens) }
    let topProjectTokens = stats.monthTopProjects.first.map { max(0, $0.totalTokens) } ?? 0
    let anomalies = detectAnomalies(days: days)
    let budgetStatuses = budgets.map {
      budgetStatus($0, projects: stats.monthTopProjects, monthProgress: monthProgress)
    }.sorted {
      if riskRank($0.risk) == riskRank($1.risk) {
        return $0.projectedProgress > $1.projectedProgress
      }
      return riskRank($0.risk) > riskRank($1.risk)
    }

    let cacheRate = input > 0 ? Double(cached) / Double(input) : nil
    let outputRatio = input > 0 ? Double(output) / Double(input) : nil
    let topModelShare = modelTotal > 0 ? Double(topModelRow?.value ?? 0) / Double(modelTotal) : nil
    let topProjectShare = monthProjectsTotal > 0 ? Double(topProjectTokens) / Double(monthProjectsTotal) : nil
    let insights = makeInsights(
      change: change,
      cacheRate: cacheRate,
      topModel: topModelRow?.key,
      topModelShare: topModelShare,
      topProjectShare: topProjectShare,
      anomalies: anomalies,
      budgetStatuses: budgetStatuses
    )

    return UsageAnalysis(
      recent7Tokens: recent7,
      previous7Tokens: previous7,
      sevenDayChangePercent: change,
      averageDailyTokens: averageDaily,
      projectedMonthTokens: projectedMonth,
      cacheHitRate: cacheRate,
      outputInputRatio: outputRatio,
      averageTokensPerCall: calls > 0 ? modelTotal / calls : nil,
      topModel: topModelRow?.key,
      topModelShare: topModelShare,
      topProjectShare: topProjectShare,
      anomalies: anomalies,
      insights: insights,
      projectBudgets: budgetStatuses
    )
  }

  private static func elapsedMonthFraction(now: Date, calendar: Calendar) -> Double {
    let components = calendar.dateComponents([.year, .month], from: now)
    guard let start = calendar.date(from: components),
          let end = calendar.date(byAdding: .month, value: 1, to: start),
          end > start else { return 1 }
    return min(1, max(1 / 31, now.timeIntervalSince(start) / end.timeIntervalSince(start)))
  }

  private static func budgetStatus(
    _ budget: ProjectBudget,
    projects: [TokenProjectBucket],
    monthProgress: Double
  ) -> ProjectBudgetStatus {
    let row = projects.first {
      ProjectBudget.identifier(projectName: $0.projectName, projectPath: $0.projectPath) == budget.id
    }
    let used = max(0, row?.totalTokens ?? 0)
    let limit = max(1, budget.monthlyTokenLimit)
    let projected = used > 0 && monthProgress > 0
      ? Int((Double(used) / monthProgress).rounded())
      : 0
    let progress = Double(used) / Double(limit)
    let projectedProgress = Double(projected) / Double(limit)
    let risk: ProjectBudgetRisk
    if row == nil || used == 0 {
      risk = .noUsage
    } else if used >= limit {
      risk = .overBudget
    } else if progress >= 0.8 || projected > limit {
      risk = .caution
    } else {
      risk = .healthy
    }
    return ProjectBudgetStatus(
      budget: budget,
      usedTokens: used,
      projectedMonthTokens: projected,
      remainingTokens: max(0, limit - used),
      progress: progress,
      projectedProgress: projectedProgress,
      risk: risk
    )
  }

  private static func detectAnomalies(days: [TokenBucket]) -> [UsageAnomaly] {
    guard days.count >= 7 else { return [] }
    let positive = days.map { max(0, $0.totalTokens) }.filter { $0 > 0 }.map(Double.init)
    guard positive.count >= 4 else { return [] }
    let baseline = median(positive)
    let deviations = positive.map { abs($0 - baseline) }
    let mad = median(deviations)
    let threshold = baseline + max(3 * mad, baseline * 0.75, 10_000)
    return days.suffix(7).compactMap { row in
      let value = Double(max(0, row.totalTokens))
      guard value > threshold else { return nil }
      return UsageAnomaly(
        dayKey: row.key,
        label: row.label,
        totalTokens: row.totalTokens,
        baselineTokens: Int(baseline.rounded()),
        multiple: baseline > 0 ? value / baseline : 0
      )
    }.sorted { $0.totalTokens > $1.totalTokens }
  }

  private static func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let rows = values.sorted()
    let middle = rows.count / 2
    return rows.count.isMultiple(of: 2)
      ? (rows[middle - 1] + rows[middle]) / 2
      : rows[middle]
  }

  private static func riskRank(_ risk: ProjectBudgetRisk) -> Int {
    switch risk {
    case .overBudget: 3
    case .caution: 2
    case .healthy: 1
    case .noUsage: 0
    }
  }

  private static func makeInsights(
    change: Double?,
    cacheRate: Double?,
    topModel: String?,
    topModelShare: Double?,
    topProjectShare: Double?,
    anomalies: [UsageAnomaly],
    budgetStatuses: [ProjectBudgetStatus]
  ) -> [UsageInsight] {
    var rows: [UsageInsight] = []
    if let change {
      if change >= 25 {
        rows.append(.init(id: "trend-up", title: "近 7 天消耗明显上升", detail: "较前 7 天增加 \(Int(change.rounded()))%，建议检查高强度任务与预算。", severity: .caution))
      } else if change <= -20 {
        rows.append(.init(id: "trend-down", title: "近 7 天消耗回落", detail: "较前 7 天下降 \(Int(abs(change).rounded()))%，当前节奏更加平稳。", severity: .positive))
      } else {
        rows.append(.init(id: "trend-stable", title: "近 7 天消耗相对稳定", detail: "较前 7 天变化 \(String(format: "%+.0f%%", change))。", severity: .neutral))
      }
    }
    if let cacheRate {
      let percent = Int((cacheRate * 100).rounded())
      rows.append(.init(
        id: "cache",
        title: cacheRate >= 0.5 ? "缓存复用表现良好" : "缓存复用仍有提升空间",
        detail: "本月 cached input / input 为 \(percent)%；该指标仅反映输入复用，不代表回答质量。",
        severity: cacheRate >= 0.5 ? .positive : (cacheRate < 0.2 ? .caution : .neutral)
      ))
    }
    if let topModel, let topModelShare, topModelShare >= 0.65 {
      rows.append(.init(id: "model-concentration", title: "模型使用较集中", detail: "\(topModel) 占本月 Token 的 \(Int((topModelShare * 100).rounded()))%。", severity: .neutral))
    }
    if let topProjectShare, topProjectShare >= 0.55 {
      rows.append(.init(id: "project-concentration", title: "单一项目消耗集中", detail: "最高项目占已识别项目 Token 的 \(Int((topProjectShare * 100).rounded()))%。", severity: .caution))
    }
    if let anomaly = anomalies.first {
      rows.append(.init(id: "anomaly", title: "检测到异常高峰", detail: "\(anomaly.label) 为日常基线的 \(String(format: "%.1f", anomaly.multiple)) 倍。", severity: .caution))
    }
    let riskyBudgets = budgetStatuses.filter { $0.risk == .caution || $0.risk == .overBudget }
    if !riskyBudgets.isEmpty {
      rows.append(.init(id: "budget-risk", title: "项目预算需要关注", detail: "有 \(riskyBudgets.count) 个项目已超预算或按当前节奏预计超预算。", severity: riskyBudgets.contains { $0.risk == .overBudget } ? .critical : .caution))
    }
    if rows.isEmpty {
      rows.append(.init(id: "learning", title: "正在建立高级分析基线", detail: "积累至少 7 天数据后将显示同期对比和异常高峰。", severity: .neutral))
    }
    return rows
  }
}

public final class ProjectBudgetStore: @unchecked Sendable {
  public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodexSuanliMeter/project-budgets-v1.json")

  private struct Payload: Codable {
    var schemaVersion: Int
    var budgets: [ProjectBudget]
  }

  private let url: URL
  private let fileManager: FileManager
  private let lock = NSLock()

  public init(url: URL = ProjectBudgetStore.defaultURL, fileManager: FileManager = .default) {
    self.url = url
    self.fileManager = fileManager
  }

  public func load() -> [ProjectBudget] {
    lock.lock()
    defer { lock.unlock() }
    return loadUnlocked()
  }

  @discardableResult
  public func upsert(_ budget: ProjectBudget) throws -> [ProjectBudget] {
    lock.lock()
    defer { lock.unlock() }
    var rows = loadUnlocked()
    if let index = rows.firstIndex(where: { $0.id == budget.id }) {
      var next = budget
      next.createdAt = rows[index].createdAt
      rows[index] = next
    } else {
      rows.append(budget)
    }
    rows.sort { $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending }
    try saveUnlocked(rows)
    return rows
  }

  @discardableResult
  public func remove(id: String) throws -> [ProjectBudget] {
    lock.lock()
    defer { lock.unlock() }
    var rows = loadUnlocked()
    rows.removeAll { $0.id == id }
    try saveUnlocked(rows)
    return rows
  }

  private func loadUnlocked() -> [ProjectBudget] {
    guard fileManager.fileExists(atPath: url.path) else { return [] }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder.projectBudgetDecoder.decode(Payload.self, from: data).budgets
        .filter { $0.monthlyTokenLimit > 0 }
    } catch {
      quarantineCorruptFile()
      return []
    }
  }

  private func saveUnlocked(_ rows: [ProjectBudget]) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let payload = Payload(schemaVersion: 1, budgets: rows)
    let data = try JSONEncoder.projectBudgetEncoder.encode(payload)
    try data.write(to: url, options: .atomic)
  }

  private func quarantineCorruptFile() {
    guard fileManager.fileExists(atPath: url.path) else { return }
    let stamp = Int(Date().timeIntervalSince1970)
    let quarantine = url.deletingPathExtension()
      .appendingPathExtension("corrupt-\(stamp).json")
    try? fileManager.moveItem(at: url, to: quarantine)
  }
}

private extension JSONEncoder {
  static var projectBudgetEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

private extension JSONDecoder {
  static var projectBudgetDecoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
