import Foundation

/// Spot balances valued on Kraken's own markets in the portfolio currency, and open margin
/// positions.
struct KrakenMetrics: Decodable {
  let currency: String
  /// Sum over priced holdings; nil when prices are unavailable.
  var totalValue: Double?
  /// Change of the current holdings since Kraken's 00:00 UTC open.
  var changeValue: Double?
  /// Largest value first; unpriced holdings last.
  var assets: [KrakenAsset]
  /// Nil when margin positions are not read.
  var margin: KrakenMargin?

  /// Values are already in `currency`, so no conversion applies.
  var money: MoneyFormat { MoneyFormat(currency: currency, rates: ["EUR": 1]) }

  /// Open margin positions; nil without any.
  var openMargin: KrakenMargin? { margin?.isOpen == true ? margin : nil }

  /// Balances plus the unrealized P&L of open positions: what the account is worth now.
  var accountValue: Double? {
    guard let totalValue else { return nil }
    guard let openMargin else { return totalValue }
    return openMargin.unrealizedNow.map { totalValue + $0 }
  }

  /// Change since Kraken's 00:00 UTC open, open positions included.
  var accountChange: Double? {
    guard let changeValue else { return nil }
    return changeValue + (openMargin?.changeToday ?? 0)
  }

  var changeFraction: Double? {
    guard let accountValue, let accountChange, accountValue - accountChange > 0 else { return nil }
    return accountChange / (accountValue - accountChange)
  }

  /// Priced crypto holdings, the choices for the menu bar price.
  var tradedAssets: [KrakenAsset] { assets.filter { !$0.fiat && $0.price != nil } }

  /// The chosen asset, or the largest holding when none is chosen.
  func asset(_ symbol: String?) -> KrakenAsset? {
    guard let symbol else { return tradedAssets.first }
    return assets.first { $0.symbol == symbol }
  }

  /// Every market a holding's price is multiplied from, and each position's market and the
  /// markets its quote currency is converted through.
  var liveSymbols: Set<String> {
    var symbols = Set(assets.flatMap { $0.route ?? [] }.map(\.symbol))
    for position in margin?.positions ?? [] {
      symbols.insert(position.symbol)
      symbols.formUnion((position.route ?? []).map(\.symbol))
    }
    return symbols
  }

  /// The same holdings and positions priced from Kraken's live feed. Holdings missing a leg keep
  /// the collector's price; the total and today's change are summed as the collector sums them.
  /// Rows keep their order, so they do not swap places between balance refreshes.
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
    copy.margin = margin?.repriced(prices)
    return copy
  }
}

/// Open margin positions and Kraken's account figures, in the portfolio currency. The figures
/// date from the balance refresh; the `…Now` values add how live prices moved the positions.
struct KrakenMargin: Decodable {
  /// Per market and side, largest first; nil when they could not be read.
  var positions: [KrakenPosition]?
  /// Collateral plus unrealized P&L.
  let equity: Double?
  /// Balances Kraken accepts as collateral.
  let tradeBalance: Double?
  /// Initial margin held by the open positions.
  let used: Double?
  let unrealized: Double?
  /// Margin levels in percent at which Kraken calls margin and liquidates.
  let marginCall: Double?
  let liquidation: Double?
  /// Why positions are not shown, such as a key without the permission to read them.
  let error: String?

  var isOpen: Bool { !(positions ?? []).isEmpty }

  /// How far live prices have moved the positions' P&L since the balance refresh.
  private var drift: Double { (positions ?? []).compactMap(\.drift).reduce(0, +) }

  var unrealizedNow: Double? {
    if let unrealized { return unrealized + drift }
    // Without Kraken's figure, the positions' own P&L, when every one is known.
    let values = (positions ?? []).map(\.pnl)
    return values.contains { $0 == nil } ? nil : values.compactMap { $0 }.reduce(0, +)
  }

  var equityNow: Double? { equity.map { $0 + drift } }

  /// What is left to open new positions.
  var freeNow: Double? {
    guard let equityNow, let used else { return nil }
    return equityNow - used
  }

