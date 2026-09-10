import AppKit
import Charts
import SwiftUI

// MARK: - Dropdown building blocks, styled after the system's menu bar extras

enum MenuMetrics {
  static let width: CGFloat = 320
  static let inset: CGFloat = 14
  static let badge: CGFloat = 30
}

struct MenuSeparator: View {
  var body: some View {
    Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
      .padding(.horizontal, MenuMetrics.inset).padding(.vertical, 6)
  }
}

struct MenuSectionLabel: View {
  let title: String
  var trailing = ""
  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).font(.system(size: 13, weight: .semibold))
      Spacer()
      Text(trailing).font(.system(size: 12)).monospacedDigit()
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, MenuMetrics.inset).padding(.top, 2).padding(.bottom, 5)
  }
}

struct MenuBadge<Content: View>: View {
  var fill: Color = Color.primary.opacity(0.09)
  /// Ring fill from 0 to 1 drawn around the badge, for example an allowance or utilization.
  var ring: Double? = nil
  var ringTint: Color = .secondary
  var size: CGFloat = MenuMetrics.badge
  @ViewBuilder var content: Content
  var body: some View {
    ZStack {
      Circle().fill(fill)
      if let ring {
        Circle().stroke(ringTint.opacity(0.2), lineWidth: 3).padding(1)
        Circle().trim(from: 0, to: min(1, max(0, ring)))
          .stroke(ringTint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
          .rotationEffect(.degrees(-90)).padding(1)
      }
      content
    }.frame(width: size, height: size)
  }
}

/// Circular badge whose ring fills with the share of an allowance that is used. With a value
/// it grows to 36pt so the number can use a readable 10pt font.
struct RingBadge: View {
  let percent: Double
  let tint: Color
  var value: String? = nil
  var body: some View {
    MenuBadge(ring: percent / 100, ringTint: tint, size: value == nil ? MenuMetrics.badge : 36) {
      if let value {
        Text(value).font(.system(size: 10, weight: .semibold)).monospacedDigit().lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
  }
}

/// Thin capacity bar for the bar gauge style.
struct CapacityBar: View {
  let fraction: Double
  let tint: Color
  var body: some View {
    GeometryReader { proxy in
      Capsule().fill(tint.opacity(0.18)).overlay(alignment: .leading) {
        Capsule().fill(tint).frame(width: proxy.size.width * min(1, max(0, fraction)))
      }
    }.frame(height: 6)
  }
}

struct MenuRow<Badge: View, Trailing: View>: View {
  let title: String
  /// Small symbol and tint shown before the title, such as a verification checkmark.
  let titleSymbol: (name: String, tint: Color)?
  let lines: [String]
  let badge: Badge
  let trailing: Trailing

  init(
    title: String, titleSymbol: (name: String, tint: Color)? = nil, lines: [String] = [],
    @ViewBuilder badge: () -> Badge, @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.titleSymbol = titleSymbol
    self.lines = lines
    self.badge = badge()
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: 14) {
      badge
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 4) {
          if let titleSymbol {
            Image(systemName: titleSymbol.name).font(.system(size: 11, weight: .semibold))
              .foregroundStyle(titleSymbol.tint)
          }
          Text(title).font(.system(size: 13))
        }
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }.fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      trailing
    }
    .padding(.horizontal, MenuMetrics.inset).padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

/// Plain text action row with the hover highlight of a system menu item.
struct MenuAction: View {
  let title: String
  var systemImage: String? = nil
  var disabled = false
  let action: () -> Void
  @State private var hovering = false
  var body: some View {
    Button(action: action) {
      HStack {
        Text(title).font(.system(size: 13))
        Spacer()
        if let systemImage {
          Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 8).padding(.vertical, 5)
      .background(
        hovering && !disabled ? Color.primary.opacity(0.08) : Color.clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
    .padding(.horizontal, 6)
    .onHover { hovering = $0 }
  }
}

func menuNote(_ text: String) -> some View {
  Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, MenuMetrics.inset).padding(.vertical, 4)
}

// MARK: - Dropdown

struct ProviderPanel: View {
  @ObservedObject var store: DashboardStore
  let category: ProviderCategory
  let openSettings: () -> Void
  /// When set, the content scrolls inside this height instead of growing.
  var maxHeight: CGFloat? = nil

  var provider: Provider { store.providers[category.rawValue] ?? .placeholder(category.rawValue) }
  var options: ProviderPreferences { store.preferences.provider(category) }
  private var id: String { category.rawValue }
  private var busy: Bool { store.refreshing.contains(id) }
  var body: some View {
    if let maxHeight {
      ScrollView { content }.frame(width: MenuMetrics.width, height: maxHeight)
    } else {
      content.frame(width: MenuMetrics.width)
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      MenuSeparator()
      if category == .vast {
        VastMenu(provider: provider, options: options, style: store.preferences.gaugeStyle)
      } else {
        allowances
      }
      MenuSeparator()
      if needsRetry {
        MenuAction(
          title: busy ? "Retrying…" : "Try again", systemImage: "arrow.clockwise", disabled: busy
        ) {
          store.refresh(force: true, only: id)
        }
      }
      if let url = provider.url.flatMap(URL.init(string:)) {
        MenuAction(
          title: category == .vast ? "Open Vast.ai console" : "Open \(category.name) usage page",
          systemImage: "arrow.up.right"
        ) {
          NSWorkspace.shared.open(url)
        }
      }
      MenuAction(title: "\(category.name) Settings…", action: openSettings)
      MenuAction(title: "Quit Information Bar") { NSApp.terminate(nil) }
    }
    .padding(.vertical, 8)
  }

  /// Data refreshes on its own; a manual retry only matters once that has failed.
  private var needsRetry: Bool {
    store.collectorErrors[id] != nil || (!provider.isFresh && provider.status != "loading")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline) {
        Text(category.name).font(.system(size: 15, weight: .semibold))
        Spacer()
        if category == .vast {
          Text(rentedHeadline).font(.system(size: 15, weight: .semibold)).monospacedDigit()
        } else if let plan = provider.plan {
          Text(plan).font(.system(size: 13)).foregroundStyle(.secondary)
        }
      }
      if category == .vast {
        Text("GPU hosting").font(.system(size: 13)).foregroundStyle(.secondary)
      }
      if provider.status == "loading" && store.collectorErrors[id] == nil {
        Text("Reading account…").font(.system(size: 13)).foregroundStyle(.secondary)
      }
      ForEach(problems, id: \.self) { message in
        Text(message).font(.system(size: 12)).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, MenuMetrics.inset).padding(.top, 4).padding(.bottom, 2)
  }

  private var rentedHeadline: String {
    guard let rented = provider.rentedCount, let total = provider.machineCount else {
      return provider.machines == nil ? "" : "—"
    }
    return "\(rented) of \(total) rented"
  }

  private var problems: [String] {
    var lines: [String] = []
    if let failure = store.collectorErrors[id] { lines.append(failure) }
    if let error = provider.error { lines.append(error) }
    guard provider.status != "loading", !provider.isFresh else { return lines }
    if let updated = provider.updatedAt {
      lines.append(
        "Stale since "
          + Date(timeIntervalSince1970: updated).formatted(date: .omitted, time: .shortened))
    } else if lines.isEmpty {
      lines.append("Not connected")
    }
    return lines
  }

  private var allowances: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(provider.visibleWindows) { window in
        AllowanceRow(
          window: window, tint: .mark(id), fresh: provider.isFresh,
          showTime: options.showResetDates, style: store.preferences.gaugeStyle)
      }
      if options.showAdditional && !provider.additionalWindows.isEmpty {
        MenuSectionLabel(title: "Additional").padding(.top, 6)
        ForEach(provider.additionalWindows) { window in
          AllowanceRow(
            window: window, tint: .mark(id), fresh: provider.isFresh,
            showTime: options.showResetDates, style: store.preferences.gaugeStyle)
        }
      }
      if provider.windows?.isEmpty != false && provider.status != "loading" {
        menuNote("Sign in to \(signInTarget) on this Mac to see allowances.")
      }
    }
  }

