import Foundation
import SwiftUI

/// Presentation shared by the app and its widgets. Dates belong to the original source,
/// never to the phone's last successful download.
struct MobileMetric: Identifiable {
  let label: String
  let value: String
  var id: String { label }
}

struct MobileSummary {
  let snapshot: MobileSnapshot
  let category: ProviderCategory
  var date = Date()

  var provider: Provider? { snapshot.provider(category) }
  var options: ProviderPreferences { snapshot.preferences.provider(category) }
  var money: MoneyFormat { MoneyFormat(currency: options.currency, rates: provider?.rates) }
  var isFresh: Bool { provider?.mobileIsFresh(at: date, interval: interval) == true }
  var interval: Int { max(15, snapshot.preferences.refreshInterval) }
  var sourceDate: Date? { provider?.updatedAt.map(Date.init(timeIntervalSince1970:)) }
  var title: String { category == .kraken ? "Portfolio" : category.name }
  var isFinancial: Bool { !category.isSubscription && category != .power }
  var tint: Color { category.mobileTint }

  var freshness: String {
    guard let sourceDate else { return "Not connected" }
    let age = max(0, date.timeIntervalSince(sourceDate))
    let duration: String
    if age < 60 { duration = "just now" }
    else if age < 3600 { duration = "\(Int(age / 60))m ago" }
    else if age < 86400 { duration = "\(Int(age / 3600))h ago" }
    else { duration = "\(Int(age / 86400))d ago" }
    return isFresh ? duration : "Stale · \(duration)"
  }

  var selectedWindow: UsageWindow? {
    provider?.visibleWindows.filter { window in
      window.resetDate.map { $0 > date } ?? true
    }.max { $0.usedPercent < $1.usedPercent }
  }

  var primary: String {
    switch category {
    case .codex, .claude, .cursor: return selectedWindow?.percent ?? "—"
    case .kraken:
      return provider?.kraken.map { $0.money.local($0.accountValue) } ?? "—"
    case .pearl: return formatHashrate(provider?.pearl?.hashrate)
    case .power: return displayWatts.map { String(format: "%.0f W", $0) } ?? "—"
    case .vast: return money.local(vastShown.today)
    }
  }

  var subtitle: String {
    switch category {
    case .codex, .claude, .cursor:
      return selectedWindow.map { "\($0.shortLabel) used" } ?? "Usage unavailable"
    case .kraken:
      guard let change = provider?.kraken?.changeFraction else { return "Change unavailable" }
      return "\(formatChange(change)) today"
    case .pearl:
      return "\(provider?.pearl?.effectiveAverageWindow.rawValue ?? "7d") average"
    case .power: return snapshot.preferences.power.displayDeviceID.flatMap { id in
      snapshot.preferences.power.devices.first { $0.id == id }?.name
    } ?? "Assigned loads"
    case .vast: return options.earningsView == .net ? "Net today" : "Earned today"
    }
  }

  var progress: Double? {
    if category.isSubscription { return selectedWindow.map { min(1, max(0, $0.usedPercent / 100)) } }
    if category == .vast { return provider?.utilizationAverage }
    if category == .pearl, let balance = provider?.pearl?.poolConfirmed,
      let threshold = provider?.pearl?.payoutThreshold, threshold > 0
    { return min(1, max(0, balance / threshold)) }
    return nil
  }

  var metrics: [MobileMetric] {
    switch category {
    case .codex, .claude, .cursor:
      return (provider?.visibleWindows ?? []).map {
        MobileMetric(label: $0.shortLabel, value: $0.resetDate.map { $0 <= date } == true ? "Awaiting reset" : $0.percent)
      }
    case .kraken:
      guard let kraken = provider?.kraken else { return [] }
      return kraken.assets.map { MobileMetric(label: $0.symbol, value: kraken.money.local($0.value)) }
    case .pearl:
      return [
        MobileMetric(label: "PRL", value: money.format(provider?.pearl?.priceUSD, digits: 3)),
        MobileMetric(label: "Net / day", value: money.local(projection.netPerDay)),
        MobileMetric(label: "Wallet", value: formatPRL(provider?.pearl?.walletBalance, digits: 2)),
        MobileMetric(label: "Unpaid", value: formatPRL(provider?.pearl?.poolBalance, digits: 2)),
      ]
    case .power:
      return [
        MobileMetric(label: "Cost / day", value: powerMoney.local(displayCostPerDay)),
        MobileMetric(label: "/ kWh", value: powerMoney.local(snapshot.preferences.power.pricePerKWh, digits: 3)),
      ]
    case .vast:
      return [
        MobileMetric(label: "Rented", value: provider.flatMap { provider in
          guard let rented = provider.rentedCount, let total = provider.machineCount else { return nil }
          return "\(rented) / \(total)"
        } ?? "—"),
        MobileMetric(label: "/ hour", value: money.local(vastShown.hourly)),
        MobileMetric(label: "7d average", value: money.local(vastShown.average)),
      ]
    }
  }

  var powerMoney: MoneyFormat { MoneyFormat(currency: snapshot.preferences.power.currency, rates: ["EUR": 1]) }

