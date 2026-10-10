import Foundation

/// Synthetic providers and preferences for QA renders, screenshots and the `--demo` launch
/// flag. Nothing here comes from a real account.
enum DemoData {
  static let urls = [
    "codex": "https://chatgpt.com/codex/settings/usage",
    "claude": "https://claude.ai/settings/usage",
    "cursor": "https://cursor.com/dashboard?tab=usage",
    "vast": "https://cloud.vast.ai/host/machines/",
  ]

  static func providers() -> [String: Provider] {
    let now = Date().timeIntervalSince1970
    var result: [String: Provider] = [:]
    let subscriptions: [(String, String, [(String, Double)])] = [
      ("codex", "Pro", [("Weekly", 34)]),
      ("claude", "Max", [("5-hour", 68), ("Weekly", 22), ("Fable · weekly", 41)]),
      ("cursor", "Enterprise", [("Cursor models", 8), ("Other models", 100)]),
    ]
    for (id, plan, windows) in subscriptions {
      result[id] = decode([
        "id": id, "name": Provider.names[id]!, "status": "ok", "plan": plan, "updatedAt": now,
        "url": urls[id]!,
        "windows": windows.enumerated().map { index, item -> [String: Any] in
          [
            "id": id == "codex" ? "codex:primary" : "\(index)", "label": item.0,
            "usedPercent": item.1, "resetAt": now + Double((index + 1) * 8000), "main": true,
          ]
        },
      ])
    }
    let today = Int(now / 86400)
    result["vast"] = decode([
      "id": "vast", "name": "Vast.ai", "status": "ok", "updatedAt": now, "url": urls["vast"]!,
      "machineCount": 2, "rentedCount": 1, "utilizationDays": 7, "rates": ["EUR": 0.86],
      "ratesDate": "2026-09-09", "estimatedHourly": 0.60, "todayEarnings": 6.50,
      "sevenDayAverage": 4.20, "sevenDayTotal": 29.40,
      "earningsBreakdown": ["gpu": 25.40, "storage": 2.40, "network": 1.60, "adjustments": 0.0],
      "daily": [2.2, 5.2, 1.4, 6.5, 7.1, 4.1, 2.9].enumerated().map {
        ["day": today - 7 + $0.offset, "amount": $0.element]
      },
      "machines": [
        [
          "id": "1", "name": "sample-5090", "gpu": "RTX 5090", "status": "Rented", "running": 1,
          "verification": "verified", "gpuCount": 1, "stored": 2, "estimatedHourly": 0.6,
          "reportedHourly": 0.65, "reportedDaily": 14.20, "gpuTemperature": 62,
          "reliability": 0.9975, "listedHourly": 0.6, "listed": true, "cpu": "AMD Ryzen 9 9950X",
          "utilization": 0.63,
        ],
        [
          "id": "2", "name": "sample-4090", "gpu": "RTX 4090", "status": "Available",
          "running": 0, "verification": "unverified", "gpuCount": 1, "stored": 0,
          "estimatedHourly": 0, "reportedHourly": 0.14, "listedHourly": 0.45, "listed": true,
          "utilization": 0.1,
        ],
      ],
    ])
    result["pearl"] = decode([
      "id": "pearl", "name": "Pearl", "status": "ok", "updatedAt": now,
      "url": "https://pool.kryptex.com/prl", "rates": ["EUR": 0.86],
      "pearl": [
        "priceUSD": 1.11, "priceUpdatedAt": now, "hashrate": 321.6e12,
        "hashrate3h": 328.6e12, "hashrate24h": 316.4e12,
        "onlineWorkers": 1, "workerCount": 1, "coinsPerDay": 6.47, "poolFeePercent": 2,
        "walletBalance": 7.63170958, "poolBalance": 2.70568857,
        "poolConfirmed": 0.78614168, "poolUnconfirmed": 1.91954689,
        "payoutThreshold": 1, "totalPaid": 8.63170958, "payoutCount": 7,
        "payouts": [
          ["id": "demo-pending", "date": now - 60, "amount": 1.02, "status": "Pending"],
          [
            "id": "demo-paid", "date": now - 4 * 3600, "amount": 1.09738591, "status": "Paid",
            "txid": String(repeating: "0", count: 64),
          ],
          [
            "id": "demo-paid-2", "date": now - 8 * 3600, "amount": 1.04144154, "status": "Paid",
            "txid": String(repeating: "1", count: 64),
          ],
        ],
      ],
    ])
    result["kraken"] = decode([
      "id": "kraken", "name": "Kraken", "status": "ok", "updatedAt": now,
      "url": "https://pro.kraken.com/app/portfolio",
      "kraken": [
        "currency": "EUR", "totalValue": 9237.24, "changeValue": 43.23,
        "assets": [
          krakenAsset("BTC", 0.06, earn: 0.01, decimals: 5, price: 74101.6, open: 73748.4),
          krakenAsset("ETH", 1.7, earn: 0.5, decimals: 5, price: 2239.99, open: 2221.6),
          krakenAsset(
            "TAO", 2, decimals: 4, price: 253.07, open: 258.91,
            route: [("TAO/USD", false), ("EUR/USD", true)]),
          krakenAsset("EUR", 260.5, decimals: 2, price: 1, open: 1, fiat: true),
          krakenAsset("DOGE", 1500, decimals: 2, price: 0.0771891, open: 0.0756),
          krakenAsset(
            "USD", 100, decimals: 2, price: 0.893455, open: 0.8941, route: [("EUR/USD", true)],
            fiat: true),
          krakenAsset("DOT", 10, earn: 10, decimals: 8, price: 1.1171, open: 1.1032),
          krakenAsset("ADA", 0.4, decimals: 6, price: 0.5512, open: 0.5498),
          krakenAsset("USDT0", 5, decimals: 4),
        ],
      ],
    ])
    result["power"] = decode([
      "id": "power", "name": "Power", "status": "ok", "updatedAt": now, "rates": ["EUR": 0.86],
      "powerDevices": [
        ["id": "demo-miner", "name": "Mining PC", "watts": 448, "status": "ok", "updatedAt": now],
        ["id": "demo-house", "name": "House P1", "watts": 1240, "status": "ok", "updatedAt": now],
        ["id": "demo-vast", "name": "Vast hosts", "watts": 750, "status": "ok", "updatedAt": now],
      ],
    ])
    return result
  }

