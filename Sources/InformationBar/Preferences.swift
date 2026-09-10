import Foundation

enum ProviderCategory: String, CaseIterable, Codable, Identifiable {
  case codex, claude, cursor, vast
  var id: String { rawValue }
  var name: String {
    switch self {
    case .codex: return "ChatGPT"
    case .claude: return "Claude"
    case .cursor: return "Cursor"
    case .vast: return "Vast.ai"
    }
  }
  var subtitle: String { self == .vast ? "GPU rentals & earnings" : "Subscription usage & resets" }
}

/// Legacy layout of older preferences, migrated to elements on load.
enum MenuStyle: String, Codable { case iconAndValue, iconOnly, valueOnly }

/// Legacy single metric of older preferences, migrated to an element on load.
enum MenuMetric: String, Codable {
  case used, remaining, reset, rentals, hourly, today
  var kind: MenuElementKind {
    switch self {
    case .used: return .used
    case .remaining: return .remaining
    case .reset: return .reset
    case .rentals: return .rentals
    case .hourly: return .hourly
    case .today: return .today
    }
  }
}

enum AppTheme: String, CaseIterable, Codable {
  case system, light, dark
  var title: String { rawValue.capitalized }
}

/// Window for the machine utilization ring in the Vast.ai dropdown.
enum UtilizationPeriod: String, CaseIterable, Codable {
  case day, week, month
  var title: String {
    switch self {
    case .day: return "Today"
    case .week: return "7 days"
    case .month: return "30 days"
    }
  }
  /// Complete UTC days before today; 0 means today so far.
  var days: Int {
    switch self {
    case .day: return 0
    case .week: return 7
    case .month: return 30
    }
  }
  var shortLabel: String {
    switch self {
    case .day: return "today"
    case .week: return "7d"
    case .month: return "30d"
    }
  }
}

/// How allowance and utilization shares are drawn in the dropdowns.
enum GaugeStyle: String, CaseIterable, Codable {
  case ring, ringValue, bar
  var title: String {
    switch self {
    case .ring: return "Ring"
    case .ringValue: return "Ring with value"
    case .bar: return "Bar"
    }
  }
}

/// How Vast.ai earnings are shown: as recorded, after the entered power cost, or both.
enum EarningsView: String, CaseIterable, Codable {
  case gross, net, both
  var title: String {
    switch self {
    case .gross: return "Gross"
    case .net: return "Net"
    case .both: return "Both"
    }
  }
}

/// One building block of a menu bar item, composed like iStat Menus: icon, values, rings, graphs.
enum MenuElementKind: String, Codable, CaseIterable {
  case icon, used, remaining, reset, ring, rentals, today, hourly, utilization, earningsGraph

  static func available(for category: ProviderCategory) -> [MenuElementKind] {
    category == .vast
      ? [.icon, .rentals, .today, .hourly, .utilization, .ring, .earningsGraph]
      : [.icon, .used, .remaining, .reset, .ring]
  }

  func title(for category: ProviderCategory) -> String {
    switch self {
    case .icon: return "Icon"
    case .used: return "Usage percentage"
    case .remaining: return "Allowance remaining"
    case .reset: return "Time until reset"
    case .ring: return category == .vast ? "Utilization ring" : "Usage ring"
    case .rentals: return "Rented / total machines"
    case .today: return "Earnings today"
    case .hourly: return "Estimated GPU rate / hour"
    case .utilization: return "Utilization percentage"
    case .earningsGraph: return "7-day earnings graph"
    }
  }

  var symbol: String {
    switch self {
    case .icon: return "app"
    case .used: return "percent"
    case .remaining: return "chart.pie"
    case .reset: return "clock"
    case .ring: return "circle.circle"
    case .rentals: return "server.rack"
    case .today: return "dollarsign.circle"
    case .hourly: return "clock.arrow.circlepath"
    case .utilization: return "speedometer"
    case .earningsGraph: return "chart.bar"
    }
  }

  /// Elements that follow one allowance pool and can carry its short name.
  func usesPool(for category: ProviderCategory) -> Bool {
    category != .vast && [.used, .remaining, .reset, .ring].contains(self)
  }

  var isText: Bool { ![.icon, .ring, .earningsGraph].contains(self) }
}

struct MenuElement: Codable, Equatable, Identifiable {
  var id = UUID()
  var kind: MenuElementKind
  /// Pool for allowance elements; nil follows the most-used main pool.
  var windowID: String?
  /// Prefix a value with the pool's short name, as in "5h 68%".
  var showLabel = false

  init(_ kind: MenuElementKind, windowID: String? = nil, showLabel: Bool = false) {
    self.kind = kind
    self.windowID = windowID
    self.showLabel = showLabel
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    kind = try values.decode(MenuElementKind.self, forKey: .kind)
    windowID = try values.decodeIfPresent(String.self, forKey: .windowID)
    showLabel = try values.decodeIfPresent(Bool.self, forKey: .showLabel) ?? false
  }
}

