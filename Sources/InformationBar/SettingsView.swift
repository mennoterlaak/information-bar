import AppKit
import SwiftUI

/// System Settings structure: sidebar list of panes, grouped forms on the right.
struct SettingsView: View {
  @ObservedObject var store: DashboardStore
  var openProvider: (ProviderCategory) -> Void = { _ in }

  private var selection: Binding<String?> {
    Binding(get: { store.selectedSettings }, set: { store.selectedSettings = $0 ?? "global" })
  }

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        HStack(spacing: 8) {
          IconTile(symbol: "gearshape", color: .gray, theme: store.iconTheme)
          Text("General")
        }.tag("global")
        Section {
          ForEach(ProviderCategory.allCases.filter { $0 != .vast }) { sidebarRow($0) }
        }
        Section {
          sidebarRow(.vast)
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
      .safeAreaInset(edge: .bottom) { sidebarFooter }
    } detail: {
      if let category = ProviderCategory(rawValue: store.selectedSettings) {
        CategorySettings(
          store: store, category: category, openDropdown: { openProvider(category) }
        ).id(category)
      } else {
        GeneralSettings(store: store)
      }
    }
    .frame(
      minWidth: 760, idealWidth: 840, maxWidth: .infinity, minHeight: 600, idealHeight: 720,
      maxHeight: .infinity)
  }

  private func sidebarRow(_ category: ProviderCategory) -> some View {
    let enabled = store.preferences.provider(category).enabled
    return HStack(spacing: 8) {
      IconTile(id: category.rawValue, theme: store.iconTheme)
      Text(category.name)
      Spacer()
      Circle().fill(enabled ? Color.green : Color.secondary.opacity(0.3))
        .frame(width: 6, height: 6)
        .help(enabled ? "Shown in the menu bar" : "Hidden from the menu bar")
    }
    .tag(category.rawValue)
    .contextMenu {
      Button(enabled ? "Hide from Menu Bar" : "Show in Menu Bar") {
        store.update(category) { $0.enabled.toggle() }
      }
    }
  }

  private var sidebarFooter: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 8) {
        Text("Information Bar \(AppInfo.version)").font(.caption).foregroundStyle(.tertiary)
          .lineLimit(1)
        Spacer(minLength: 4)
        Button {
          NSApp.terminate(nil)
        } label: {
          Image(systemName: "power")
        }.buttonStyle(.plain).help("Quit Information Bar")
      }
      .font(.callout).padding(.horizontal, 12).padding(.vertical, 10)
    }
  }
}

/// Explanation behind an info icon: a popover on click, a tooltip on hover.
struct InfoButton: View {
  let text: String
  @State private var shown = false
  var body: some View {
    Button {
      shown.toggle()
    } label: {
      Image(systemName: "info.circle")
    }
    .buttonStyle(.plain).foregroundStyle(.secondary).help(text)
    .popover(isPresented: $shown, arrowEdge: .bottom) {
      Text(text).font(.callout).frame(width: 280, alignment: .leading).padding(14)
    }
  }
}

/// Section header with an info icon at the end.
func sectionHeader(_ title: String, info: String) -> some View {
  HStack(spacing: 6) {
    Text(title)
    InfoButton(text: info)
  }
}

/// The system's icon style from System Settings, Appearance: default, dark, clear or tinted.
enum IconStyle {
  case standard, dark, clear, tinted

  /// Resolves the `AppleIconAppearanceTheme` value; automatic variants follow the appearance.
  static func resolve(_ theme: String, for scheme: ColorScheme) -> IconStyle {
    let automatic = theme.localizedCaseInsensitiveContains("auto")
    let applies = !automatic || scheme == .dark
    if theme.contains("Clear") { return .clear }
    if theme.contains("Tinted") { return applies ? .tinted : .standard }
    if theme.contains("Dark") { return applies ? .dark : .standard }
    return .standard
  }
}

