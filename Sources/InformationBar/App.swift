import AppKit
import SwiftUI

/// Borderless floating panel under a status item, styled after the system's own menu bar
/// extras: glass background, rounded corners, no arrow, closes on outside clicks or Escape.
@MainActor
final class MenuPanel: NSPanel {
  static let cornerRadius: CGFloat = 16
  private let glass = NSGlassEffectView()
  /// Clips everything to the rounded shape so the window shadow follows it rather than the
  /// rectangular bounds, which otherwise shows as a thin dark outline.
  private let container = NSView()
  private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
  private var monitors: [Any] = []
  /// Windows whose clicks must not close the panel; the status items toggle it themselves.
  var ignoresClicks: (NSWindow?) -> Bool = { _ in false }
  var onDismiss: (() -> Void)?
  /// Called after the panel changes size while open; the QA flag logs it.
  var onRefit: ((NSSize) -> Void)?

  init() {
    glass.cornerRadius = Self.cornerRadius
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .popUpMenu
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    animationBehavior = .utilityWindow
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    hosting.autoresizingMask = [.width, .height]
    glass.contentView = hosting
    container.wantsLayer = true
    container.layer?.cornerRadius = Self.cornerRadius
    container.layer?.masksToBounds = true
    container.layer?.backgroundColor = NSColor.clear.cgColor
    glass.autoresizingMask = [.width, .height]
    container.addSubview(glass)
    contentView = container
  }

