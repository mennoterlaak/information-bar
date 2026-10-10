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
  private func routed(age: Double = 0) throws -> Provider {
    let raw: [String: Any] = [
      "id": "kraken", "name": "Kraken", "status": "ok",
      "updatedAt": Date().timeIntervalSince1970 - age,
      "kraken": [
        "currency": "EUR", "totalValue": 7540, "changeValue": 80,
        "assets": [
          asset("BTC", 0.1, price: 70000, open: 69000, route: [("BTC/EUR", false)]),
          asset(
            "TAO", 2, price: 200, open: 210, route: [("TAO/USD", false), ("EUR/USD", true)]),
          asset("USD", 100, price: 0.9, open: 0.9, fiat: true, route: [("EUR/USD", true)]),
          asset("EUR", 50, price: 1, open: 1, fiat: true),
          asset("USDT0", 5),
        ],
      ],
    ]
    return try JSONDecoder().decode(
      Provider.self, from: JSONSerialization.data(withJSONObject: raw))
  }

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

  func testHashratePairsShareTheirUnit() {
    XCTAssertEqual(formatHashrates(325.26e12, 322.03e12), "325.26 · 322.03 TH/s")
    XCTAssertEqual(formatHashrates(980e9, 1.02e12), "980.00 GH/s · 1.02 TH/s")
    XCTAssertEqual(formatHashrates(nil, 1.02e12), "— · 1.02 TH/s")
    XCTAssertEqual(ProjectionPeriod.month.title, "Monthly")
  }
}
