import Foundation
import XCTest

@testable import InformationBar

final class KrakenTests: XCTestCase {
  private let euro = MoneyFormat(currency: "EUR", rates: ["EUR": 1])

  private func asset(
    _ symbol: String, _ amount: Double, price: Double? = nil, open: Double? = nil,
    fiat: Bool = false, route: [(String, Bool)]? = nil
  ) -> [String: Any] {
    var raw: [String: Any] = [
      "symbol": symbol, "amount": amount, "earn": 0, "decimals": 5, "fiat": fiat,
    ]
    if let price {
      raw["price"] = price
      raw["value"] = amount * price
    }
    if let open { raw["openPrice"] = open }
    if let route { raw["route"] = route.map { ["symbol": $0.0, "invert": $0.1] } }
    return raw
  }

  /// A EUR portfolio priced directly (BTC), through a bridge (TAO), inverted (USD), as cash
  /// (EUR) and not at all (USDT0). Total 7,540; change since the open 80.
  private func routedPayload() -> [String: Any] {
    [
      "currency": "EUR", "totalValue": 7540, "changeValue": 80,
      "assets": [
        asset("BTC", 0.1, price: 70000, open: 69000, route: [("BTC/EUR", false)]),
        asset("TAO", 2, price: 200, open: 210, route: [("TAO/USD", false), ("EUR/USD", true)]),
        asset("USD", 100, price: 0.9, open: 0.9, fiat: true, route: [("EUR/USD", true)]),
        asset("EUR", 50, price: 1, open: 1, fiat: true),
        asset("USDT0", 5),
      ],
    ]
  }

  private func kraken(_ payload: [String: Any], age: Double = 0) throws -> Provider {
    let raw: [String: Any] = [
      "id": "kraken", "name": "Kraken", "status": "ok",
      "updatedAt": Date().timeIntervalSince1970 - age, "kraken": payload,
    ]
    return try JSONDecoder().decode(
      Provider.self, from: JSONSerialization.data(withJSONObject: raw))
  }

  private func routed(age: Double = 0) throws -> Provider { try kraken(routedPayload(), age: age) }

  /// A collector payload: cash is the largest holding, so it must not become the default price.
  private func provider(
    total: Double? = 6260, change: Double? = 60, status: String = "ok", age: Double = 0
  ) throws -> Provider {
    let raw: [String: Any] = [
      "id": "kraken", "name": "Kraken", "status": status,
      "updatedAt": Date().timeIntervalSince1970 - age,
      "kraken": [
        "currency": "EUR", "totalValue": (total as Any?) ?? NSNull(),
        "changeValue": (change as Any?) ?? NSNull(),
        "assets": [
          asset("EUR", 5000, price: 1, open: 1, fiat: true),
          asset("BTC", 0.015, price: 74101.6, open: 73000),
          asset("DOGE", 1500, price: 0.0771891, open: 0.0756),
          asset("USDT0", 5),
        ],
      ],
    ]
    return try JSONDecoder().decode(
      Provider.self, from: JSONSerialization.data(withJSONObject: raw))
  }

  func testMenuBarValuesUseThePortfolioCurrency() throws {
    let item = try provider()
    let options = ProviderPreferences.defaults(for: .kraken)
    XCTAssertEqual(options.elements.map(\.kind), [.icon, .portfolioValue])
    XCTAssertEqual(item.text(for: MenuElement(.portfolioValue), preferences: options), "€6,260")
    XCTAssertEqual(
      try provider(total: 512.3).text(for: MenuElement(.portfolioValue), preferences: options),
      "€512.30")
    XCTAssertEqual(item.text(for: MenuElement(.portfolioChange), preferences: options), "+1.0%")
    XCTAssertEqual(
      try provider(change: -125).text(for: MenuElement(.portfolioChange), preferences: options),
      "-2.0%")
  }

