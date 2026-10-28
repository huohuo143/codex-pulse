import CodexBalanceCore
import SwiftUI

struct CodexRadarView: View {
  let snapshot: CodexRadarSnapshot?
  let palette: DashboardPalette
  let isLoading: Bool
  let nextSyncAt: Date?
  let statusMessage: String
  let refresh: () -> Void
  @AppStorage("radarDetailsExpanded") private var detailsExpanded = false
  @AppStorage("radarCommunityExpanded") private var communityExpanded = false
  @State private var allTiboPostsExpanded = false

  private var sourceLabel: String { snapshot?.tiboSourceID == "x-first" ? "X 官网优先 · 三个网站备用" : (snapshot?.tiboSourceID == "x" ? "X 官网 · Tibo 发帖与回复" : CodexRadarService.attributionText) }
  private var sourceURL: URL { ["x", "x-first"].contains(snapshot?.tiboSourceID ?? "") ? XTiboTimeline.profileURL : CodexRadarService.siteURL }

  var body: some View {
    VStack(spacing: 14) {
      TimelineView(.periodic(from: .now, by: snapshot?.tiboCompletionUntil(at: Date()) == nil ? 30 : 1)) { _ in
        // A newly published analysis may be newer than the last scheduled tick.
        resetOverviewCard(at: Date())
      }
      DisclosureGroup("动态、原帖与翻译", isExpanded: $detailsExpanded) { tiboCard }
      DisclosureGroup("模型效率与社区推荐", isExpanded: $communityExpanded) { CodexRadarCommunityView(snapshot: snapshot) }
    }
  }

