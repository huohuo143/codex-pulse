import Foundation

extension CodexStatusReader {
  func buildCachedTokenStats(from events: [RateLimitEvent], now: Date) -> TokenStats {
    let signature = "\(fileIndex.revision)|" + workspaceLabelSignature() + "|" + ModelPricingStore.shared.snapshot().version
    if let cached = tokenStatsCache, cached.signature == signature, now < cached.validUntil {
      return cached.stats
    }
    diagnostics.aggregations += 1
    let stats = buildTokenStats(from: events, now: now)
    let nextHour = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 3600) + 1) * 3600)
    // Rolling windows change at actual event boundaries, including within the same hour.
    let boundary = events.flatMap { event in
      [event.timestamp, event.timestamp.addingTimeInterval(86400.001), event.timestamp.addingTimeInterval(7 * 86400 + 0.001)]
    }.filter { $0 > now }.min() ?? nextHour
    tokenStatsCache = TokenStatsCache(signature: signature, validUntil: min(nextHour, boundary), stats: stats)
    return stats
  }

  func tokenStatsSignature(for events: [RateLimitEvent]) -> String {
    guard let last = events.last else { return "empty" }
    return [
      String(events.count),
      last.sourcePath,
      String(last.timestamp.timeIntervalSince1970),
      String(last.usage.totalTokens),
      String(last.usage.lastTotalTokens),
      last.model,
      String(last.usage.lastCachedInputTokens),
      workspaceLabelSignature()
    ].joined(separator: "|")
  }

  func buildTokenStats(from events: [RateLimitEvent], now: Date) -> TokenStats {
    let usageEvents = buildTokenUsageEvents(from: events).filter { $0.timestamp <= now }
    var daily: [String: TokenBucket] = [:]
    var monthly: [String: TokenBucket] = [:]
    var hourly: [String: TokenBucket] = [:]
    var modelHourly: [String: ModelHourlyBucket] = [:]

    for event in usageEvents {
      add(event, to: &daily, key: periodKey(event.timestamp, period: .day))
      add(event, to: &monthly, key: periodKey(event.timestamp, period: .month))
      let hour = hourKey(event.timestamp)
      add(event, to: &hourly, key: hour, label: formatHourLabel(event.timestamp))
      add(event, to: &modelHourly, hourKey: hour)
    }

    let dailyRows = fillDailyRows(daily, count: 30, now: now)
    let monthlyRows = fillMonthlyRows(monthly, count: 6, now: now)
    let todayKey = periodKey(now, period: .day)
    let monthKey = periodKey(now, period: .month)
    let cutoff24h = now.addingTimeInterval(-24 * 60 * 60)
    // The existing "近7天" Token total includes today and the six preceding
    // calendar days. Price exactly that same set of events.
    let cutoff7d = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now)) ?? now
    let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now)) ?? .distantPast
    let events24h = usageEvents.filter { $0.timestamp >= cutoff24h && $0.timestamp <= now }
    let events7d = usageEvents.filter { $0.timestamp >= cutoff7d && $0.timestamp <= now }
    let eventsMonth = usageEvents.filter { $0.timestamp >= monthStart && $0.timestamp <= now }
    let last7Keys = Set(fillDailyKeys(count: 7, now: now))
    let last7Tokens = daily
      .filter { last7Keys.contains($0.key) }
      .reduce(0) { $0 + $1.value.totalTokens }
    let categoryBreakdown = buildCategoryBreakdown(
      from: usageEvents.filter { periodKey($0.timestamp, period: .month) == monthKey }
    )
    let todayTopProjects = buildProjectBreakdown(
      from: usageEvents.filter { periodKey($0.timestamp, period: .day) == todayKey },
      limit: 3
    )
    let monthTopProjects = buildProjectBreakdown(
      from: usageEvents.filter { periodKey($0.timestamp, period: .month) == monthKey },
      limit: 3
    )

    return TokenStats(
      rolling24HoursTokens: events24h.reduce(0) { $0 + $1.totalTokens },
      todayTokens: daily[todayKey]?.totalTokens ?? 0,
      monthTokens: monthly[monthKey]?.totalTokens ?? 0,
      last7DaysTokens: last7Tokens,
      sampleCount: usageEvents.count,
      hourly: fillHourlyRows(hourly, count: 24, now: now),
      modelHourly: modelHourly.values
        .filter { Int($0.hourKey).map { Date(timeIntervalSince1970: Double($0 * 3600)) >= monthStart } ?? false }
        .sorted { $0.id < $1.id },
      daily: dailyRows,
      monthly: monthlyRows,
      cost24Hours: ModelPricingCatalog.current.estimate(events: events24h),
      cost7Days: ModelPricingCatalog.current.estimate(events: events7d),
      costMonth: ModelPricingCatalog.current.estimate(events: eventsMonth),
      categoryBreakdown: categoryBreakdown,
      todayTopProjects: todayTopProjects,
      monthTopProjects: monthTopProjects,
      recentUsageEvents: Array(usageEvents.suffix(12).reversed())
    )
  }

  func buildTokenUsageEvents(from events: [RateLimitEvent]) -> [TokenUsageEvent] {
    var unique: [String: TokenUsageEvent] = [:]
    for event in events where event.usage.lastTotalTokens > 0 && event.usage.totalTokens > 0 {
      // `totalTokens` is cumulative within one rollout file. Codex can emit
      // multiple quota snapshots without advancing that cumulative counter,
      // sometimes with a different `lastTotalTokens` value. Count the first
      // occurrence only so a status-only refresh never becomes new usage.
      let key = "\(event.sourcePath):\(event.usage.totalTokens)"
      let displayProjectName = workspaceLabel(for: event.projectPath) ?? event.projectName
      let usageEvent = TokenUsageEvent(
        timestamp: event.timestamp,
        sourceName: event.sourceName,
        model: event.model,
        totalTokens: event.usage.lastTotalTokens,
        inputTokens: event.usage.lastInputTokens,
        cachedInputTokens: event.usage.lastCachedInputTokens,
        outputTokens: event.usage.lastOutputTokens,
        reasoningOutputTokens: event.usage.lastReasoningOutputTokens,
        category: event.usageCategory,
        projectName: displayProjectName,
        projectPath: event.projectPath
      )
      if unique[key]?.timestamp ?? .distantFuture > usageEvent.timestamp {
        unique[key] = usageEvent
      }
    }
    return unique.values.sorted { $0.timestamp < $1.timestamp }
  }

  func add(_ event: TokenUsageEvent, to buckets: inout [String: TokenBucket], key: String) {
    var bucket = buckets[key] ?? TokenBucket(key: key, label: formatPeriodLabel(key))
    bucket.totalTokens += event.totalTokens
    bucket.inputTokens += event.inputTokens
    bucket.cachedInputTokens += event.cachedInputTokens
    bucket.outputTokens += event.outputTokens
    bucket.reasoningOutputTokens += event.reasoningOutputTokens
    bucket.calls += 1
    buckets[key] = bucket
  }

  func add(
    _ event: TokenUsageEvent,
    to buckets: inout [String: TokenBucket],
    key: String,
    label: String
  ) {
    var bucket = buckets[key] ?? TokenBucket(key: key, label: label)
    bucket.totalTokens += event.totalTokens
    bucket.inputTokens += event.inputTokens
    bucket.cachedInputTokens += event.cachedInputTokens
    bucket.outputTokens += event.outputTokens
    bucket.reasoningOutputTokens += event.reasoningOutputTokens
    bucket.calls += 1
    buckets[key] = bucket
  }

  func add(
    _ event: TokenUsageEvent,
    to buckets: inout [String: ModelHourlyBucket],
    hourKey: String
  ) {
    let model = event.model.isEmpty ? "unknown" : event.model
    let key = "\(hourKey)|\(model)"
    var bucket = buckets[key] ?? ModelHourlyBucket(hourKey: hourKey, model: model)
    bucket.totalTokens += event.totalTokens
    bucket.inputTokens += event.inputTokens
    bucket.cachedInputTokens += event.cachedInputTokens
    bucket.outputTokens += event.outputTokens
    bucket.reasoningOutputTokens += event.reasoningOutputTokens
    bucket.calls += 1
    buckets[key] = bucket
  }

  func buildCategoryBreakdown(from events: [TokenUsageEvent]) -> [TokenCategoryBucket] {
    var rows = Dictionary(
      uniqueKeysWithValues: TokenUsageCategory.allCases.map {
        ($0, TokenCategoryBucket(category: $0))
      }
    )

    for event in events {
      var bucket = rows[event.category] ?? TokenCategoryBucket(category: event.category)
      bucket.totalTokens += event.totalTokens
      bucket.inputTokens += event.inputTokens
      bucket.outputTokens += event.outputTokens
      bucket.reasoningOutputTokens += event.reasoningOutputTokens
      bucket.calls += 1
      rows[event.category] = bucket
    }

    return TokenUsageCategory.allCases.compactMap { rows[$0] }
  }

  func buildProjectBreakdown(from events: [TokenUsageEvent], limit: Int) -> [TokenProjectBucket] {
    var rows: [String: TokenProjectBucket] = [:]
    for event in events {
      let key = event.projectPath.isEmpty ? event.projectName : event.projectPath
      var bucket = rows[key] ?? TokenProjectBucket(
        projectName: event.projectName,
        projectPath: event.projectPath
      )
      bucket.totalTokens += event.totalTokens
      bucket.calls += 1
      rows[key] = bucket
    }

    return rows.values
      .sorted {
        if $0.totalTokens == $1.totalTokens {
          return $0.projectName < $1.projectName
        }
        return $0.totalTokens > $1.totalTokens
      }
      .prefix(limit)
      .map { $0 }
  }

  func fillDailyRows(_ rows: [String: TokenBucket], count: Int, now: Date) -> [TokenBucket] {
    fillDailyKeys(count: count, now: now).map { rows[$0] ?? TokenBucket(key: $0, label: formatPeriodLabel($0)) }
  }

  func fillHourlyRows(_ rows: [String: TokenBucket], count: Int, now: Date) -> [TokenBucket] {
    let currentHour = Int(floor(now.timeIntervalSince1970 / 3600))
    return (0..<count).map { index in
      let value = currentHour - (count - 1 - index)
      let key = String(value)
      let date = Date(timeIntervalSince1970: Double(value * 3600))
      return rows[key] ?? TokenBucket(key: key, label: formatHourLabel(date))
    }
  }

  func hourKey(_ date: Date) -> String {
    String(Int(floor(date.timeIntervalSince1970 / 3600)))
  }

  func formatHourLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M/d HH时"
    return formatter.string(from: date)
  }

  func fillDailyKeys(count: Int, now: Date) -> [String] {
    let calendar = Calendar.current
    return (0..<count).compactMap { index in
      let offset = count - 1 - index
      return calendar.date(byAdding: .day, value: -offset, to: now).map { periodKey($0, period: .day) }
    }
  }

  func fillMonthlyRows(_ rows: [String: TokenBucket], count: Int, now: Date) -> [TokenBucket] {
    let calendar = Calendar.current
    return (0..<count).compactMap { index -> TokenBucket? in
      let offset = count - 1 - index
      guard let date = calendar.date(byAdding: .month, value: -offset, to: now) else { return nil }
      let key = periodKey(date, period: .month)
      return rows[key] ?? TokenBucket(key: key, label: formatPeriodLabel(key))
    }
  }

  enum Period {
    case day
    case month
  }

  func periodKey(_ date: Date, period: Period) -> String {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    let year = components.year ?? 0
    let month = components.month ?? 0
    if period == .month {
      return String(format: "%04d-%02d", year, month)
    }
    return String(format: "%04d-%02d-%02d", year, month, components.day ?? 0)
  }

  func formatPeriodLabel(_ key: String) -> String {
    let parts = key.split(separator: "-")
    if parts.count == 2 {
      return "\(parts[0])/\(parts[1])"
    }
    if parts.count == 3 {
      return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
    }
    return key
  }
}
