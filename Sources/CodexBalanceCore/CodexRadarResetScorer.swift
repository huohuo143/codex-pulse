import Foundation

enum CodexRadarVerifiedTiboSignals {
  static let shippingSignalID = "2082655731204096275"

  static func mergedPosts(
    current: [CodexRadarTiboPost],
    previous: [CodexRadarTiboPost] = [],
    resetAt: Date?,
    now: Date
  ) -> [CodexRadarTiboPost] {
    let candidates = current + previous + verifiedPosts
    var seen = Set<String>()
    return candidates
      .filter { post in
        guard let date = post.publishedAt else { return true }
        guard date <= now.addingTimeInterval(60 * 60) else { return false }
        guard let resetAt else { return true }
        if date > resetAt { return true }

        // A single Tibo status can close the just-completed reset while also
        // deferring a separate celebration to the next day. Keep that dual-cycle
        // signal when its timestamp is the reset anchor; an ordinary completion
        // status at the same boundary still belongs to the old cycle and clears.
        return abs(date.timeIntervalSince(resetAt)) < 1
          && isDeferredNextCycleSignal(post)
      }
      .filter(\.isResetRelevantForDisplay)
      .filter { seen.insert($0.id).inserted }
      .sorted { lhs, rhs in
        switch (lhs.publishedAt, rhs.publishedAt) {
        case let (left?, right?): left > right
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): lhs.id > rhs.id
        }
      }
  }

  static func resetAnchor(for page: CodexRadarPublicPageSnapshot) -> Date? {
    if page.eventStatus?.lowercased() == "completed"
      || page.eventKind?.lowercased() == "window_closed"
      || page.judgement.headline.contains("完成") {
      return page.resetAt ?? page.judgement.updatedAt
    }
    return page.resetAt
  }

  static func isDeferredNextCycleSignal(_ post: CodexRadarTiboPost) -> Bool {
    let text = [post.originalText, post.translationZh ?? ""]
      .joined(separator: " ")
      .lowercased()
    let hasTomorrow = text.contains("tomorrow") || text.contains("明天")
    let hasDeferral = text.contains("moved to tomorrow")
      || text.contains("move to tomorrow")
      || text.contains("postponed until tomorrow")
      || text.contains("deferred until tomorrow")
      || text.contains("移到明天")
      || text.contains("改到明天")
      || text.contains("延期到明天")
      || text.contains("延至明天")
    let hasButton = text.contains("button") || text.contains("按钮")
    let hasPressed = text.contains("pressed")
      || text.contains("按下")
      || text.contains("按过")
    let hasToday = text.contains("today") || text.contains("今天")
    let hasBankedReset = text.contains("banked reset")
      || text.contains("可储存的重置")
      || text.contains("可储存重置")

    return hasBankedReset == false
      && hasTomorrow
      && hasDeferral
      && hasButton
      && hasPressed
      && hasToday
  }

  private static let verifiedPosts = [
    CodexRadarTiboPost(
      id: shippingSignalID,
      url: URL(string: "https://x.com/thsottiaux/status/\(shippingSignalID)"),
      publishedAt: Date(timeIntervalSince1970: 1_785_378_794.848),
      relevance: "high",
      relevanceLabel: "组合强信号",
      originalText: "This week is all about intelligence too cheap to meter. Tomorrow we ship again.",
      translationZh: "本周的重点，是让智能便宜到几乎无需计量。明天我们再次发布。",
      analysisZh: "独立 Post 同时出现低成本/高供给措辞与明确的次日发布预告；属于强发布前信号，但没有明确承诺重置额度。"
    )
  ]
}

enum CodexRadarResetScorer {
  static let methodology = "以最近一次官方重置为边界，只根据其后仍在有效时间窗内的 Tibo Posts / Replies 本地计分。一般近时信号前 6 小时保持权重，随后线性衰减并在 24 小时归零；“tomorrow/明天”按 Tibo 所在 PT 时区的目标日衰减。上游相关性标签只用于展示，不单独增加概率；BANKED reset 是可储存权益，不计入全局硬重置。同类信号只计一次，上限 95%。"

  private struct Lifetime {
    var factor: Double
    var validUntil: Date?
  }

  private struct PostSemantics {
    var post: CodexRadarTiboPost
    var hasReleaseTiming: Bool
    var hasAbundance: Bool
    var hasContextualResetTiming: Bool
    var hasDeferredNextCycleSignal: Bool
    var hasExplicitReset: Bool
    var hasBankedReset: Bool
    var releaseLifetime: Lifetime
    var abundanceLifetime: Lifetime
    var contextualLifetime: Lifetime
    var deferredLifetime: Lifetime
    var explicitLifetime: Lifetime

