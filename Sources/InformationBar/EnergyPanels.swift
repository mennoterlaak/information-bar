import SwiftUI

struct PearlMenu: View {
  let provider: Provider
  let options: ProviderPreferences
  let power: PowerContext
  private var money: MoneyFormat { MoneyFormat(currency: options.currency, rates: provider.rates) }
  private var projection: MiningProjection { provider.pearlProjection(options, power: power) }
  /// Nil while stale, so every figure shows a dash instead of an outdated value.
  private var pearl: PearlMetrics? { provider.isFresh ? provider.pearl : nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      projectionTable
      if projection.powerPerDay == nil {
        menuNote("Profit needs a tariff and a meter assigned to Pearl in Power Settings.")
      }
      MenuSeparator()
      MenuSectionLabel(title: "Mining")
      MenuValueRow(title: "PRL price", value: money.format(pearl?.priceUSD, digits: 3))
      MenuValueRow(
        title: "Hashrate 3h · 24h", value: formatHashrates(pearl?.hashrate3h, pearl?.hashrate24h)
      )
      .help("Kryptex's accepted-share averages. The headline is the 30-minute average.")
      MenuValueRow(
        title: "Yield", value: pearl?.coinsPerDay.map { String(format: "%.2f PRL/day", $0) } ?? "—"
      )
      .help(yieldHelp)
      MenuSeparator()
      balances
      MenuSeparator()
      payouts
    }
  }

  /// Same layout as the Vast.ai earnings table: label column, then left-aligned figures.
  private var projectionTable: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
      GridRow {
        Text("Projection").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
        Text("Revenue").font(.system(size: 11)).foregroundStyle(.secondary)
        Text("Profit").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      ForEach(ProjectionPeriod.allCases) { period in
        GridRow {
          Text(period.title).font(.system(size: 13)).foregroundStyle(.secondary)
          Text(money.local(projection.revenuePerDay.map { $0 * period.days }))
          Text(money.local(projection.netPerDay.map { $0 * period.days }))
        }
        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
      }
      if let cost = projection.powerPerDay {
        GridRow {
          Text("Power").font(.system(size: 13)).foregroundStyle(.secondary)
          Text("")
          Text("-" + money.local(cost) + "/day").font(.system(size: 13)).monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.horizontal, MenuMetrics.inset).padding(.top, 2).padding(.bottom, 4)
    .help(
      "Mining continuously at the current price, yield and draw. Profit deducts the electricity assigned to Pearl; hardware, tax and exchange costs are excluded. Monthly is 30 days."
    )
  }

  private var yieldHelp: String {
    var text = "Projected PRL per day from the 30-minute hashrate and Kryptex's PPS+ rate"
    if let fee = pearl?.poolFeePercent { text += String(format: ", after the %.2g%% pool fee", fee) }
    return text + ". The miner's developer fee is already reflected in the accepted hashrate."
  }

  private var balances: some View {
    VStack(alignment: .leading, spacing: 0) {
      MenuSectionLabel(title: "Balances")
      MenuValueRow(
        title: "Wallet", value: formatPRL(pearl?.walletBalance, digits: 4),
        detail: worth(pearl?.walletBalance)
      )
      .help(
        "Confirmed balance at your mining address on Pearl's explorer: "
          + formatPRL(pearl?.walletBalance))
      MenuValueRow(
        title: "Unpaid rewards", value: formatPRL(pearl?.poolBalance, digits: 4),
        detail: worth(pearl?.poolBalance)
      )
      .help(
        formatPRL(pearl?.poolBalance) + " held by Kryptex: " + formatPRL(pearl?.poolConfirmed)
          + " confirmed, " + formatPRL(pearl?.poolUnconfirmed) + " still maturing.")
      if let confirmed = pearl?.poolConfirmed, let threshold = pearl?.payoutThreshold,
        threshold > 0
      {
        VStack(alignment: .leading, spacing: 4) {
          CapacityBar(fraction: confirmed / threshold, tint: .provider("pearl"))
          Text(
            confirmed >= threshold
              ? "Payout threshold reached"
              : String(
                format: "%.2f of %.2f PRL confirmed for the next payout", confirmed, threshold)
          )
          .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, MenuMetrics.inset).padding(.top, 2).padding(.bottom, 4)
        .accessibilityElement(children: .combine)
      }
      MenuValueRow(title: "Total paid", value: formatPRL(pearl?.totalPaid, digits: 4))
        .help("All-time payouts reported by Kryptex: " + formatPRL(pearl?.totalPaid))
    }
  }

  /// Current market value of a PRL amount, or nil when either figure is unknown.
  private func worth(_ amount: Double?) -> String? {
    guard let amount, let price = pearl?.priceUSD else { return nil }
    return money.format(amount * price)
  }

  private var payoutCountLabel: String {
    guard let shown = pearl?.payouts?.count, let total = pearl?.payoutCount, total > shown else {
      return ""
    }
    return "\(shown) of \(total)"
  }

  private var payouts: some View {
    VStack(alignment: .leading, spacing: 0) {
      MenuSectionLabel(title: "Recent payouts", trailing: payoutCountLabel)
      if let payouts = pearl?.payouts {
        if payouts.isEmpty { menuNote("No payouts yet.") }
        ForEach(payouts) { PayoutRow(payout: $0) }
      } else {
        menuNote("Payout history unavailable.")
      }
    }
  }
}

