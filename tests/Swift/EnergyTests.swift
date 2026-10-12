import Foundation
import XCTest

@testable import InformationBar

final class EnergyTests: XCTestCase {
  private func provider(_ id: String, fields: [String: Any], age: Double = 0) throws -> Provider {
    let raw: [String: Any] = [
      "id": id, "name": id, "status": "ok", "updatedAt": Date().timeIntervalSince1970 - age,
    ]
    .merging(fields) { _, new in new }
    return try JSONDecoder().decode(
      Provider.self, from: JSONSerialization.data(withJSONObject: raw))
  }

  private func measuredPower(_ watts: Double) throws -> PowerContext {
    var power = PowerContext.empty
    power.preferences.devices = [HomeWizardDevice(id: "miner", assignment: .pearl)]
    power.provider = try provider(
      "power",
      fields: [
        "powerDevices": [
          [
            "id": "miner", "name": "Miner", "status": "ok", "watts": watts,
            "updatedAt": Date().timeIntervalSince1970,
          ]
        ]
      ])
    return power
  }

  func testLegacyTariffMigratesButManualWattsAreRetired() throws {
    let saved = Data(
      #"{"providers":{"vast":{"currency":"EUR","powerPrice":0.21,"machineWatts":{"1":448}}}}"#.utf8)
    var preferences = try JSONDecoder().decode(AppPreferences.self, from: saved)
    XCTAssertEqual(preferences.power.currency, "EUR")
    XCTAssertEqual(preferences.power.pricePerKWh, 0.21)
    XCTAssertNil(PowerContext(preferences: preferences.power).watts(for: .vast))
    preferences.power.pricePerKWh = nil
    let data = try JSONEncoder().encode(preferences)
    let reloaded = try JSONDecoder().decode(AppPreferences.self, from: data)
    XCTAssertNil(reloaded.power.pricePerKWh)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let vast = (json["providers"] as? [String: [String: Any]])?["vast"]
    XCTAssertNil(vast?["powerPrice"])
    XCTAssertNil(vast?["machineWatts"])
    let previousPower = Data(
      #"{"power":{"currency":"EUR","pricePerKWh":0.21,"pearlWatts":400,"vastMachineWatts":{"1":448},"devices":[]}}"#
        .utf8)
    let previous = try JSONDecoder().decode(AppPreferences.self, from: previousPower)
    XCTAssertEqual(previous.power.pricePerKWh, 0.21)
    XCTAssertNil(PowerContext(preferences: previous.power).displayWatts)
    let encoded =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(previous.power)) as? [String: Any]
    XCTAssertNil(encoded?["pearlWatts"])
    XCTAssertNil(encoded?["vastMachineWatts"])
  }

  func testProfitPeriodsAndTariffCurrencyAreIndependentOfRevenueCurrency() throws {
    let item = try provider(
      "pearl",
      fields: [
        "rates": ["EUR": 0.5],
        "pearl": ["priceUSD": 2, "hashrate": 300e12, "coinsPerDay": 6],
      ])
    var power = try measuredPower(400)
    power.preferences.currency = "EUR"
    power.preferences.pricePerKWh = 0.25
    let usd = ProviderPreferences.defaults(for: .pearl)
    let projection = item.pearlProjection(usd, power: power)
    XCTAssertEqual(projection.revenuePerDay, 12)
    XCTAssertEqual(projection.powerPerDay ?? 0, 4.8, accuracy: 1e-10)
    for (kind, expected) in [
      (MenuElementKind.profitHourly, "$0.30/h"), (.profitDaily, "$7.20/d"),
      (.profitWeekly, "$50.40/wk"), (.profitMonthly, "$216.00/mo"),
    ] {
      XCTAssertEqual(item.text(for: MenuElement(kind), preferences: usd, power: power), expected)
    }
    var euro = usd
    euro.currency = "EUR"
    XCTAssertEqual(
      item.text(for: MenuElement(.profitDaily), preferences: euro, power: power), "€3.60/d")
    XCTAssertEqual(power.preferences.pricePerKWh, 0.25)
    XCTAssertEqual(item.text(for: MenuElement(.hashrate), preferences: usd), "300.00 TH/s")
    XCTAssertEqual(item.text(for: MenuElement(.tokenPrice), preferences: euro), "€1.000")
  }