struct ProviderPreferences: Codable, Equatable {
  var enabled = true
  /// Ordered contents of the menu bar item.
  var elements: [MenuElement] = [MenuElement(.icon), MenuElement(.used)]
  var showAdditional = true
  var showResetDates = true
  var showEarningsHistory = true
  var showMachineDetails = true
  // Vast.ai only
  var currency = "USD"
  /// Electricity price per kWh in the display currency.
  var powerPrice: Double?
  /// Average draw in watts per machine id, entered by the user.
  var machineWatts: [String: Double] = [:]
  var utilizationPeriod = UtilizationPeriod.week
  var earningsView = EarningsView.gross

  enum CodingKeys: String, CodingKey {
    case enabled, elements, showAdditional, showResetDates, showEarningsHistory
    case showMachineDetails, currency, powerPrice, machineWatts, utilizationPeriod, earningsView
  }

  private enum LegacyKeys: String, CodingKey { case style, metric, windowID }

  init() {}

  // Saved preferences predate newer keys; every key decodes with its default when absent, and
  // the old style-plus-metric layout becomes a list of elements.
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    showAdditional = try values.decodeIfPresent(Bool.self, forKey: .showAdditional) ?? true
    showResetDates = try values.decodeIfPresent(Bool.self, forKey: .showResetDates) ?? true
    showEarningsHistory =
      try values.decodeIfPresent(Bool.self, forKey: .showEarningsHistory) ?? true
    showMachineDetails = try values.decodeIfPresent(Bool.self, forKey: .showMachineDetails) ?? true
    currency = try values.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
    powerPrice = try values.decodeIfPresent(Double.self, forKey: .powerPrice)
    machineWatts = try values.decodeIfPresent([String: Double].self, forKey: .machineWatts) ?? [:]
    utilizationPeriod =
      try values.decodeIfPresent(UtilizationPeriod.self, forKey: .utilizationPeriod) ?? .week
    earningsView = try values.decodeIfPresent(EarningsView.self, forKey: .earningsView) ?? .gross
    if let saved = try values.decodeIfPresent([MenuElement].self, forKey: .elements) {
      elements = saved
    } else {
      let legacy = try decoder.container(keyedBy: LegacyKeys.self)
      elements = Self.elements(
        style: try legacy.decodeIfPresent(MenuStyle.self, forKey: .style) ?? .iconAndValue,
        metric: try legacy.decodeIfPresent(MenuMetric.self, forKey: .metric),
        windowID: try legacy.decodeIfPresent(String.self, forKey: .windowID))
    }
  }

  /// Older preferences described the item as a style and one metric.
  static func elements(style: MenuStyle, metric: MenuMetric?, windowID: String?) -> [MenuElement] {
    let value = MenuElement(metric?.kind ?? .used, windowID: windowID)
    switch style {
    case .iconOnly: return [MenuElement(.icon)]
    case .valueOnly: return [value]
    case .iconAndValue: return [MenuElement(.icon), value]
    }
  }

  static func defaults(for category: ProviderCategory) -> Self {
    var value = Self()
    value.elements = [MenuElement(.icon), MenuElement(category == .vast ? .rentals : .used)]
    return value
  }
}

struct AppPreferences: Codable, Equatable {
  var providers: [String: ProviderPreferences] = [:]
  var theme = AppTheme.system
  var refreshInterval = 60
  var gaugeStyle = GaugeStyle.ring

  enum CodingKeys: String, CodingKey { case providers, theme, refreshInterval, gaugeStyle }
  private enum LegacyKeys: String, CodingKey { case ringValuesInside }

  init() {}

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    providers =
      try values.decodeIfPresent([String: ProviderPreferences].self, forKey: .providers) ?? [:]
    theme = try values.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .system
    refreshInterval = try values.decodeIfPresent(Int.self, forKey: .refreshInterval) ?? 60
    if let style = try values.decodeIfPresent(GaugeStyle.self, forKey: .gaugeStyle) {
      gaugeStyle = style
    } else {
      let legacy = try decoder.container(keyedBy: LegacyKeys.self)
      let inside = try legacy.decodeIfPresent(Bool.self, forKey: .ringValuesInside) ?? false
      gaugeStyle = inside ? .ringValue : .ring
    }
  }

  func provider(_ category: ProviderCategory) -> ProviderPreferences {
    providers[category.rawValue] ?? .defaults(for: category)
  }

  static func load(from defaults: UserDefaults) -> Self {
    if let data = defaults.data(forKey: "preferences.v2"),
      let saved = try? JSONDecoder().decode(Self.self, from: data)
    {
      return saved
    }
    var result = Self()
    if defaults.bool(forKey: "compactMenu") {
      for category in ProviderCategory.allCases {
        var item = ProviderPreferences.defaults(for: category)
        item.elements = [MenuElement(.icon)]
        result.providers[category.rawValue] = item
      }
    }
    return result
  }
}