  func testPriceFollowsTheLargestCryptoHoldingOrTheChosenAsset() throws {
    let item = try provider()
    let options = ProviderPreferences.defaults(for: .kraken)
    XCTAssertEqual(
      item.text(for: MenuElement(.assetPrice, showLabel: true), preferences: options),
      "BTC €74,102")
    XCTAssertEqual(
      item.text(for: MenuElement(.assetPrice, asset: "DOGE"), preferences: options), "€0.07719")
    // A sold asset shows a dash rather than silently switching to another price.
    XCTAssertEqual(
      item.text(for: MenuElement(.assetPrice, asset: "SOL"), preferences: options), "—")
    XCTAssertEqual(item.kraken?.tradedAssets.map(\.symbol), ["BTC", "DOGE"])
  }

  func testMissingPricesAndStaleDataNeverShowAnOldTotal() throws {
    let options = ProviderPreferences.defaults(for: .kraken)
    let unpriced = try provider(total: nil, change: nil, status: "partial")
    XCTAssertEqual(unpriced.text(for: MenuElement(.portfolioValue), preferences: options), "—")
    XCTAssertEqual(unpriced.text(for: MenuElement(.portfolioChange), preferences: options), "—")
    let stale = try provider(age: 3600)
    XCTAssertEqual(stale.text(for: MenuElement(.portfolioValue), preferences: options), "—")
    XCTAssertEqual(stale.text(for: MenuElement(.assetPrice), preferences: options), "—")
  }

  func testChangeIsRelativeToTheOpeningValue() throws {
    let kraken = try XCTUnwrap(try provider().kraken)
    XCTAssertEqual(kraken.changeFraction ?? 0, 60.0 / 6200, accuracy: 1e-12)
    let btc = try XCTUnwrap(kraken.asset("BTC"))
    XCTAssertEqual(btc.change ?? 0, 74101.6 / 73000 - 1, accuracy: 1e-12)
    XCTAssertNil(kraken.asset("USDT0")?.change)
  }

  func testQuantitiesPricesAndChangesAreFormattedForReading() {
    XCTAssertEqual(formatQuantity(0.15, decimals: 5), "0.15")
    XCTAssertEqual(formatQuantity(1500, decimals: 2), "1,500")
    XCTAssertEqual(formatQuantity(0.000012345, decimals: 5), "0.00001")
    XCTAssertEqual(formatQuantity(0.0000001, decimals: 5), "1e-07")
    XCTAssertEqual(formatPrice(74101.6, money: euro), "€74,101.60")
    XCTAssertEqual(formatPrice(74101.6, money: euro, compact: true), "€74,102")
    XCTAssertEqual(formatPrice(253.07, money: euro), "€253.07")
    XCTAssertEqual(formatPrice(1.1171, money: euro), "€1.117")
    XCTAssertEqual(formatPrice(0.0771891, money: euro), "€0.07719")
    XCTAssertEqual(formatPrice(0.00001234, money: euro), "€0.00001234")
    XCTAssertEqual(formatPrice(nil, money: euro), "—")
    XCTAssertEqual(formatChange(0.004712), "+0.47%")
    XCTAssertEqual(formatChange(-0.0226), "-2.26%")
    XCTAssertEqual(formatChange(-0.00001), "0.00%")
  }

  func testMoneyGroupsThousands() {
    let usd = MoneyFormat(currency: "USD", rates: nil)
    XCTAssertEqual(groupThousands("1234567.891"), "1,234,567.891")
    XCTAssertEqual(groupThousands("999"), "999")
    XCTAssertEqual(groupThousands("1000"), "1,000")
    XCTAssertEqual(usd.local(12345.678), "$12,345.68")
    XCTAssertEqual(usd.local(-1234.5), "-$1,234.50")
  }

