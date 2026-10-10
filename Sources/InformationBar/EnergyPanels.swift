import SwiftUI

struct PearlMenu: View {
  let provider: Provider
  let options: ProviderPreferences
  let power: PowerContext
  private var money: MoneyFormat { MoneyFormat(currency: options.currency, rates: provider.rates) }
  private var projection: MiningProjection { provider.pearlProjection(options, power: power) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      metric(
        "PRL price", value: money.format(provider.pearl?.priceUSD, digits: 3),
        symbol: "dollarsign.circle")
      metric("Pool hashrate · 30m", value: formatHashrate(provider.pearl?.hashrate), symbol: "speedometer")
      if provider.isFresh {
        if let rate3h = provider.pearl?.hashrate3h, let rate24h = provider.pearl?.hashrate24h {
          menuNote("3h " + formatHashrate(rate3h) + " · 24h " + formatHashrate(rate24h))
        }
        if let online = provider.pearl?.onlineWorkers, let count = provider.pearl?.workerCount {
          menuNote("Kryptex · \(online)/\(count) workers online")
        }
      }
      if let coins = provider.pearl?.coinsPerDay, provider.isFresh {
        menuNote(String(format: "≈ %.4f PRL/day after pool fee", coins))
      }
      MenuSeparator()
      walletSection
      MenuSeparator()
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
        GridRow {
          Text("Projections")
          Text("Revenue")
          Text("Profit")
        }.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        ForEach(ProjectionPeriod.allCases) { period in
          GridRow {
            Text(period.title).foregroundStyle(.secondary)
            Text(money.local(projection.revenuePerDay.map { $0 * period.days }))
            Text(money.local(projection.netPerDay.map { $0 * period.days }))
              .fontWeight(.semibold)
          }.font(.system(size: 12)).monospacedDigit()
        }
      }.padding(.horizontal, MenuMetrics.inset).padding(.vertical, 6)
      if let cost = projection.powerPerDay {
        menuNote("Power ≈ " + money.local(cost) + "/day")
      } else {
        menuNote("Set a tariff and assign power to Pearl in Power Settings to see profit.")
      }
      if let poolFee = provider.pearl?.poolFeePercent {
        menuNote(String(format: "Pool fee %.2g%% · Developer fee reflected in hashrate", poolFee))
      }
      menuNote(
        "At current price, yield and draw, mining continuously. Profit is after fees and power; other costs excluded."
      )
      MenuSeparator()
      payoutSection
    }
  }

  private var walletSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      metric("Wallet balance", value: formatPRL(provider.pearl?.walletBalance), symbol: "wallet.pass")
      menuNote("Confirmed on-chain at your mining address.")
      metric("Unpaid pool rewards", value: formatPRL(provider.pearl?.poolBalance), symbol: "hourglass")
      if provider.isFresh {
        if let confirmed = provider.pearl?.poolConfirmed,
          let unconfirmed = provider.pearl?.poolUnconfirmed
        {
          menuNote("Confirmed " + formatPRL(confirmed) + "\nMaturing " + formatPRL(unconfirmed))
        }
        if let threshold = provider.pearl?.payoutThreshold {
          menuNote("Payout threshold: " + formatPRL(threshold, digits: 2) + " confirmed.")
        }
      }
    }
  }

  private var payoutSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      metric("Total paid by pool", value: formatPRL(provider.pearl?.totalPaid), symbol: "arrow.down.circle")
      MenuSectionLabel(title: "Recent payouts").padding(.top, 6)
      if provider.isFresh, let payouts = provider.pearl?.payouts {
        if payouts.isEmpty {
          menuNote("No payouts yet.")
        } else {
          ForEach(payouts) { payout in
            HStack(alignment: .top, spacing: 8) {
              VStack(alignment: .leading, spacing: 2) {
                Text(payout.paidAt.formatted(.dateTime.year().month(.abbreviated).day().hour().minute()))
                Text(payout.status).font(.system(size: 10)).foregroundStyle(.secondary)
              }
              Spacer(minLength: 4)
              Text(formatPRL(payout.amount)).monospacedDigit().fixedSize()
              if let url = payout.explorerURL {
                Link(destination: url) {
                  Image(systemName: "arrow.up.right")
                }
                .help("View payout transaction")
                .accessibilityLabel("View payout transaction")
              }
            }
            .font(.system(size: 11))
            .padding(.horizontal, MenuMetrics.inset).padding(.vertical, 4)
          }
          if let count = provider.pearl?.payoutCount, count > payouts.count {
            menuNote("Showing latest \(payouts.count) of \(count) payouts.")
          }
          menuNote("Payout statuses are reported by Kryptex.")
        }
      } else {
        menuNote("Payout history unavailable.")
      }
    }
  }

  private func metric(_ title: String, value: String, symbol: String) -> some View {
    MenuRow(title: title) {
      MenuBadge { Image(systemName: symbol).foregroundStyle(Color.provider("pearl")) }
    } trailing: {
      Text(provider.isFresh ? value : "—").font(.system(size: 13, weight: .semibold))
        .monospacedDigit().fixedSize(horizontal: true, vertical: false)
    }
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
        MenuSectionLabel(title: "Cost at current draw")
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