/// Icon-canvas tile painted with Canvas in the system icon style: continuous corners, the
/// style's base, a specular highlight across the top, a faint rim, and the mark inside.
struct IconTile: View {
  enum Glyph {
    case provider(String)
    case symbol(String, Color)
  }
  let glyph: Glyph
  var size: CGFloat = 22
  /// System icon style value; passed in so a change re-renders the tile at once.
  var theme = UserDefaults.standard.AppleIconAppearanceTheme ?? "Regular"
  @Environment(\.colorScheme) private var scheme

  init(id: String, size: CGFloat = 22, theme: String? = nil) {
    glyph = .provider(id)
    self.size = size
    if let theme { self.theme = theme }
  }

  init(symbol: String, color: Color, size: CGFloat = 22, theme: String? = nil) {
    glyph = .symbol(symbol, color)
    self.size = size
    if let theme { self.theme = theme }
  }

  private var color: Color {
    switch glyph {
    case .provider(let id): return .provider(id)
    case .symbol(_, let color): return color
    }
  }

  /// Provider marks come pre-tinted because Canvas draws NSImage-backed images verbatim.
  private func glyphImage(_ style: IconStyle) -> Image {
    switch glyph {
    case .provider(let id):
      return Image(
        nsImage: ProviderArtwork.image(id, size: size * 0.6, tint: NSColor(glyphColor(style))))
    case .symbol(let name, _):
      return Image(systemName: name).renderingMode(.template)
    }
  }

  var body: some View {
    let style = IconStyle.resolve(theme, for: scheme)
    let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
    ZStack {
      if style == .clear {
        shape.fill(.clear).glassEffect(.regular, in: shape)
      }
      Canvas { context, canvasSize in
        let rect = CGRect(origin: .zero, size: canvasSize)
        let path = shape.path(in: rect)
        context.clip(to: path)
        switch style {
        case .standard:
          context.fill(
            path,
            with: .linearGradient(
              Gradient(colors: [color.opacity(0.85), color, color.opacity(0.92)]),
              startPoint: .zero, endPoint: CGPoint(x: 0, y: rect.maxY)))
        case .dark:
          context.fill(
            path,
            with: .linearGradient(
              Gradient(colors: [Color(white: 0.13), Color(white: 0.09)]),
              startPoint: .zero, endPoint: CGPoint(x: 0, y: rect.maxY)))
        case .tinted:
          context.fill(path, with: .color(Color(white: 0.1)))
          context.fill(
            path,
            with: .linearGradient(
              Gradient(colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.25)]),
              startPoint: .zero, endPoint: CGPoint(x: 0, y: rect.maxY)))
        case .clear:
          break
        }
        // A soft sheen below the top edge; barely there on the dark canvas, which System
        // Settings keeps almost flat.
        let sheen: Double
        switch style {
        case .standard: sheen = 0.14
        case .dark: sheen = 0.04
        case .clear: sheen = 0.3
        case .tinted: sheen = 0.1
        }
        let highlight = Path(
          ellipseIn: CGRect(
            x: -rect.width * 0.2, y: -rect.height * 0.6, width: rect.width * 1.4,
            height: rect.height * 0.95))
        context.fill(
          highlight,
          with: .linearGradient(
            Gradient(colors: [.white.opacity(sheen), .white.opacity(0)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: rect.height * 0.4)))
        // Faint rim just inside the edge.
        context.stroke(
          shape.path(in: rect.insetBy(dx: 0.5, dy: 0.5)),
          with: .color(.white.opacity(style == .dark ? 0.1 : 0.16)), lineWidth: 1)
        // The mark, tinted for the style and centred.
        var mark = context.resolve(glyphImage(style))
        mark.shading = .color(glyphColor(style))
        let target = size * 0.6
        let ratio = mark.size.width / max(1, mark.size.height)
        let drawn =
          ratio > 1
          ? CGSize(width: target, height: target / ratio)
          : CGSize(width: target * ratio, height: target)
        context.draw(
          mark,
          in: CGRect(
            x: (rect.width - drawn.width) / 2, y: (rect.height - drawn.height) / 2,
            width: drawn.width, height: drawn.height))
      }
      // Template images take the canvas foreground style; the mark colour follows the icon style.
      .foregroundStyle(glyphColor(style))
    }
    .frame(width: size, height: size)
  }

  /// Monochrome brands get a white mark on the dark canvas; coloured brands keep their colour.
  private var monochrome: Bool {
    if case .provider(let id) = glyph { return Color.isMonochrome(id) }
    return false
  }

  private func glyphColor(_ style: IconStyle) -> Color {
    switch style {
    case .standard: return .white
    case .dark: return monochrome ? .white : color
    case .clear: return .primary
    case .tinted: return .accentColor
    }
  }
}