  private func resetOverviewCard(at now: Date) -> some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Text("Tibo 重置预告")
            .font(.system(size: 24, weight: .heavy, design: .rounded))
          Spacer()
          Text(snapshot?.tiboModelLabel ?? "本机 Codex 模型")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(palette.weekly)
        }
        refreshStatus(at: now)
        if let snapshot {
          if let deadline = snapshot.tiboDeadline(at: now), let date = deadline.date {
            VStack(alignment: .leading, spacing: 7) {
              Label("最晚到账时间 · 北京时间", systemImage: "clock.badge.exclamationmark")
                .font(.system(size: 15, weight: .bold))
              Text(BalanceFormatters.beijingDeadline(date))
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .monospacedDigit()
              Text(date <= now ? "预告时限已过，实际到账仍待确认" : "Tibo 明确预告的期限，实际到账仍待确认")
                .font(.system(size: 12, weight: .semibold))
              if let clarification = deadline.timeZoneClarification {
                Text(clarification).font(.system(size: 11, weight: .semibold))
              }
              Text("原文（\(deadline.sourceTimeZone)）：\(deadline.sourceQuote)")
                .font(.system(size: 11)).textSelection(.enabled)
              if let url = snapshot.tiboFeed?.posts.first(where: { $0.id == deadline.evidenceID })?.url {
                Link("查看期限原帖", destination: url).font(.system(size: 11, weight: .semibold))
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .foregroundStyle(Color.black)
            .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
          }
          if let until = snapshot.tiboCompletionUntil(at: now) {
            HStack {
              Label("24小时完成提示 · 剩余", systemImage: "checkmark.seal.fill")
              Spacer()
              Text(timerInterval: now...until, countsDown: true).monospacedDigit().fixedSize()
            }
            .font(.system(size: 24, weight: .heavy, design: .rounded))
            .padding(14).foregroundStyle(.black)
            .background(Color.green, in: RoundedRectangle(cornerRadius: 12))
          }
          Text(snapshot.tiboStatusTitle(at: now))
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .foregroundStyle(palette.weekly)
          Text(snapshot.tiboStatusSummary(at: now))
            .font(.system(size: 13, weight: .medium))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
          if snapshot.tiboRefreshIsHealthy(at: now),
             let analysis = snapshot.tiboAnalysis {
            if snapshot.tiboHasAnnouncement(at: now), !analysis.timingZh.isEmpty {
              Text(analysis.timingZh)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DashboardColors.subtleText)
                .fixedSize(horizontal: false, vertical: true)
            }
            ForEach((snapshot.tiboFeed?.posts ?? []).filter { analysis.evidenceIDs.contains($0.id) }.sorted {
              if ($0.id == analysis.announcementEvidenceID) != ($1.id == analysis.announcementEvidenceID) {
                return $0.id == analysis.announcementEvidenceID
              }
              return ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
            }) { post in
              VStack(alignment: .leading, spacing: 5) {
                Text(post.originalText)
                  .font(.system(size: 12, weight: .semibold))
                  .textSelection(.enabled)
                HStack {
                  if let date = post.publishedAt { Text("原帖 · \(radarUpdateTime(date))") }
                  if let url = post.url { Link("查看 Tibo 原帖", destination: url) }
                }
                .font(.system(size: 11, weight: .medium))
              }
              .padding(10)
              .background(DashboardColors.faintFill, in: RoundedRectangle(cornerRadius: 10))
            }
            if let date = analysis.analyzedAt {
              Text("分析完成 · \(radarUpdateTime(date)) · \(CodexRadarRefreshPolicy.tiboPollingSummary(at: Date()))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DashboardColors.subtleText)
            }
          }
        } else {
          unavailableOverview
        }
        Divider().overlay(DashboardColors.separator)
        Text("\(CodexRadarRefreshPolicy.tiboPollingSummary(at: Date())) · 仅保留最近 7 天 · 不预测概率")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
        Link(sourceLabel, destination: sourceURL)
          .font(.system(size: 10, weight: .medium))
      }
    }
  }

  private func refreshStatus(at now: Date) -> some View {
    let paused = CodexRadarRefreshPolicy.isTiboPollingPaused(at: now)
    let healthy = snapshot?.tiboDisplayRefreshIsHealthy(at: now) == true
    let hasFailure = (snapshot?.tiboAnalysisEnabled != false && snapshot?.tiboAnalysisFailure != nil) || (snapshot?.syncState?.consecutiveFailures ?? 0) > 0
    let route = snapshot?.tiboReadRoute
    let title = paused ? "Tibo 定时暂停 · 北京时间 21:00 恢复" : isLoading ? "正在检查与分析" : (route?.xState == .notChecked ? "等待 X 检查" : healthy ? (route?.usedBackup == true ? "备用来源读取成功" : route?.xState == .success ? "X 官网读取成功" : "来源读取成功") : (hasFailure ? "刷新或分析未成功" : "等待刷新与分析"))
    let color: Color = paused ? palette.weekly : isLoading ? palette.weekly : (healthy && route?.xState != .notChecked ? .green : .orange)
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 9) {
        if isLoading { ProgressView().controlSize(.small) }
        else { Image(systemName: paused ? "moon.fill" : healthy && route?.xState != .notChecked ? "checkmark.circle.fill" : "exclamationmark.circle.fill") }
        Text(title)
        Spacer()
      }
      .font(.system(size: 18, weight: .bold))
      .foregroundStyle(color)
      HStack(alignment: .top, spacing: 25) {
        VStack(alignment: .leading, spacing: 4) {
          Text("最近成功检查").font(.system(size: 12, weight: .semibold))
          Text(snapshot?.syncState?.lastSuccessAt.map { radarUpdateTime($0) } ?? "尚未成功")
            .font(.system(size: 22, weight: .heavy, design: .rounded)).monospacedDigit()
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("下次检查").font(.system(size: 12, weight: .semibold))
          Text(nextSyncAt.map { radarUpdateTime($0) } ?? "等待安排")
            .font(.system(size: 22, weight: .heavy, design: .rounded)).monospacedDigit()
        }
        Spacer(minLength: 0)
      }
      if !paused, let failure = snapshot?.syncState?.failureMessage {
        Text(failure).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
      }
      if let latest = snapshot?.tiboFeed?.posts.compactMap(\.publishedAt).max() {
        Text("最新原帖 · \(radarUpdateTime(latest))").font(.system(size: 12, weight: .semibold))
      }
      if let route { Text(route.message).font(.system(size: 12, weight: .medium)).foregroundStyle(route.xState == .success ? Color.secondary : Color.orange) }
      if let checks = snapshot?.tiboSourceChecks, !checks.isEmpty {
        Text(checks.map { "\($0.source.label)：\($0.succeeded ? "已读取" : "暂不可用")" }.joined(separator: " · "))
          .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
      }
      Text("检查成功表示来源可读；公开来源收录仍可能延迟或遗漏。")
        .font(.system(size: 11)).foregroundStyle(DashboardColors.subtleText)
    }
    .padding(13)
    .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .combine)
  }

  private var unavailableOverview: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Codex")
        .font(.system(size: 27, weight: .heavy, design: .rounded))
      Text("等待公开摘要")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(DashboardColors.subtleText)
      Divider().overlay(DashboardColors.separator)
      Text(statusMessage)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(DashboardColors.subtleText)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("重新同步") { refresh() }
          .disabled(isLoading)
        Link("打开数据源", destination: CodexRadarService.siteURL)
      }
      .font(.caption)
    }
  }

  private var tiboCard: some View {
    let presence = snapshot?.tiboPresence
    let timezoneID = presence?.timezone ?? "America/Los_Angeles"
    return PanelCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .firstTextBaseline) {
          Text("Tibo 雷达")
            .font(.system(size: 20, weight: .heavy, design: .rounded))
            .foregroundStyle(palette.weekly)
          Spacer()
          Text("\(presence?.handle ?? "@thsottiaux") · PT")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DashboardColors.subtleText)
        }

        TiboClockView(
          timezoneID: timezoneID,
          hasRadarData: presence != nil,
          tint: palette.weekly
        )

        HStack(alignment: .top, spacing: 13) {
          ZStack {
            Circle()
              .fill(palette.weekly.opacity(0.13))
            Circle()
              .stroke(palette.weekly.opacity(0.55), lineWidth: 1.5)
            Image(systemName: "person.fill")
              .font(.system(size: 22, weight: .semibold))
              .foregroundStyle(palette.weekly)
          }
          .frame(width: 52, height: 52)

          VStack(alignment: .leading, spacing: 4) {
            Text(presence?.locationLabelZh ?? "旧金山湾区 / PT")
              .font(.system(size: 16, weight: .bold))
            Text(presence == nil ? "等待公开摘要" : "公开推测时区")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(DashboardColors.subtleText)
            Text(snapshot?.tiboSourceID == "x-first" ? "优先读取 Tibo 的 X 发帖与回复，受限时自动使用备用来源。此时钟不表示在线状态。" : presence?.evidenceSummaryZh ?? "公开摘要尚未返回时区依据；未获取数据时不推测实时状态。")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(DashboardColors.subtleText)
              .lineSpacing(2)
              .lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        Divider().overlay(DashboardColors.separator)

        latestTiboUpdate(snapshot: snapshot, presence: presence)

        if let posts = snapshot?.tiboFeed?.posts,
           displayPosts(from: posts).isEmpty == false {
          Divider().overlay(DashboardColors.separator)
          tiboPosts(posts)
        }

        HStack {
          Link(sourceLabel, destination: sourceURL)
          Spacer()
          Text(snapshot?.tiboReadRoute?.usedBackup == true ? "本轮使用备用网站" : snapshot?.tiboSourceID == "x-first" || snapshot?.tiboSourceID == "x" ? "X 页面实际加载的动态" : "公开源收录的动态")
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(DashboardColors.subtleText)
      }
    }
  }

  private func tiboPosts(_ posts: [CodexRadarTiboPost]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("最新 Posts / Replies")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(palette.weekly)
        Spacer()
        Text("只读公开动态")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
      }

      ForEach(displayPosts(from: posts)) { post in
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 7) {
            Text(post.isReply ? "回复" : "动态")
              .font(.system(size: 9, weight: .bold, design: .rounded))
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(palette.weekly.opacity(0.12), in: Capsule())
            if let label = CodexRadarTiboAttention.label(for: post) {
              Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.orange)
            }
            Spacer()
            if let date = post.publishedAt {
              Text(radarUpdateTime(date))
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(DashboardColors.subtleText)
            }
            if let url = post.url {
              Link(destination: url) {
                Image(systemName: "arrow.up.right.square")
              }
              .help("打开 Tibo X 原帖")
            }
          }
          Text(post.isPublicSummary ? post.displayTextZh : post.originalText)
            .font(.system(size: 11, weight: .semibold))
            .textSelection(.enabled)
          if let translation = post.translationZh, translation.isEmpty == false {
            Text(translation)
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(DashboardColors.subtleText)
              .textSelection(.enabled)
          }

        }
        .padding(10)
        .background(DashboardColors.faintFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      if posts.count > 3 {
        Button(allTiboPostsExpanded ? "收起动态" : "查看全部 \(posts.count) 条动态") {
          allTiboPostsExpanded.toggle()
        }
        .font(.system(size: 11, weight: .semibold))
        .buttonStyle(.plain)
        .foregroundStyle(palette.weekly)
      }
    }
  }

  private func displayPosts(from posts: [CodexRadarTiboPost]) -> [CodexRadarTiboPost] {
    allTiboPostsExpanded ? posts : CodexRadarTiboAttention.previewPosts(posts, at: Date())
  }

  private func relevanceTint(_ relevance: String) -> Color {
    switch relevance.lowercased() {
    case "official", "direct", "high": .green
    case "medium": .orange
    case "indirect": .yellow
    default: DashboardColors.subtleText
    }
  }

  @ViewBuilder
  private func latestTiboUpdate(
    snapshot: CodexRadarSnapshot?,
    presence: CodexRadarTiboPresence?
  ) -> some View {
    let latest = snapshot?.tiboFeed?.posts.first
    let activity = latest?.displayTextZh
    let usesPublicJudgement = activity == nil
    let fallback = snapshot?.tiboStatusSummary
    let activityDate = latest?.publishedAt
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(usesPublicJudgement || activity == nil ? "最新研判" : "最新动态")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(palette.weekly)
        Spacer()
        if let date = activityDate {
          Text(date.formatted(.dateTime.month().day().hour().minute()))
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(DashboardColors.subtleText)
        }
      }
      Text(activity ?? fallback ?? "公开摘要尚未返回最新动态或研判摘要。")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(DashboardColors.text.opacity(0.90))
        .lineSpacing(3)
        .lineLimit(3)
    }
  }

  private func shortTime(_ date: Date) -> String {
    date.formatted(.dateTime.hour().minute())
  }

  private func radarUpdateTime(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
      return shortTime(date)
    }
    return date.formatted(.dateTime.month().day().hour().minute())
  }

}

