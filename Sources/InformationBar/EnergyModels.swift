import Foundation

enum PearlAverageWindow: String, Codable, CaseIterable {
  case thirtyMinutes = "30m", threeHours = "3h", day = "24h", week = "7d"

  var title: String {
    switch self {
    case .thirtyMinutes: return "30 minutes"
    case .threeHours: return "3 hours"
    case .day: return "24 hours"
    case .week: return "7 days"
    }
  }

  var averageDescription: String {
    switch self {
    case .thirtyMinutes: return "30-minute average"
    case .threeHours: return "3-hour average"
    case .day: return "24-hour average"
    case .week: return "7-day average"
    }
  }
}

struct PearlPreferences: Codable, Equatable {
  var walletAddress = ""
  /// Empty includes all workers mining to this wallet.
  var workerName = ""
  var averageWindow = PearlAverageWindow.week

  enum CodingKeys: String, CodingKey { case walletAddress, workerName, averageWindow }

  init() {}

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    // Ignore retired local API settings without resetting the user's other preferences.
    walletAddress = try values.decodeIfPresent(String.self, forKey: .walletAddress) ?? ""
    workerName = try values.decodeIfPresent(String.self, forKey: .workerName) ?? ""
    let savedWindow = try values.decodeIfPresent(String.self, forKey: .averageWindow)
    averageWindow = savedWindow.flatMap(PearlAverageWindow.init(rawValue:)) ?? .week
  }

  var validationError: String? {
    guard walletAddress.range(of: "^prl1[0-9a-z]{20,120}$", options: .regularExpression) != nil else {
      return "Enter the public PRL wallet address used for mining on Kryptex."
    }
    return nil
  }
}

enum PowerAssignment: String, Codable, CaseIterable {
  case none, pearl, vast
  var title: String {
    switch self {
    case .none: return "Monitor only"
    case .pearl: return "Pearl mining"
    case .vast: return "Vast.ai hosting"
    }
  }
}

struct HomeWizardDevice: Codable, Equatable, Identifiable {
  var id = UUID().uuidString
  var name = "HomeWizard"
  var address = ""
  var apiVersion = "v1"
  var productType = "p1dongle"
  var serial = ""
  var assignment = PowerAssignment.none

  var credentialAccount: String { "homewizard-" + id }

  var endpointIdentity: String? {
    let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URLComponents(string: raw.contains("://") ? raw : "http://" + raw),
      let host = url.host
    else { return nil }
    let port = url.port.flatMap { [80, 443].contains($0) ? nil : $0 }
    return host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      + (port.map { ":\($0)" } ?? "")
  }

  var validationError: String? {
    let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
    let scheme = apiVersion == "v2" ? "https" : "http"
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !raw.isEmpty,
      let url = URLComponents(string: raw.contains("://") ? raw : scheme + "://" + raw),
      url.scheme == scheme, let host = url.host, !host.isEmpty,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      ["", "/", apiVersion == "v2" ? "/api/measurement" : "/api/v1/data"].contains(url.path)
    else { return "Enter a name and a device address using \(scheme)." }
    if apiVersion == "v2" && (serial.count != 12 || !serial.allSatisfy(\.isHexDigit)) {
      return "Enter the device's 12-character serial number for its secure connection."
    }
    return nil
  }
}

struct PowerPreferences: Codable, Equatable {
  var currency = "USD"
  var pricePerKWh: Double?
  var devices: [HomeWizardDevice] = []
  /// Nil displays the sum of assigned loads; selecting a meter displays that meter alone.
  var displayDeviceID: String?

  func alreadyContains(_ device: HomeWizardDevice) -> Bool {
    devices.contains {
      $0.id != device.id
        && (($0.endpointIdentity != nil && $0.endpointIdentity == device.endpointIdentity)
          || (!device.serial.isEmpty && $0.serial.lowercased() == device.serial.lowercased()))
    }
  }
}

struct PowerReading: Decodable, Identifiable {
  let id: String
  let name: String
  let watts: Double?
  let status: String
  let updatedAt: Double?
  let error: String?

  var currentWatts: Double? {
    guard status == "ok", let updatedAt,
      Date().timeIntervalSince1970 - updatedAt < Freshness.staleAfter("power")
    else { return nil }
    return watts
  }
}

struct PearlMetrics: Decodable {
  let priceUSD: Double?
  let priceUpdatedAt: Double?
  let hashrate: Double?
  let averageWindow: PearlAverageWindow?
  let hashrate30m: Double?
  let hashrate3h: Double?
  let hashrate24h: Double?
  let hashrate7d: Double?
  let historyUpdatedAt: Double?
  let onlineWorkers: Int?
  let workerCount: Int?
  let coinsPerDay: Double?
  let poolFeePercent: Double?
  let walletBalance: Double?
  let poolBalance: Double?
  let poolConfirmed: Double?
  let poolUnconfirmed: Double?
  let payoutThreshold: Double?
  let totalPaid: Double?
  let payoutCount: Int?
  let payouts: [PearlPayout]?

  // Cached metrics from older app versions always used the 30-minute rate.
  var effectiveAverageWindow: PearlAverageWindow { averageWindow ?? .thirtyMinutes }
  var shortHashrate: Double? { hashrate30m ?? (averageWindow == nil ? hashrate : nil) }
}

struct PearlPayout: Decodable, Identifiable {
  let id: String
  let date: Double
  let amount: Double
  let status: String
  let txid: String?

