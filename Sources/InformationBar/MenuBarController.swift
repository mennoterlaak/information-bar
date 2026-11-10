import AppKit
import SwiftUI

/// Hosts the composed item inside the status button while leaving clicks to the button.
final class PassthroughHostingView: NSHostingView<AnyView> {
  required init(rootView: AnyView) { super.init(rootView: rootView) }
  @objc required dynamic init?(coder: NSCoder) { fatalError("not used") }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(_ title: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) { fatalError("not used") }
  @objc private func run() { handler() }
}

/// Owns the app's status items: which providers share one, how much each provider shows, and
/// which dropdown a click opens.
///
/// macOS places every new status item itself and puts other apps' items back at the
/// positions it remembers for them, which can land between this app's items. Grouped, the
/// providers share a single status item, so their order is the one set in Settings and
/// nothing can come between them.
@MainActor
final class MenuBarController: NSObject, NSViewToolTipOwner {
  /// One provider's part of a status item, in the button's coordinates.
  private struct Cell: Equatable {
    let category: ProviderCategory
    let minX: CGFloat
    let maxX: CGFloat
  }

  /// One status item and the providers drawn in it, left to right.
  private final class Slot {
    let item: NSStatusItem
    let hosting: PassthroughHostingView
    var segments: [MenuBarSegment] = []
    var cells: [Cell] = []
    var observers: [NSObjectProtocol] = []

    init(item: NSStatusItem, hosting: PassthroughHostingView) {
      self.item = item
      self.hosting = hosting
    }

    func cell(at x: CGFloat) -> Cell? {
      MenuBarFit.cell(at: x, ends: cells.map(\.maxX)).map { cells[$0] }
    }
  }

  /// Points macOS adds around a status item's length, on both sides together.
  private static let itemPadding: CGFloat = 16
  /// Kept free at the edge of the room that is left, so a rounding error hides nothing.
  private static let margin: CGFloat = 4
  /// Extra room a roomier arrangement needs before items grow back.
  private static let slack: CGFloat = 20
  /// Assumed width of other apps' items until the first measurement.
  private static let assumedOthers: CGFloat = 300
  private static let othersKey = "menuBar.othersWidth"

  private let store: DashboardStore
  private let panel: MenuPanel
  /// Opens Settings, on a provider's pane when one is given.
  var openSettings: (ProviderCategory?) -> Void = { _ in }

  private var slots: [Slot] = []
  /// The layout and the providers of each status item; a change rebuilds the items.
  private var structure = ""
  private var fallbackItem: NSStatusItem?
  private var activeCategory: ProviderCategory?
  /// Position on the ladder of arrangements, nil until the first fit of a composition.
  private var step: Int?
  private var ladderKey = ""
  /// Width of other apps' items right of this app's leftmost item, as last measured.
  private var others: CGFloat?
  private let measurer = NSHostingView(rootView: AnyView(EmptyView()))
  private var widths: [String: CGFloat] = [:]
  private var screenObserver: NSObjectProtocol?
  private var refitScheduled = false
  /// QA: `--notch 650` fits the items as on a display with 650 points right of its notch.
  private let simulatedBudget: CGFloat?
  private(set) var lastLimit: CGFloat?