  func testMissingPowerOrExchangeRateNeverMasqueradesAsProfit() throws {
    let item = try provider(
      "pearl", fields: ["pearl": ["priceUSD": 1, "hashrate": 1e12, "coinsPerDay": 6]])
    let options = ProviderPreferences.defaults(for: .pearl)
    var power = PowerContext.empty
    XCTAssertEqual(
      item.text(for: MenuElement(.profitDaily), preferences: options, power: power), "—")
    power = try measuredPower(400)
    power.preferences.pricePerKWh = 0.21
    power.preferences.currency = "EUR"
    XCTAssertNil(item.pearlProjection(options, power: power).netPerDay)
    power.preferences.pricePerKWh = 0
    XCTAssertEqual(item.pearlProjection(options, power: power).netPerDay, 6)
    power.preferences.pricePerKWh = 1
    power.preferences.currency = "USD"
    XCTAssertEqual(
      item.text(for: MenuElement(.profitDaily), preferences: options, power: power), "-$3.60/d")
  }

  func testOnlyAssignedMetersContributeAndOfflineMetersLeavePowerUnavailable() throws {
    var power = PowerContext.empty
    power.preferences.devices = [
      HomeWizardDevice(id: "miner", assignment: .pearl), HomeWizardDevice(id: "house"),
    ]
    power.provider = try provider(
      "power",
      fields: [
        "powerDevices": [
          [
            "id": "miner", "name": "Miner", "status": "ok", "watts": 448,
            "updatedAt": Date().timeIntervalSince1970,
          ],
          [
            "id": "house", "name": "House", "status": "ok", "watts": 2000,
            "updatedAt": Date().timeIntervalSince1970,
          ],
        ]
      ])
    XCTAssertEqual(power.watts(for: .pearl), 448)
    XCTAssertEqual(power.displayWatts, 448)
    power.preferences.displayDeviceID = "house"
    XCTAssertEqual(power.displayWatts, 2000)
    power.provider = try provider(
      "power",
      fields: [
        "powerDevices": [
          ["id": "miner", "name": "Miner", "status": "error"]
        ]
      ])
    XCTAssertNil(power.watts(for: .pearl))
    power.preferences.devices = []
    XCTAssertNil(power.watts(for: .pearl))
  }

  func testPartialMeterFailureAndStaleReadingInvalidateWholeAssignedCost() throws {
    var power = PowerContext.empty
    power.preferences.devices = [
      HomeWizardDevice(id: "a", assignment: .pearl), HomeWizardDevice(id: "b", assignment: .pearl),
    ]
    power.provider = try provider(
      "power",
      fields: [
        "status": "partial",
        "powerDevices": [
          [
            "id": "a", "name": "a", "status": "ok", "watts": 300,
            "updatedAt": Date().timeIntervalSince1970,
          ],
          [
            "id": "b", "name": "b", "status": "ok", "watts": 200,
            "updatedAt": Date().timeIntervalSince1970 - 1000,
          ],
        ],
      ])
    XCTAssertNil(power.watts(for: .pearl))
    power.preferences.devices.removeLast()
    XCTAssertEqual(power.watts(for: .pearl), 300)
  }

  func testNetVastDoesNotFallBackToGrossWithoutPower() throws {
    let item = try provider("vast", fields: ["estimatedHourly": 1.25])
    var options = ProviderPreferences.defaults(for: .vast)
    options.earningsView = .net
    XCTAssertEqual(item.text(for: MenuElement(.hourly), preferences: options), "—")
  }

  func testMissingPriceAndStoppedMinerAreDistinct() throws {
    var power = try measuredPower(400)
    power.preferences.pricePerKWh = 0.25
    let options = ProviderPreferences.defaults(for: .pearl)
    let noPrice = try provider("pearl", fields: ["pearl": ["hashrate": 300e12, "coinsPerDay": 6]])
    XCTAssertEqual(noPrice.text(for: MenuElement(.tokenPrice), preferences: options), "—")
    XCTAssertEqual(
      noPrice.text(for: MenuElement(.profitDaily), preferences: options, power: power), "—")
    let stopped = try provider(
      "pearl", fields: ["pearl": ["priceUSD": 1, "hashrate": 0, "coinsPerDay": 0]])
    XCTAssertEqual(stopped.text(for: MenuElement(.hashrate), preferences: options), "0 H/s")
    XCTAssertEqual(
      stopped.text(for: MenuElement(.profitDaily), preferences: options, power: power), "-$2.40/d")
    let stale = try provider(
      "pearl", fields: ["pearl": ["priceUSD": 1, "hashrate": 300e12, "coinsPerDay": 6]], age: 1000)
    XCTAssertEqual(
      stale.text(for: MenuElement(.profitDaily), preferences: options, power: power), "—")
  }