  private func layoutContent() {
    glass.frame = container.bounds
    hosting.frame = glass.bounds
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// Shows `content` under `button`, sized to fit. Content taller than the screen scrolls.
  func present(below button: NSStatusBarButton, content: (_ maxHeight: CGFloat?) -> AnyView) {
    guard let anchor = button.window else { return }
    let visible = (anchor.screen ?? NSScreen.main)?.visibleFrame ?? anchor.frame
    let limit = visible.height - 16
    hosting.rootView = content(nil)
    var size = hosting.fittingSize
    if size.height > limit {
      hosting.rootView = content(limit)
      size = hosting.fittingSize
    }
    let buttonFrame = anchor.convertToScreen(button.convert(button.bounds, to: nil))
    let x = min(
      max(buttonFrame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
    setFrame(
      NSRect(x: x, y: visible.maxY - 4 - size.height, width: size.width, height: size.height),
      display: true)
    layoutContent()
    makeKeyAndOrderFront(nil)
    invalidateShadow()
    installMonitors()
  }

  /// Re-measures after data changes while open, keeping the top edge under the menu bar.
  func refit() {
    guard isVisible else { return }
    let size = hosting.fittingSize
    guard abs(size.height - frame.height) > 0.5 else { return }
    setFrame(
      NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
      display: true)
    layoutContent()
    invalidateShadow()
    onRefit?(size)
  }

  func dismiss() {
    removeMonitors()
    guard isVisible else { return }
    orderOut(nil)
    onDismiss?()
  }

  private func installMonitors() {
    removeMonitors()
    let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    if let global = NSEvent.addGlobalMonitorForEvents(
      matching: clicks,
      handler: { [weak self] _ in
        self?.dismiss()
      })
    {
      monitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(
      matching: clicks.union(.keyDown),
      handler: { [weak self] event in
        guard let self else { return event }
        if event.type == .keyDown {
          guard event.keyCode == 53 else { return event }  // Escape
          self.dismiss()
          return nil
        }
        if event.window !== self && !self.ignoresClicks(event.window) { self.dismiss() }
        return event
      })
    {
      monitors.append(local)
    }
  }

  private func removeMonitors() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors.removeAll()
  }
}

/// Hosts the composed item inside the status button while leaving clicks to the button.
final class PassthroughHostingView: NSHostingView<AnyView> {
  required init(rootView: AnyView) { super.init(rootView: rootView) }
  @objc required dynamic init?(coder: NSCoder) { fatalError("not used") }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let store: DashboardStore

  override init() {
    // `--demo` runs on synthetic data in its own preferences domain, for screenshots and QA.
    if CommandLine.arguments.contains("--demo") {
      let suite = "InformationBar.Demo"
      let defaults = UserDefaults(suiteName: suite)!
      defaults.removePersistentDomain(forName: suite)
      defaults.set(try? JSONEncoder().encode(DemoData.preferences()), forKey: "preferences.v2")
      store = DashboardStore(defaults: defaults)
      store.demo = true
      store.providers = DemoData.providers()
    } else {
      store = DashboardStore()
    }
    super.init()
  }
  private var statusItems: [ProviderCategory: NSStatusItem] = [:]
  private var itemViews: [ProviderCategory: PassthroughHostingView] = [:]
  private var fallbackItem: NSStatusItem?
  private var activeCategory: ProviderCategory?
  private let panel = MenuPanel()
  private var settingsWindow: NSWindow?
  private var spaceObserver: NSObjectProtocol?
  private var settingsCloseObserver: NSObjectProtocol?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    let menu = NSMenu()
    let appMenu = NSMenu()
    let appItem = NSMenuItem()
    appItem.submenu = appMenu
    menu.addItem(appItem)
    let settings = NSMenuItem(
      title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    settings.target = self
    appMenu.addItem(settings)
    appMenu.addItem(.separator())
    appMenu.addItem(
      NSMenuItem(
        title: "Quit Information Bar", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"))
    let editItem = NSMenuItem()
    editItem.submenu = editMenu()
    menu.addItem(editItem)
    NSApp.mainMenu = menu
    panel.ignoresClicks = { [weak self] window in
      self?.statusItems.values.contains { $0.button?.window === window } ?? false
    }
    panel.onDismiss = { [weak self] in
      guard let self, let category = self.activeCategory else { return }
      self.statusItems[category]?.button?.highlight(false)
      self.activeCategory = nil
    }
    spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.panel.dismiss() }
    }
    store.onUpdate = { [weak self] in self?.updateMenuItems() }
    updateMenuItems()
    store.start()
    let arguments = CommandLine.arguments
    // QA: `--panel claude` opens that dropdown at launch and prints its placement;
    // `--exit-after 3` quits after that many seconds.
    if let index = arguments.firstIndex(of: "--panel"), index + 1 < arguments.count,
      let category = ProviderCategory(rawValue: arguments[index + 1])
    {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self else { return }
        self.openProvider(category)
        let frame = self.panel.frame
        let bar = self.statusItems[category]?.button?.window?.frame ?? .zero
        let screen = NSScreen.main?.frame ?? .zero
        let fitting = self.itemViews[category]?.fittingSize ?? .zero
        print(
          "screen \(Int(screen.width))x\(Int(screen.height)) fitting \(Int(fitting.width))x\(Int(fitting.height)) length \(Int(self.statusItems[category]?.length ?? 0))"
        )
        print(
          "panel window \(self.panel.windowNumber) visible \(self.panel.isVisible) frame "
            + "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) "
            + "item \(Int(bar.minX)),\(Int(bar.minY)) \(Int(bar.width))x\(Int(bar.height))")
        fflush(stdout)
        self.panel.onRefit = { size in
          print("panel refit \(Int(size.width))x\(Int(size.height))")
          fflush(stdout)
        }
      }
    }
    if let index = arguments.firstIndex(of: "--exit-after"), index + 1 < arguments.count,
      let seconds = Double(arguments[index + 1])
    {
      DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
    }
    if arguments.contains("--settings") || !UserDefaults.standard.bool(forKey: "hasLaunched") {
      UserDefaults.standard.set(true, forKey: "hasLaunched")
      openSettings()
    }
  }

  // Without an Edit menu, ⌘X/⌘C/⌘V/⌘A never reach text fields such as the Vast API key field.
  private func editMenu() -> NSMenu {
    let edit = NSMenu(title: "Edit")
    let items: [(String, String, String)] = [
      ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"),
      ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
    ]
    for (title, action, key) in items {
      edit.addItem(NSMenuItem(title: title, action: Selector((action)), keyEquivalent: key))
    }
    edit.insertItem(.separator(), at: 2)
    return edit
  }

  private func updateMenuItems() {
    switch store.preferences.theme {
    case .system: NSApp.appearance = nil
    case .light: NSApp.appearance = NSAppearance(named: .aqua)
    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
    }
    for category in ProviderCategory.allCases {
      let options = store.preferences.provider(category)
      if !options.enabled {
        if activeCategory == category { panel.dismiss() }
        if let item = statusItems.removeValue(forKey: category) {
          NSStatusBar.system.removeStatusItem(item)
          itemViews.removeValue(forKey: category)
        }
        continue
      }
      if statusItems[category] == nil {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "InformationBar.\(category.rawValue)"
        item.button?.identifier = NSUserInterfaceItemIdentifier(category.rawValue)
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        let hosting = PassthroughHostingView(rootView: AnyView(EmptyView()))
        hosting.autoresizingMask = [.height]
        item.button?.addSubview(hosting)
        itemViews[category] = hosting
        statusItems[category] = item
      }
      guard let item = statusItems[category], let button = item.button,
        let hosting = itemViews[category]
      else { continue }
      let provider = store.providers[category.rawValue] ?? .placeholder(category.rawValue)
      hosting.rootView = AnyView(MenuBarItemView(provider: provider, options: options))
      // macOS pads every status item by about 8pt per side. The content is drawn a little
      // into that margin so neighbouring items sit closer; beyond 8pt it would be clipped.
      let overflow: CGFloat = 3
      let content = ceil(hosting.fittingSize.width) + 2
      let width = max(1, content - 2 * overflow)
      if abs(item.length - width) > 0.5 { item.length = width }
      hosting.frame = NSRect(x: -overflow, y: 0, width: content, height: button.bounds.height)
      let summary = provider.menuSummary(options)
      button.toolTip = "\(category.name) · \(summary) · \(provider.ageLabel)"
      button.setAccessibilityLabel("\(category.name): \(summary)")
    }
    if statusItems.isEmpty && fallbackItem == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      item.button?.image = NSImage(
        systemSymbolName: "gearshape", accessibilityDescription: "Information Bar settings")
      item.button?.target = self
      item.button?.action = #selector(openSettings)
      item.button?.toolTip = "Information Bar settings. All menu bar items are hidden."
      fallbackItem = item
    } else if !statusItems.isEmpty, let item = fallbackItem {
      NSStatusBar.system.removeStatusItem(item)
      fallbackItem = nil
    }
    // SwiftUI applies the new data on the next pass; measure the open panel after it.
    DispatchQueue.main.async { [weak self] in self?.panel.refit() }
  }

  @objc private func togglePanel(_ sender: NSStatusBarButton) {
    guard let id = sender.identifier?.rawValue, let category = ProviderCategory(rawValue: id) else {
      return
    }
    if panel.isVisible && activeCategory == category {
      panel.dismiss()
      return
    }
    panel.dismiss()
    activeCategory = category
    store.refresh(only: id)
    let openSettings = { [weak self] in
      self?.store.selectedSettings = id
      self?.openSettings()
    }
    panel.present(below: sender) { maxHeight in
      AnyView(
        ProviderPanel(
          store: store, category: category, openSettings: openSettings, maxHeight: maxHeight))
    }
    sender.highlight(true)
  }

  @objc func openSettings() {
    panel.dismiss()
    if settingsWindow == nil {
      let controller = NSHostingController(
        rootView: SettingsView(
          store: store, openProvider: { [weak self] category in self?.openProvider(category) }))
      let window = NSWindow(contentViewController: controller)
      // Tahoe window chrome: content under a unified glass toolbar, sidebar running to the top.
      window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
      window.toolbar = NSToolbar(identifier: "InformationBar.Settings")
      window.toolbarStyle = .unified
      window.title = "Information Bar Settings"
      window.isReleasedWhenClosed = false
      window.contentMinSize = NSSize(width: 760, height: 600)
      window.setContentSize(NSSize(width: 820, height: 700))
      window.setFrameAutosaveName("InformationBar.Settings")
      if !window.setFrameUsingName("InformationBar.Settings") { window.center() }
      settingsWindow = window
      // While Settings is open the app behaves like a regular app: Dock icon and app menu.
      settingsCloseObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
      ) { _ in
        Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
      }
    }
    NSApp.setActivationPolicy(.regular)
    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if CommandLine.arguments.contains("--exit-after"), let window = settingsWindow {
      let frame = window.frame
      print(
        "settings window \(window.windowNumber) frame \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) screen \(Int(NSScreen.main?.frame.height ?? 0)) policy \(NSApp.activationPolicy() == .regular ? "regular" : "accessory")"
      )  // QA capture
      fflush(stdout)
    }
  }

  private func openProvider(_ category: ProviderCategory) {
    guard let button = statusItems[category]?.button else { return }
    togglePanel(button)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag { openSettings() }
    return true
  }
}

@main
struct InformationBarEntry {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
  }
}
