import Foundation
import SwiftUI
import XCTest

@testable import InformationBar

final class ModelsTests: XCTestCase {
  private let usd = MoneyFormat(currency: "USD", rates: nil)
  private let cursorSettings = ProviderPreferences.defaults(for: .cursor)

  /// The menu bar's usage value for the most-used main pool.
  private func headline(_ item: Provider) -> String? {
    item.text(for: MenuElement(.used), preferences: cursorSettings)
  }

  private func provider(
    status: String = "ok", age: Double = 0, id: String = "cursor", windows: [[String: Any]]
  ) throws -> Provider {
    let raw: [String: Any] = [
      "id": id, "name": id, "status": status,
      "updatedAt": Date().timeIntervalSince1970 - age, "windows": windows,
    ]
    return try JSONDecoder().decode(
      Provider.self, from: JSONSerialization.data(withJSONObject: raw))
  }

  private func window(_ id: String, percent: Double, resetIn: Double = 3600) -> [String: Any] {
    [
      "id": id, "label": id, "usedPercent": percent,
      "resetAt": Date().timeIntervalSince1970 + resetIn,
    ]
  }

  func testMostConstrainedPoolIsNotBlendedWithOtherPools() throws {
    let item = try provider(windows: [window("auto", percent: 8), window("api", percent: 100)])
    XCTAssertEqual(headline(item), "100%")
  }

  func testExpiredWindowDoesNotMasqueradeAsCurrentUsage() throws {
    let item = try provider(windows: [
      window("auto", percent: 100, resetIn: -1), window("api", percent: 12),
    ])
    XCTAssertEqual(headline(item), "12%")
    XCTAssertTrue(item.windows![0].hasExpired)
  }

  func testStaleOrAgedDataLeavesMenuBarSummary() throws {
    XCTAssertEqual(
      headline(try provider(status: "stale", windows: [window("api", percent: 10)])), "—")
    XCTAssertEqual(headline(try provider(age: 181, windows: [window("api", percent: 10)])), "—")
  }

  func testSeparateModelLimitDoesNotReplaceMainCodexAllowance() throws {
    let item = try provider(
      id: "codex",
      windows: [window("codex:primary", percent: 15), window("spark:primary", percent: 100)])
    XCTAssertEqual(headline(item), "15%")
    XCTAssertEqual(item.additionalWindows.count, 1)
  }

  func testCollectorMainFlagsSelectTheVisibleWindows() throws {
    var weekly = window("seven_day", percent: 19)
    weekly["main"] = true
    var fable = window("seven_day_fable", percent: 36)
    fable["main"] = true
    var cowork = window("seven_day_cowork", percent: 2)
    cowork["main"] = false
    let item = try provider(id: "claude", windows: [weekly, fable, cowork])
    XCTAssertEqual(item.visibleWindows.map(\.id), ["seven_day", "seven_day_fable"])
    XCTAssertEqual(item.additionalWindows.map(\.id), ["seven_day_cowork"])
    XCTAssertEqual(headline(item), "36%")
  }

  func testClaudeAllowsItsLongerRefreshInterval() throws {
    XCTAssertTrue(try provider(age: 400, id: "claude", windows: []).isFresh)
    XCTAssertFalse(try provider(age: 661, id: "claude", windows: []).isFresh)
  }

  func testStalenessFollowsTheConfiguredRefreshInterval() throws {
    let saved = Freshness.refreshInterval
    defer { Freshness.refreshInterval = saved }
    Freshness.refreshInterval = 120
    XCTAssertTrue(try provider(age: 300, windows: [window("api", percent: 10)]).isFresh)
    XCTAssertFalse(try provider(age: 361, windows: [window("api", percent: 10)]).isFresh)
    XCTAssertTrue(try provider(age: 600, id: "claude", windows: []).isFresh)
    XCTAssertFalse(try provider(age: 661, id: "claude", windows: []).isFresh)
  }

  func testUnknownRevenueIsNotFormattedAsZero() {
    XCTAssertEqual(usd.format(nil), "—")
    XCTAssertEqual(usd.format(0), "$0.00")
    XCTAssertEqual(usd.format(1.3542857), "$1.35")
  }

  func testNegativeAdjustmentsKeepTheSignBeforeTheCurrencySymbol() {
    XCTAssertEqual(usd.local(-1.5), "-$1.50")
    XCTAssertEqual(usd.local(-0.001), "$0.00")
    XCTAssertEqual(usd.local(-12.4, digits: 0), "-$12")
  }

  func testCountdownsRoundUpToTheNextMinute() {
    XCTAssertEqual(shortCountdown(nil), "—")
    XCTAssertEqual(shortCountdown(Date().addingTimeInterval(-5)), "—")
    XCTAssertEqual(shortCountdown(Date().addingTimeInterval(20)), "1m")
    XCTAssertEqual(shortCountdown(Date().addingTimeInterval(90 * 60)), "1h 30m")
    XCTAssertEqual(shortCountdown(Date().addingTimeInterval(25 * 3600)), "1d 1h")
    XCTAssertEqual(resetText(nil), "Reset time unavailable")
    XCTAssertEqual(resetText(Date().addingTimeInterval(-5)), "Reset passed · awaiting update")
    XCTAssertEqual(resetText(Date().addingTimeInterval(90 * 60)), "Resets in 1h 30m")
  }