  func testMeterSetupValidationAndPersistence() throws {
    var device = HomeWizardDevice(name: "Miner", address: "192.168.1.18", assignment: .pearl)
    XCTAssertNil(device.validationError)
    device.address = "http://user:secret@192.168.1.18"
    XCTAssertNotNil(device.validationError)
    device.address = "192.168.1.18"
    device.apiVersion = "v2"
    XCTAssertNotNil(device.validationError)
    device.serial = "aabbccddeeff"
    XCTAssertNil(device.validationError)
    var preferences = AppPreferences()
    preferences.power.devices = [device]
    preferences.power.displayDeviceID = device.id
    preferences.pearl.walletAddress = "prl1" + String(repeating: "x", count: 59)
    preferences.pearl.workerName = "rtx4090"
    XCTAssertEqual(
      try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences)),
      preferences)
  }

  func testLegacyPearlSettingsMigrateWithoutResettingPowerOrDisplay() throws {
    let data = Data(
      #"{"theme":"dark","pearl":{"minerURL":"http://miner.local/api","hashrateField":"hashrate_hs","hashrateUnit":"H/s","timestampField":"","minerFeePercent":2},"power":{"currency":"EUR","pricePerKWh":0.23,"devices":[]}}"#.utf8)
    let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
    XCTAssertEqual(preferences.theme, .dark)
    XCTAssertEqual(preferences.power.pricePerKWh, 0.23)
    XCTAssertEqual(preferences.pearl.walletAddress, "")
    XCTAssertEqual(preferences.pearl.averageWindow, .week)
    let saved = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
    XCTAssertFalse(saved.contains("minerURL"))
    XCTAssertFalse(saved.contains("minerFeePercent"))
    XCTAssertTrue(ProviderPreferences.defaults(for: .pearl).elements.contains { $0.kind == .hashrate })
  }

  func testPearlAverageSelectionPersistsAndExistingWalletUsesSevenDays() throws {
    let legacy = Data(#"{"walletAddress":"prl1example","workerName":"rtx4090"}"#.utf8)
    var preferences = try JSONDecoder().decode(PearlPreferences.self, from: legacy)
    XCTAssertEqual(preferences.averageWindow, .week)
    XCTAssertEqual(preferences.walletAddress, "prl1example")
    XCTAssertEqual(preferences.workerName, "rtx4090")
    for window in PearlAverageWindow.allCases {
      preferences.averageWindow = window
      XCTAssertEqual(
        try JSONDecoder().decode(PearlPreferences.self, from: JSONEncoder().encode(preferences)),
        preferences)
    }
    let unknown = Data(#"{"walletAddress":"prl1example","averageWindow":"unknown"}"#.utf8)
    XCTAssertEqual(try JSONDecoder().decode(PearlPreferences.self, from: unknown).averageWindow, .week)
  }

  func testSelectedPearlAverageFeedsMenuAndProjectionWithAccurateLegacyLabel() throws {
    let options = ProviderPreferences.defaults(for: .pearl)
    let item = try provider("pearl", fields: ["pearl": [
      "priceUSD": 2, "hashrate": 300e12, "hashrate30m": 400e12, "hashrate7d": 300e12,
      "coinsPerDay": 5.88, "averageWindow": "7d",
    ]])
    XCTAssertEqual(item.pearl?.effectiveAverageWindow, .week)
    XCTAssertEqual(item.pearl?.shortHashrate, 400e12)
    XCTAssertEqual(item.text(for: MenuElement(.hashrate), preferences: options), "300.00 TH/s")
    XCTAssertEqual(item.pearlProjection(options, power: PowerContext(preferences: .init())).revenuePerDay, 11.76)
    let old = try provider("pearl", fields: ["pearl": ["hashrate": 400e12]])
    XCTAssertEqual(old.pearl?.effectiveAverageWindow, .thirtyMinutes)
    XCTAssertEqual(old.pearl?.shortHashrate, 400e12)
    let missing = try provider("pearl", fields: ["pearl": ["averageWindow": "7d", "hashrate30m": 400e12]])
    XCTAssertEqual(missing.text(for: MenuElement(.hashrate), preferences: options), "—")
    XCTAssertNil(missing.pearlProjection(options, power: PowerContext(preferences: .init())).revenuePerDay)
  }

  func testPearlPoolConnectionValidation() {
    var preferences = PearlPreferences()
    XCTAssertNotNil(preferences.validationError)
    preferences.walletAddress = "prl1" + String(repeating: "x", count: 59)
    XCTAssertNil(preferences.validationError)
    preferences.walletAddress = "http://miner.local"
    XCTAssertNotNil(preferences.validationError)
  }

  func testWalletAndPayoutMenuValuesStayDistinctAndUnavailableRemainsUnknown() throws {
    let options = ProviderPreferences.defaults(for: .pearl)
    let metrics: [String: Any] = ["walletBalance": 7.63170958, "poolBalance": 2.7, "totalPaid": 9.1234]
    let item = try provider("pearl", fields: ["pearl": metrics])
    XCTAssertEqual(item.text(for: MenuElement(.walletBalance), preferences: options), "7.6317 PRL")
    XCTAssertEqual(item.text(for: MenuElement(.poolBalance), preferences: options), "2.7000 PRL")
    XCTAssertEqual(item.text(for: MenuElement(.totalPaid), preferences: options), "9.1234 PRL")
    XCTAssertEqual(formatPRL(item.pearl?.walletBalance), "7.63170958 PRL")
    let zero = try provider("pearl", fields: ["pearl": ["walletBalance": 0]])
    XCTAssertEqual(zero.text(for: MenuElement(.walletBalance), preferences: options), "0.0000 PRL")
    XCTAssertEqual(zero.text(for: MenuElement(.poolBalance), preferences: options), "—")
    let stale = try provider("pearl", fields: ["pearl": metrics], age: 1000)
    XCTAssertEqual(stale.text(for: MenuElement(.walletBalance), preferences: options), "—")
    XCTAssertEqual(stale.text(for: MenuElement(.totalPaid), preferences: options), "—")
  }

  func testPayoutTransactionsOnlyLinkToPearlMainnet() throws {
    let txid = String(repeating: "a", count: 64)
    let item = try provider("pearl", fields: ["pearl": ["payoutCount": 2, "payouts": [
      ["id": "paid", "date": 1791014813, "amount": 1.09738591, "status": "Paid", "txid": txid],
      ["id": "pending", "date": 1791015813, "amount": 1.02, "status": "Pending", "txid": "https://bad.example"],
    ]]])
    let payouts = try XCTUnwrap(item.pearl?.payouts)
    XCTAssertEqual(payouts.first?.explorerURL?.absoluteString, "https://explorer.pearlresearch.ai/tx/\(txid)?network=mainnet")
    XCTAssertNil(payouts.last?.explorerURL)
    XCTAssertEqual(payouts.first?.paidAt.timeIntervalSince1970, 1791014813)
  }

  func testWalletMenuOptionsPersistAlongsideExistingPearlConnection() throws {
    var preferences = AppPreferences()
    preferences.pearl.walletAddress = "prl1" + String(repeating: "x", count: 59)
    var pearl = ProviderPreferences.defaults(for: .pearl)
    pearl.elements += [MenuElement(.walletBalance), MenuElement(.poolBalance), MenuElement(.totalPaid)]
    preferences.providers["pearl"] = pearl
    let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
    XCTAssertEqual(restored, preferences)
    XCTAssertTrue(MenuElementKind.available(for: .pearl).contains(.walletBalance))
    XCTAssertFalse(MenuElementKind.available(for: .power).contains(.walletBalance))
  }

  func testDuplicateMeterAddressesAndSerialNumbersAreDetected() {
    let existing = HomeWizardDevice(
      address: "http://meter.local/api/v1/data", serial: "aabbccddeeff")
    var preferences = PowerPreferences()
    preferences.devices = [existing]
    XCTAssertFalse(preferences.alreadyContains(existing))
    XCTAssertTrue(preferences.alreadyContains(HomeWizardDevice(address: "https://METER.local/")))
    XCTAssertTrue(
      preferences.alreadyContains(HomeWizardDevice(address: "192.168.1.42", serial: "AABBCCDDEEFF"))
    )
    XCTAssertFalse(preferences.alreadyContains(HomeWizardDevice(address: "127.0.0.1:8765")))
  }
}
