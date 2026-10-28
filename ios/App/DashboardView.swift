import SwiftUI
import Charts

struct DashboardView: View {
  @EnvironmentObject private var store: MobileStore
  @State private var settings = false
  @State private var path: [String] = []

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if let snapshot = store.snapshot {
          TimelineView(.periodic(from: .now, by: 60)) { timeline in
            dashboard(snapshot, at: timeline.date)
          }
        } else {
          emptyState
        }
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .navigationTitle("Information")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { settings = true } label: {
            Image(systemName: "slider.horizontal.3")
              .frame(minWidth: 32, minHeight: 32)
          }
          .accessibilityLabel("Settings")
        }
      }
      .navigationDestination(for: String.self) { value in
        if let category = ProviderCategory(rawValue: value), let snapshot = store.snapshot {
          MobileProviderDetail(snapshot: snapshot, category: category)
        }
      }
    }
    .tint(Color.primary)
    .sheet(isPresented: $settings) { settingsSheet }
    .onChange(of: store.selectedProvider?.rawValue, initial: true) { _, value in
      if let value {
        path = [value]
        store.selectedProvider = nil
      }
    }
  }

  private func dashboard(_ snapshot: MobileSnapshot, at date: Date) -> some View {
    let categories = snapshot.enabledCategories
    let hero = categories.contains(.kraken) ? ProviderCategory.kraken
      : categories.contains(.pearl) ? .pearl : categories.first
    let subscriptions = categories.filter(\.isSubscription)
    let remaining = categories.filter { !$0.isSubscription && $0 != hero }
    return ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        if store.demo {
          Text("PREVIEW")
            .font(.caption2.weight(.semibold)).tracking(2)
            .foregroundStyle(.secondary)
        }
        if let hero {
          NavigationLink(value: hero.rawValue) {
            dashboardHero(MobileSummary(snapshot: snapshot, category: hero, date: date))
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        if !subscriptions.isEmpty {
          VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Usage")
            ForEach(subscriptions) { category in
              NavigationLink(value: category.rawValue) {
                usageRow(MobileSummary(snapshot: snapshot, category: category, date: date))
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              if category != subscriptions.last { Divider() }
            }
          }
          .padding(22)
          .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
        }
        if !remaining.isEmpty {
          VStack(spacing: 23) {
            ForEach(remaining) { category in
              NavigationLink(value: category.rawValue) {
                compactRow(MobileSummary(snapshot: snapshot, category: category, date: date))
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              if category != remaining.last { Divider() }
            }
          }
          .padding(.horizontal, 4)
        }
        if categories.isEmpty {
          Text("Enable a source on your Mac to see it here.")
            .font(.body).foregroundStyle(.secondary)
        }
        if let error = store.error {
          Label(error, systemImage: "wifi.exclamationmark")
            .font(.footnote).foregroundStyle(.secondary)
        }
        HStack(spacing: 6) {
          if store.syncing { ProgressView().controlSize(.mini) }
          Text(store.demo ? "Sample data" : "Pull to refresh")
        }
        .font(.caption).foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
      }
      .padding(.horizontal, 24)
      .padding(.top, 20)
      .padding(.bottom, 28)
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
    }
    .refreshable { await store.refresh() }
  }

  private func dashboardHero(_ summary: MobileSummary) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(summary.title).font(.title3.weight(.medium))
        Spacer()
        Image(systemName: "arrow.up.right").font(.footnote.weight(.medium)).foregroundStyle(.tertiary)
      }
      Text(summary.primary)
        .font(.system(.largeTitle, design: .rounded, weight: .medium))
        .fontWidth(.condensed)
        .monospacedDigit()
        .minimumScaleFactor(0.65)
        .lineLimit(1)
        .privacySensitive(summary.isFinancial)
        .padding(.top, 6)
      HStack(alignment: .firstTextBaseline) {
        Text(summary.subtitle).font(.subheadline)
          .foregroundStyle(heroChangeColor(summary))
        Spacer(minLength: 8)
        MobileSourceStamp(summary: summary)
      }
      if summary.category == .kraken, let kraken = summary.provider?.kraken,
        let total = kraken.totalValue, total > 0
      {
        holdingStrip(kraken, total: total)
          .padding(.top, 14)
      }
    }
    .padding(.horizontal, 4)
    .padding(.bottom, 5)
    .accessibilityElement(children: .combine)
    .accessibilityHint("Opens \(summary.title) details")
  }

  private func heroChangeColor(_ summary: MobileSummary) -> Color {
    guard summary.category == .kraken, let change = summary.provider?.kraken?.accountChange else { return .secondary }
    return change < 0 ? .orange : Color(red: 0.17, green: 0.48, blue: 0.37)
  }

  private func holdingStrip(_ kraken: KrakenMetrics, total: Double) -> some View {
    let colors: [Color] = [.init(red: 0.42, green: 0.35, blue: 0.59),
      .init(red: 0.62, green: 0.56, blue: 0.72), .init(red: 0.74, green: 0.70, blue: 0.81),
      .init(red: 0.83, green: 0.80, blue: 0.86)]
    return VStack(alignment: .leading, spacing: 10) {
      GeometryReader { geometry in
        HStack(spacing: 3) {
          ForEach(Array(kraken.assets.filter { ($0.value ?? 0) > 0 }.enumerated()), id: \.element.id) { index, asset in
            Capsule().fill(colors[min(index, colors.count - 1)])
              .frame(width: max(0, (geometry.size.width - CGFloat(max(0, kraken.assets.count - 1)) * 3)
                * min(1, max(0, (asset.value ?? 0) / total))))
          }
        }
      }
      .frame(height: 6)
      .accessibilityHidden(true)
      HStack(spacing: 14) {
        ForEach(Array(kraken.assets.prefix(3).enumerated()), id: \.element.id) { index, asset in
          HStack(spacing: 5) {
            Circle().fill(colors[index]).frame(width: 5, height: 5)
            Text(asset.symbol)
          }
        }
      }
      .font(.caption2).foregroundStyle(.secondary)
    }
  }

  private func usageRow(_ summary: MobileSummary) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(summary.category.name).font(.body.weight(.medium))
        Spacer()
        Text(summary.primary).font(.title3.weight(.medium)).monospacedDigit()
      }
      if let progress = summary.progress { MobileProgress(fraction: progress, tint: summary.tint) }
      HStack(alignment: .firstTextBaseline) {
        Text(summary.selectedWindow.map { "\($0.shortLabel) · \(resetText($0.resetDate))" } ?? "No active allowance")
          .font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 6)
        if !summary.isFresh { MobileSourceStamp(summary: summary) }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityHint("Opens all \(summary.category.name) allowances")
  }

  private func compactRow(_ summary: MobileSummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(summary.title).font(.body.weight(.medium))
        Spacer(minLength: 12)
        Text(summary.primary).font(.title3.weight(.medium)).monospacedDigit()
          .multilineTextAlignment(.trailing).privacySensitive(summary.isFinancial)
      }
      HStack(alignment: .firstTextBaseline) {
        if let metric = summary.metrics.first {
          Text("\(metric.value) \(metric.label == "PRL" ? "per PRL" : metric.label.lowercased())")
            .font(.caption).foregroundStyle(.secondary).privacySensitive(summary.isFinancial)
        } else {
          Text(summary.subtitle).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        MobileSourceStamp(summary: summary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityHint("Opens \(summary.title) details")
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 22) {
      Spacer()
      Image(systemName: "circle.dotted.circle")
        .font(.system(size: 46, weight: .ultraLight)).foregroundStyle(.secondary)
      Text(store.paired ? "Waiting for your Mac." : "Your information.\nA little closer.")
        .font(.largeTitle.weight(.medium))
      Text(store.paired
        ? "Your latest information appears here when your Mac is reachable."
        : "Usage, portfolio, mining and power. Connect your Mac once, then keep the essentials on your Home Screen.")
        .font(.body).foregroundStyle(.secondary)
      if let error = store.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
      Button {
        if store.paired { Task { await store.refresh() } }
        else { store.showPairing = true }
      } label: {
        HStack {
          Text(store.paired ? "Refresh" : "Connect Mac")
          Spacer()
          if store.syncing { ProgressView().tint(.white) }
          else { Image(systemName: "arrow.right") }
        }
        .padding(.vertical, 9)
      }
      .buttonStyle(.borderedProminent)
      .tint(Color(red: 0.17, green: 0.38, blue: 0.33))
      .disabled(store.syncing)
      Spacer()
      Spacer()
    }
    .padding(28)
    .frame(maxWidth: 580)
    .frame(maxWidth: .infinity)
  }

  private var settingsSheet: some View {
    NavigationStack {
      Form {
        Section {
          if store.demo {
            LabeledContent("Connection", value: "Preview")
          } else if let host = store.endpointHost {
            LabeledContent("Mac", value: host)
          } else {
            Text("Connect to Information Bar on your Mac.").foregroundStyle(.secondary)
          }
          Button("\(store.paired ? "Refresh now" : "Connect Mac")") {
            if store.paired { Task { await store.refresh() } }
            else { settings = false; store.showPairing = true }
          }
          .disabled(store.syncing)
        } header: { Text("Connection") } footer: {
          Text("The Mac supplies your existing sources. Keep it awake and reachable on the same network, or through your private VPN.")
        }
        Section {
          Text("Touch and hold your Home Screen, add an Information Bar widget, then edit it to choose a source.")
          Text("Widgets update when iOS allows. Each one shows the age of its source, and keeps older readings visibly marked.")
        } header: { Text("Widgets") }
        if store.paired || store.demo {
          Section {
            Button("Disconnect", role: .destructive) {
              store.disconnect()
              settings = false
            }
          }
        }
      }
      .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } }
    }
  }
}