private struct TiboClockView: View {
  let timezoneID: String
  let hasRadarData: Bool
  let tint: Color

  private let timeFormatter: DateFormatter
  private let weekdayFormatter: DateFormatter
  private let calendar: Calendar

  init(timezoneID: String, hasRadarData: Bool, tint: Color) {
    self.timezoneID = timezoneID
    self.hasRadarData = hasRadarData
    self.tint = tint

    let timezone = TimeZone(identifier: timezoneID) ?? TimeZone(identifier: "America/Los_Angeles")!
    let timeFormatter = DateFormatter()
    timeFormatter.timeZone = timezone
    timeFormatter.dateFormat = "HH:mm:ss"
    self.timeFormatter = timeFormatter

    let weekdayFormatter = DateFormatter()
    weekdayFormatter.locale = Locale(identifier: "zh_CN")
    weekdayFormatter.timeZone = timezone
    weekdayFormatter.dateFormat = "EEE"
    self.weekdayFormatter = weekdayFormatter

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    self.calendar = calendar
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(timeFormatter.string(from: context.date))
          .font(.system(size: 34, weight: .heavy, design: .rounded))
          .monospacedDigit()
        Text(weekdayFormatter.string(from: context.date))
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(DashboardColors.subtleText)
        Text("当地时间 · 非在线状态")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(tint)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(tint.opacity(0.10), in: Capsule())
      }
      .accessibilityElement(children: .combine)
    }
  }


}