/// Decimal entry that accepts "," or "." and commits on Enter or when focus leaves.
struct DecimalField: View {
  let title: String
  @Binding var value: Double?
  var prompt = ""
  var suffix: String? = nil
  var minimumDigits = 0
  @State private var text = ""
  @FocusState private var focused: Bool

  var body: some View {
    LabeledContent(title) {
      HStack(spacing: 5) {
        TextField(title, text: $text, prompt: Text(prompt)).labelsHidden()
          .multilineTextAlignment(.trailing).frame(maxWidth: 140)
          .focused($focused).onSubmit(commit)
        if let suffix { Text(suffix).foregroundStyle(.secondary) }
      }
    }
    .onAppear { text = formatDecimalInput(value, minimumDigits: minimumDigits) }
    .onChange(of: focused) { _, isFocused in
      if !isFocused { commit() }
    }
    .onChange(of: value) { _, newValue in
      if !focused { text = formatDecimalInput(newValue, minimumDigits: minimumDigits) }
    }
    .onDisappear(perform: commit)
  }

  private func commit() {
    let parsed = parseDecimalInput(text)
    if parsed != value { value = parsed }
    text = formatDecimalInput(parsed, minimumDigits: minimumDigits)
  }
}

struct GeneralSettings: View {
  @ObservedObject var store: DashboardStore