struct MobileProviderDetail: View {
  let snapshot: MobileSnapshot
  let category: ProviderCategory

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { timeline in
      let summary = MobileSummary(snapshot: snapshot, category: category, date: timeline.date)
      ScrollView {
        VStack(alignment: .leading, spacing: 30) {
          detailHeader(summary)
          if let provider = summary.provider {
            if category.isSubscription { subscriptionDetails(provider, summary: summary) }
            switch category {
            case .pearl: pearlDetails(provider, summary: summary)
            case .kraken: krakenDetails(provider, summary: summary)
            case .power: powerDetails(provider, summary: summary)
            case .vast: vastDetails(provider, summary: summary)
            default: EmptyView()
            }
            if let error = provider.error {
              Label(error, systemImage: "exclamationmark.circle")
                .font(.footnote).foregroundStyle(.secondary)
            }
          } else {
            Text("This source is not connected on your Mac.").foregroundStyle(.secondary)
          }
        }
        .padding(24)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
      }
      .background(Color(uiColor: .systemGroupedBackground))
    }
    .navigationTitle(category == .kraken ? "Portfolio" : category.name)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func detailHeader(_ summary: MobileSummary) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(summary.primary)
        .font(.system(.largeTitle, design: .rounded, weight: .medium))
        .monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
        .privacySensitive(summary.isFinancial)
      Text(summary.subtitle).font(.subheadline).foregroundStyle(.secondary)
      MobileSourceStamp(summary: summary)
      if let date = summary.sourceDate {
        Text(date.formatted(date: .abbreviated, time: .standard))
          .font(.caption2).foregroundStyle(.tertiary)
      }
      if !summary.isFresh, summary.sourceDate != nil {
        Text("Last known readings. Current projections stay unavailable until the sources refresh.")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
  }

