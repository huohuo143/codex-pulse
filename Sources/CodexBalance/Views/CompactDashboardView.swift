import CodexBalanceCore
import SwiftUI

struct CompactDashboardView: View {
  @EnvironmentObject private var store: DashboardStore
  @Environment(\.dashboardAppearance) private var appearance
  @Environment(\.colorScheme) private var colorScheme

  private var mini: Bool { store.compactSizeMode == .mini }
  private var stats: TokenStats { store.tokenStats }
  private var activeMetrics: [FloatingPanelMetric] {
    FloatingPanelMetric.allCases.filter(store.floatingPanelMetrics.contains)
  }
  private func shows(_ metric: FloatingPanelMetric) -> Bool {
    store.floatingPanelMetrics.contains(metric)
  }
  private var activeQuotaMetrics: [FloatingPanelMetric] {
    [.weeklyQuota, .fiveHourQuota].filter(shows)
  }
  private var primaryQuotaMetric: FloatingPanelMetric? { activeQuotaMetrics.first }
  private var secondaryQuotaMetric: FloatingPanelMetric? { activeQuotaMetrics.dropFirst().first }
  private var fiveHourTint: Color { .orange }
  private var resetProbability: Int? { store.codexRadarSnapshot?.probability24hPercent }
  private var resetProbabilityText: String { resetProbability.map { "\($0)%" } ?? "--" }
  private var resetProbabilityTint: Color {
    guard let resetProbability else { return DashboardColors.subtleText }
    switch resetProbability {
    case 70...: return store.palette.weekly
    case 40...: return .orange
    default: return store.palette.usage24h
    }
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      compactContent
        .allowsHitTesting(false)

      WindowDragSurface(help: "拖动 Codex 脉动窗口")
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      compactWindowControls
        .padding(mini ? 6 : 9)
    }
    .contextMenu {
      Button("打开主界面", systemImage: "arrow.up.left.and.arrow.down.right", action: store.showDashboard)
      Button("复制用量摘要", systemImage: "doc.on.doc", action: store.copyUsageSummary)
      Divider()
      Button("设置", systemImage: "gearshape.fill", action: store.showSettings)
    }
  }

  @ViewBuilder
  private var compactWindowControls: some View {
    if store.compactStyle.usesCompactMenu {
      Menu {
        Button("打开主界面", systemImage: "arrow.up.left.and.arrow.down.right") {
          store.showDashboard()
        }
        Button("设置", systemImage: "gearshape.fill") {
          store.showSettings()
        }
        Button("复制用量摘要", systemImage: "doc.on.doc") {
          store.copyUsageSummary()
        }
      } label: {
        Image(systemName: "ellipsis.circle.fill")
          .font(.system(size: mini ? 13 : 15, weight: .bold))
          .foregroundStyle(Color.white.opacity(0.88))
          .frame(width: mini ? 20 : 22, height: mini ? 20 : 22)
          .background(Circle().fill(Color.black.opacity(0.30)))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("打开主界面或设置")
    } else {
      HStack(spacing: mini ? 3 : 5) {
        compactControlButton(
          "arrow.up.left.and.arrow.down.right",
          help: "打开主界面",
          action: store.showDashboard
        )
        compactControlButton("gearshape.fill", help: "打开设置", action: store.showSettings)
      }
    }
  }

  private func compactControlButton(
    _ symbol: String,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: mini ? 9 : 11, weight: .bold))
        .frame(width: mini ? 20 : 24, height: mini ? 20 : 24)
        .background(Circle().fill(Color.black.opacity(0.34)))
    }
    .buttonStyle(.plain)
    .foregroundStyle(Color.white.opacity(0.92))
    .help(help)
    .accessibilityLabel(help)
  }

  private var compactContent: some View {
    Group {
      switch store.compactStyle {
      case .rings: ringLayout
      case .circle: circleLayout
      case .square: squareLayout
      case .pill: pillLayout
      case .bars: barLayout(detailed: false)
      case .barsQuad: barLayout(detailed: true)
      case .badge: badgeLayout(detailed: false)
      case .badgeQuad: badgeLayout(detailed: true)
      }
    }
    .padding(mini ? 10 : 14)
    .background(compactBackground)
  }

  private var compactShape: AnyShape {
    switch store.compactStyle {
    case .circle: AnyShape(Circle())
    case .pill: AnyShape(Capsule())
    case .square: AnyShape(RoundedRectangle(cornerRadius: mini ? 20 : 26, style: .continuous))
    case .badge, .badgeQuad: AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    default: AnyShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
  }

  @ViewBuilder
  private var compactBackground: some View {
    let shape = compactShape
    switch appearance {
    case .aurora:
      if colorScheme == .light {
        shape
          .fill(Color.white.opacity(max(0.74, store.compactBackgroundOpacity)))
          .overlay(shape.stroke(store.palette.weekly.opacity(0.30), lineWidth: 1))
      } else {
        shape
          .fill(store.palette.panel.opacity(store.compactBackgroundOpacity))
          .overlay(shape.stroke(Color.primary.opacity(0.11), lineWidth: 1))
      }
    case .glass:
      shape
        .fill(.ultraThinMaterial)
        .overlay(
          shape.stroke(
            LinearGradient(
              colors: [Color.primary.opacity(0.24), store.palette.weekly.opacity(0.14), Color.primary.opacity(0.06)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: 1
          )
        )
    case .graphite:
      if colorScheme == .light {
        shape
          .fill(Color(red: 0.94, green: 0.95, blue: 0.955).opacity(max(0.78, store.compactBackgroundOpacity)))
          .overlay(shape.stroke(Color.primary.opacity(0.11), lineWidth: 1))
      } else {
        shape
          .fill(Color(red: 0.055, green: 0.06, blue: 0.065).opacity(store.compactBackgroundOpacity))
          .overlay(shape.stroke(Color.primary.opacity(0.09), lineWidth: 1))
      }
    }
  }

  private var ringLayout: some View {
    Group {
      if store.compactRingOrientation == .horizontal {
        horizontalRingLayout
      } else {
        verticalRingLayout
      }
    }
  }

  private var horizontalRingLayout: some View {
    VStack(spacing: mini ? 6 : 8) {
      if activeQuotaMetrics.count == 2 {
        HStack(spacing: mini ? 12 : 18) {
          ForEach(activeQuotaMetrics) { metric in
            quotaGauge(metric, size: mini ? 104 : 124, lineWidth: mini ? 10 : 12)
          }
        }
        if shows(.rolling24Tokens) { verticalRollingUsage }
      } else if let quotaMetric = primaryQuotaMetric, shows(.rolling24Tokens) {
        HStack(spacing: mini ? 12 : 18) {
          quotaGauge(quotaMetric, size: mini ? 116 : 148, lineWidth: mini ? 11 : 14)
          rollingUsage
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else if let quotaMetric = primaryQuotaMetric {
        quotaGauge(quotaMetric, size: mini ? 116 : 148, lineWidth: mini ? 11 : 14)
        .frame(maxWidth: .infinity)
      } else if shows(.rolling24Tokens) {
        rollingUsage
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if shows(.resetRadar) { resetRadarRow }
      if shows(.resetCredits) { resetCreditsCard }
    }
  }

  private var verticalRingLayout: some View {
    VStack(spacing: mini ? 6 : 8) {
      ForEach(activeQuotaMetrics) { metric in
        quotaGauge(metric, size: mini ? 116 : 148, lineWidth: mini ? 11 : 14)
      }
      if shows(.rolling24Tokens) { verticalRollingUsage }
      if shows(.resetRadar) { resetRadarRow }
      if shows(.resetCredits) { resetCreditsCard }
    }
  }

  private var circleLayout: some View {
    let progress = max(0.008, min(1, (quotaWindow(primaryQuotaMetric)?.remainingPercent ?? 0) / 100))
    return ZStack {
      Circle()
        .stroke(DashboardColors.track, lineWidth: mini ? 10 : 13)
      if let primaryQuotaMetric {
        Circle()
          .trim(from: 0, to: progress)
          .stroke(quotaTint(primaryQuotaMetric), style: StrokeStyle(lineWidth: mini ? 10 : 13, lineCap: .round))
          .rotationEffect(.degrees(-90))
      }
      VStack(spacing: activeMetrics.count >= 4 ? 1 : (mini ? 2 : 4)) {
        if let primaryQuotaMetric {
          Text(quotaPercentText(primaryQuotaMetric))
            .font(.system(size: activeMetrics.count >= 3 ? (mini ? 24 : 30) : (mini ? 30 : 38), weight: .heavy, design: .rounded))
            .foregroundStyle(quotaTint(primaryQuotaMetric))
            .monospacedDigit()
            .contentTransition(.numericText())
          Text(quotaShortTitle(primaryQuotaMetric))
            .font(.system(size: mini ? 8.5 : 10.5, weight: .bold))
            .foregroundStyle(DashboardColors.subtleText)
        }
        if let secondaryQuotaMetric {
          circleMetric(
            quotaBadgeTitle(secondaryQuotaMetric),
            quotaPercentText(secondaryQuotaMetric),
            tint: quotaTint(secondaryQuotaMetric)
          )
        }
        if shows(.rolling24Tokens) {
          circleMetric("24h", BalanceFormatters.compactNumber(stats.rolling24HoursTokens), tint: store.palette.usage24h)
        }
        if shows(.resetRadar) {
          circleMetric("重置", resetProbabilityText, tint: resetProbabilityTint)
        }
        if shows(.resetCredits) {
          circleMetric("Full reset", resetCreditsCountText, tint: store.palette.weekly)
        }
      }
      .padding(.horizontal, mini ? 15 : 20)
    }
    .frame(width: mini ? 116 : 148, height: mini ? 116 : 148)
    .animation(.smooth(duration: 0.32), value: progress)
  }

  private var squareLayout: some View {
    VStack(alignment: .leading, spacing: mini ? 7 : 10) {
      if let primaryQuotaMetric {
        Label("CODEX · \(quotaBadgeTitle(primaryQuotaMetric))", systemImage: primaryQuotaMetric.systemImage)
          .font(.system(size: mini ? 8.5 : 10, weight: .bold, design: .rounded))
          .foregroundStyle(DashboardColors.subtleText)
        Text(quotaPercentText(primaryQuotaMetric))
          .font(.system(size: mini ? 34 : 43, weight: .heavy, design: .rounded))
          .foregroundStyle(quotaTint(primaryQuotaMetric))
          .monospacedDigit()
          .contentTransition(.numericText())
        ProgressView(value: (quotaWindow(primaryQuotaMetric)?.remainingPercent ?? 0) / 100)
          .tint(quotaTint(primaryQuotaMetric))
      }
      if let secondaryQuotaMetric {
        HStack(spacing: 4) {
          Image(systemName: secondaryQuotaMetric.systemImage)
          Text(quotaShortTitle(secondaryQuotaMetric))
          Spacer(minLength: 2)
          Text(quotaPercentText(secondaryQuotaMetric))
            .foregroundStyle(quotaTint(secondaryQuotaMetric))
            .monospacedDigit()
        }
        .font(.system(size: mini ? 8.5 : 10, weight: .bold, design: .rounded))
      }
      if shows(.resetRadar) {
        HStack(spacing: 4) {
          Image(systemName: "scope")
          Text("24h重置")
          Spacer(minLength: 2)
          Text(resetProbabilityText)
            .foregroundStyle(resetProbabilityTint)
            .monospacedDigit()
        }
        .font(.system(size: mini ? 8.5 : 10, weight: .bold, design: .rounded))
      }
      if shows(.rolling24Tokens) || shows(.resetCredits) {
        HStack {
          if shows(.rolling24Tokens) {
            VStack(alignment: .leading, spacing: 2) {
              Text("滚动24h")
              Text(BalanceFormatters.compactNumber(stats.rolling24HoursTokens))
                .foregroundStyle(store.palette.usage24h)
            }
          }
          if shows(.rolling24Tokens), shows(.resetCredits) { Spacer() }
          if shows(.resetCredits) {
            VStack(alignment: shows(.rolling24Tokens) ? .trailing : .leading, spacing: 2) {
              Text("Full reset")
              Text(resetCreditsCountText).foregroundStyle(store.palette.weekly)
            }
          }
        }
        .font(.system(size: mini ? 8.5 : 10.5, weight: .bold, design: .rounded))
      }
    }
    .foregroundStyle(DashboardColors.subtleText)
    .animation(.snappy(duration: 0.24), value: store.weekly?.remainingPercent)
    .animation(.snappy(duration: 0.24), value: store.fiveHour?.remainingPercent)
  }

  private var pillLayout: some View {
    HStack(spacing: mini ? 7 : 9) {
      ForEach(activeMetrics) { metric in
        if metric != activeMetrics.first {
          Divider()
            .frame(height: mini ? 25 : 31)
            .overlay(DashboardColors.separator)
        }
        pillMetric(metric)
      }
      Spacer(minLength: mini ? 20 : 24)
    }
    .foregroundStyle(DashboardColors.text)
    .animation(.snappy(duration: 0.24), value: store.weekly?.remainingPercent)
    .animation(.snappy(duration: 0.24), value: store.fiveHour?.remainingPercent)
  }

  @ViewBuilder
  private var resetCreditsCard: some View {
    if shows(.resetCredits) {
      CompactResetCreditsView(
        summary: store.rateLimitResetCredits,
        isLoading: store.isLoading,
        tint: store.palette.weekly,
        mini: mini
      )
    }
  }

  @ViewBuilder
  private func pillMetric(_ metric: FloatingPanelMetric) -> some View {
    switch metric {
    case .weeklyQuota:
      HStack(spacing: mini ? 5 : 7) {
        Circle()
          .trim(from: 0, to: max(0.008, min(1, (store.weekly?.remainingPercent ?? 0) / 100)))
          .stroke(store.palette.weekly, style: StrokeStyle(lineWidth: mini ? 4 : 5, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .frame(width: mini ? 28 : 34, height: mini ? 28 : 34)
          .overlay {
            Text(store.weekly.map { "\(Int($0.remainingPercent.rounded()))" } ?? "--")
              .font(.system(size: mini ? 8 : 10, weight: .heavy, design: .rounded))
              .foregroundStyle(store.palette.weekly)
          }
        pillValue(
          title: "7天剩余",
          value: store.weekly.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--",
          tint: store.palette.weekly
        )
      }
    case .fiveHourQuota:
      HStack(spacing: mini ? 5 : 7) {
        Circle()
          .trim(from: 0, to: max(0.008, min(1, (store.fiveHour?.remainingPercent ?? 0) / 100)))
          .stroke(fiveHourTint, style: StrokeStyle(lineWidth: mini ? 4 : 5, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .frame(width: mini ? 28 : 34, height: mini ? 28 : 34)
          .overlay {
            Text(store.fiveHour.map { "\(Int($0.remainingPercent.rounded()))" } ?? "--")
              .font(.system(size: mini ? 8 : 10, weight: .heavy, design: .rounded))
              .foregroundStyle(fiveHourTint)
          }
        pillValue(
          title: "5小时剩余",
          value: quotaPercentText(.fiveHourQuota),
          tint: fiveHourTint
        )
      }
    case .rolling24Tokens:
      pillValue(
        title: "滚动24h",
        value: BalanceFormatters.compactNumber(stats.rolling24HoursTokens),
        tint: store.palette.usage24h
      )
    case .resetRadar:
      pillValue(title: "重置概率", value: resetProbabilityText, tint: resetProbabilityTint)
    case .resetCredits:
      pillValue(title: "Full reset", value: resetCreditsCountText, tint: store.palette.weekly)
    }
  }

  private func pillValue(title: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title)
        .font(.system(size: mini ? 7.5 : 9, weight: .bold))
        .foregroundStyle(DashboardColors.subtleText)
      Text(value)
        .font(.system(size: mini ? 10 : 13, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
        .monospacedDigit()
        .lineLimit(1)
    }
  }

  private func circleMetric(_ title: String, _ value: String, tint: Color) -> some View {
    HStack(spacing: 3) {
      Text("\(title) ·")
      Text(value).foregroundStyle(tint)
    }
    .font(.system(size: activeMetrics.count >= 4 ? (mini ? 7.5 : 9) : (mini ? 8 : 9.5), weight: .bold, design: .rounded))
    .foregroundStyle(DashboardColors.subtleText)
    .monospacedDigit()
    .lineLimit(1)
  }

  private var resetCreditsCountText: String {
    guard let count = store.rateLimitResetCredits?.availableCount else { return "-- 次" }
    return "\(count) 次"
  }

  private var rollingUsage: some View {
    let parts = BalanceFormatters.compactNumberParts(stats.rolling24HoursTokens)
    return VStack(alignment: .leading, spacing: mini ? 4 : 7) {
      Label("滚动24h", systemImage: "clock.arrow.circlepath")
        .font(.system(size: mini ? 10.5 : 12.5, weight: .bold))
        .foregroundStyle(DashboardColors.subtleText)
      HStack(alignment: .firstTextBaseline, spacing: 1) {
        Text(parts.value)
          .font(.system(size: mini ? 24 : 31, weight: .heavy, design: .rounded))
        if !parts.unit.isEmpty {
          Text(parts.unit)
            .font(.system(size: mini ? 11 : 14, weight: .bold, design: .rounded))
        }
      }
      .foregroundStyle(store.palette.usage24h)
      .monospacedDigit()
      .lineLimit(1)
      .minimumScaleFactor(0.72)
      .contentTransition(.numericText())
      Text("Token")
        .font(.system(size: mini ? 9.5 : 11, weight: .semibold))
        .foregroundStyle(DashboardColors.subtleText)
      Text(costText)
        .font(.system(size: mini ? 9.5 : 11.5, weight: .semibold, design: .rounded))
        .foregroundStyle(DashboardColors.text.opacity(0.86))
        .lineLimit(2)
    }
    .animation(.snappy(duration: 0.26), value: stats.rolling24HoursTokens)
  }

  private var verticalRollingUsage: some View {
    let parts = BalanceFormatters.compactNumberParts(stats.rolling24HoursTokens)
    return VStack(alignment: .trailing, spacing: 2) {
      HStack(alignment: .center, spacing: mini ? 7 : 9) {
        Label("滚动24h", systemImage: "clock.arrow.circlepath")
          .font(.system(size: mini ? 10 : 11.5, weight: .bold))
          .foregroundStyle(DashboardColors.subtleText)
        Spacer(minLength: 2)
        HStack(alignment: .firstTextBaseline, spacing: 1) {
          Text(parts.value)
            .font(.system(size: mini ? 22 : 27, weight: .heavy, design: .rounded))
          if !parts.unit.isEmpty {
            Text(parts.unit)
              .font(.system(size: mini ? 10.5 : 12.5, weight: .bold, design: .rounded))
          }
        }
        .foregroundStyle(store.palette.usage24h)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .contentTransition(.numericText())
        Text("Token")
          .font(.system(size: mini ? 9 : 10, weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
      }
      Text(costText)
        .font(.system(size: mini ? 8.5 : 9.5, weight: .semibold, design: .rounded))
        .foregroundStyle(DashboardColors.text.opacity(0.86))
        .lineLimit(1)
    }
    .animation(.snappy(duration: 0.26), value: stats.rolling24HoursTokens)
  }

  private func barLayout(detailed: Bool) -> some View {
    VStack(alignment: .leading, spacing: detailed ? 10 : 7) {
      ForEach(activeQuotaMetrics) { metric in
        quotaBar(metric)
      }
      if shows(.rolling24Tokens) {
        HStack {
          Label("24h \(BalanceFormatters.compactNumber(stats.rolling24HoursTokens))", systemImage: "clock")
            .foregroundStyle(store.palette.usage24h)
          Spacer()
          if detailed { Text(costText).foregroundStyle(DashboardColors.text) }
        }
        .font(.system(size: mini ? 9 : 11, weight: .semibold))
      }
      if shows(.resetRadar) {
        HStack {
          Label("24h 重置概率", systemImage: "scope")
          Spacer()
          Text(resetProbabilityText)
            .foregroundStyle(resetProbabilityTint)
            .monospacedDigit()
        }
        .font(.system(size: mini ? 9 : 11, weight: .bold, design: .rounded))
      }
      if shows(.resetCredits) {
        HStack {
          Label("Full reset 权益", systemImage: "arrow.counterclockwise.circle.fill")
          Spacer()
          Text(resetCreditsCountText)
            .foregroundStyle(store.palette.weekly)
            .monospacedDigit()
        }
        .font(.system(size: mini ? 9 : 11, weight: .bold, design: .rounded))
      }
    }
    .foregroundStyle(DashboardColors.text)
    .animation(.snappy(duration: 0.26), value: store.weekly?.remainingPercent)
    .animation(.snappy(duration: 0.26), value: store.fiveHour?.remainingPercent)
  }

  private func badgeLayout(detailed _: Bool) -> some View {
    HStack(spacing: 8) {
      Text("C")
        .font(.system(size: 11, weight: .black))
        .foregroundStyle(.black)
        .frame(width: 22, height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(store.palette.weekly))
      ForEach(activeMetrics) { metric in
        Divider().frame(height: 20).overlay(DashboardColors.separator)
        badgeMetric(metric)
      }
      Spacer(minLength: mini ? 16 : 20)
    }
    .animation(.snappy(duration: 0.26), value: store.weekly?.remainingPercent)
    .animation(.snappy(duration: 0.26), value: store.fiveHour?.remainingPercent)
  }

  @ViewBuilder
  private func badgeMetric(_ metric: FloatingPanelMetric) -> some View {
    switch metric {
    case .weeklyQuota:
      Text(store.weekly.map { "7天 \(Int($0.remainingPercent.rounded()))%" } ?? "7天 --")
        .foregroundStyle(store.palette.weekly)
    case .fiveHourQuota:
      Text(store.fiveHour.map { "5h \(Int($0.remainingPercent.rounded()))%" } ?? "5h --")
        .foregroundStyle(fiveHourTint)
    case .rolling24Tokens:
      Text("24h \(BalanceFormatters.compactNumber(stats.rolling24HoursTokens))")
        .foregroundStyle(store.palette.usage24h)
    case .resetRadar:
      Text("重置 \(resetProbabilityText)")
        .foregroundStyle(resetProbabilityTint)
    case .resetCredits:
      Text("Reset \(resetCreditsCountText)")
        .foregroundStyle(store.palette.weekly)
    }
  }

  @ViewBuilder
  private func quotaGauge(_ metric: FloatingPanelMetric, size: CGFloat, lineWidth: CGFloat) -> some View {
    WeeklyGaugeView(
      remainingPercent: quotaWindow(metric)?.remainingPercent,
      tint: quotaTint(metric),
      size: size,
      lineWidth: lineWidth,
      label: quotaShortTitle(metric)
    )
  }

  private func quotaBar(_ metric: FloatingPanelMetric) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Label("Codex · \(quotaShortTitle(metric))", systemImage: metric.systemImage)
          .font(.system(size: mini ? 10 : 12, weight: .bold))
        Spacer()
        Text(quotaPercentText(metric))
          .font(.system(size: mini ? 13 : 16, weight: .heavy, design: .rounded))
          .foregroundStyle(quotaTint(metric))
          .contentTransition(.numericText())
      }
      ProgressView(value: (quotaWindow(metric)?.remainingPercent ?? 0) / 100)
        .tint(quotaTint(metric))
    }
  }

  private func quotaWindow(_ metric: FloatingPanelMetric?) -> LimitWindow? {
    switch metric {
    case .weeklyQuota: store.weekly
    case .fiveHourQuota: store.fiveHour
    case .rolling24Tokens, .resetRadar, .resetCredits, nil: nil
    }
  }

  private func quotaTint(_ metric: FloatingPanelMetric) -> Color {
    metric == .fiveHourQuota ? fiveHourTint : store.palette.weekly
  }

  private func quotaShortTitle(_ metric: FloatingPanelMetric) -> String {
    metric == .fiveHourQuota ? "5小时剩余" : "7天剩余"
  }

  private func quotaBadgeTitle(_ metric: FloatingPanelMetric) -> String {
    metric == .fiveHourQuota ? "5h" : "7天"
  }

  private func quotaPercentText(_ metric: FloatingPanelMetric) -> String {
    quotaWindow(metric).map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--"
  }

  private var resetRadarRow: some View {
    HStack(spacing: mini ? 5 : 7) {
      Image(systemName: "scope")
      Text("24h 重置概率")
      Spacer(minLength: 4)
      if store.codexRadarIsLoading {
        ProgressView().controlSize(.mini)
      }
      Text(resetProbabilityText)
        .font(.system(size: mini ? 11 : 13, weight: .heavy, design: .rounded))
        .foregroundStyle(resetProbabilityTint)
        .monospacedDigit()
        .contentTransition(.numericText())
    }
    .font(.system(size: mini ? 9 : 10.5, weight: .bold, design: .rounded))
    .foregroundStyle(DashboardColors.subtleText)
    .padding(.horizontal, mini ? 8 : 10)
    .frame(height: mini ? 24 : 28)
    .background(
      RoundedRectangle(cornerRadius: mini ? 8 : 9, style: .continuous)
        .fill(resetProbabilityTint.opacity(0.10))
        .overlay(
          RoundedRectangle(cornerRadius: mini ? 8 : 9, style: .continuous)
            .stroke(resetProbabilityTint.opacity(0.22), lineWidth: 1)
        )
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Codex 24 小时重置概率 \(resetProbabilityText)")
  }

  private var radarMicroLabel: some View {
    HStack(spacing: 3) {
      Image(systemName: "scope")
      Text("R \(resetProbabilityText)")
        .monospacedDigit()
    }
    .font(.system(size: mini ? 8 : 9.5, weight: .heavy, design: .rounded))
    .foregroundStyle(resetProbabilityTint)
    .lineLimit(1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("24 小时重置概率 \(resetProbabilityText)")
  }

  private var costText: String {
    let usd = stats.cost24Hours.usd
    let usdText = String(format: "$%.2f", usd)
    guard let cny = store.cnyValue(for: stats.cost24Hours) else { return "\(usdText) · ¥--" }
    return "\(usdText) · ¥\(String(format: "%.2f", cny))"
  }
}