  init(store: DashboardStore, panel: MenuPanel) {
    self.store = store
    self.panel = panel
    simulatedBudget = AppInfo.argument("--notch").flatMap(Double.init).flatMap {
      $0 > 0 ? CGFloat($0) : nil
    }
    super.init()
    let saved = store.demo ? 0 : UserDefaults.standard.double(forKey: Self.othersKey)
    if saved > 0 { others = saved }
    panel.ignoresClicks = { [weak self] window in
      self?.slots.contains { $0.item.button?.window === window } ?? false
    }
    panel.onDismiss = { [weak self] in
      guard let self, self.activeCategory != nil else { return }
      self.activeCategory = nil
      self.slots.forEach(self.render)
    }
    panel.onStep = { [weak self] offset in self?.openNeighbour(offset) }
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.scheduleRefit() }
    }
  }

  // MARK: - Layout

  /// Brings the status items in line with the preferences and the latest readings.
  func update() {
    let preferences = store.preferences
    let categories = preferences.menuCategories
    let groups: [[ProviderCategory]]
    switch preferences.menuLayout {
    case .grouped: groups = categories.isEmpty ? [] : [categories]
    case .separate: groups = categories.map { [$0] }
    }
    rebuild(groups, layout: preferences.menuLayout)
    if let activeCategory, !categories.contains(activeCategory) { panel.dismiss() }
    let forms = fit(categories)
    if let activeCategory, forms[activeCategory]?.hidden == true { panel.dismiss() }
    for (slot, group) in zip(slots, groups) { draw(slot, group, forms: forms) }
    if store.menuStep != step ?? 0 { store.menuStep = step ?? 0 }
    updateFallback()
    // SwiftUI applies the new data on the next pass; measure the open panel after it.
    DispatchQueue.main.async { [weak self] in self?.panel.refit() }
  }

  /// Creates the status items for `groups`, replacing the current ones when the layout or
  /// the providers of an item changed. A group keeps its one item while providers come and
  /// go, so it stays where the user put it.
  private func rebuild(_ groups: [[ProviderCategory]], layout: MenuLayout) {
    let key: String
    switch layout {
    case .grouped: key = groups.isEmpty ? "" : "grouped"
    case .separate: key = "separate:" + groups.map { $0[0].rawValue }.joined(separator: ",")
    }
    guard key != structure else { return }
    structure = key
    panel.dismiss()
    for slot in slots {
      slot.observers.forEach(NotificationCenter.default.removeObserver)
      NSStatusBar.system.removeStatusItem(slot.item)
    }
    // A QA run on synthetic data keeps its own positions.
    let prefix = store.demo ? "InformationBar.Demo." : "InformationBar."
    // macOS adds a new item left of the existing ones, so the last provider is made first.
    slots = groups.reversed().map { group in
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.autosaveName = prefix + (layout == .grouped ? "group" : group[0].rawValue)
      let hosting = PassthroughHostingView(rootView: AnyView(EmptyView()))
      hosting.autoresizingMask = [.height]
      let slot = Slot(item: item, hosting: hosting)
      guard let button = item.button else { return slot }
      button.target = self
      button.action = #selector(clicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      button.addSubview(hosting)
      // The item moves when other apps' items come and go, and to the display in use.
      // Without a window there is nothing to follow; a nil object would mean every window.
      guard let window = button.window else { return slot }
      for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
        slot.observers.append(
          NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
            [weak self] _ in
            Task { @MainActor in self?.scheduleRefit() }
          })
      }
      return slot
    }.reversed()
  }

  /// How much each provider shows: everything, or less when the menu bar is short of room.
  private func fit(_ categories: [ProviderCategory]) -> [ProviderCategory: MenuItemForm] {
    let preferences = store.preferences
    let counts = categories.map { preferences.provider($0).valueCount }
    let ladder = preferences.menuLadder
    let key =
      structure + "|" + categories.map(\.rawValue).joined(separator: ",") + "|"
      + counts.map(String.init).joined(separator: ",")
    if key != ladderKey {
      ladderKey = key
      step = nil
    }
    let chrome = CGFloat(slots.count) * (Self.itemPadding - 2 * MenuBarMetrics.overflow)
    let width: (Int) -> CGFloat = { [self] index in
      zip(categories, ladder[index]).reduce(chrome) {
        $1.1.hidden ? $0 : $0 + contentWidth($1.0, form: $1.1) + MenuBarMetrics.gap
      }
    }
    var chosen = 0
    lastLimit = nil
    if preferences.shortening != .never {
      lastLimit = limit()
      chosen = MenuBarFit.step(
        count: ladder.count, current: step, limit: lastLimit, slack: Self.slack, width: width)
      if preferences.shortening == .always {
        chosen = max(chosen, min(MenuBarFit.compactStep(valueCounts: counts), ladder.count - 1))
      }
    }
    step = chosen
    return Dictionary(uniqueKeysWithValues: zip(categories, ladder[chosen]))
  }

  /// Room for this app's items on the display that shows them now.
  private func limit() -> CGFloat? {
    // An item that is left out keeps the frame it had, so only the shown ones are measured.
    let visible = slots.filter { !$0.segments.isEmpty }
    let frames = visible.compactMap { $0.item.button?.window?.frame }
    let placed = frames.first { $0.height > 0 }
    let shown = placed.flatMap { frame in
      NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
    }
    if let shown, frames.count == visible.count,
      let measured = MenuBarSpace.others(
        items: frames, screen: shown.frame, rightOfNotch: shown.auxiliaryTopRightArea?.width),
      abs(measured - (others ?? -1)) > 0.5
    {
      others = measured
      if !store.demo { UserDefaults.standard.set(Double(measured), forKey: Self.othersKey) }
    }
    guard let screen = shown ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
    let budget =
      simulatedBudget
      ?? MenuBarSpace.budget(
        screenWidth: screen.frame.width, rightOfNotch: screen.auxiliaryTopRightArea?.width)
    return MenuBarSpace.limit(
      budget: budget, others: others ?? Self.assumedOthers, margin: Self.margin)
  }

  /// Width of a provider's content in `form`. Widths are measured once per distinct content;
  /// most updates change no text.
  private func contentWidth(_ category: ProviderCategory, form: MenuItemForm) -> CGFloat {
    let provider = store.providers[category.rawValue] ?? .placeholder(category.rawValue)
    let options = store.preferences.provider(category).shortened(to: form)
    let power = store.powerContext
    let key =
      category.rawValue + "|"
      + options.elements.map { element -> String in
        if let text = provider.text(for: element, preferences: options, power: power) {
          return text
        }
        // Rings and icons have a fixed width; the graph grows with its bars.
        let graph = element.kind == .earningsGraph && provider.isFresh
        let bars = graph ? provider.daily?.count ?? 0 : 0
        return "\u{1}\(element.kind.rawValue)\(bars)"
      }.joined(separator: "\u{2}")
    if let cached = widths[key] { return cached }
    measurer.rootView = AnyView(MenuBarItemView(provider: provider, options: options, power: power))
    let width = ceil(measurer.fittingSize.width)
    if widths.count > 400 { widths.removeAll(keepingCapacity: true) }
    widths[key] = width
    return width
  }

  private func draw(
    _ slot: Slot, _ group: [ProviderCategory], forms: [ProviderCategory: MenuItemForm]
  ) {
    guard let button = slot.item.button else { return }
    var segments: [MenuBarSegment] = []
    var cells: [Cell] = []
    var x = -MenuBarMetrics.overflow
    // A provider that does not fit even as an icon is left out until there is room.
    let group = group.filter { forms[$0]?.hidden != true }
    for category in group {
      let form = forms[category] ?? .full
      let width = contentWidth(category, form: form)
      segments.append(
        MenuBarSegment(
          category: category,
          provider: store.providers[category.rawValue] ?? .placeholder(category.rawValue),
          options: store.preferences.provider(category).shortened(to: form), width: width))
      cells.append(Cell(category: category, minX: x, maxX: x + width + MenuBarMetrics.gap))
      x += width + MenuBarMetrics.gap
    }
    slot.segments = segments
    render(slot)
    // A separate item whose provider is left out takes no room at all.
    if slot.item.isVisible == group.isEmpty { slot.item.isVisible = !group.isEmpty }
    let total = x + MenuBarMetrics.overflow
    let length = max(1, total - 2 * MenuBarMetrics.overflow)
    if abs(slot.item.length - length) > 0.5 { slot.item.length = length }
    slot.hosting.frame = NSRect(
      x: -MenuBarMetrics.overflow, y: 0, width: total, height: button.bounds.height)
    if cells != slot.cells {
      slot.cells = cells
      button.removeAllToolTips()
      // One provider uses the button's own tooltip; several get one each.
      button.toolTip = nil
      if cells.count > 1 {
        for cell in cells {
          button.addToolTip(
            NSRect(x: cell.minX, y: 0, width: cell.maxX - cell.minX, height: button.bounds.height),
            owner: self, userData: nil)
        }
      }
    }
    if let only = group.first, group.count == 1 {
      button.toolTip = tooltip(only)
      button.setAccessibilityLabel("\(only.name): \(summary(only))")
      button.setAccessibilityCustomActions(nil)
    } else {
      button.setAccessibilityLabel(
        "Information Bar: " + group.map { "\($0.name) \(summary($0))" }.joined(separator: ", "))
      button.setAccessibilityCustomActions(
        group.map { category in
          NSAccessibilityCustomAction(name: "Open \(category.name)") { [weak self] in
            self?.open(category)
            return true
          }
        })
    }
  }

  private func render(_ slot: Slot) {
    // The highlight is drawn here: it marks one provider of a group, and macOS 27 no longer
    // draws the button's own highlight for a dropdown the app opens itself.
    slot.hosting.rootView = AnyView(
      MenuBarStripView(
        segments: slot.segments, power: store.powerContext, active: activeCategory))
  }

  /// Every value of the provider's composition, whatever is shown of it at the moment.
  private func summary(_ category: ProviderCategory) -> String {
    let provider = store.providers[category.rawValue] ?? .placeholder(category.rawValue)
    return provider.menuSummary(store.preferences.provider(category), power: store.powerContext)
  }

  private func tooltip(_ category: ProviderCategory) -> String {
    let provider = store.providers[category.rawValue] ?? .placeholder(category.rawValue)
    return "\(category.name) · \(summary(category)) · \(provider.ageLabel)"
  }

  func view(
    _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
    userData data: UnsafeMutableRawPointer?
  ) -> String {
    guard let slot = slots.first(where: { $0.item.button === view }),
      let cell = slot.cell(at: point.x)
    else { return "" }
    return tooltip(cell.category)
  }

  /// A settings icon stays in the menu bar while every provider is hidden.
  private func updateFallback() {
    if slots.isEmpty && fallbackItem == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      item.button?.image = NSImage(
        systemSymbolName: "gearshape", accessibilityDescription: "Information Bar settings")
      item.button?.target = self
      item.button?.action = #selector(openGeneralSettings)
      item.button?.toolTip = "Information Bar settings. All menu bar items are hidden."
      fallbackItem = item
    } else if !slots.isEmpty, let item = fallbackItem {
      NSStatusBar.system.removeStatusItem(item)
      fallbackItem = nil
    }
  }

  private func scheduleRefit() {
    guard !refitScheduled else { return }
    refitScheduled = true
    // Moves arrive in bursts while macOS lays the menu bar out again.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      self?.refitScheduled = false
      self?.update()
    }
  }

  // MARK: - Dropdowns

  @objc private func openGeneralSettings() { openSettings(nil) }

  @objc private func clicked(_ sender: NSStatusBarButton) {
    guard let slot = slots.first(where: { $0.item.button === sender }), let window = sender.window
    else { return }
    // The pointer's place on screen says which provider was clicked. It needs nothing from
    // the event, which macOS delivers through the menu bar's own process.
    let location = window.convertPoint(fromScreen: NSEvent.mouseLocation)
    guard let cell = slot.cell(at: sender.convert(location, from: nil).x) else { return }
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      showMenu(for: cell, in: slot)
    } else {
      toggle(cell.category)
    }
  }

  /// Opens the provider's dropdown under its part of the menu bar, or closes it when open.
  func toggle(_ category: ProviderCategory) {
    if panel.isVisible && activeCategory == category {
      panel.dismiss()
      return
    }
    panel.dismiss()
    guard let (slot, cell) = locate(category), let button = slot.item.button,
      let window = button.window
    else { return }
    activeCategory = category
    store.refresh(only: category.rawValue)
    let openSettings = { [weak self] in
      self?.openSettings(category)
      return
    }
    let anchor = window.convertToScreen(
      button.convert(
        NSRect(x: cell.minX, y: 0, width: cell.maxX - cell.minX, height: button.bounds.height),
        to: nil))
    panel.present(under: anchor, on: window.screen) { [store] maxHeight in
      AnyView(
        ProviderPanel(
          store: store, category: category, openSettings: openSettings, maxHeight: maxHeight))
    }
    slots.forEach(render)
  }

  /// Opens the provider's dropdown unless it is open already.
  func open(_ category: ProviderCategory) {
    if !(panel.isVisible && activeCategory == category) { toggle(category) }
  }

  func dismiss() { panel.dismiss() }

  /// Left and right arrow keys move between the dropdowns, as between menus.
  private func openNeighbour(_ offset: Int) {
    let shown = slots.flatMap { $0.cells.map(\.category) }
    guard let activeCategory,
      let next = MenuBarFit.neighbour(of: activeCategory, in: shown, offset: offset)
    else { return }
    toggle(next)
  }

  private func locate(_ category: ProviderCategory) -> (Slot, Cell)? {
    for slot in slots {
      if let cell = slot.cells.first(where: { $0.category == category }) { return (slot, cell) }
    }
    return nil
  }

  /// Secondary click: the actions that need no dropdown.
  private func showMenu(for cell: Cell, in slot: Slot) {
    guard let button = slot.item.button else { return }
    panel.dismiss()
    let category = cell.category
    let menu = NSMenu()
    menu.addItem(
      ActionMenuItem("Refresh \(category.name)") { [store] in
        store.refresh(force: true, only: category.rawValue)
      })
    menu.addItem(
      ActionMenuItem("\(category.name) Settings…") { [weak self] in self?.openSettings(category) })
    menu.addItem(.separator())
    menu.addItem(
      ActionMenuItem("Information Bar Settings…") { [weak self] in self?.openSettings(nil) })
    menu.addItem(ActionMenuItem("Quit Information Bar") { NSApp.terminate(nil) })
    activeCategory = category
    slots.forEach(render)
    // Runs until the menu closes.
    menu.popUp(
      positioning: nil, at: NSPoint(x: max(0, cell.minX), y: button.bounds.maxY + 6), in: button)
    activeCategory = nil
    slots.forEach(render)
  }

  // MARK: - QA

  /// The status item window that holds `category`, for placement logs.
  func itemFrame(_ category: ProviderCategory) -> NSRect {
    locate(category)?.0.item.button?.window?.frame ?? .zero
  }

  /// One line on the arrangement in use, for `--exit-after` runs.
  var layoutDescription: String {
    let forms = slots.flatMap(\.segments).map { segment -> String in
      let kept = segment.options.elements.filter { $0.kind != .icon }.count
      return "\(segment.category.rawValue):\(kept)"
    }
    let lengths = slots.map { String(Int($0.item.length)) }.joined(separator: ",")
    // Left edges of the status items, which read left to right when the order is right.
    let edges = slots.filter { !$0.segments.isEmpty }.map {
      $0.item.button?.window?.frame.minX ?? 0
    }
    let ordered = zip(edges, edges.dropFirst()).allSatisfy { $0 < $1 }
    let hidden = store.preferences.menuCategories.count - forms.count
    return "menu bar layout \(store.preferences.menuLayout.rawValue) step \(step ?? 0) limit "
      + (lastLimit.map { String(Int($0)) } ?? "none")
      + " others \(others.map { String(Int($0)) } ?? "unknown") lengths \(lengths) order "
      + (ordered ? "ok" : "mixed") + " left out \(hidden) values " + forms.joined(separator: " ")
  }
}