  var paidAt: Date { Date(timeIntervalSince1970: date) }

  var explorerURL: URL? {
    guard let txid,
      txid.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    else { return nil }
    return URL(string: "https://explorer.pearlresearch.ai/tx/\(txid)?network=mainnet")
  }
}

enum ProjectionPeriod: String, CaseIterable, Identifiable {
  case hour, day, week, month
  var id: String { rawValue }
  var title: String {
    switch self {
    case .hour: return "Hourly"
    case .day: return "Daily"
    case .week: return "Weekly"
    case .month: return "Monthly"
    }
  }
  var days: Double {
    switch self {
    case .hour: return 1 / 24
    case .day: return 1
    case .week: return 7
    case .month: return 30
    }
  }
  var suffix: String {
    switch self {
    case .hour: return "/h"
    case .day: return "/d"
    case .week: return "/wk"
    case .month: return "/mo"
    }
  }
  init(_ element: MenuElementKind) {
    switch element {
    case .profitHourly: self = .hour
    case .profitWeekly: self = .week
    case .profitMonthly: self = .month
    default: self = .day
    }
  }
}

struct MiningProjection {
  let revenuePerDay: Double?
  let powerPerDay: Double?
  var netPerDay: Double? {
    guard let revenuePerDay, let powerPerDay else { return nil }
    return revenuePerDay - powerPerDay
  }
}

/// Shared power settings and current readings, independent of any revenue provider.
struct PowerContext {
  var preferences: PowerPreferences
  var provider: Provider?
  static let empty = PowerContext(preferences: .init())

  var money: MoneyFormat { MoneyFormat(currency: preferences.currency, rates: ["EUR": 1]) }

  func reading(_ id: String) -> PowerReading? { provider?.powerDevices?.first { $0.id == id } }

  func watts(for category: ProviderCategory) -> Double? {
    let devices = preferences.devices.filter { $0.assignment.rawValue == category.rawValue }
    guard !devices.isEmpty, provider?.isFresh == true else { return nil }
    let values = devices.compactMap { reading($0.id)?.currentWatts }
    guard values.count == devices.count else { return nil }
    return values.reduce(0) { $0 + max(0, $1) }
  }

  func tariff(in code: String, rates: [String: Double]?) -> Double? {
    guard let price = preferences.pricePerKWh, price >= 0, price.isFinite else { return nil }
    if price == 0 || code == preferences.currency { return price }
    guard let eur = rates?["EUR"] ?? provider?.rates?["EUR"], eur > 0, eur.isFinite else {
      return nil
    }
    return preferences.currency == "EUR" ? price / eur : price * eur
  }

  func dailyCost(
    for category: ProviderCategory,
    money: MoneyFormat, rates: [String: Double]?
  ) -> Double? {
    guard let watts = watts(for: category), watts >= 0, watts.isFinite,
      let price = tariff(in: money.code, rates: rates)
    else { return nil }
    return watts / 1000 * 24 * price
  }

  var displayWatts: Double? {
    if let id = preferences.displayDeviceID {
      return provider?.isFresh == true ? reading(id)?.currentWatts : nil
    }
    var values: [Double] = []
    for category in [ProviderCategory.pearl, .vast] {
      let assigned = preferences.devices.contains { $0.assignment.rawValue == category.rawValue }
      if assigned {
        guard let value = watts(for: category) else { return nil }
        values.append(value)
      }
    }
    return values.isEmpty ? nil : values.reduce(0, +)
  }

  var displayCostPerDay: Double? {
    guard let watts = displayWatts, let price = preferences.pricePerKWh else { return nil }
    return max(0, watts) / 1000 * 24 * price
  }
}

extension Provider {
  func pearlProjection(_ options: ProviderPreferences, power: PowerContext) -> MiningProjection {
    let money = MoneyFormat(currency: options.currency, rates: rates)
    var revenue: Double?
    if isFresh, let coins = pearl?.coinsPerDay, let price = pearl?.priceUSD {
      revenue = coins * price * money.factor
    }
    return MiningProjection(
      revenuePerDay: revenue,
      powerPerDay: power.dailyCost(for: .pearl, money: money, rates: rates))
  }
}

func formatHashrate(_ value: Double?) -> String {
  guard let (number, unit) = hashrateParts(value) else { return "—" }
  return number + " " + unit
}

/// Two averages sharing one unit when they can, as in "325.26 · 322.03 TH/s".
func formatHashrates(_ first: Double?, _ second: Double?) -> String {
  guard let a = hashrateParts(first), let b = hashrateParts(second), a.1 == b.1 else {
    return formatHashrate(first) + " · " + formatHashrate(second)
  }
  return a.0 + " · " + b.0 + " " + a.1
}

private func hashrateParts(_ value: Double?) -> (String, String)? {
  guard let value, value.isFinite, value >= 0 else { return nil }
  for (scale, unit) in [
    (1e18, "EH/s"), (1e15, "PH/s"), (1e12, "TH/s"), (1e9, "GH/s"), (1e6, "MH/s"), (1e3, "KH/s"),
  ] {
    if value >= scale { return (String(format: "%.2f", value / scale), unit) }
  }
  return (String(format: "%.0f", value), "H/s")
}

func formatPRL(_ value: Double?, digits: Int = 8) -> String {
  guard let value, value.isFinite, value >= 0 else { return "—" }
  return String(format: "%.*f PRL", digits, value)
}
