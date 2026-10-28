import AppKit
import CodexBalanceCore
import SwiftUI

struct ResetCalendarView: View {
  @Environment(\.colorScheme) private var colorScheme
  let snapshot: CodexResetCalendarSnapshot?
  let tint: Color
  let isLoading: Bool
  let refresh: () -> Void
  @State private var displayedMonth: Date
  @State private var selectedDay: String
  @State private var filter = "全部"
  private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

  init(snapshot: CodexResetCalendarSnapshot?, tint: Color, isLoading: Bool, refresh: @escaping () -> Void,
    now: Date = Date()) {
    self.snapshot = snapshot; self.tint = tint; self.isLoading = isLoading; self.refresh = refresh
    _displayedMonth = State(initialValue: CodexResetCalendarDates.month(now))
    _selectedDay = State(initialValue: CodexResetCalendarDates.day(now))
  }

  private var events: [CodexResetCalendarEvent] { snapshot?.events ?? [] }
  private var monthKey: String { String(CodexResetCalendarDates.day(displayedMonth).prefix(7)) }
  private var monthEvents: [CodexResetCalendarEvent] { events.filter { $0.day.hasPrefix(monthKey) } }
  private var visibleEvents: [CodexResetCalendarEvent] { events.filter { filter == "全部" || $0.kind.title == filter } }
  private var selectedEvents: [CodexResetCalendarEvent] { visibleEvents.filter { $0.day == selectedDay } }
  private var today: String { CodexResetCalendarDates.day(Date()) }

