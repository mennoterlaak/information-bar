import AppIntents
import SwiftUI
import WidgetKit

enum InformationSource: String, AppEnum {
  case codex, claude, cursor, vast, pearl, kraken, power

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Source")
  static let caseDisplayRepresentations: [InformationSource: DisplayRepresentation] = [
    .codex: "ChatGPT", .claude: "Claude", .cursor: "Cursor", .vast: "Vast.ai",
    .pearl: "Pearl", .kraken: "Portfolio", .power: "Power",
  ]

  var category: ProviderCategory { ProviderCategory(rawValue: rawValue)! }
}

struct InformationConfiguration: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Information"
  static let description = IntentDescription("Keep a source from your Mac close at hand.")

  @Parameter(title: "Source", default: .kraken)
  var source: InformationSource
}

struct InformationEntry: TimelineEntry {
  let date: Date
  let snapshot: MobileSnapshot?
  let source: InformationSource
}

struct InformationTimeline: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> InformationEntry {
    InformationEntry(date: .now, snapshot: .demo, source: .kraken)
  }

  func snapshot(for configuration: InformationConfiguration, in context: Context) async -> InformationEntry {
    InformationEntry(date: .now,
      snapshot: MobileCache.load() ?? (context.isPreview ? .demo : nil),
      source: configuration.source)
  }

  func timeline(for configuration: InformationConfiguration, in context: Context) async -> Timeline<InformationEntry> {
    let snapshot = (try? await MobileSync.refresh()) ?? MobileCache.load()
    let now = Date()
    let reload = now.addingTimeInterval(15 * 60)
    var dates = [now]

    // A scheduled entry changes cached data to stale even if the next network update
    // is delayed by iOS. Derived profit also expires when an assigned meter expires.
    if let snapshot {
      let interval = max(15, snapshot.preferences.refreshInterval)
      var boundaries: [Double] = []
      for provider in snapshot.providers {
        if let updated = provider.updatedAt {
          boundaries.append(updated + Double(3 * interval + (provider.id == "claude" ? 300 : 0)) + 1)
        }
        boundaries += (provider.powerDevices ?? []).compactMap { $0.updatedAt.map { $0 + Double(3 * interval) + 1 } }
        boundaries += (provider.windows ?? []).compactMap { $0.resetAt.map { $0 + 1 } }
      }
      dates += Set(boundaries).map(Date.init(timeIntervalSince1970:))
        .filter { $0 > now && $0 < reload }.sorted()
    }
    return Timeline(entries: dates.map {
      InformationEntry(date: $0, snapshot: snapshot, source: configuration.source)
    }, policy: .after(reload))
  }
}