  /// Equity as a percentage of the used margin, as Kraken computes it.
  var levelNow: Double? {
    guard let equityNow, let used, used > 0 else { return nil }
    return equityNow / used * 100
  }

  /// How much equity can still be lost before Kraken liquidates.
  var cushionNow: Double? {
    guard let equityNow, let used, let liquidation else { return nil }
    return equityNow - used * liquidation / 100
  }

  enum Risk { case normal, noFreeMargin, marginCall }

  /// At or below Kraken's margin call level, or below 100%, where no margin is left to open
  /// positions with.
  var risk: Risk {
    guard let level = levelNow else { return .normal }
    if let marginCall, level <= marginCall { return .marginCall }
    return level < 100 ? .noFreeMargin : .normal
  }

  /// Change of the positions since Kraken's 00:00 UTC open; positions without an open are left
  /// out, as holdings are.
  var changeToday: Double { (positions ?? []).compactMap(\.changeToday).reduce(0, +) }

  /// Estimated rollover fees per day; nil when any position's terms are unknown.
  var rolloverPerDay: Double? {
    let values = (positions ?? []).map(\.rolloverPerDay)
    guard !values.isEmpty, !values.contains(where: { $0 == nil }) else { return nil }
    return values.compactMap { $0 }.reduce(0, +)
  }

  func repriced(_ prices: [String: Double]) -> KrakenMargin {
    var copy = self
    copy.positions = positions?.map { $0.repriced(prices) }
    return copy
  }
}

/// The open part of every fill on one market and side. Prices and amounts are in the market's
/// quote currency unless named otherwise; `rate` converts them to the portfolio currency.
struct KrakenPosition: Decodable, Identifiable {
  /// The market as Kraken's website and live feed name it, such as "BTC/USD".
  let symbol: String
  let base: String
  let quote: String
  /// "long" or "short".
  let side: String
  /// Base currency still open.
  let amount: Double
  /// Kraken's display precision for the base currency.
  let decimals: Int
  /// Average opening price.
  let entryPrice: Double?
  /// Last trade at the balance refresh.
  let price: Double?
  /// The market's 00:00 UTC open.
  let openPrice: Double?
  /// What the open amount was worth at today's open, or at entry for fills opened since.
  let openValue: Double?
  let cost: Double?
  let margin: Double?
  /// Opening fees already paid.
  let fee: Double?
  /// Kraken's unrealized P&L at the balance refresh, before closing fees.
  let net: Double?
  /// Quote to portfolio currency at the balance refresh; 1 when they are the same.
  let rate: Double?
  /// Markets the rate is multiplied from; empty when the quote is the portfolio currency.
  let route: [KrakenLeg]?
  /// Estimated in the portfolio currency.
  let rolloverPerDay: Double?
  /// Kraken's rollover terms, such as "0.0100% per 4 hours".
  let terms: String?
  let nextRollover: Double?
  let opened: Double?
  /// Kraken lists each fill as a position of its own.
  let fills: Int?
  /// Live last trade and conversion rate, between balance refreshes.
  var livePrice: Double?
  var liveRate: Double?

  var id: String { symbol + " " + side }
  var isLong: Bool { side == "long" }
  private var direction: Double { isLong ? 1 : -1 }

  var currentPrice: Double? { livePrice ?? price }
  var currentRate: Double? { liveRate ?? rate }

  /// P&L in the quote currency, moved by the live price since the balance refresh.
  var netNow: Double? {
    guard let net else { return nil }
    guard let livePrice, let price else { return net }
    return net + direction * amount * (livePrice - price)
  }

  /// Unrealized P&L in the portfolio currency.
  var pnl: Double? {
    guard let netNow, let currentRate else { return nil }
    return netNow * currentRate
  }

  /// How far live prices moved `pnl` since the balance refresh.
  var drift: Double? {
    guard let pnl, let net, let rate else { return nil }
    return pnl - net * rate
  }

  /// Change since the market's 00:00 UTC open, in the portfolio currency.
  var changeToday: Double? {
    guard let currentPrice, let openValue, let currentRate else { return nil }
    return direction * (amount * currentPrice - openValue) * currentRate
  }