extension Provider {
  /// The pool an element follows: a specific window, or the most-used main pool.
  func pool(_ windowID: String?) -> UsageWindow? {
    if let windowID {
      return windows?.first { $0.id == windowID && !$0.hasExpired }
    }
    return visibleWindows.filter { !$0.hasExpired }.max { $0.usedPercent < $1.usedPercent }
  }

  /// Mean utilization over the machines that reported one.
  var utilizationAverage: Double? {
    let values = (machines ?? []).compactMap(\.utilization)
    return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
  }

  /// Earnings in the display currency, gross as recorded and net of the entered power cost.
  func earnings(_ preferences: ProviderPreferences) -> EarningsFigures {
    let money = MoneyFormat(currency: preferences.currency, rates: rates)
    let gross = EarningsFigures.Set(
      today: todayEarnings.map { $0 * money.factor },
      hourly: estimatedHourly.map { $0 * money.factor },
      average: sevenDayAverage.map { $0 * money.factor })
    var powerPerDay: Double?
    if let price = preferences.powerPrice, price > 0 {
      let watts = (machines ?? []).compactMap { preferences.machineWatts[$0.id] }.reduce(0, +)
      if watts > 0 { powerPerDay = watts * 24 / 1000 * price }
    }
    guard let powerPerDay else { return EarningsFigures(gross: gross, net: nil, powerPerDay: nil) }
    // Today only carries the power used since 00:00 UTC.
    let elapsed = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) / 86400
    let net = EarningsFigures.Set(
      today: gross.today.map { $0 - powerPerDay * elapsed },
      hourly: gross.hourly.map { $0 - powerPerDay / 24 },
      average: gross.average.map { $0 - powerPerDay })
    return EarningsFigures(gross: gross, net: net, powerPerDay: powerPerDay)
  }

  /// Text for a value element; nil for icon, ring and graph elements. Stale data shows a dash.
  func text(for element: MenuElement, preferences: ProviderPreferences) -> String? {
    guard element.kind.isText else { return nil }
    guard isFresh else { return "—" }
    let money = MoneyFormat(currency: preferences.currency, rates: rates)
    switch element.kind {
    case .rentals:
      guard let rentedCount, let machineCount else { return "—" }
      return "\(rentedCount)/\(machineCount)"
    case .today: return money.local(earnings(preferences).shown(preferences.earningsView).today)
    case .hourly:
      return earnings(preferences).shown(preferences.earningsView).hourly.map {
        money.local($0) + "/h"
      } ?? "—"
    case .utilization: return utilizationAverage.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    default:
      guard let window = pool(element.windowID) else { return "—" }
      let value: String
      switch element.kind {
      case .remaining: value = String(format: "%.0f%%", max(0, 100 - window.usedPercent))
      case .reset: value = shortCountdown(window.resetDate)
      default: value = window.percent
      }
      return element.showLabel ? window.shortLabel + " " + value : value
    }
  }

  /// Every text element on one line, for tooltips and accessibility.
  func menuSummary(_ preferences: ProviderPreferences) -> String {
    let parts = preferences.elements.compactMap { text(for: $0, preferences: preferences) }
    return parts.isEmpty ? displayName : parts.joined(separator: " · ")
  }
}

struct EarningsFigures {
  struct Set {
    let today: Double?
    let hourly: Double?
    let average: Double?
  }
  let gross: Set
  /// Present only when a power price and at least one wattage are configured.
  let net: Set?
  let powerPerDay: Double?

  /// Figures for a single-value context such as the menu bar: net when asked and available.
  func shown(_ view: EarningsView) -> Set { view == .net ? (net ?? gross) : gross }
}

extension UsageWindow {
  /// Compact pool name for the menu bar: "5h", "Wk", "Fable", "Cursor".
  var shortLabel: String {
    let lower = label.lowercased()
    if let range = lower.range(of: #"^\d+[\s-]*(hour|minute)"#, options: .regularExpression) {
      let digits = lower[range].prefix { $0.isNumber }
      return digits + (lower[range].contains("hour") ? "h" : "m")
    }
    if lower == "weekly" { return "Wk" }
    if let separator = label.range(of: " · ") { return String(label[..<separator.lowerBound]) }
    return String(label.split(separator: " ").first ?? Substring(label))
  }
}

func shortCountdown(_ date: Date?) -> String {
  guard let date, date > Date() else { return "—" }
  let minutes = max(1, Int(ceil(date.timeIntervalSinceNow / 60)))
  if minutes < 60 { return "\(minutes)m" }
  if minutes < 1440 { return "\(minutes / 60)h \(minutes % 60)m" }
  return "\(minutes / 1440)d \((minutes / 60) % 24)h"
}