  func testChosenAssetPersistsAndOlderElementsDecode() throws {
    let element = MenuElement(.assetPrice, showLabel: true, asset: "ETH")
    let decoded = try JSONDecoder().decode(
      MenuElement.self, from: JSONEncoder().encode(element))
    XCTAssertEqual(decoded, element)
    let older = try JSONDecoder().decode(
      MenuElement.self, from: Data(#"{"kind":"used","windowID":"auto"}"#.utf8))
    XCTAssertNil(older.asset)
    XCTAssertTrue(MenuElementKind.available(for: .kraken).contains(.assetPrice))
    XCTAssertFalse(MenuElementKind.available(for: .kraken).contains(.used))
    XCTAssertFalse(MenuElementKind.available(for: .pearl).contains(.assetPrice))
  }

  func testRoutesNameTheMarketsToStream() throws {
    let kraken = try XCTUnwrap(try routed().kraken)
    XCTAssertEqual(kraken.liveSymbols, ["BTC/EUR", "TAO/USD", "EUR/USD"])
    XCTAssertEqual(kraken.asset("TAO")?.market, "TAO/USD · EUR/USD")
    XCTAssertNil(kraken.asset("EUR")?.market)
    XCTAssertEqual(routePrice([KrakenLeg(symbol: "EUR/USD", invert: true)], ["EUR/USD": 1.25]), 0.8)
    XCTAssertNil(routePrice([], ["EUR/USD": 1.25]))
  }

  func testLivePricesRepriceHoldingsTheTotalAndTodaysChange() throws {
    let live = try routed().repriced(["BTC/EUR": 80000, "TAO/USD": 250, "EUR/USD": 1.25])
    let kraken = try XCTUnwrap(live.kraken)
    XCTAssertEqual(kraken.asset("BTC")?.price, 80000)
    XCTAssertEqual(kraken.asset("TAO")?.price ?? 0, 200, accuracy: 1e-9)
    XCTAssertEqual(kraken.asset("USD")?.price ?? 0, 0.8, accuracy: 1e-9)
    XCTAssertEqual(kraken.asset("EUR")?.price, 1)
    XCTAssertNil(kraken.asset("USDT0")?.price)
    XCTAssertEqual(kraken.totalValue ?? 0, 8000 + 400 + 80 + 50, accuracy: 1e-9)
    XCTAssertEqual(kraken.changeValue ?? 0, 1100 - 20 - 10, accuracy: 1e-9)
    // Rows keep their order between balance refreshes.
    XCTAssertEqual(kraken.assets.map(\.symbol), ["BTC", "TAO", "USD", "EUR", "USDT0"])

    // A leg without a live price leaves that holding at the collector's price.
    let partial = try XCTUnwrap(try routed().repriced(["BTC/EUR": 80000]).kraken)
    XCTAssertEqual(partial.asset("TAO")?.price, 200)
    XCTAssertEqual(partial.totalValue ?? 0, 8000 + 400 + 90 + 50, accuracy: 1e-9)
  }

  func testStaleOrUnpricedPortfoliosAreNotRepriced() throws {
    let prices = ["BTC/EUR": 80000.0]
    XCTAssertEqual(try routed(age: 3600).repriced(prices).kraken?.totalValue, 7540)
    let unpriced = try XCTUnwrap(try provider(total: nil, change: nil, status: "partial").kraken)
    XCTAssertNil(unpriced.repriced(prices).totalValue)
    XCTAssertEqual(try routed().repriced([:]).kraken?.totalValue, 7540)
  }

  func testLivePricesStayOffForEarlierPreferences() throws {
    let older = try JSONDecoder().decode(
      ProviderPreferences.self, from: Data(#"{"enabled":true,"currency":"EUR"}"#.utf8))
    XCTAssertFalse(older.livePrices)
    var options = ProviderPreferences.defaults(for: .kraken)
    options.livePrices = true
    let decoded = try JSONDecoder().decode(
      ProviderPreferences.self, from: JSONEncoder().encode(options))
    XCTAssertTrue(decoded.livePrices)
  }

  private func position(
    _ symbol: String, long: Bool, _ amount: Double, entry: Double, price: Double, open: Double,
    leverage: Double, rate: Double, route: [(String, Bool)], rollover: Double
  ) -> [String: Any] {
    let parts = symbol.split(separator: "/").map(String.init)
    let cost = amount * entry
    return [
      "symbol": symbol, "base": parts[0], "quote": parts[1], "side": long ? "long" : "short",
      "amount": amount, "decimals": 5, "entryPrice": entry, "price": price, "openPrice": open,
      "openValue": amount * open, "cost": cost, "margin": cost / leverage,
      "net": (long ? 1 : -1) * amount * (price - entry), "rate": rate,
      "route": route.map { ["symbol": $0.0, "invert": $0.1] }, "rolloverPerDay": rollover,
      "terms": "0.0100% per 4 hours", "fills": 1,
    ]
  }

  /// The routed portfolio (balances 7,540, change 80) with a 5× BTC/USD long worth 480 and a
  /// 2× ETH/EUR short worth 200: 680 unrealized on 2,960 of used margin.
  private func margined(_ margin: [String: Any]? = nil, age: Double = 0) throws -> Provider {
    var payload = routedPayload()
    payload["margin"] =
      margin ?? [
        "equity": 7680, "tradeBalance": 7000, "used": 2960, "unrealized": 680, "marginCall": 80,
        "liquidation": 40,
        "positions": [
          position(
            "BTC/USD", long: true, 0.1, entry: 60000, price: 66000, open: 65000, leverage: 5,
            rate: 0.8, route: [("EUR/USD", true)], rollover: 2.88),
          position(
            "ETH/EUR", long: false, 2, entry: 2000, price: 1900, open: 1950, leverage: 2, rate: 1,
            route: [], rollover: 4.56),
        ],
      ]
    return try kraken(payload, age: age)
  }

  func testOpenPositionsAddTheirProfitAndTodaysMoveToTheAccount() throws {
    let kraken = try XCTUnwrap(try margined().kraken)
    let margin = try XCTUnwrap(kraken.openMargin)
    XCTAssertEqual(kraken.totalValue, 7540)
    XCTAssertEqual(kraken.accountValue ?? 0, 7540 + 680, accuracy: 1e-9)
    // The long gained 100 dollars today, the short 100 euros: 80 + 100 on top of the balances' 80.
    XCTAssertEqual(margin.changeToday, 180, accuracy: 1e-9)
    XCTAssertEqual(kraken.accountChange ?? 0, 260, accuracy: 1e-9)
    XCTAssertEqual(kraken.changeFraction ?? 0, 260.0 / 7960, accuracy: 1e-12)
    XCTAssertEqual(margin.levelNow ?? 0, 7680.0 / 2960 * 100, accuracy: 1e-9)
    XCTAssertEqual(margin.freeNow ?? 0, 4720, accuracy: 1e-9)
    XCTAssertEqual(margin.cushionNow ?? 0, 7680 - 2960 * 0.4, accuracy: 1e-9)
    XCTAssertEqual(margin.rolloverPerDay ?? 0, 7.44, accuracy: 1e-9)
    let long = try XCTUnwrap(margin.positions?.first)
    XCTAssertEqual(long.leverage, 5)
    XCTAssertEqual(long.pnl ?? 0, 480, accuracy: 1e-9)
    XCTAssertEqual(long.marketChange ?? 0, 66000.0 / 65000 - 1, accuracy: 1e-12)
    XCTAssertEqual(margin.positions?.last?.pnl, 200)
  }

  func testLivePricesMoveThePositionsEquityAndMarginLevel() throws {
    let live = try margined().repriced([
      "BTC/EUR": 80000, "TAO/USD": 250, "EUR/USD": 1.25, "BTC/USD": 70000, "ETH/EUR": 1800,
    ])
    let kraken = try XCTUnwrap(live.kraken)
    let margin = try XCTUnwrap(kraken.openMargin)
    // The long is up 400 more dollars at 0.8, the short 200 more euros.
    XCTAssertEqual(margin.unrealizedNow ?? 0, 680 + 320 + 200, accuracy: 1e-9)
    XCTAssertEqual(margin.equityNow ?? 0, 7680 + 520, accuracy: 1e-9)
    XCTAssertEqual(margin.levelNow ?? 0, 8200.0 / 2960 * 100, accuracy: 1e-9)
    XCTAssertEqual(margin.changeToday, 400 + 300, accuracy: 1e-9)
    XCTAssertEqual(kraken.accountValue ?? 0, 8530 + 1200, accuracy: 1e-9)
    XCTAssertEqual(kraken.accountChange ?? 0, 1070 + 700, accuracy: 1e-9)
    XCTAssertEqual(
      kraken.liveSymbols, ["BTC/EUR", "TAO/USD", "EUR/USD", "BTC/USD", "ETH/EUR"])
    // A position without a live price keeps its refresh-time P&L.
    let partial = try XCTUnwrap(try margined().repriced(["ETH/EUR": 1800]).kraken?.openMargin)
    XCTAssertEqual(partial.positions?.first?.pnl ?? 0, 480, accuracy: 1e-9)
    XCTAssertEqual(partial.unrealizedNow ?? 0, 880, accuracy: 1e-9)
  }

  func testMarginMenuBarValues() throws {
    let options = ProviderPreferences.defaults(for: .kraken)
    let item = try margined()
    XCTAssertEqual(item.text(for: MenuElement(.portfolioValue), preferences: options), "€8,220")
    XCTAssertEqual(item.text(for: MenuElement(.portfolioChange), preferences: options), "+3.3%")
    XCTAssertEqual(item.text(for: MenuElement(.marginPnL), preferences: options), "+€680.00")
    XCTAssertEqual(item.text(for: MenuElement(.marginLevel), preferences: options), "259%")
    XCTAssertEqual(
      try margined(age: 3600).text(for: MenuElement(.marginPnL), preferences: options), "—")

    // No open positions: nothing to add, and no margin level to speak of.
    let flat = try margined(["positions": []])
    XCTAssertEqual(flat.text(for: MenuElement(.portfolioValue), preferences: options), "€7,540")
    XCTAssertEqual(flat.text(for: MenuElement(.marginPnL), preferences: options), "€0.00")
    XCTAssertEqual(flat.text(for: MenuElement(.marginLevel), preferences: options), "—")
    // A key that cannot read positions leaves the P&L unknown rather than zero.
    let denied = try margined(["error": "Margin positions need another permission."])
    XCTAssertEqual(denied.text(for: MenuElement(.portfolioValue), preferences: options), "€7,540")
    XCTAssertEqual(denied.text(for: MenuElement(.marginPnL), preferences: options), "—")
    XCTAssertEqual(try provider().text(for: MenuElement(.marginPnL), preferences: options), "—")
    XCTAssertTrue(MenuElementKind.available(for: .kraken).contains(.marginLevel))
    XCTAssertFalse(MenuElementKind.available(for: .pearl).contains(.marginPnL))
  }

  func testMarginRiskFollowsKrakensLevels() throws {
    func risk(equity: Double, call: Double? = 80) throws -> KrakenMargin.Risk? {
      var margin: [String: Any] = [
        "equity": equity, "used": 1000, "unrealized": 0, "liquidation": 40,
        "positions": [
          position(
            "ETH/EUR", long: true, 1, entry: 2000, price: 2000, open: 2000, leverage: 2, rate: 1,
            route: [], rollover: 1)
        ],
      ]
      if let call { margin["marginCall"] = call }
      return try margined(margin).kraken?.openMargin?.risk
    }
    XCTAssertEqual(try risk(equity: 5750), .normal)
    XCTAssertEqual(try risk(equity: 1000), .normal)
    // Below 100% nothing is left to open positions with; at the call level Kraken may close them.
    XCTAssertEqual(try risk(equity: 990), .noFreeMargin)
    XCTAssertEqual(try risk(equity: 800), .marginCall)
    XCTAssertEqual(try risk(equity: 500, call: nil), .noFreeMargin)
  }

  func testPositionsWithoutKrakensAccountFiguresStillAddUp() throws {
    let only = try margined([
      "positions": [
        position(
          "ETH/EUR", long: false, 2, entry: 2000, price: 1900, open: 1950, leverage: 2, rate: 1,
          route: [], rollover: 4.56)
      ]
    ])
    let kraken = try XCTUnwrap(only.kraken)
    XCTAssertEqual(kraken.openMargin?.unrealizedNow, 200)
    XCTAssertEqual(kraken.accountValue, 7740)
    XCTAssertNil(kraken.openMargin?.levelNow)
    XCTAssertEqual(
      only.text(for: MenuElement(.marginLevel), preferences: .defaults(for: .kraken)), "—")
  }

  func testQuoteCurrencyAmountsAndLeverageAreFormattedForReading() {
    XCTAssertEqual(formatQuotePrice(66000, quote: "USD"), "$66,000.00")
    XCTAssertEqual(formatQuotePrice(66000, quote: "USD", compact: true), "$66,000")
    XCTAssertEqual(formatQuotePrice(2239.99, quote: "EUR"), "€2,239.99")
    XCTAssertEqual(formatQuotePrice(0.055, quote: "BTC"), "0.05500 BTC")
    XCTAssertEqual(formatQuotePrice(nil, quote: "BTC"), "—")
    XCTAssertEqual(formatQuoteMove(from: 79000, to: 82938.2, quote: "USD"), "$79,000 → $82,938")
    XCTAssertEqual(formatQuoteMove(from: 0.055, to: 0.05, quote: "BTC"), "0.05500 → 0.05000 BTC")
    XCTAssertEqual(formatQuoteAmount(0.01, quote: "BTC", signed: true), "+0.01 BTC")
    XCTAssertEqual(formatQuoteAmount(-12.5, quote: "USD", signed: true), "-$12.50")
    XCTAssertEqual(formatQuoteAmount(7700, quote: "USD"), "$7,700.00")
    XCTAssertEqual(formatSigned(43.234, money: euro), "+€43.23")
    XCTAssertEqual(formatSigned(-1240.5, money: euro), "-€1,240.50")
    XCTAssertEqual(formatSigned(-0.001, money: euro), "€0.00")
    XCTAssertEqual(formatLeverage(5), "5×")
    XCTAssertEqual(formatLeverage(2.5), "2.5×")
    XCTAssertEqual(formatLeverage(4.99996), "5×")
    XCTAssertEqual(formatMarginLevel(12345.6), "12,346%")
  }

  func testMarginPositionsAreReadByDefaultAndTheChoiceReachesTheCollector() throws {
    let older = try JSONDecoder().decode(
      ProviderPreferences.self, from: Data(#"{"enabled":true,"currency":"EUR"}"#.utf8))
    XCTAssertTrue(older.marginPositions)
    var options = ProviderPreferences.defaults(for: .kraken)
    options.marginPositions = false
    let decoded = try JSONDecoder().decode(
      ProviderPreferences.self, from: JSONEncoder().encode(options))
    XCTAssertFalse(decoded.marginPositions)

    let credentials = KrakenCredentials(apiKey: "key", privateKey: "secret")
    let payload = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(["kraken": KrakenConfiguration(credentials, margin: false)]))
    XCTAssertEqual(
      (payload as? [String: [String: Any]])?["kraken"]?["margin"] as? Bool, false)
    let missing: [String: KrakenConfiguration?] = ["kraken": nil]
    XCTAssertEqual(
      String(decoding: try JSONEncoder().encode(missing), as: UTF8.self), #"{"kraken":null}"#)
  }

  func testHashratePairsShareTheirUnit() {
    XCTAssertEqual(formatHashrates(325.26e12, 322.03e12), "325.26 · 322.03 TH/s")
    XCTAssertEqual(formatHashrates(980e9, 1.02e12), "980.00 GH/s · 1.02 TH/s")
    XCTAssertEqual(formatHashrates(nil, 1.02e12), "— · 1.02 TH/s")
    XCTAssertEqual(ProjectionPeriod.month.title, "Monthly")
  }
}