  private func subscriptionDetails(_ provider: Provider, summary: MobileSummary) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      if let plan = provider.plan { Text(plan).font(.subheadline).foregroundStyle(.secondary) }
      ForEach(provider.windows ?? []) { window in
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .firstTextBaseline) {
            Text(window.label).font(.body.weight(.medium))
            Spacer()
            Text(window.percent).font(.title3.weight(.medium)).monospacedDigit()
          }
          MobileProgress(fraction: window.usedPercent / 100, tint: summary.tint)
          Text(resetText(window.resetDate)).font(.caption).foregroundStyle(.secondary)
          if let date = window.resetDate {
            Text(date.formatted(date: .abbreviated, time: .shortened))
              .font(.caption2).foregroundStyle(.tertiary)
          }
        }
        .accessibilityElement(children: .combine)
        Divider()
      }
      if provider.windows?.isEmpty != false {
        Text("No allowances available.").foregroundStyle(.secondary)
      }
    }
  }

  private func pearlDetails(_ provider: Provider, summary: MobileSummary) -> some View {
    let pearl = provider.pearl
    return VStack(alignment: .leading, spacing: 30) {
      detailSection("Projection") {
        ForEach(ProjectionPeriod.allCases) { period in
          projectionRow(period == .month ? "30 days" : period.title,
            revenue: summary.money.local(summary.projection.revenuePerDay.map { $0 * period.days }),
            net: summary.money.local(summary.projection.netPerDay.map { $0 * period.days }))
        }
        Text("At the \(pearl?.effectiveAverageWindow.averageDescription ?? "selected average"), current price and measured draw. Net deducts electricity; hardware, tax and exchange costs are excluded.")
          .font(.caption).foregroundStyle(.secondary)
        if summary.projection.netPerDay == nil {
          Text("Net needs fresh mining data, an assigned meter and an electricity tariff.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      detailSection("Mining") {
        detailRow("PRL price", summary.money.format(pearl?.priceUSD, digits: 3))
        detailRow("30 minutes", formatHashrate(pearl?.shortHashrate))
        detailRow("3 hours", formatHashrate(pearl?.hashrate3h))
        detailRow("24 hours", formatHashrate(pearl?.hashrate24h))
        detailRow("7 days", formatHashrate(pearl?.hashrate7d))
        detailRow("Yield / day", formatPRL(pearl?.coinsPerDay, digits: 4))
        detailRow("Workers online", pearl?.onlineWorkers.map { online in
          pearl?.workerCount.map { "\(online) / \($0)" } ?? String(online)
        } ?? "—")
        detailRow("Pool fee", pearl?.poolFeePercent.map { String(format: "%.2g%%", $0) } ?? "—")
        if let date = pearl?.priceUpdatedAt {
          sourceNote("Price", timestamp: date)
        }
        if let date = pearl?.historyUpdatedAt {
          sourceNote("Hashrate history", timestamp: date)
        }
      }
      detailSection("Balances") {
        detailRow("Wallet", formatPRL(pearl?.walletBalance, digits: 4))
        detailRow("Unpaid rewards", formatPRL(pearl?.poolBalance, digits: 4))
        detailRow("Confirmed", formatPRL(pearl?.poolConfirmed, digits: 4))
        detailRow("Maturing", formatPRL(pearl?.poolUnconfirmed, digits: 4))
        detailRow("Payout threshold", formatPRL(pearl?.payoutThreshold, digits: 2))
        if let progress = summary.progress { MobileProgress(fraction: progress, tint: summary.tint) }
        detailRow("Total paid", formatPRL(pearl?.totalPaid, digits: 4))
      }
      .privacySensitive()
      detailSection("Payouts") {
        if let payouts = pearl?.payouts {
          if payouts.isEmpty { Text("No payouts yet.").font(.subheadline).foregroundStyle(.secondary) }
          ForEach(payouts) { payout in
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 5) {
                Text(payout.paidAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                Text(payout.status).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text(formatPRL(payout.amount, digits: 4)).font(.subheadline).monospacedDigit()
              if let url = payout.explorerURL {
                Link(destination: url) { Image(systemName: "arrow.up.right").padding(6) }
                  .accessibilityLabel("View payout transaction")
              }
            }
          }
          if let count = pearl?.payoutCount, count > payouts.count {
            Text("\(payouts.count) of \(count) payouts").font(.caption).foregroundStyle(.secondary)
          }
        } else { Text("Payout history unavailable.").font(.subheadline).foregroundStyle(.secondary) }
      }
      .privacySensitive()
    }
  }

  private func krakenDetails(_ provider: Provider, summary: MobileSummary) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      if let kraken = provider.kraken {
        Text("Since 00:00 UTC · \(kraken.money.local(kraken.accountChange))")
          .font(.subheadline).foregroundStyle(.secondary)
        ForEach(kraken.assets) { asset in
          VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
              Text(asset.symbol).font(.title3.weight(.medium))
              Spacer()
              Text(kraken.money.local(asset.value)).font(.title3.weight(.medium)).monospacedDigit()
            }
            detailRow("Balance", formatQuantity(asset.amount, decimals: asset.decimals))
            if asset.earn > 0 { detailRow("Earn", formatQuantity(asset.earn, decimals: asset.decimals)) }
            detailRow("Price", formatPrice(asset.price, money: kraken.money))
            detailRow("Today", asset.change.map { formatChange($0) } ?? "—")
            if let market = asset.market { Text(market).font(.caption2).foregroundStyle(.tertiary) }
            Divider().padding(.top, 8)
          }
        }
        if kraken.assets.isEmpty { Text("No holdings.").foregroundStyle(.secondary) }
      } else { Text("Portfolio unavailable.").foregroundStyle(.secondary) }
    }
    .privacySensitive()
  }

  private func powerDetails(_ provider: Provider, summary: MobileSummary) -> some View {
    VStack(alignment: .leading, spacing: 30) {
      detailSection("At current draw") {
        detailRow("Tariff / kWh", summary.powerMoney.local(snapshot.preferences.power.pricePerKWh, digits: 4))
        ForEach(ProjectionPeriod.allCases) { period in
          detailRow(period == .month ? "30 days" : period.title,
            summary.powerMoney.local(summary.displayCostPerDay.map { $0 * period.days }))
        }
        Text("Assumes constant draw. Negative watts indicate export; export credits are excluded.")
          .font(.caption).foregroundStyle(.secondary)
      }
      detailSection("Meters") {
        ForEach(snapshot.preferences.power.devices) { device in
          let reading = provider.powerDevices?.first { $0.id == device.id }
          VStack(alignment: .leading, spacing: 8) {
            detailRow(device.name, summary.watts(device.id).map { String(format: "%.0f W", $0) } ?? "—")
            Text(device.assignment.title).font(.caption).foregroundStyle(.secondary)
            if let timestamp = reading?.updatedAt { sourceNote("Reading", timestamp: timestamp) }
            if let error = reading?.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            Divider().padding(.top, 5)
          }
        }
        if snapshot.preferences.power.devices.isEmpty {
          Text("Add a HomeWizard meter on your Mac.").font(.subheadline).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func vastDetails(_ provider: Provider, summary: MobileSummary) -> some View {
    VStack(alignment: .leading, spacing: 30) {
      detailSection("Earnings") {
        projectionRow("Today", revenue: summary.money.local(summary.vastGross.today), net: summary.money.local(summary.vastNet.today))
        projectionRow("Per hour", revenue: summary.money.local(summary.vastGross.hourly), net: summary.money.local(summary.vastNet.hourly))
        projectionRow("7d average", revenue: summary.money.local(summary.vastGross.average), net: summary.money.local(summary.vastNet.average))
        detailRow("7-day total", summary.money.format(provider.sevenDayTotal))
        detailRow("Power / day", summary.money.local(summary.powerCost(.vast)))
        if let days = provider.daily, !days.isEmpty {
          Chart(days) { day in
            BarMark(x: .value("Date", day.date, unit: .day), y: .value("Earnings", day.amount * summary.money.factor))
              .foregroundStyle(summary.tint.opacity(0.65)).cornerRadius(3)
              .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
              .accessibilityValue(summary.money.format(day.amount))
          }
          .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
          .chartYAxis(.hidden)
          .frame(height: 110)
          .padding(.vertical, 8)
          ForEach(days) { day in
            detailRow(day.date.formatted(date: .abbreviated, time: .omitted), summary.money.format(day.amount))
          }
        }
        if let breakdown = provider.earningsBreakdown {
          detailRow("GPU", summary.money.format(breakdown.gpu))
          detailRow("Storage", summary.money.format(breakdown.storage))
          detailRow("Network", summary.money.format(breakdown.network))
          detailRow("Adjustments", summary.money.format(breakdown.adjustments))
        }
        if let start = provider.billingStart, let end = provider.billingEnd {
          Text("Billing \(Date(timeIntervalSince1970: start).formatted(date: .abbreviated, time: .omitted)) – \(Date(timeIntervalSince1970: end).formatted(date: .abbreviated, time: .omitted))")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .privacySensitive()
      detailSection("Machines") {
        detailRow("Rented", provider.rentedCount.map(String.init) ?? "—")
        detailRow("Total", provider.machineCount.map(String.init) ?? "—")
        detailRow("Utilization", provider.utilizationAverage.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
        if let days = provider.utilizationDays {
          Text(days == 0 ? "Utilization today" : "Utilization over \(days) complete UTC days")
            .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(provider.machines ?? []) { machine in
          machineDetails(machine, summary: summary)
        }
        if let error = provider.utilizationError { Text(error).font(.caption).foregroundStyle(.secondary) }
      }
    }
  }

  private func machineDetails(_ machine: Machine, summary: MobileSummary) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Divider().padding(.vertical, 4)
      Text(machine.name).font(.body.weight(.medium))
      Text(machine.gpuCount.map { "\(Int($0)) × \(machine.gpu)" } ?? machine.gpu)
        .font(.subheadline).foregroundStyle(.secondary)
      detailRow("Status", machine.status)
      detailRow("Running", machine.running.map { String(format: "%.0f", $0) } ?? "—")
      detailRow("Stored", machine.stored.map { String(format: "%.0f", $0) } ?? "—")
      detailRow("Estimated / hour", summary.money.format(machine.estimatedHourly))
      detailRow("Reported / hour", summary.money.format(machine.reportedHourly))
      detailRow("Reported / day", summary.money.format(machine.reportedDaily))
      detailRow("Listed / hour", summary.money.format(machine.listedHourly))
      detailRow("Utilization", machine.utilization.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
      detailRow("Temperature", machine.gpuTemperature.map { String(format: "%.0f °C", $0) } ?? "—")
      detailRow("Reliability", machine.reliability.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
      if let cpu = machine.cpu { detailRow("CPU", cpu) }
      if let verification = machine.verification { detailRow("Verification", verification) }
      if let listed = machine.listed { detailRow("Listed", listed ? "Yes" : "No") }
    }
  }
}

private func sectionTitle(_ title: String) -> some View {
  Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
}

private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
  VStack(alignment: .leading, spacing: 17) {
    sectionTitle(title).padding(.bottom, 3)
    content()
  }
}

private func detailRow(_ label: String, _ value: String) -> some View {
  ViewThatFits(in: .horizontal) {
    HStack(alignment: .firstTextBaseline, spacing: 20) {
      Text(label).foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(value).monospacedDigit().multilineTextAlignment(.trailing)
    }
    VStack(alignment: .leading, spacing: 5) {
      Text(label).foregroundStyle(.secondary)
      Text(value).monospacedDigit()
    }
  }
  .font(.subheadline)
  .accessibilityElement(children: .combine)
}

private func projectionRow(_ label: String, revenue: String, net: String) -> some View {
  VStack(alignment: .leading, spacing: 8) {
    Text(label).font(.subheadline.weight(.medium))
    HStack(alignment: .firstTextBaseline) {
      Text(revenue).monospacedDigit()
      Text("gross").foregroundStyle(.tertiary)
      Spacer(minLength: 10)
      Text(net).monospacedDigit()
      Text("net").foregroundStyle(.tertiary)
    }
    .font(.subheadline)
  }
  .accessibilityElement(children: .combine)
}

private func sourceNote(_ label: String, timestamp: Double) -> some View {
  Text("\(label) · \(Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened))")
    .font(.caption2).foregroundStyle(.tertiary)
}