  func testCategoryNamesBackProviderDisplayNames() {
    for category in ProviderCategory.allCases {
      XCTAssertEqual(Provider.names[category.rawValue], category.name)
    }
    XCTAssertEqual(Provider.placeholder("codex").displayName, "ChatGPT")
  }

  func testElementsFollowTheirOwnPool() throws {
    let item = try provider(windows: [window("auto", percent: 8), window("api", percent: 100)])
    let settings = ProviderPreferences.defaults(for: .cursor)
    XCTAssertEqual(
      item.text(for: MenuElement(.used, windowID: "auto"), preferences: settings), "8%")
    XCTAssertEqual(
      item.text(for: MenuElement(.remaining, windowID: "auto"), preferences: settings), "92%")
    XCTAssertEqual(
      item.text(for: MenuElement(.used, windowID: "removed-pool"), preferences: settings), "—")
    XCTAssertEqual(item.text(for: MenuElement(.used), preferences: settings), "100%")
    XCTAssertEqual(
      item.text(for: MenuElement(.used, windowID: "auto", showLabel: true), preferences: settings),
      "auto 8%")
    XCTAssertNil(item.text(for: MenuElement(.icon), preferences: settings))
    XCTAssertEqual(item.menuSummary(settings), "100%")
  }

  func testVastElementsRespectMissingAndStaleData() throws {
    var raw: [String: Any] = [
      "id": "vast", "name": "Vast.ai", "status": "ok",
      "updatedAt": Date().timeIntervalSince1970, "machineCount": 2, "rentedCount": 1,
      "estimatedHourly": 0.6,
    ]
    func decode() throws -> Provider {
      try JSONDecoder().decode(Provider.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    let options = ProviderPreferences.defaults(for: .vast)
    XCTAssertEqual(try decode().text(for: MenuElement(.rentals), preferences: options), "1/2")
    XCTAssertEqual(try decode().text(for: MenuElement(.hourly), preferences: options), "$0.60/h")
    XCTAssertEqual(try decode().text(for: MenuElement(.today), preferences: options), "—")
    raw["status"] = "stale"
    XCTAssertEqual(try decode().text(for: MenuElement(.rentals), preferences: options), "—")
  }

  func testShortPoolLabels() throws {
    let item = try provider(windows: [
      window("a", percent: 1), window("b", percent: 1), window("c", percent: 1),
      window("d", percent: 1),
    ])
    _ = item
    let labels = ["5-hour", "Weekly", "Fable · weekly", "Cursor models", "30-minute"]
    let raw = labels.enumerated().map { index, label -> [String: Any] in
      ["id": "\(index)", "label": label, "usedPercent": 1]
    }
    let windows = try JSONDecoder().decode(
      [UsageWindow].self, from: JSONSerialization.data(withJSONObject: raw))
    XCTAssertEqual(windows.map(\.shortLabel), ["5h", "Wk", "Fable", "Cursor", "30m"])
  }

  func testLegacyStyleAndMetricMigrateToElements() throws {
    let data = Data(
      #"{"providers":{"claude":{"style":"valueOnly","metric":"reset","windowID":"seven_day"},"codex":{"style":"iconOnly"}}}"#
        .utf8)
    let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
    let claude = preferences.provider(.claude).elements
    XCTAssertEqual(claude.map(\.kind), [.reset])
    XCTAssertEqual(claude.first?.windowID, "seven_day")
    XCTAssertEqual(preferences.provider(.codex).elements.map(\.kind), [.icon])
  }

  func testPerProviderPreferencesPersistWithoutAffectingOtherCategories() throws {
    let name = "InformationBarTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    var preferences = AppPreferences.load(from: defaults)
    var vast = preferences.provider(.vast)
    vast.enabled = false
    vast.elements = [MenuElement(.hourly), MenuElement(.earningsGraph)]
    vast.showEarningsHistory = false
    preferences.providers["vast"] = vast
    defaults.set(try JSONEncoder().encode(preferences), forKey: "preferences.v2")
    let saved = AppPreferences.load(from: defaults)
    XCTAssertEqual(saved.provider(.vast), vast)
    XCTAssertTrue(saved.provider(.codex).enabled)
    XCTAssertEqual(saved.provider(.codex).elements.map(\.kind), [.icon, .used])
  }

  func testOlderPreferencesDecodeWithNewDefaults() throws {
    let data = Data(
      #"{"providers":{"vast":{"enabled":false,"metric":"today"}},"theme":"dark","refreshInterval":120}"#
        .utf8)
    let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
    let vast = preferences.provider(.vast)
    XCTAssertFalse(vast.enabled)
    XCTAssertEqual(vast.elements.map(\.kind), [.icon, .today])
    XCTAssertEqual(vast.currency, "USD")
    XCTAssertNil(vast.powerPrice)
    XCTAssertEqual(vast.utilizationPeriod, .week)
    XCTAssertEqual(preferences.theme, .dark)
  }

  func testTypedAmountsAcceptEitherDecimalSeparator() {
    XCTAssertEqual(parseDecimalInput("0.30"), 0.3)
    XCTAssertEqual(parseDecimalInput("0,30"), 0.3)
    XCTAssertEqual(parseDecimalInput("€ 0,30"), 0.3)
    XCTAssertEqual(parseDecimalInput(".3"), 0.3)
    XCTAssertEqual(parseDecimalInput("1.234,56"), 1234.56)
    XCTAssertEqual(parseDecimalInput("1,234.56"), 1234.56)
    XCTAssertEqual(parseDecimalInput("350"), 350)
    XCTAssertNil(parseDecimalInput(""))
    XCTAssertNil(parseDecimalInput("abc"))
    XCTAssertNil(parseDecimalInput("-1"))
    XCTAssertEqual(formatDecimalInput(0.3, minimumDigits: 2), "0.30")
    XCTAssertEqual(formatDecimalInput(0.2875, minimumDigits: 2), "0.2875")
    XCTAssertEqual(formatDecimalInput(350), "350")
    XCTAssertEqual(formatDecimalInput(nil), "")
  }

  func testNetEarningsDeductTheEnteredPowerCost() throws {
    let raw: [String: Any] = [
      "id": "vast", "name": "Vast.ai", "status": "ok",
      "updatedAt": Date().timeIntervalSince1970, "todayEarnings": 4.8, "estimatedHourly": 1.0,
      "sevenDayAverage": 3.4,
      "machines": [["id": "1", "name": "a", "gpu": "g", "status": "Rented"]],
    ]
    let item = try JSONDecoder().decode(
      Provider.self, from: JSONSerialization.data(withJSONObject: raw))
    var options = ProviderPreferences.defaults(for: .vast)
    XCTAssertNil(item.earnings(options).net)
    options.powerPrice = 0.25
    options.machineWatts = ["1": 400]
    let figures = item.earnings(options)
    XCTAssertEqual(figures.powerPerDay, 2.4)
    XCTAssertEqual(figures.net?.hourly ?? 0, 0.9, accuracy: 0.0001)
    XCTAssertEqual(figures.net?.average ?? 0, 1.0, accuracy: 0.0001)
    XCTAssertGreaterThanOrEqual(figures.net?.today ?? 0, 4.8 - 2.4)
    options.earningsView = .net
    XCTAssertEqual(item.text(for: MenuElement(.hourly), preferences: options), "$0.90/h")
    options.earningsView = .both
    XCTAssertEqual(item.text(for: MenuElement(.hourly), preferences: options), "$1.00/h")
  }

  func testIconStyleValuesMatchWhatMacOSWrites() {
    // Values observed from System Settings; Automatic follows the appearance, anything else
    // is drawn as Default, as macOS does for app icons.
    XCTAssertEqual(IconStyle.resolve("Regular", for: .dark), .standard)
    XCTAssertEqual(IconStyle.resolve("RegularDark", for: .light), .dark)
    XCTAssertEqual(IconStyle.resolve("RegularAutomatic", for: .light), .standard)
    XCTAssertEqual(IconStyle.resolve("RegularAutomatic", for: .dark), .dark)
    XCTAssertEqual(IconStyle.resolve("ClearLight", for: .dark), .clearLight)
    XCTAssertEqual(IconStyle.resolve("ClearDark", for: .light), .clearDark)
    XCTAssertEqual(IconStyle.resolve("ClearAutomatic", for: .light), .clearLight)
    XCTAssertEqual(IconStyle.resolve("TintedLight", for: .dark), .tintedLight)
    XCTAssertEqual(IconStyle.resolve("TintedDark", for: .light), .tintedDark)
    XCTAssertEqual(IconStyle.resolve("TintedAutomatic", for: .dark), .tintedDark)
    for fallback in ["Clear", "Tinted", "Dark", "RegularLight", "Bogus", ""] {
      XCTAssertEqual(IconStyle.resolve(fallback, for: .dark), .standard, fallback)
    }
  }

  func testMoneyFormatsInTheDisplayCurrency() {
    let euro = MoneyFormat(currency: "EUR", rates: ["EUR": 0.5])
    XCTAssertEqual(euro.format(10), "€5.00")
    XCTAssertEqual(euro.format(-3, digits: 0), "-€2")
    XCTAssertEqual(euro.format(nil), "—")
    XCTAssertEqual(euro.local(1.25), "€1.25")
    XCTAssertEqual(MoneyFormat(currency: "EUR", rates: nil).format(10), "$10.00")
    XCTAssertEqual(MoneyFormat(currency: "USD", rates: ["EUR": 0.5]).format(10), "$10.00")
  }

  func testLegacyCompactPreferenceBecomesFourIndependentIcons() {
    let name = "InformationBarTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: "compactMenu")
    let preferences = AppPreferences.load(from: defaults)
    XCTAssertTrue(
      ProviderCategory.allCases.allSatisfy {
        preferences.provider($0).elements.map(\.kind) == [.icon]
      })
  }
}