    var supportsGlobalHardResetPrediction: Bool {
      hasContextualResetTiming
        || hasDeferredNextCycleSignal
        || hasExplicitReset
    }

    var strongestActiveFactor: Double {
      [
        releaseLifetime.factor,
        abundanceLifetime.factor,
        contextualLifetime.factor,
        deferredLifetime.factor,
        explicitLifetime.factor
      ].max() ?? 0
    }

    var activeValidUntil: Date? {
      [
        releaseLifetime.validUntil,
        abundanceLifetime.validUntil,
        contextualLifetime.validUntil,
        deferredLifetime.validUntil,
        explicitLifetime.validUntil
      ].compactMap { $0 }.max()
    }
  }

  static func estimate(
    from page: CodexRadarPublicPageSnapshot,
    now: Date
  ) -> CodexRadarResetEstimate {
    let event = eventScore(
      kind: page.eventKind,
      status: page.eventStatus,
      headline: page.judgement.headline
    )
    let resetAt = CodexRadarVerifiedTiboSignals.resetAnchor(for: page)
    let posts = CodexRadarVerifiedTiboSignals.mergedPosts(
      current: page.tiboFeed.posts,
      resetAt: resetAt,
      now: now
    )
    let semantics = posts.map { analyze($0, now: now) }
    let resetSupportingSemantics = semantics.filter(\.supportsGlobalHardResetPrediction)
    let releaseFactor = resetSupportingSemantics.map(\.releaseLifetime.factor).max() ?? 0
    let abundanceFactor = resetSupportingSemantics.map(\.abundanceLifetime.factor).max() ?? 0
    let contextualFactor = semantics.map(\.contextualLifetime.factor).max() ?? 0
    let deferredFactor = semantics.map(\.deferredLifetime.factor).max() ?? 0
    let explicitFactor = semantics.map(\.explicitLifetime.factor).max() ?? 0
    let hasReleaseTiming = releaseFactor > 0
    let hasAbundance = abundanceFactor > 0
    let hasContextualResetTiming = contextualFactor > 0
    let hasDeferredNextCycleSignal = deferredFactor > 0
    let hasExplicitReset = explicitFactor > 0
    let hasBankedReset = semantics.contains(where: \.hasBankedReset)
    let hasStandaloneSignal = resetSupportingSemantics.contains {
      $0.strongestActiveFactor > 0 && $0.post.isReply == false
    }
    let hasCombinationSignal = hasReleaseTiming && hasAbundance

    var semanticScore = 0
    var scoreSignals: [String] = []
    if hasReleaseTiming {
      let score = decayedScore(30, factor: releaseFactor)
      semanticScore += score
      scoreSignals.append("发布预告 +\(score)%")
    }
    if hasAbundance {
      let score = decayedScore(20, factor: abundanceFactor)
      semanticScore += score
      scoreSignals.append("低成本 / 高供给 +\(score)%")
    }
    if hasCombinationSignal {
      let score = decayedScore(20, factor: min(releaseFactor, abundanceFactor))
      semanticScore += score
      scoreSignals.append("跨状态组合加成 +\(score)%")
    }
    if hasContextualResetTiming {
      let score = decayedScore(55, factor: contextualFactor)
      semanticScore = max(semanticScore, score)
      scoreSignals.append("含歧义的重置时点暗示 +\(score)%")
    }
    if hasDeferredNextCycleSignal {
      let score = decayedScore(70, factor: deferredFactor)
      semanticScore = max(semanticScore, score)
      scoreSignals.append("跨周期次日庆祝强信号 +\(score)%")
    }
    if hasStandaloneSignal {
      let factor = resetSupportingSemantics
        .filter { $0.post.isReply == false }
        .map(\.strongestActiveFactor)
        .max() ?? 0
      let score = decayedScore(5, factor: factor)
      semanticScore += score
      scoreSignals.append("独立 Post 权重 +\(score)%")
    }
    if hasExplicitReset {
      let directBase = semantics.contains {
        $0.explicitLifetime.factor > 0 && $0.post.isReply == false
      } ? 65 : 55
      let score = decayedScore(directBase, factor: explicitFactor)
      semanticScore = max(semanticScore, score)
      scoreSignals.append("明确重置措辞：至少 \(score)%")
    }
    if hasBankedReset {
      scoreSignals.append("BANKED reset：已确认为可储存权益，不计入全局硬重置概率")
    }

    let tiboScore = semanticScore
    let percent = min(95, event.score + tiboScore)
    let activeSemantics = resetSupportingSemantics.filter { $0.strongestActiveFactor > 0 }
    let evidenceUpdatedAt = activeSemantics.compactMap { $0.post.publishedAt }.max()
    let validUntil = activeSemantics.compactMap(\.activeValidUntil).max()

    var signals = [
      "窗口基准 \(event.score)%：\(event.reason)"
    ]
    if let resetAt {
      signals.append(
        "统计边界：上次重置 \(resetAt.formatted(.dateTime.month().day().hour().minute()))；其后收录 \(posts.count) 条 Tibo 状态"
      )
    } else {
      signals.append("统计边界：尚未取得明确重置时间；收录 \(posts.count) 条 Tibo 状态")
    }
    if scoreSignals.isEmpty {
      signals.append("Tibo 状态 +0%：未发现新的重置信号")
    } else {
      signals.append("Tibo 状态 +\(tiboScore)%：\(scoreSignals.joined(separator: "；"))")
    }
    signals.append("上游相关性标签不单独计分；超过有效时间窗自动衰减归零；上限 95%")

    let statusText: String
    if hasCombinationSignal {
      statusText = "上次重置后，Tibo 状态形成“发布预告 + 低成本/高供给”的组合强信号，但仍未明确承诺额度重置。"
    } else if hasExplicitReset {
      statusText = "上次重置后出现明确的额度重置措辞，建议打开原帖核对官方语境。"
    } else if hasDeferredNextCycleSignal {
      statusText = "Tibo 确认本轮按钮已按下，同时将另一场庆祝延期至明天，构成跨重置周期的下一轮强信号，但仍未明确承诺再次全局重置。"
    } else if hasContextualResetTiming {
      statusText = "Tibo 的独立 Post 同时提到 reset button 与明天，构成含歧义的重置时点暗示，但仍未明确承诺 Codex 全局额度重置。"
    } else if tiboScore > 0 {
      statusText = "上次重置后的动态涉及发布或用量语境，但未出现新的重置承诺。"
    } else if hasBankedReset {
      statusText = "Tibo 已明确宣布发放 BANKED reset，但这是可储存权益，不等于全局硬重置；当前没有新的硬重置信号。"
    } else {
      statusText = "上次重置后尚未出现新的重置信号。"
    }
    let summary = "\(page.judgement.summary) \(statusText)"

    return CodexRadarResetEstimate(
      probability24h: Double(percent) / 100,
      level: level(for: percent),
      summary: summary,
      updatedAt: now,
      evaluatedAt: now,
      evidenceUpdatedAt: evidenceUpdatedAt,
      validUntil: validUntil,
      signals: signals,
      methodology: methodology
    )
  }