  private var signInTarget: String {
    switch category {
    case .codex: return "the Codex CLI with your ChatGPT account"
    case .claude: return "Claude Code"
    default: return category.name
    }
  }
}

struct AllowanceRow: View {
  let window: UsageWindow
  let tint: Color
  let fresh: Bool
  let showTime: Bool
  var style = GaugeStyle.ring
  private var color: Color { window.usedPercent >= 90 ? .orange : tint }

  /// "Resets in 6h 40m", with the clock time appended when the setting asks for it.
  private var resetLine: String {
    var text = resetText(window.resetDate)
    if showTime, let date = window.resetDate, !window.hasExpired {
      text += " · " + resetClock(date)
    }
    return text
  }

  private var valueText: some View {
    HStack(alignment: .firstTextBaseline, spacing: 3) {
      Text(window.percent).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        .foregroundStyle(window.usedPercent >= 90 ? Color.orange : Color.primary)
      Text("used").font(.system(size: 11)).foregroundStyle(.secondary)
    }
  }

  var body: some View {
    Group {
      if style == .bar {
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline) {
            Text(window.label).font(.system(size: 13))
            Spacer()
            valueText
          }
          CapacityBar(fraction: window.usedPercent / 100, tint: color)
          Text(resetLine).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, MenuMetrics.inset).padding(.vertical, 5)
        .accessibilityElement(children: .combine)
      } else {
        MenuRow(title: window.label, lines: [resetLine]) {
          RingBadge(
            percent: window.usedPercent, tint: color,
            value: style == .ringValue ? window.percent : nil)
        } trailing: {
          if style == .ringValue { EmptyView() } else { valueText }
        }
      }
    }
    .opacity(fresh && !window.hasExpired ? 1 : 0.55)
    .help(
      String(format: "%.0f%% remaining", max(0, 100 - window.usedPercent)) + " · "
        + (window.resetDate?.formatted(date: .complete, time: .shortened)
          ?? "The provider did not report a reset time."))
  }
}