  /// The market's own move today, as on the holding rows.
  var marketChange: Double? {
    guard let currentPrice, let openPrice, openPrice > 0 else { return nil }
    return currentPrice / openPrice - 1
  }

  /// Opening cost over initial margin: 5 for a 5× position.
  var leverage: Double? {
    guard let cost, let margin, margin > 0 else { return nil }
    return cost / margin
  }

  func repriced(_ prices: [String: Double]) -> KrakenPosition {
    var copy = self
    copy.livePrice = prices[symbol]
    // An empty route is the portfolio currency itself, which needs no rate.
    if let route, !route.isEmpty { copy.liveRate = routePrice(route, prices) }
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

/// What the collector reads for Kraken: both keys and whether to read margin positions.
struct KrakenConfiguration: Encodable {
  let apiKey: String
  let privateKey: String
  let margin: Bool

  init(_ credentials: KrakenCredentials, margin: Bool) {
    apiKey = credentials.apiKey
    privateKey = credentials.privateKey
    self.margin = margin
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
  return money.local(value, digits: priceDigits(value, compact: compact))
}

private func priceDigits(_ value: Double, compact: Bool) -> Int {
  compact && value >= 1000 ? 0 : min(10, max(2, 3 - Int(floor(log10(value)))))
}

/// A price in a market's quote currency: dollars and euros with their sign, other currencies
/// by name, as in "0.05500 BTC".
func formatQuotePrice(_ value: Double?, quote: String, compact: Bool = false) -> String {
  guard let value, value > 0 else { return "—" }
  if let money = quoteMoney(quote) { return formatPrice(value, money: money, compact: compact) }
  let text = groupThousands(String(format: "%.*f", priceDigits(value, compact: compact), value))
  return quote.isEmpty ? text : text + " " + quote
}

/// An amount in a market's quote currency, such as "$7,700.00" or "+0.01 BTC".
func formatQuoteAmount(_ value: Double?, quote: String, signed: Bool = false) -> String {
  guard let value else { return "—" }
  if let money = quoteMoney(quote) {
    return signed ? formatSigned(value, money: money) : money.local(value)
  }
  let text = formatQuantity(abs(value), decimals: 8)
  let sign = text == "0" ? "" : value < 0 ? "-" : signed ? "+" : ""
  return sign + text + (quote.isEmpty ? "" : " " + quote)
}

/// From entry to the last trade, as in "$79,000 → $82,938" or "0.05500 → 0.05000 BTC".
func formatQuoteMove(from entry: Double?, to price: Double?, quote: String) -> String {
  // Other currencies name the unit once, after the second price.
  let first = formatQuotePrice(entry, quote: quoteMoney(quote) == nil ? "" : quote, compact: true)
  return first + " → " + formatQuotePrice(price, quote: quote, compact: true)
}

/// Dollars and euros are written with their sign; other quote currencies are not money here.
private func quoteMoney(_ quote: String) -> MoneyFormat? {
  quote == "USD" || quote == "EUR" ? MoneyFormat(currency: quote, rates: ["EUR": 1]) : nil
}

/// A signed amount, as in "+€43.23" or "-€1,240.50"; an amount that rounds to zero has no sign.
func formatSigned(_ value: Double, money: MoneyFormat, digits: Int = 2) -> String {
  let text = money.local(abs(value), digits: digits)
  guard text != money.local(0, digits: digits) else { return text }
  return (value < 0 ? "-" : "+") + text
}

/// A margin level, as in "762%" or "1,250%".
func formatMarginLevel(_ level: Double) -> String {
  groupThousands(String(format: "%.0f", level)) + "%"
}

/// A signed percentage, as in "+1.2%" or "-0.4%".
func formatChange(_ fraction: Double, digits: Int = 2) -> String {
  let text = String(format: "%+.*f%%", digits, fraction * 100)
  // "-0.00%" and "+0.00%" both read as no change.
  return Double(text.dropLast()) == 0 ? String(format: "%.*f%%", digits, 0.0) : text
}