  private static func analyze(_ post: CodexRadarTiboPost, now: Date) -> PostSemantics {
    let text = [
      post.originalText,
      post.translationZh ?? ""
    ]
      .joined(separator: " ")
      .lowercased()
    let hasReleaseTiming = (
      text.contains("tomorrow")
        || text.contains("明天")
        || text.contains("soon")
        || text.contains("很快")
    ) && (
      text.contains("ship")
        || text.contains("roll out")
        || text.contains("launch")
        || text.contains("release")
        || text.contains("发布")
        || text.contains("上线")
    )
    let hasAbundance = text.contains("too cheap to meter")
      || text.contains("无需计量")
      || text.contains("几乎无需计量")
      || text.contains("unmetered")
      || text.contains("more capacity")
      || text.contains("更多容量")
      || text.contains("高供给")
    let hasBankedReset = text.contains("banked reset")
      || text.contains("banked my friend")
      || text.contains("可储存的重置")
      || text.contains("可存起来的重置")
      || text.contains("可储存重置")
    let hasNearTermTiming = text.contains("tomorrow")
      || text.contains("明天")
      || text.contains("within 24 hours")
      || text.contains("24小时内")
      || text.contains("24 小时内")
    let hasTomorrow = text.contains("tomorrow") || text.contains("明天")
    let hasResetButtonMetaphor = text.contains("reset button")
      || text.contains("press reset")
      || text.contains("pressed reset")
      || text.contains("按下重置")
      || text.contains("按过重置")
      || text.contains("重置按钮")
    let hasDeferredNextCycleSignal = CodexRadarVerifiedTiboSignals
      .isDeferredNextCycleSignal(post)
    let hasContextualResetTiming = hasBankedReset == false
      && hasNearTermTiming
      && hasResetButtonMetaphor
      && hasDeferredNextCycleSignal == false
    let hasExplicitReset = hasBankedReset == false && (
      text.contains("usage reset")
        || text.contains("reset usage")
        || text.contains("reset the limit")
        || text.contains("hard reset")
        || text.contains("global reset")
        || text.contains("硬重置")
        || text.contains("全局重置")
        || text.contains("统一清零")
        || text.contains("重置额度")
        || text.contains("额度重置")
    )

    let generalLifetime = rollingLifetime(for: post, now: now)
    let timingLifetime = hasTomorrow
      ? tomorrowLifetime(for: post, now: now)
      : generalLifetime

    return PostSemantics(
      post: post,
      hasReleaseTiming: hasReleaseTiming,
      hasAbundance: hasAbundance,
      hasContextualResetTiming: hasContextualResetTiming,
      hasDeferredNextCycleSignal: hasDeferredNextCycleSignal,
      hasExplicitReset: hasExplicitReset,
      hasBankedReset: hasBankedReset,
      releaseLifetime: hasReleaseTiming ? timingLifetime : inactiveLifetime,
      abundanceLifetime: hasAbundance ? generalLifetime : inactiveLifetime,
      contextualLifetime: hasContextualResetTiming ? timingLifetime : inactiveLifetime,
      deferredLifetime: hasDeferredNextCycleSignal ? timingLifetime : inactiveLifetime,
      explicitLifetime: hasExplicitReset ? timingLifetime : inactiveLifetime
    )
  }