/// Clock time for a reset: today's time, a weekday and time within the week, else the date.
func resetClock(_ date: Date) -> String {
  let seconds = date.timeIntervalSinceNow
  if seconds < 20 * 3600 { return date.formatted(date: .omitted, time: .shortened) }
  if seconds < 6 * 86400 {
    return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
  }
  return date.formatted(.dateTime.day().month(.abbreviated))
}

struct VastMenu: View {
  let provider: Provider
  let options: ProviderPreferences
  var style = GaugeStyle.ring
  private var utc: TimeZone { TimeZone(secondsFromGMT: 0)! }
  private var machines: [Machine] { provider.machines ?? [] }
  private var money: MoneyFormat { MoneyFormat(currency: options.currency, rates: provider.rates) }

  private var figures: EarningsFigures { provider.earnings(options) }
  /// Both columns only when net figures exist; otherwise the single column that applies.
  private var columns: [(String, EarningsFigures.Set)] {
    switch (options.earningsView, figures.net) {
    case (.both, .some(let net)): return [("Gross", figures.gross), ("Net", net)]
    case (.net, .some(let net)): return [("Net", net)]
    default: return [("Gross", figures.gross)]
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if provider.machines != nil {
        earningsTable
        MenuSeparator()
      }
      if !machines.isEmpty {
        MenuSectionLabel(title: "Machines", trailing: "\(machines.count) hosts")
      }
      ForEach(machines) { machine in
        MachineRow(
          machine: machine, fresh: provider.isFresh, detailed: options.showMachineDetails,
          money: money, period: options.utilizationPeriod,
          periodDays: provider.utilizationDays, watts: options.machineWatts[machine.id],
          powerPrice: options.powerPrice, style: style)
      }
      if provider.machines == nil && provider.status != "loading" {
        menuNote("Add your Vast.ai API key in Settings to see rentals and earnings.")
      } else if machines.isEmpty && provider.machines != nil {
        menuNote("No host machines found.")
      }
      if options.showEarningsHistory, let daily = provider.daily, !daily.isEmpty {
        MenuSeparator()
        MenuSectionLabel(
          title: "7-day earnings",
          trailing: money.format(provider.sevenDayTotal) + " · "
            + money.format(provider.sevenDayAverage) + "/day"
        )
        .help(earningsTooltip)
        Chart(daily) { day in
          BarMark(
            x: .value("Day (UTC)", day.date, unit: .day),
            y: .value(money.code, day.amount * money.factor)
          )
          .foregroundStyle(Color.vast.gradient).cornerRadius(3)
          .accessibilityLabel(
            day.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: utc))
          )
          .accessibilityValue(money.format(day.amount))
        }
        .chartXAxis {
          AxisMarks(values: .stride(by: .day)) { _ in
            AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
          }
        }
        .chartYAxis {
          AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
            AxisGridLine().foregroundStyle(.primary.opacity(0.08))
            AxisValueLabel {
              if let amount = value.as(Double.self) { Text(money.local(amount, digits: 0)) }
            }
          }
        }
        .environment(\.timeZone, utc).font(.system(size: 10)).frame(height: 72)
        .padding(.horizontal, MenuMetrics.inset).padding(.top, 6).padding(.bottom, 2)
      }
    }
  }

  /// Label column then one value column per view, all left-aligned so figures line up.
  private var earningsTable: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
      GridRow {
        Text("Earnings").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
        ForEach(columns, id: \.0) { column in
          Text(columnTitle(column.0)).font(.system(size: 11)).foregroundStyle(.secondary)
            .help(columnHelp)
        }
      }
      earningsRow("Today", \.today, unit: "")
      earningsRow("Rate", \.hourly, unit: "/h")
      earningsRow("7-day average", \.average, unit: "/day")
      if figures.net != nil && options.earningsView != .gross, let power = figures.powerPerDay {
        GridRow {
          Text("Power").font(.system(size: 13)).foregroundStyle(.secondary)
          if columns.count > 1 { Text("") }
          Text("-" + money.local(power) + "/day").font(.system(size: 13)).monospacedDigit()
            .foregroundStyle(.secondary)
            .help("Entered watts × 24 h × price per kWh, summed over machines.")
        }
      }
    }
    .padding(.horizontal, MenuMetrics.inset).padding(.top, 2).padding(.bottom, 4)
    .opacity(provider.isFresh ? 1 : 0.55)
  }

  private func columnTitle(_ name: String) -> String {
    options.earningsView == .net ? "After power" : name
  }

  private var columnHelp: String {
    options.earningsView != .gross && figures.net == nil
      ? "Set an electricity price and wattages in Settings to show net figures." : ""
  }

  private func earningsRow(
    _ label: String, _ value: KeyPath<EarningsFigures.Set, Double?>, unit: String
  ) -> some View {
    GridRow {
      Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
      ForEach(columns, id: \.0) { column in
        Text(column.1[keyPath: value].map { money.local($0) + unit } ?? "—")
          .font(.system(size: 13, weight: .semibold)).monospacedDigit()
      }
    }
  }

  private var earningsTooltip: String {
    var text = "Previous seven complete UTC days, idle days included, today excluded."
    if let split = provider.earningsBreakdown {
      text +=
        " GPU \(money.format(split.gpu)) · Storage \(money.format(split.storage)) · Network \(money.format(split.network))"
      if abs(split.adjustments) > 0.0001 { text += " · SLA \(money.format(split.adjustments))" }
      text += "."
    }
    return text + " Revenue before costs."
  }
}

