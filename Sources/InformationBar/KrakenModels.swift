import Foundation

/// Spot balances valued on Kraken's own markets in the portfolio currency.
struct KrakenMetrics: Decodable {
  let currency: String
  /// Sum over priced holdings; nil when prices are unavailable.
  let totalValue: Double?
  /// Change of the current holdings since Kraken's 00:00 UTC open.
  let changeValue: Double?
  /// Largest value first; unpriced holdings last.
  let assets: [KrakenAsset]

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
  let price: Double?
  /// Today's 00:00 UTC opening price in the portfolio currency.
  let openPrice: Double?
  let value: Double?
  /// Kraken markets the price comes from, such as "TAO/USD · EUR/USD".
  let market: String?

  var id: String { symbol }

  var change: Double? {
    guard let price, let openPrice, openPrice > 0 else { return nil }
    return price / openPrice - 1
  }
}

struct KrakenCredentials: Codable, Equatable {
  var apiKey: String
  var privateKey: String

  /// Both keys live in one Keychain item, so a rebuilt app asks for access once.
  static func load() -> KrakenCredentials? {
    CredentialStore.read(account: CredentialStore.krakenAccount).flatMap {
      try? JSONDecoder().decode(Self.self, from: Data($0.utf8))
    }
  }
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
