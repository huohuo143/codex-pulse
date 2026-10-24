import Foundation
import CryptoKit
import CodexMobileCore

public enum MobileDetailAdapter {
  public static func make(status: CodexStatus, device: MobileDevice, usageAt: Date?, history: [QuotaSnapshot], forecast: QuotaForecast?, budgets: [ProjectBudget], radar: CodexRadarSnapshot?, rate: ExchangeRateSnapshot?, health: ReliabilitySnapshot) -> MobileDetailSnapshot {
    let basic = MobileSnapshotAdapter.make(status: status, device: device)
    var result = MobileDetailSnapshot(publishedAt: status.generatedAt, device: device, accountID: basic.account?.id)
    result.sourceTimeZone = TimeZone.current.identifier
    result.usageSampledAt = usageAt; result.usageValidUntil = status.usageValidUntil
    if usageAt != nil {
      let stats = status.tokenStats
      var usage = MobileUsage()
      usage.today=stats.todayTokens; usage.week=stats.last7DaysTokens; usage.month=stats.monthTokens; usage.rolling=stats.rolling24HoursTokens
      usage.hourly=stats.hourly.suffix(24).map(point); usage.daily=stats.daily.suffix(30).map(point); usage.monthly=stats.monthly.suffix(24).map(point)
      usage.models=Dictionary(grouping: stats.modelHourly, by: \.model).map { model, rows in
        MobileMetric(model, model, Double(rows.reduce(0) { $0 + $1.totalTokens }))
      }.sorted { ($0.value ?? 0) > ($1.value ?? 0) }.prefix(200).map { $0 }
      usage.categories=stats.categoryBreakdown.map { MobileMetric($0.category.rawValue, $0.category.label, Double($0.totalTokens)) }
      func anonymous(_ id: String) -> String {
        SHA256.hash(data: Data(("mobile-project-v1:"+device.id+":"+id).utf8)).map { String(format:"%02x", $0) }.joined()
      }
      usage.projects=stats.monthTopProjects.prefix(100).map {
        let id=anonymous($0.id); return MobileMetric(id,"项目 · "+id.prefix(8),Double($0.totalTokens),secondary:Double($0.calls))
      }
      // Recompute from exactly this captured stats value, avoiding async UI analysis races.
      let analysis=UsageAnalyzer.analyze(stats:stats,budgets:budgets,now:status.generatedAt)
      usage.budgets=analysis.projectBudgets.prefix(100).map {
        let id=anonymous($0.budget.id)
        return MobileMetric(id,"项目 · "+id.prefix(8),Double($0.usedTokens),secondary:Double($0.budget.monthlyTokenLimit),tertiary:Double($0.projectedMonthTokens))
      }
      usage.devices=stats.deviceUsage.prefix(100).map {
        MobileMetric($0.deviceID,$0.deviceName,Double($0.todayTokens),secondary:Double($0.monthTokens),note:$0.updatedAt.ISO8601Format())
      }
      usage.analysis=[
        MobileMetric("recent7","最近 7 天",Double(analysis.recent7Tokens)),
        MobileMetric("previous7","此前 7 天",Double(analysis.previous7Tokens)),
        MobileMetric("change","7 天环比",analysis.sevenDayChangePercent,note:"%"),
        MobileMetric("daily","日均 Token",Double(analysis.averageDailyTokens)),
        MobileMetric("projection","月末预计 Token",Double(analysis.projectedMonthTokens)),
        MobileMetric("cache","缓存命中率",analysis.cacheHitRate.map { $0 * 100 },note:"%"),
        MobileMetric("call","每次调用平均 Token",analysis.averageTokensPerCall.map(Double.init)),
        MobileMetric("modelShare","最高模型集中度",analysis.topModelShare.map { $0 * 100 },note:"%"),
        MobileMetric("projectShare","最高项目集中度",analysis.topProjectShare.map { $0 * 100 },note:"%")]
      usage.analysis += analysis.anomalies.prefix(14).map { MobileMetric("peak-"+$0.dayKey,$0.label+" 异常高峰",Double($0.totalTokens),secondary:$0.multiple,note:"相对近期基线倍数；仅描述性异常") }
      usage.costs=[("24h","滚动 24 小时",stats.cost24Hours),("7d","最近 7 天",stats.cost7Days),("month","本月",stats.costMonth)].map { id,label,cost in
        MobileMetric(id,label,cost.hasEstimate ? cost.usd : nil,secondary:cost.coveragePercent,note:cost.unpricedModels.prefix(8).joined(separator:", "))
      }
      usage.cnyRate=rate?.rate; usage.rateDate=rate?.rateDate
      result.usage=usage
    }
    if basic.account != nil {
      result.history=Array(QuotaHistoryTrend.displayPoints(QuotaHistoryTrend.points(snapshots:history,period:.month,now:status.generatedAt)).suffix(10000)).map {
        MobileHistoryPoint(date:$0.snapshot.recordedAt,remaining:$0.snapshot.remainingPercent,resetAt:$0.snapshot.resetsAt,segment:$0.segment)
      }
      if let f=forecast {
        result.forecast=MobileForecast(generatedAt:f.generatedAt,resetAt:f.resetsAt,hourlyRate:f.ratePerHour,earliest:f.earliestExhaustion,estimated:f.estimatedExhaustion,latest:f.latestExhaustion,balancedDaily:f.balancedDailyPercent,risk:f.risk.rawValue,confidence:f.confidence.rawValue,summary:f.riskExplanation)
      }
      result.creditsRead=basic.resetCredits?.read
      let grouped=Dictionary(grouping:status.rateLimitResetCredits?.availableCredits ?? []) { "\($0.grantedAt.timeIntervalSince1970)-\($0.expiresAt?.timeIntervalSince1970 ?? 0)" }
      result.credits=grouped.values.compactMap { rows in rows.first.map { MobileCreditBatch(grantedAt:$0.grantedAt,expiresAt:$0.expiresAt,count:rows.count) } }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }
    if let radar {
      result.radar=MobileRadar(title:radar.tiboStatusTitle(at:status.generatedAt),summary:radar.tiboStatusSummary(at:status.generatedAt),
        sampledAt:radar.syncState?.lastSuccessAt,checkedAt:radar.syncState?.lastAttemptAt,validUntil:radar.tiboStatusValidUntil,
        deadline:radar.tiboDeadline(at:status.generatedAt)?.date,completionUntil:radar.tiboCompletionUntil(at:status.generatedAt),
        healthy:radar.tiboDisplayRefreshIsHealthy(at:status.generatedAt),
        links:Array((radar.tiboFeed?.posts.compactMap { $0.url?.absoluteString } ?? []).filter(MobileDetailSnapshot.safeURL).prefix(8)))
      if let calendar=radar.resetCalendar {
        result.calendarReadAt=calendar.lastSuccessAt; result.calendarFailed=calendar.failureMessage != nil
        result.calendar=calendar.events.prefix(4000).map { e in
          let links=[e.sourceURL,e.announcementURL,e.completionURL,e.evidenceURL].compactMap { $0?.absoluteString }.filter(MobileDetailSnapshot.safeURL)
          return MobileCalendarEvent(id:e.id,day:e.day,kind:e.kind.title,title:e.title,summary:e.summary,confirmation:e.confirmation.title,precision:e.dateExplanation,occurredAt:e.occurredAt,links:Array(Set(links)).sorted())
        }
        result.monthlyResets=calendar.monthlyTotals.prefix(120).map { MobileMetric($0.month,$0.month,Double($0.hardResets),secondary:Double($0.resetCards),note:$0.verifiedOn ?? "") }
      }
    }
    result.healthAt=health.generatedAt
    result.health=health.checks.map { MobileMetric($0.id.rawValue,$0.title,note:$0.level.rawValue) }
    return result
  }
  private static func point(_ p: TokenBucket) -> MobileTokenPoint {
    MobileTokenPoint(key:p.key,label:p.label,tokens:p.totalTokens,input:p.inputTokens,cached:p.cachedInputTokens,output:p.outputTokens)
  }
}