  var body: some View {
    Form {
      Section {
        MenuBarPreview(store: store)
      } header: {
        sectionHeader(
          "Menu bar",
          info:
            "Hold ⌘ and drag items in the menu bar to reorder them. Each item's contents are composed on its own pane."
        )
      }
      Section("Menu bar items") {
        ForEach(ProviderCategory.allCases) { category in
          Toggle(
            isOn: Binding(
              get: { store.preferences.provider(category).enabled },
              set: { value in store.update(category) { $0.enabled = value } })
          ) {
            HStack(spacing: 10) {
              IconTile(id: category.rawValue, size: 26, theme: store.iconTheme)
              VStack(alignment: .leading, spacing: 1) {
                Text(category.name)
                Text(category.subtitle).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      Section {
        Picker(
          "Appearance", selection: Binding(get: { store.preferences.theme }, set: store.setTheme)
        ) {
          ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Picker(
          "Refresh accounts",
          selection: Binding(
            get: { store.preferences.refreshInterval }, set: store.setRefreshInterval)
        ) {
          Text("Every minute").tag(60)
          Text("Every 2 minutes").tag(120)
        }
        Picker(
          "Gauges",
          selection: Binding(get: { store.preferences.gaugeStyle }, set: store.setGaugeStyle)
        ) {
          ForEach(GaugeStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Toggle(
          "Open at login",
          isOn: Binding(get: { store.launchAtLogin }, set: store.setLaunchAtLogin))
        if let message = store.loginMessage {
          Text(message).font(.callout).foregroundStyle(.orange)
        }
      } header: {
        sectionHeader(
          "Options",
          info:
            "Gauges are the rings or bars that show allowance and utilization shares in the dropdowns. Claude is checked at most every 5 minutes whatever the interval. Server retry delays are honored."
        )
      }
    }
    .formStyle(.grouped)
    .navigationTitle("General")
  }
}

struct MenuBarPreview: View {
  @ObservedObject var store: DashboardStore
  var category: ProviderCategory?
  private var categories: [ProviderCategory] {
    category.map { [$0] }
      ?? ProviderCategory.allCases.filter { store.preferences.provider($0).enabled }
  }
  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "apple.logo").font(.system(size: 13)).foregroundStyle(.tertiary)
      Spacer(minLength: 10)
      ForEach(categories) { item in
        let option = store.preferences.provider(item)
        MenuBarItemView(
          provider: store.providers[item.rawValue] ?? .placeholder(item.rawValue), options: option
        ).opacity(option.enabled ? 1 : 0.35)
      }
      if categories.isEmpty {
        Image(systemName: "gearshape").help(
          "A settings icon stays in the menu bar while every item is hidden.")
      }
      Image(systemName: "switch.2").foregroundStyle(.tertiary)
    }.padding(.horizontal, 14).frame(height: 38)
      .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
      .accessibilityLabel("Menu bar preview")
  }
}

/// One row of the menu bar composition: what it shows, which pool it follows, drag to reorder,
/// and a remove button.
struct MenuElementRow: View {
  @ObservedObject var store: DashboardStore
  let category: ProviderCategory
  let element: MenuElement
  let windows: [UsageWindow]
  @State private var targeted = false
  private var elements: [MenuElement] { store.preferences.provider(category).elements }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
        .help("Drag to reorder")
      Image(systemName: element.kind.symbol).foregroundStyle(.secondary).frame(width: 18)
      Text(element.kind.title(for: category))
      Spacer()
      if element.kind.usesPool(for: category) {
        Picker("Allowance", selection: poolBinding) {
          Text("Most-used main allowance").tag("automatic")
          ForEach(windows) { Text($0.label).tag($0.id) }
          if let selected = element.windowID, !windows.contains(where: { $0.id == selected }) {
            Text("Previously selected (unavailable)").tag(selected)
          }
        }.labelsHidden().frame(maxWidth: 220)
        if element.kind.isText {
          Toggle("Label", isOn: labelBinding).toggleStyle(.checkbox)
            .help("Prefix the value with the pool's short name")
        }
      }
      Button(action: remove) {
        Image(systemName: "minus.circle").foregroundStyle(.secondary)
      }
      .buttonStyle(.plain).disabled(elements.count == 1).help("Remove this item")
    }
    .padding(.horizontal, 6).padding(.vertical, 2)
    .background(
      targeted ? Color.accentColor.opacity(0.12) : Color.clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
    .contentShape(Rectangle())
    .draggable(element.id.uuidString)
    .dropDestination(for: String.self) { dropped, _ in
      guard let dragged = dropped.first.flatMap(UUID.init(uuidString:)) else { return false }
      move(dragged, before: element.id)
      return true
    } isTargeted: {
      targeted = $0
    }
  }

  private var poolBinding: Binding<String> {
    Binding(
      get: { element.windowID ?? "automatic" },
      set: { value in change { $0.windowID = value == "automatic" ? nil : value } })
  }

  private var labelBinding: Binding<Bool> {
    Binding(get: { element.showLabel }, set: { value in change { $0.showLabel = value } })
  }

  private func change(_ update: (inout MenuElement) -> Void) {
    store.update(category) { preferences in
      if let position = preferences.elements.firstIndex(where: { $0.id == element.id }) {
        update(&preferences.elements[position])
      }
    }
  }

  /// Puts the dragged element in the target row's place; the rest shift to make room.
  private func move(_ dragged: UUID, before target: UUID) {
    store.update(category) { preferences in
      guard let from = preferences.elements.firstIndex(where: { $0.id == dragged }),
        let to = preferences.elements.firstIndex(where: { $0.id == target }), from != to
      else { return }
      let item = preferences.elements.remove(at: from)
      preferences.elements.insert(item, at: to)
    }
  }

  private func remove() {
    store.update(category) { $0.elements.removeAll { $0.id == element.id } }
  }
}

struct CategorySettings: View {
  @ObservedObject var store: DashboardStore
  let category: ProviderCategory
  let openDropdown: () -> Void
  @State private var key = ""
  private var options: ProviderPreferences { store.preferences.provider(category) }
  private var provider: Provider {
    store.providers[category.rawValue] ?? .placeholder(category.rawValue)
  }

  private func binding<T>(_ keyPath: WritableKeyPath<ProviderPreferences, T>) -> Binding<T> {
    Binding(
      get: { options[keyPath: keyPath] },
      set: { value in store.update(category) { $0[keyPath: keyPath] = value } })
  }

  var body: some View {
    Form {
      Section {
        HStack(spacing: 12) {
          IconTile(id: category.rawValue, size: 40, theme: store.iconTheme)
          VStack(alignment: .leading, spacing: 2) {
            Text(category.name).font(.title3.weight(.semibold))
            Text(category.subtitle).font(.callout).foregroundStyle(.secondary)
          }
          Spacer()
          Toggle("Show in menu bar", isOn: binding(\.enabled)).labelsHidden()
            .toggleStyle(.switch)
            .help("Show \(category.name) in the menu bar")
        }.padding(.vertical, 2)
      }
      Section {
        MenuBarPreview(store: store, category: category)
        ForEach(options.elements) { element in
          MenuElementRow(
            store: store, category: category, element: element, windows: provider.windows ?? [])
        }
        HStack {
          Menu {
            ForEach(MenuElementKind.available(for: category), id: \.self) { kind in
              Button(kind.title(for: category)) {
                store.update(category) { $0.elements.append(MenuElement(kind)) }
              }
            }
          } label: {
            Label("Add item", systemImage: "plus")
          }
          .fixedSize()
          Spacer()
          Button("Open dropdown", action: openDropdown).disabled(!options.enabled)
        }
      } header: {
        sectionHeader(
          "Menu bar",
          info: category == .vast
            ? "Drag rows to reorder the menu bar item; the minus removes an item."
            : "Drag rows to reorder the menu bar item; the minus removes an item. Value items can follow one allowance and carry its short name, as in 5h 68%."
        )
      }
      Section {
        if category == .vast {
          Toggle("7-day earnings chart", isOn: binding(\.showEarningsHistory))
          Toggle("Machine details line", isOn: binding(\.showMachineDetails))
        } else {
          Toggle("Additional allowances", isOn: binding(\.showAdditional))
          Toggle("Exact reset times", isOn: binding(\.showResetDates))
        }
      } header: {
        sectionHeader(
          "Dropdown",
          info: category == .vast
            ? "Hover a machine in the dropdown for its reported averages, temperature, reliability and CPU."
            : "Percentages and reset times are reported by \(category.name).")
      }
      if category == .vast {
        currencyAndPower
        utilization
      }
      connection
    }
    .formStyle(.grouped)
    .navigationTitle(category.name)
  }

  private var currencyAndPower: some View {
    Section {
      Picker("Currency", selection: binding(\.currency)) {
        Text("US dollar").tag("USD")
        Text("Euro").tag("EUR")
      }
      if options.currency == "EUR" {
        LabeledContent("Exchange rate", value: rateDescription)
      }
      DecimalField(
        title: "Electricity price per kWh", value: priceBinding, prompt: "Not set",
        suffix: options.currency, minimumDigits: 2)
      ForEach(provider.machines ?? []) { machine in
        DecimalField(
          title: "\(machine.gpu) · \(machine.name)", value: wattsBinding(machine.id),
          prompt: "Average draw", suffix: "W")
      }
      if provider.machines?.isEmpty != false {
        Text("Machines appear here once the account is connected.").foregroundStyle(.secondary)
      }
      Picker("Earnings", selection: binding(\.earningsView)) {
        ForEach(EarningsView.allCases, id: \.self) { Text($0.title).tag($0) }
      }
    } header: {
      sectionHeader(
        "Currency & power",
        info:
          "Euro amounts use the European Central Bank reference rate via api.frankfurter.dev, refreshed every 12 hours. Power cost is each machine's watts × 24 h × the price per kWh. Net earnings deduct it: today for the hours elapsed since 00:00 UTC, the rate per hour, and the 7-day average per day. Gross shows recorded revenue; Both shows two columns."
      )
    }
  }

  private var rateDescription: String {
    if let rate = provider.rates?["EUR"] {
      return String(format: "1 USD = %.4f EUR", rate)
        + (provider.ratesDate.map { " · ECB \($0)" } ?? "")
    }
    return provider.updatedAt == nil ? "Fetching…" : "Unavailable, amounts stay in USD"
  }

  private var priceBinding: Binding<Double?> {
    Binding(
      get: { options.powerPrice },
      set: { value in
        store.update(category) { $0.powerPrice = (value ?? 0) > 0 ? value : nil }
      })
  }

  private func wattsBinding(_ id: String) -> Binding<Double?> {
    Binding(
      get: { options.machineWatts[id] },
      set: { value in
        store.update(category) {
          if let value, value > 0 {
            $0.machineWatts[id] = value
          } else {
            $0.machineWatts.removeValue(forKey: id)
          }
        }
      })
  }

  private var utilization: some View {
    Section {
      Picker("Ring period", selection: binding(\.utilizationPeriod)) {
        ForEach(UtilizationPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      if let error = provider.utilizationError {
        Text(error).font(.callout).foregroundStyle(.orange)
      }
    } header: {
      sectionHeader(
        "Utilization",
        info:
          "Each machine's ring shows the share of the period's listed GPU hours that earned revenue. Rentals priced below the listing lower it."
      )
    }
  }

  private var connection: some View {
    Section {
      LabeledContent(
        category == .vast ? "Vast.ai host account" : (provider.plan ?? "Subscription") + " account"
      ) {
        StatePill(
          text: provider.isFresh
            ? "Connected"
            : category == .vast && store.keyConnected ? "Key saved" : "Check connection",
          color: provider.isFresh ? .live : .orange)
      }
      if category == .vast {
        SecureField(store.keyConnected ? "Replace API key" : "Vast.ai API key", text: $key)
          .onSubmit(save)
        HStack {
          Link("Manage API keys", destination: URL(string: "https://cloud.vast.ai/manage-keys/")!)
          Spacer()
          if store.validatingKey { ProgressView().controlSize(.small) }
          Button("Save & connect", action: save).buttonStyle(.borderedProminent)
            .disabled(key.isEmpty || store.validatingKey)
        }
        if let message = store.settingsMessage {
          Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Text(
          category == .codex
            ? "Reads the ChatGPT account signed in to the Codex CLI on this Mac."
            : category == .claude
              ? "Reads the Claude Code login on this Mac."
              : "Reads the account signed in to the Cursor app on this Mac."
        ).foregroundStyle(.secondary)
        HStack {
          Text(provider.ageLabel).foregroundStyle(.tertiary)
          Spacer()
          Button("Refresh account") { store.refresh(force: true, only: category.rawValue) }
            .disabled(store.refreshing.contains(category.rawValue))
        }
        if let error = store.collectorErrors[category.rawValue] ?? provider.error {
          Text(error).font(.callout).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    } header: {
      if category == .vast {
        sectionHeader(
          "Connection",
          info:
            "The key is stored in macOS Keychain and needs read access to machines and earnings.")
      } else {
        Text("Connection")
      }
    }
  }

  private func save() { Task { if await store.saveKey(key) { key = "" } } }
}