  /// Defaults plus a shared tariff, synthetic meters and both Vast.ai earnings columns.
  static func preferences() -> AppPreferences {
    var preferences = AppPreferences()
    var vast = ProviderPreferences.defaults(for: .vast)
    vast.earningsView = .both
    preferences.providers["vast"] = vast
    preferences.power.pricePerKWh = 0.21
    preferences.power.currency = "EUR"
    preferences.power.devices = [
      HomeWizardDevice(
        id: "demo-miner", name: "Mining PC", address: "192.168.1.20",
        serial: "000000000001", assignment: .pearl),
      HomeWizardDevice(id: "demo-house", name: "House P1", address: "192.168.1.21"),
      HomeWizardDevice(
        id: "demo-vast", name: "Vast hosts", address: "192.168.1.22", assignment: .vast),
    ]
    preferences.pearl.walletAddress = "prl1" + String(repeating: "x", count: 59)
    preferences.pearl.workerName = "rtx4090"
    var pearl = ProviderPreferences.defaults(for: .pearl)
    pearl.currency = "EUR"
    pearl.elements += [MenuElement(.profitDaily)]
    preferences.providers["pearl"] = pearl
    var kraken = ProviderPreferences.defaults(for: .kraken)
    kraken.currency = "EUR"
    kraken.elements += [MenuElement(.assetPrice, showLabel: true)]
    preferences.providers["kraken"] = kraken
    return preferences
  }

  private static func krakenAsset(
    _ symbol: String, _ amount: Double, earn: Double = 0, decimals: Int, price: Double? = nil,
    open: Double? = nil, route: [(String, Bool)]? = nil, fiat: Bool = false
  ) -> [String: Any] {
    var asset: [String: Any] = [
      "symbol": symbol, "amount": amount, "earn": earn, "decimals": decimals, "fiat": fiat,
    ]
    if let price {
      asset["price"] = price
      asset["value"] = amount * price
      if let legs = route ?? (price == 1 ? nil : [(symbol + "/EUR", false)]) {
        asset["route"] = legs.map { ["symbol": $0.0, "invert": $0.1] }
      }
    }
    if let open { asset["openPrice"] = open }
    return asset
  }

  static func discoveredMeters() -> [DiscoveredHomeWizard] {
    [
      DiscoveredHomeWizard(
        type: "_hwenergy._tcp.", host: "socket-demo.local.", port: 80,
        txt: [
          "serial": "000000000001", "product_name": "Energy Socket", "product_type": "HWE-SKT",
          "path": "/api/v1", "api_enabled": "1",
        ], addresses: ["192.168.1.20"]),
      DiscoveredHomeWizard(
        type: "_hwenergy._tcp.", host: "spare-socket-demo.local.", port: 80,
        txt: [
          "serial": "000000000003", "product_name": "Energy Socket", "product_type": "HWE-SKT",
          "path": "/api/v1", "api_enabled": "0",
        ], addresses: ["192.168.1.23"]),
      DiscoveredHomeWizard(
        type: "_homewizard._tcp.", host: "p1-demo.local.", port: 443,
        txt: [
          "serial": "000000000004", "product_name": "P1 Meter", "product_type": "HWE-P1",
          "id": "appliance/p1dongle/000000000004", "api_version": "2.3.0",
        ],
        addresses: ["192.168.1.24"]),
    ].compactMap { $0 }
  }

  private static func decode(_ raw: [String: Any]) -> Provider {
    // swiftlint:disable:next force_try
    try! JSONDecoder().decode(Provider.self, from: JSONSerialization.data(withJSONObject: raw))
  }
}
