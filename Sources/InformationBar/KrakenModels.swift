import Foundation

/// Spot balances valued on Kraken's own markets in the portfolio currency.
struct KrakenMetrics: Decodable {
  let currency: String
  /// Sum over priced holdings; nil when prices are unavailable.
  var totalValue: Double?
  /// Change of the current holdings since Kraken's 00:00 UTC open.
  var changeValue: Double?
  /// Largest value first; unpriced holdings last.
  var assets: [KrakenAsset]

  /// Values are already in `currency`, so no conversion applies.
  var money: MoneyFormat { MoneyFormat(currency: currency, rates: ["EUR": 1]) }

  var changeFraction: Double? {
    guard let totalValue, let changeValue, totalValue - changeValue > 0 else { return nil }
    return changeValue / (totalValue - changeValue)
  }

  /// Priced crypto holdings, the choices for the menu bar price.
  var tradedAssets: [KrakenAsset] { assets.filter { !$0.fiat && $0.price != nil } }

  /// The chosen asset, or the largest holding when none is chosen.
  func asset(_ symbol: String?) -> KrakenAsset? {
    guard let symbol else { return tradedAssets.first }
    return assets.first { $0.symbol == symbol }
  }

  /// Every market a holding's price is multiplied from.
  var liveSymbols: Set<String> { Set(assets.flatMap { $0.route ?? [] }.map(\.symbol)) }

  /// The same holdings priced from Kraken's live feed. Holdings missing a leg keep the
  /// collector's price; the total and today's change are summed as the collector sums them.
  /// Holdings keep their order, so rows do not swap places between balance refreshes.
  func repriced(_ prices: [String: Double]) -> KrakenMetrics {
    guard totalValue != nil else { return self }
    var copy = self
    var total = 0.0
    var change = 0.0
    for index in copy.assets.indices {
      var asset = copy.assets[index]
      if let price = asset.route.flatMap({ routePrice($0, prices) }) {
        asset.price = price
        asset.value = asset.amount * price
      }
      if let value = asset.value {
        total += value
        if let open = asset.openPrice { change += value - asset.amount * open }
      }
      copy.assets[index] = asset
    }
    copy.totalValue = total
    copy.changeValue = change
    return copy
  }
}

struct KrakenAsset: Decodable, Identifiable {
  let symbol: String
  /// Total across spot, Earn and held balances.
  let amount: Double
  /// Part of `amount` that is staked or earning rewards.
  let earn: Double
  /// Kraken's display precision for the asset.
  let decimals: Int
  let fiat: Bool
  /// Last trade in the portfolio currency.
  var price: Double?
  /// Today's 00:00 UTC opening price in the portfolio currency.
  let openPrice: Double?
  var value: Double?
  /// Markets the price is multiplied from; nil for cash in the portfolio currency and for
  /// assets Kraken cannot price.
  let route: [KrakenLeg]?

  var id: String { symbol }

  /// Kraken markets the price comes from, such as "TAO/USD · EUR/USD".
  var market: String? { route.map { $0.map(\.symbol).joined(separator: " · ") } }

  var change: Double? {
    guard let price, let openPrice, openPrice > 0 else { return nil }
    return price / openPrice - 1
  }
}

/// One market on the way to the portfolio currency, named as Kraken's WebSocket feed names it.
struct KrakenLeg: Decodable, Equatable {
  let symbol: String
  /// The pair is quoted the other way round, so its price is divided instead of multiplied.
  let invert: Bool
}

/// The product of each leg's last trade, or nil while any leg has none.
func routePrice(_ route: [KrakenLeg], _ prices: [String: Double]) -> Double? {
  guard !route.isEmpty else { return nil }
  var rate = 1.0
  for leg in route {
    guard let price = prices[leg.symbol], price > 0 else { return nil }
    rate *= leg.invert ? 1 / price : price
  }
  return rate
}

extension Provider {
  /// Kraken balances priced from the live feed. Stale balances stay as they are, so they keep
  /// dropping out of the menu bar like every other stale value.
  func repriced(_ prices: [String: Double]) -> Provider {
    guard isFresh, !prices.isEmpty, let kraken else { return self }
    var copy = self
    copy.kraken = kraken.repriced(prices)
    return copy
  }
}

struct KrakenCredentials: Codable, Equatable {
  var apiKey: String
  var privateKey: String

  /// Both keys live in one Keychain item, so a rebuilt app asks for access once.
  #if os(macOS)
  static func load() -> KrakenCredentials? {
    CredentialStore.read(account: CredentialStore.krakenAccount).flatMap {
      try? JSONDecoder().decode(Self.self, from: Data($0.utf8))
    }
  }
  #endif
}

/// An asset quantity at Kraken's display precision, without trailing zeros.
func formatQuantity(_ value: Double, decimals: Int) -> String {
  var text = String(format: "%.*f", max(0, decimals), value)
  if text.contains(".") {
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
  }
  if text == "0" && value > 0 { return String(format: "%.2g", value) }
  return groupThousands(text)
}

/// A unit price with at least four significant digits and two decimals; `compact` drops the
/// decimals from 1,000 up, for the menu bar.
func formatPrice(_ value: Double?, money: MoneyFormat, compact: Bool = false) -> String {
  guard let value, value > 0 else { return "—" }
  if compact && value >= 1000 { return money.local(value, digits: 0) }
  return money.local(value, digits: min(10, max(2, 3 - Int(floor(log10(value))))))
}

/// A signed percentage, as in "+1.2%" or "-0.4%".
func formatChange(_ fraction: Double, digits: Int = 2) -> String {
  let text = String(format: "%+.*f%%", digits, fraction * 100)
  // "-0.00%" and "+0.00%" both read as no change.
  return Double(text.dropLast()) == 0 ? String(format: "%.*f%%", digits, 0.0) : text
}