  func watts(_ id: String) -> Double? {
    guard let power = snapshot.provider(.power), power.mobileIsFresh(at: date, interval: interval),
      let reading = power.powerDevices?.first(where: { $0.id == id }), reading.status == "ok",
      let updatedAt = reading.updatedAt,
      date.timeIntervalSince1970 - updatedAt >= -60,
      date.timeIntervalSince1970 - updatedAt < Double(3 * interval),
      let watts = reading.watts, watts.isFinite
    else { return nil }
    return watts
  }

  func assignedWatts(_ category: ProviderCategory) -> Double? {
    let devices = snapshot.preferences.power.devices.filter { $0.assignment.rawValue == category.rawValue }
    guard !devices.isEmpty else { return nil }
    let values = devices.compactMap { watts($0.id) }
    guard values.count == devices.count else { return nil }
    return values.reduce(0) { $0 + max(0, $1) }
  }

  var displayWatts: Double? {
    if let id = snapshot.preferences.power.displayDeviceID { return watts(id) }
    let assigned = [ProviderCategory.pearl, .vast].filter { category in
      snapshot.preferences.power.devices.contains { $0.assignment.rawValue == category.rawValue }
    }
    guard !assigned.isEmpty else { return nil }
    let values = assigned.compactMap(assignedWatts)
    return values.count == assigned.count ? values.reduce(0, +) : nil
  }

  var displayCostPerDay: Double? {
    guard let watts = displayWatts, let tariff = snapshot.preferences.power.pricePerKWh,
      tariff.isFinite, tariff >= 0 else { return nil }
    return max(0, watts) / 1000 * 24 * tariff
  }

  func powerCost(_ category: ProviderCategory) -> Double? {
    guard let watts = assignedWatts(category),
      let tariff = snapshot.power.tariff(in: money.code, rates: provider?.rates)
    else { return nil }
    return watts / 1000 * 24 * tariff
  }

  var projection: MiningProjection {
    var revenue: Double?
    if isFresh, let coins = provider?.pearl?.coinsPerDay, let price = provider?.pearl?.priceUSD,
      coins.isFinite, price.isFinite, coins >= 0, price >= 0
    { revenue = coins * price * money.factor }
    return MiningProjection(revenuePerDay: revenue, powerPerDay: powerCost(.pearl))
  }

  var vastGross: EarningsFigures.Set {
    EarningsFigures.Set(today: provider?.todayEarnings.map { $0 * money.factor },
      hourly: provider?.estimatedHourly.map { $0 * money.factor },
      average: provider?.sevenDayAverage.map { $0 * money.factor })
  }

  var vastNet: EarningsFigures.Set {
    guard isFresh, let cost = powerCost(.vast) else {
      return EarningsFigures.Set(today: nil, hourly: nil, average: nil)
    }
    let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) / 86400
    return EarningsFigures.Set(today: vastGross.today.map { $0 - cost * elapsed },
      hourly: vastGross.hourly.map { $0 - cost / 24 }, average: vastGross.average.map { $0 - cost })
  }

  var vastShown: EarningsFigures.Set { options.earningsView == .net ? vastNet : vastGross }
}

extension Provider {
  func mobileIsFresh(at date: Date, interval: Int) -> Bool {
    guard status == "ok" || status == "partial", let updatedAt else { return false }
    let age = date.timeIntervalSince1970 - updatedAt
    return age >= -60 && age < Double(3 * interval + (id == "claude" ? 300 : 0))
  }
}

extension ProviderCategory {
  var mobileTint: Color {
    switch self {
    case .codex: return Color(red: 0.15, green: 0.47, blue: 0.40)
    case .claude: return Color(red: 0.69, green: 0.40, blue: 0.28)
    case .cursor: return Color(red: 0.37, green: 0.41, blue: 0.48)
    case .pearl: return Color(red: 0.15, green: 0.48, blue: 0.43)
    case .kraken: return Color(red: 0.47, green: 0.38, blue: 0.66)
    case .power: return Color(red: 0.66, green: 0.49, blue: 0.15)
    case .vast: return Color(red: 0.28, green: 0.46, blue: 0.64)
    }
  }

  var mobileSymbol: String {
    switch self {
    case .codex: return "circle.hexagongrid"
    case .claude: return "sun.max"
    case .cursor: return "cursorarrow"
    case .pearl: return "circle.dotted.circle"
    case .kraken: return "chart.line.uptrend.xyaxis"
    case .power: return "bolt"
    case .vast: return "server.rack"
    }
  }
}

struct MobileProgress: View {
  let fraction: Double
  var tint: Color = .accentColor

  var body: some View {
    GeometryReader { geometry in
      Capsule().fill(tint.opacity(0.12))
        .overlay(alignment: .leading) {
          Capsule().fill(tint).frame(width: geometry.size.width * min(1, max(0, fraction)))
        }
    }
    .frame(height: 4)
    .accessibilityHidden(true)
  }
}

struct MobileSourceStamp: View {
  let summary: MobileSummary

  var body: some View {
    HStack(spacing: 5) {
      if !summary.isFresh { Image(systemName: "clock").accessibilityHidden(true) }
      Text(summary.freshness)
    }
    .font(.caption2)
    .foregroundStyle(summary.isFresh ? Color.secondary : Color.orange)
    .accessibilityLabel("\(summary.title), \(summary.freshness)")
  }
}
