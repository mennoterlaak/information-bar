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
    return result
  }

  /// Defaults plus a configured Vast.ai pane: a power price, wattages and both earnings columns.
  static func preferences() -> AppPreferences {
    var preferences = AppPreferences()
    var vast = ProviderPreferences.defaults(for: .vast)
    vast.powerPrice = 0.30
    vast.machineWatts = ["1": 450, "2": 300]
    vast.earningsView = .both
    preferences.providers["vast"] = vast
    return preferences
  }

  private static func decode(_ raw: [String: Any]) -> Provider {
    // swiftlint:disable:next force_try
    try! JSONDecoder().decode(Provider.self, from: JSONSerialization.data(withJSONObject: raw))
  }
}
