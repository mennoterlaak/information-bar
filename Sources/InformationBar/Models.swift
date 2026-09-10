import Foundation

struct UsageWindow: Decodable, Identifiable {
  let id: String
  let label: String
  let usedPercent: Double
  let resetAt: Double?
  /// Collector's verdict: an account-wide or per-model pool (listed first, eligible for the
  /// menu bar value) rather than a surface-specific extra. Absent in older cache files.
  let main: Bool?

  var resetDate: Date? { resetAt.map(Date.init(timeIntervalSince1970:)) }
  var hasExpired: Bool { resetDate.map { $0 <= Date() } ?? false }
  var percent: String { String(format: "%.0f%%", usedPercent) }
}

struct Machine: Decodable, Identifiable {
  let id: String
  let name: String
  let gpu: String
  let gpuCount: Double?
  let status: String
  let running: Double?
  let stored: Double?
  let verification: String?
  let estimatedHourly: Double?
  let reportedHourly: Double?
  let reportedDaily: Double?
  let listedHourly: Double?
  let gpuTemperature: Double?
  let reliability: Double?
  let cpu: String?
  let listed: Bool?
  /// Share of the selected period's listed GPU hours that earned revenue (0...1).
  let utilization: Double?
}

struct EarningDay: Decodable, Identifiable {
  let day: Int
  let amount: Double
  var id: Int { day }
  var date: Date { Date(timeIntervalSince1970: Double(day) * 86400) }
}

struct EarningsBreakdown: Decodable {
  let gpu: Double
  let storage: Double
  let network: Double
  let adjustments: Double
}

struct Provider: Decodable, Identifiable {
  let id: String
  let name: String
  let source: String?
  let url: String?
  let status: String
  let plan: String?
  let windows: [UsageWindow]?
  let updatedAt: Double?
  let checkedAt: Double?
  let nextRetryAt: Double?
  let error: String?
  let machines: [Machine]?
  let machineCount: Int?
  let rentedCount: Int?
  let estimatedHourly: Double?
  let todayEarnings: Double?
  let sevenDayTotal: Double?
  let sevenDayAverage: Double?
  let daily: [EarningDay]?
  let currency: String?
  let billingStart: Double?
  let billingEnd: Double?
  let earningsBreakdown: EarningsBreakdown?
  /// USD to display-currency rates from the ECB, present when a non-USD currency is selected.
  let rates: [String: Double]?
  let ratesDate: String?
  let utilizationDays: Int?
  let utilizationError: String?

  static func placeholder(_ id: String) -> Provider {
    let data = Data(
      "{\"id\":\"\(id)\",\"name\":\"\(names[id] ?? id)\",\"status\":\"loading\"}".utf8)
    return try! JSONDecoder().decode(Provider.self, from: data)
  }

  static let names = Dictionary(
    uniqueKeysWithValues: ProviderCategory.allCases.map { ($0.rawValue, $0.name) })

  var displayName: String { Self.names[id] ?? name }

  var isFresh: Bool {
    guard status == "ok" || status == "partial", let updatedAt else { return false }
    return Date().timeIntervalSince1970 - updatedAt < Freshness.staleAfter(id)
  }

  var visibleWindows: [UsageWindow] {
    let all = windows ?? []
    if all.contains(where: { $0.main != nil }) { return all.filter { $0.main == true } }
    if id == "codex" { return all.filter { $0.id.hasPrefix("codex:") } }
    return Array(all.prefix(2))
  }

  var additionalWindows: [UsageWindow] {
    let visible = Set(visibleWindows.map(\.id))
    return (windows ?? []).filter { !visible.contains($0.id) }
  }

  var ageLabel: String {
    guard let updatedAt else { return "Not connected" }
    let age = max(0, Int(Date().timeIntervalSince1970 - updatedAt))
    if age < 60 { return "Just updated" }
    if age < 3600 { return "Updated \(age / 60)m ago" }
    return "Updated \(age / 3600)h ago"
  }
}

enum Freshness {
  /// Seconds between scheduled refreshes. Mirrors the saved preference so menu values and
  /// views judge staleness against the interval actually in use.
  static var refreshInterval = 60

  /// A value stays current through two consecutive failed polls. Claude adds the collector's
  /// five-minute minimum between its fetches.
  static func staleAfter(_ id: String) -> Double {
    Double(3 * refreshInterval + (id == "claude" ? 300 : 0))
  }
}

/// Formats USD amounts in the display currency, falling back to USD without a rate.
struct MoneyFormat {
  let symbol: String
  let factor: Double

  init(currency: String, rates: [String: Double]?) {
    if currency == "EUR", let rate = rates?["EUR"], rate > 0 {
      symbol = "€"
      factor = rate
    } else {
      symbol = "$"
      factor = 1
    }
  }

  var code: String { symbol == "€" ? "EUR" : "USD" }

  func format(_ usd: Double?, digits: Int = 2) -> String {
    guard let usd else { return "—" }
    return local(usd * factor, digits: digits)
  }

  /// For amounts already in the display currency, such as the entered power price.
  func local(_ value: Double?, digits: Int = 2) -> String {
    guard let value else { return "—" }
    let magnitude = String(format: "%.*f", digits, abs(value))
    let negative = value < 0 && Double(magnitude) != 0
    return (negative ? "-" : "") + symbol + magnitude
  }
}

/// Parses a typed amount, accepting "," or "." as the decimal separator. Locale-aware parsing
/// on comma-decimal locales turned a typed 0.30 into 30, so both are handled here explicitly.
/// When both separators appear, the last one is the decimal point. Negative or invalid → nil.
func parseDecimalInput(_ input: String) -> Double? {
  let raw = input.filter { !$0.isWhitespace && $0 != "€" && $0 != "$" }
  guard !raw.isEmpty else { return nil }
  let separators = raw.indices.filter { raw[$0] == "," || raw[$0] == "." }
  var text = ""
  for index in raw.indices {
    if separators.contains(index) {
      if index == separators.last { text.append(".") }
    } else {
      text.append(raw[index])
    }
  }
  guard let value = Double(text), value.isFinite, value >= 0 else { return nil }
  return value
}

/// Plain decimal text for editing: up to four decimals, trailing zeros trimmed to `minimumDigits`.
func formatDecimalInput(_ value: Double?, minimumDigits: Int = 0) -> String {
  guard let value else { return "" }
  var text = String(format: "%.4f", value)
  while text.hasSuffix("0"), let dot = text.firstIndex(of: "."),
    text.distance(from: dot, to: text.endIndex) - 1 > minimumDigits
  {
    text.removeLast()
  }
  if text.hasSuffix(".") { text.removeLast() }
  return text
}

func resetText(_ date: Date?) -> String {
  guard let date else { return "Reset time unavailable" }
  let seconds = date.timeIntervalSinceNow
  if seconds <= 0 { return "Reset passed · awaiting update" }
  let minutes = max(1, Int(ceil(seconds / 60)))
  if minutes < 60 { return "Resets in \(minutes)m" }
  let hours = minutes / 60
  if hours < 24 { return "Resets in \(hours)h \(minutes % 60)m" }
  return "Resets in \(hours / 24)d \(hours % 24)h"
}