struct InformationWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: InformationEntry

  var body: some View {
    Group {
      if let snapshot = entry.snapshot,
        snapshot.preferences.provider(entry.source.category).enabled
      {
        let summary = MobileSummary(snapshot: snapshot, category: entry.source.category, date: entry.date)
        switch family {
        case .accessoryCircular: circular(summary)
        case .accessoryRectangular: rectangular(summary)
        case .accessoryInline: inline(summary)
        case .systemMedium: medium(summary)
        case .systemLarge: large(summary)
        default: small(summary)
        }
      } else {
        disconnected
      }
    }
    .widgetURL(URL(string: "informationbar://provider/\(entry.source.rawValue)"))
    .containerBackground(for: .widget) {
      Color(uiColor: .secondarySystemGroupedBackground)
    }
  }

  private func small(_ summary: MobileSummary) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      heading(summary)
      Spacer(minLength: 0)
      headline(summary, style: .title)
      Text(summary.subtitle).font(.caption2).foregroundStyle(.secondary)
        .lineLimit(1).minimumScaleFactor(0.8)
      if let progress = summary.progress {
        MobileProgress(fraction: progress, tint: summary.tint).padding(.top, 4)
      }
      Spacer(minLength: 0)
      MobileSourceStamp(summary: summary)
    }
    .privacySensitive(summary.isFinancial)
    .accessibilityElement(children: .combine)
  }

  private func medium(_ summary: MobileSummary) -> some View {
    HStack(alignment: .top, spacing: 18) {
      VStack(alignment: .leading, spacing: 8) {
        heading(summary)
        Spacer(minLength: 0)
        headline(summary, style: .title2)
        Text(summary.subtitle).font(.caption2).foregroundStyle(.secondary)
          .lineLimit(2).minimumScaleFactor(0.85)
        Spacer(minLength: 0)
        MobileSourceStamp(summary: summary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(summary.metrics.prefix(3)) { metric in
          VStack(alignment: .leading, spacing: 2) {
            Text(metric.label).font(.caption2).foregroundStyle(.secondary)
            Text(metric.value).font(.subheadline.weight(.medium)).monospacedDigit()
              .lineLimit(1).minimumScaleFactor(0.7)
          }
        }
        if summary.metrics.isEmpty {
          Text("Open for details").font(.caption).foregroundStyle(.secondary)
        }
        if let progress = summary.progress { MobileProgress(fraction: progress, tint: summary.tint) }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    .privacySensitive(summary.isFinancial)
  }

  private func large(_ summary: MobileSummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      heading(summary)
      headline(summary, style: .largeTitle)
      Text(summary.subtitle).font(.caption).foregroundStyle(.secondary)
      if let progress = summary.progress { MobileProgress(fraction: progress, tint: summary.tint) }
      Divider().padding(.vertical, 2)
      ForEach(expandedMetrics(summary).prefix(6)) { metric in
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(metric.label).foregroundStyle(.secondary)
          Spacer(minLength: 4)
          Text(metric.value).fontWeight(.medium).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
      }
      Spacer(minLength: 0)
      MobileSourceStamp(summary: summary)
    }
    .privacySensitive(summary.isFinancial)
  }

  private func rectangular(_ summary: MobileSummary) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(summary.title).font(.caption.weight(.semibold))
      Text(summary.primary).font(.headline).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.65)
      Text(summary.freshness).font(.caption2).lineLimit(1)
        .foregroundStyle(.secondary)
    }
    .privacySensitive(summary.isFinancial)
    .accessibilityElement(children: .combine)
  }

  private func circular(_ summary: MobileSummary) -> some View {
    Group {
      if summary.category.isSubscription, let progress = summary.progress {
        Gauge(value: progress) {
          Image(systemName: summary.isFresh ? summary.category.mobileSymbol : "clock")
        } currentValueLabel: {
          Text(summary.primary).font(.caption2).minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircular)
      } else {
        let compact = circularText(summary)
        VStack(spacing: 2) {
          Image(systemName: summary.isFresh ? summary.category.mobileSymbol : "clock")
            .font(.caption2)
          Text(compact.value).font(.system(.subheadline, design: .rounded, weight: .semibold))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
          Text(summary.isFresh ? compact.unit : "Stale").font(.caption2)
            .lineLimit(1).minimumScaleFactor(0.7)
        }
      }
    }
    .privacySensitive(summary.isFinancial)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(summary.title), \(summary.primary), \(summary.subtitle), \(summary.freshness)")
  }

  private func circularText(_ summary: MobileSummary) -> (value: String, unit: String) {
    switch summary.category {
    case .kraken:
      guard let kraken = summary.provider?.kraken, let total = kraken.accountValue else { return ("—", "Portfolio") }
      if abs(total) >= 1_000_000 { return (kraken.money.local(total / 1_000_000, digits: 1) + "m", "Portfolio") }
      if abs(total) >= 1000 { return (kraken.money.local(total / 1000, digits: 1) + "k", "Portfolio") }
      return (kraken.money.local(total, digits: 0), "Portfolio")
    case .pearl:
      let parts = summary.primary.split(separator: " ")
      guard parts.count == 2, let value = Double(parts[0]) else { return ("—", "Pearl") }
      return (String(format: "%.1f", value), String(parts[1]))
    case .power:
      return (summary.displayWatts.map { String(format: "%.0f", $0) } ?? "—", "W")
    case .vast:
      return (summary.money.local(summary.vastShown.today, digits: 1), "Today")
    default: return (summary.primary, summary.title)
    }
  }

  private func inline(_ summary: MobileSummary) -> some View {
    Text("\(summary.title) \(summary.primary) · \(summary.freshness)")
      .privacySensitive(summary.isFinancial)
  }

  private func heading(_ summary: MobileSummary) -> some View {
    HStack(spacing: 7) {
      Image(systemName: summary.category.mobileSymbol)
        .foregroundStyle(summary.tint).widgetAccentable()
      Text(summary.title).foregroundStyle(.secondary)
    }
    .font(.caption.weight(.medium))
    .lineLimit(1)
  }

  private func headline(_ summary: MobileSummary, style: Font.TextStyle) -> some View {
    Text(summary.primary)
      .font(.system(style, design: .rounded, weight: .medium))
      .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
      .foregroundStyle(summary.sourceDate == nil ? Color.secondary : Color.primary)
  }

  private func expandedMetrics(_ summary: MobileSummary) -> [MobileMetric] {
    if summary.category.isSubscription {
      return (summary.provider?.windows ?? []).map { window in
        MobileMetric(label: window.label,
          value: window.resetDate.map { $0 <= entry.date } == true ? "Awaiting reset" : window.percent)
      }
    }
    if summary.category == .pearl {
      return summary.metrics + [
        MobileMetric(label: "Net / week", value: summary.money.local(summary.projection.netPerDay.map { $0 * 7 })),
        MobileMetric(label: "Net / 30 days", value: summary.money.local(summary.projection.netPerDay.map { $0 * 30 })),
      ]
    }
    if summary.category == .power {
      return summary.metrics + summary.snapshot.preferences.power.devices.map { device in
        MobileMetric(label: device.name, value: summary.watts(device.id).map { String(format: "%.0f W", $0) } ?? "—")
      }
    }
    if summary.category == .vast {
      return summary.metrics + [
        MobileMetric(label: "7-day total", value: summary.money.format(summary.provider?.sevenDayTotal)),
        MobileMetric(label: "Utilization", value: summary.provider?.utilizationAverage.map { String(format: "%.0f%%", $0 * 100) } ?? "—"),
      ]
    }
    return summary.metrics
  }

  private var disconnected: some View {
    let paired = entry.snapshot != nil
    return Group {
      switch family {
      case .accessoryInline:
        Text(paired ? "\(entry.source.category.name) · source disabled" : "Information · connect your Mac")
      case .accessoryCircular:
        VStack(spacing: 3) {
          Image(systemName: "circle.dotted.circle")
          Text(paired ? "Source off" : "Open app").font(.caption2)
        }
      case .accessoryRectangular:
        VStack(alignment: .leading) {
          Text("Information").font(.headline)
          Text(paired ? "Choose an enabled source" : "Connect your Mac").font(.caption)
        }
      default:
        VStack(alignment: .leading, spacing: 8) {
          Image(systemName: "circle.dotted.circle").font(.title2).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Text(paired ? "Choose a source." : "A little closer.").font(.headline)
          Text(paired ? "Edit this widget to choose a source, or enable \(entry.source.category.name) on your Mac."
            : "Open Information Bar to connect your Mac.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
}

struct InformationWidget: Widget {
  let kind = "InformationBar.Source"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: kind, intent: InformationConfiguration.self, provider: InformationTimeline()) { entry in
      InformationWidgetView(entry: entry)
    }
    .configurationDisplayName("Information")
    .description("Your usage, portfolio, mining and power. Choose a source for each widget.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
      .accessoryCircular, .accessoryRectangular, .accessoryInline])
  }
}

@main
struct InformationWidgets: WidgetBundle {
  var body: some Widget { InformationWidget() }
}