struct MachineRow: View {
  let machine: Machine
  let fresh: Bool
  let detailed: Bool
  let money: MoneyFormat
  let period: UtilizationPeriod
  let periodDays: Int?
  let watts: Double?
  let powerPrice: Double?
  var style = GaugeStyle.ring
  private var rented: Bool { fresh && machine.status == "Rented" }
  /// The ring shows the period the collector reported, which can trail a settings change.
  private var periodLabel: String {
    UtilizationPeriod.allCases.first { $0.days == periodDays }?.shortLabel ?? period.shortLabel
  }

  private var verified: Bool { machine.verification?.lowercased() == "verified" }

  private var lines: [String] { [subtitle] + (detailed ? [details].compactMap { $0 } : []) }

  private var statusText: some View {
    Text(fresh ? machine.status : "Stale").font(.system(size: 12, weight: .medium))
      .foregroundStyle(rented ? Color.live : Color.secondary)
  }

  var body: some View {
    Group {
      if style == .bar {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 4) {
            if verified {
              Image(systemName: "checkmark.seal.fill").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.live)
            }
            Text(title).font(.system(size: 13))
            Spacer()
            statusText
          }
          if let utilization = machine.utilization {
            HStack(spacing: 8) {
              CapacityBar(fraction: utilization, tint: .vast)
              Text(String(format: "%.0f%%", utilization * 100))
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
              Text(periodLabel).font(.system(size: 10)).foregroundStyle(.secondary)
            }
          }
          ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, MenuMetrics.inset).padding(.vertical, 5)
        .accessibilityElement(children: .combine)
      } else {
        MenuRow(
          title: title, titleSymbol: verified ? ("checkmark.seal.fill", Color.live) : nil,
          lines: lines
        ) {
          // Same ring as the allowance rows: the fill is the utilization share.
          if let utilization = machine.utilization {
            RingBadge(
              percent: utilization * 100, tint: .vast,
              value: style == .ringValue ? String(format: "%.0f%%", utilization * 100) : nil)
          } else {
            MenuBadge(fill: rented ? Color.live : Color.primary.opacity(0.09)) {
              Image(systemName: "server.rack").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(rented ? Color.white : Color.secondary)
            }
          }
        } trailing: {
          VStack(alignment: .trailing, spacing: 1) {
            if let utilization = machine.utilization, style == .ring {
              HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(format: "%.0f%%", utilization * 100))
                  .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Text(periodLabel).font(.system(size: 11)).foregroundStyle(.secondary)
              }
            }
            statusText
            if machine.utilization != nil && style == .ringValue {
              Text(periodLabel).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
          }
        }
      }
    }
    .opacity(fresh ? 1 : 0.6)
    .help(tooltip)
  }

  private var title: String {
    (machine.gpuCount.map { $0 > 1 ? "\(Int($0)) × " : "" } ?? "") + machine.gpu
  }

  /// The one number that matters in the machine's current state; the host name is in the tooltip.
  private var subtitle: String {
    if rented { return "Earning " + money.format(machine.estimatedHourly) + "/h" }
    if machine.listed == false { return "Unlisted" }
    if let price = machine.listedHourly { return "Listed " + money.format(price) + "/GPU/h" }
    return "No listing price reported"
  }

  /// Health at a glance; verification is the checkmark, counts stay in the tooltip.
  private var details: String? {
    var parts: [String] = []
    if let temperature = machine.gpuTemperature {
      parts.append(String(format: "%.0f °C", temperature))
    }
    if let reliability = machine.reliability {
      parts.append(String(format: "%.1f%% reliable", reliability * 100))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private var tooltip: String {
    var lines = [machine.name + " · machine #" + machine.id]
    if let utilization = machine.utilization {
      lines.append(
        String(
          format: "Utilization (%@): %.0f%% of listed GPU hours earned", periodLabel,
          utilization * 100))
    }
    lines.append("Vast reported hourly average: " + money.format(machine.reportedHourly) + "/h")
    if let daily = machine.reportedDaily {
      lines.append("Vast reported daily earnings: " + money.format(daily))
    }
    if let price = machine.listedHourly {
      lines.append("Listed price: " + money.format(price) + "/GPU/h")
    }
    if let watts, let powerPrice, powerPrice > 0 {
      lines.append(
        String(format: "Power: %.0f W ≈ ", watts) + money.local(watts * 24 / 1000 * powerPrice)
          + "/day")
    }
    lines.append("\(count(machine.running)) running · \(count(machine.stored)) resident")
    if let verification = machine.verification { lines.append("Verification: " + verification) }
    if let temperature = machine.gpuTemperature {
      lines.append(String(format: "GPU temperature: %.0f °C", temperature))
    }
    if let reliability = machine.reliability {
      lines.append(String(format: "Reliability: %.2f%%", reliability * 100))
    }
    if let cpu = machine.cpu { lines.append("CPU: " + cpu) }
    lines.append("Resident containers include running ones.")
    return lines.joined(separator: "\n")
  }

  private func count(_ value: Double?) -> String { value.map { String(Int($0)) } ?? "—" }
}