  var body: some View {
    VStack(spacing: 14) {
      PanelCard {
        VStack(alignment: .leading, spacing: 13) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Label("Tibo 历史重置月历", systemImage: "calendar")
                .font(.system(size: 20, weight: .bold, design: .rounded))
              Text("北京时间 · UTC+8")
                .font(.system(size: 11)).foregroundStyle(DashboardColors.subtleText)
            }
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
              .help("刷新重置历史").accessibilityLabel("刷新重置历史").disabled(isLoading)
          }
          HStack(spacing: 10) {
            Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
              .accessibilityLabel("上个月").help("上个月")
            Text(monthKey.replacingOccurrences(of: "-", with: "年") + "月")
              .font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
              .frame(minWidth: 118)
            Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
              .accessibilityLabel("下个月").help("下个月")
            Button("本月") {
              displayedMonth = CodexResetCalendarDates.month(Date()); selectedDay = today
            }.accessibilityLabel("返回本月")
            Spacer()
          }
          Picker("事件类型", selection: $filter) {
            ForEach(["全部", "硬重置", "重置卡"], id: \.self) { Text($0).tag($0) }
          }.pickerStyle(.segmented).frame(maxWidth: 320)

          HStack(spacing: 18) {
            Label("硬重置 \(monthEvents.filter { $0.kind == .hardReset }.count)", systemImage: CodexResetKind.hardReset.symbol)
              .foregroundStyle(color(.hardReset))
            Label("重置卡 \(monthEvents.filter { $0.kind == .resetCard }.count)", systemImage: CodexResetKind.resetCard.symbol)
              .foregroundStyle(color(.resetCard))
            Text("已定位日期的记录").foregroundStyle(DashboardColors.subtleText)
          }.font(.system(size: 11, weight: .semibold))

          LazyVGrid(columns: columns, spacing: 5) {
            ForEach(["周一", "周二", "周三", "周四", "周五", "周六", "周日"], id: \.self) {
              Text($0).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DashboardColors.subtleText).frame(maxWidth: .infinity).padding(.bottom, 3)
            }
            ForEach(CodexResetCalendarDates.cells(in: displayedMonth), id: \.self) { date in dayCell(date) }
          }
          Text("只展示已收录历史；空白日期不代表没有发生重置。")
            .font(.system(size: 10)).foregroundStyle(DashboardColors.subtleText)
          Text("公共事件月历，所有账号共用。个人灵活额度、Full reset 数量和实际到账以当前账号的本机数据为准。")
            .font(.system(size: 10)).foregroundStyle(DashboardColors.subtleText)
          if events.contains(where: { $0.historicalCatalogRevision != nil }) {
            Text("内置公开历史可离线查看；7—9 月已核对记录随包提供，尚不能确认完整覆盖。安装后的新动态继续按北京时间分时段每 3–20 分钟读取 Tibo 发帖与回复。")
              .font(.system(size: 10)).foregroundStyle(DashboardColors.subtleText)
            Link("部分历史资料：codex-reset.com · CC BY 4.0",
              destination: URL(string: "https://codex-reset.com/data/codex-resets.json")!)
              .font(.system(size: 10))
          }
          syncStatus
        }
      }

      PanelCard {
        VStack(alignment: .leading, spacing: 12) {
          Text(selectedDay + " · 日期详情").font(.system(size: 15, weight: .bold, design: .rounded))
          if selectedEvents.isEmpty {
            Text("暂无已收录记录").font(.system(size: 12)).foregroundStyle(DashboardColors.subtleText)
          }
          ForEach(selectedEvents) { event in eventDetails(event) }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }

      if let total = snapshot?.monthlyTotals.first(where: { $0.month == monthKey }) {
        PanelCard {
          VStack(alignment: .leading, spacing: 7) {
            Text("Codex Radar 原始月度统计").font(.system(size: 13, weight: .bold))
            Text("\(total.month) · 硬重置 \(total.hardResets) 次 · 重置卡 \(total.resetCards) 次")
              .font(.system(size: 12, weight: .medium))
            Text("不同来源的覆盖范围与统计口径可能不同；保留原始总数，不据此补造或删除日历事件。")
              .font(.system(size: 10)).foregroundStyle(DashboardColors.subtleText)
            if let verified = total.verifiedOn {
              Text("内置月度统计 · 核对日期 \(verified) · 可离线查看")
                .font(.system(size: 10)).foregroundStyle(DashboardColors.subtleText)
            }
            if total.hardResets != monthEvents.filter({ $0.kind == .hardReset }).count
              || total.resetCards != monthEvents.filter({ $0.kind == .resetCard }).count {
              Text("月度总数与可定位日期的条目尚未完全对应；未核实的日期保留为空白。")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            }
            Link("查看 Codex Radar 历史说明", destination: URL(string: "https://codexradar.com/#reset-radar")!)
              .font(.system(size: 11))
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  private func dayCell(_ date: Date) -> some View {
    let day = CodexResetCalendarDates.day(date)
    let inMonth = day.hasPrefix(monthKey)
    let future = day > today
    let items = visibleEvents.filter { $0.day == day }
    return Button { selectedDay = day } label: {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 2) {
          Text("\(CodexResetCalendarDates.calendar.component(.day, from: date))")
            .font(.system(size: 12, weight: day == today ? .heavy : .semibold))
          Spacer(minLength: 0)
          if day == today { Text("今").font(.system(size: 9, weight: .bold)).foregroundStyle(color(.hardReset)) }
        }
        ForEach(CodexResetKind.allCases, id: \.self) { kind in
          let count = items.filter { $0.kind == kind }.count
          if inMonth && !future && count > 0 {
            Label("\(kind.title)\(count > 1 ? " \(count)" : "")", systemImage: kind.symbol)
              .font(.system(size: 9, weight: .semibold)).foregroundStyle(color(kind)).lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(6).frame(maxWidth: .infinity, minHeight: 66, maxHeight: 66, alignment: .topLeading)
      .foregroundStyle(inMonth ? DashboardColors.text : DashboardColors.subtleText.opacity(0.35))
      .background(day == selectedDay ? tint.opacity(0.16) : DashboardColors.text.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(day == today || day == selectedDay ? tint.opacity(0.8) : .clear, lineWidth: 1))
    }
    .buttonStyle(.plain).disabled(!inMonth || future)
    .accessibilityLabel(day + (items.isEmpty ? "，暂无已收录记录" : "，\(items.count) 条事件"))
    .accessibilityAddTraits(day == selectedDay ? .isSelected : [])
    .help(day + (items.isEmpty ? " · 暂无已收录记录" : " · 点击查看事件详情"))
  }

  private var syncStatus: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let success = snapshot?.lastSuccessAt {
        Text("上次成功同步：\(time(success)) · 随 Tibo 分时段检测同步")
      } else { Text(isLoading ? "正在读取历史记录…" : "等待首次成功同步") }
      if let failure = snapshot?.failureMessage { Text(failure).foregroundStyle(.orange) }
    }.font(.system(size: 10)).foregroundStyle(DashboardColors.subtleText)
  }

  private func eventDetails(_ event: CodexResetCalendarEvent) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .top) {
        Label(event.kind.title, systemImage: event.kind.symbol).foregroundStyle(color(event.kind))
        Spacer()
        Text(event.confirmation.title).foregroundStyle(DashboardColors.subtleText)
      }.font(.system(size: 11, weight: .semibold))
      Text(event.title).font(.system(size: 13, weight: .bold))
      Text(event.summary).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      Text(event.dateExplanation).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
      if let actual = event.occurredAt { Text("实际发生：\(time(actual))") }
      if let published = event.publishedAt {
        if let url = event.publicationURL { Link("原帖发布：\(time(published))", destination: url) }
        else { Text("原帖发布：\(time(published))") }
      }
      if let confirmed = event.confirmedAt { Text("确认帖发布：\(time(confirmed))") }
      HStack(spacing: 14) {
        if let url = event.announcementURL { Link(event.kind == .resetCard ? "原始发放帖" : "原预告帖", destination: url) }
        if let url = event.completionURL { Link("官方完成确认", destination: url) }
        if let url = event.evidenceURL { Link("佐证原帖", destination: url) }
        Link("公开来源记录", destination: event.sourceURL)
        ForEach(Array((event.corroborationURLs ?? []).enumerated()), id: \.offset) { item in
          Link("交叉来源\(item.offset + 1)", destination: item.element)
        }
      }.font(.system(size: 11))
      Divider()
    }.font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading)
  }

  private func moveMonth(_ delta: Int) {
    guard let next = CodexResetCalendarDates.calendar.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
    displayedMonth = next; selectedDay = CodexResetCalendarDates.day(next)
  }
  private func color(_ kind: CodexResetKind) -> Color {
    let base = kind == .hardReset ? tint : Color.orange
    guard colorScheme == .light else { return base }
    return Color(nsColor: NSColor(base).blended(withFraction: 0.48, of: .black) ?? .labelColor)
  }
  private func time(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = CodexResetCalendarDates.calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
  }
}