  private static let inactiveLifetime = Lifetime(factor: 0, validUntil: nil)

  private static func rollingLifetime(
    for post: CodexRadarTiboPost,
    now: Date
  ) -> Lifetime {
    guard let publishedAt = post.publishedAt else { return inactiveLifetime }
    let age = now.timeIntervalSince(publishedAt)
    guard age >= -60 * 60, age < 24 * 60 * 60 else {
      return inactiveLifetime
    }
    let factor: Double
    if age <= 6 * 60 * 60 {
      factor = 1
    } else {
      factor = (24 * 60 * 60 - age) / (18 * 60 * 60)
    }
    return Lifetime(
      factor: min(1, max(0, factor)),
      validUntil: publishedAt.addingTimeInterval(24 * 60 * 60)
    )
  }

  private static func tomorrowLifetime(
    for post: CodexRadarTiboPost,
    now: Date
  ) -> Lifetime {
    guard let publishedAt = post.publishedAt else { return inactiveLifetime }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
    let postedDay = calendar.startOfDay(for: publishedAt)
    guard let targetStart = calendar.date(byAdding: .day, value: 1, to: postedDay),
          let targetEnd = calendar.date(byAdding: .day, value: 1, to: targetStart),
          now >= publishedAt.addingTimeInterval(-60 * 60),
          now < targetEnd
    else { return inactiveLifetime }
    let factor: Double
    if now < targetStart {
      factor = 1
    } else {
      factor = targetEnd.timeIntervalSince(now) / targetEnd.timeIntervalSince(targetStart)
    }
    return Lifetime(
      factor: min(1, max(0, factor)),
      validUntil: targetEnd
    )
  }

  private static func decayedScore(_ base: Int, factor: Double) -> Int {
    Int((Double(base) * min(1, max(0, factor))).rounded())
  }

  private static func eventScore(
    kind: String?,
    status: String?,
    headline: String
  ) -> (score: Int, reason: String) {
    let kind = kind?.lowercased() ?? ""
    let status = status?.lowercased() ?? ""
    if status == "completed" || kind == "window_closed" || headline.contains("完成") {
      return (0, "上轮官方重置已完成，旧状态已清零")
    }
    if ["open", "active", "announced", "confirmed"].contains(status)
      || ["window_open", "reset_announced"].contains(kind) {
      return (90, "官方已宣布或开启重置窗口")
    }
    if ["probing", "polling", "monitoring"].contains(status)
      || ["probe", "poll"].contains(kind) {
      return (25, "官方正在试探或征询重置")
    }
    return (0, "未确认开启重置窗口")
  }

  private static func level(for percent: Int) -> String {
    switch percent {
    case 90...: "very_high"
    case 75...: "high"
    case 60...: "medium_high"
    case 45...: "medium"
    case 30...: "medium_low"
    case 15...: "low"
    default: "very_low"
    }
  }
}