struct PayoutRow: View {
  let payout: PearlPayout
  private var failed: Bool { ["Failed", "Rejected", "Cancelled"].contains(payout.status) }

  var body: some View {
    HStack(spacing: 8) {
      Text(payout.paidAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
        .foregroundStyle(.secondary)
      Text(payout.status).foregroundStyle(failed ? Color.orange : Color.secondary)
      Spacer(minLength: 4)
      Text(formatPRL(payout.amount, digits: 4)).monospacedDigit()
      // Rows without a transaction keep the space so amounts stay aligned.
      if let url = payout.explorerURL {
        Link(destination: url) { Image(systemName: "arrow.up.right") }
          .help("View the payout transaction")
          .accessibilityLabel("View the payout transaction")
      } else {
        Image(systemName: "arrow.up.right").hidden()
      }
    }
    .font(.system(size: 12)).lineLimit(1)
    .padding(.horizontal, MenuMetrics.inset).padding(.vertical, 3)
    .help(formatPRL(payout.amount) + " · status reported by Kryptex")
  }
}

struct PowerMenu: View {
  let power: PowerContext
  private var selectedName: String {
    power.preferences.devices.first { $0.id == power.preferences.displayDeviceID }?.name
      ?? "Assigned loads"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      MenuRow(title: selectedName, lines: ["Current draw"]) {
        MenuBadge { Image(systemName: "bolt.fill").foregroundStyle(Color.provider("power")) }
      } trailing: {
        Text(power.displayWatts.map { String(format: "%.0f W", $0) } ?? "—")
          .font(.system(size: 15, weight: .semibold)).monospacedDigit()
      }
      if let price = power.preferences.pricePerKWh {
        menuNote(power.money.local(price, digits: 4) + "/kWh")
      } else {
        menuNote("Set your electricity tariff in Power Settings.")
      }
      if let cost = power.displayCostPerDay {
        MenuSeparator()
        MenuSectionLabel(title: "Cost at current draw").help("Monthly is 30 days.")
        ForEach(ProjectionPeriod.allCases) { period in
          HStack {
            Text(period.title).foregroundStyle(.secondary)
            Spacer()
            Text(power.money.local(cost * period.days)).monospacedDigit()
          }.font(.system(size: 12)).padding(.horizontal, MenuMetrics.inset).padding(.vertical, 3)
        }
      }
      if !power.preferences.devices.isEmpty {
        MenuSeparator()
        MenuSectionLabel(title: "HomeWizard meters")
        ForEach(power.preferences.devices) { device in
          let reading = power.reading(device.id)
          MenuRow(title: device.name, lines: [device.assignment.title]) {
            MenuBadge { Image(systemName: "powerplug").foregroundStyle(.secondary) }
          } trailing: {
            Text(
              (power.provider?.isFresh == true ? reading?.currentWatts : nil).map {
                String(format: "%.0f W", $0)
              } ?? "—"
            )
            .font(.system(size: 13)).monospacedDigit()
          }
          if let error = reading?.error { menuNote(error) }
        }
      } else {
        menuNote("Search for HomeWizard meters in Power Settings to read your power usage.")
      }
      menuNote(
        "Costs assume constant draw. Negative watts indicate export; export credits are excluded.")
    }
  }
}
