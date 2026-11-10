import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let store: DashboardStore

  override init() {
    // `--demo` runs on synthetic data in its own preferences domain, for screenshots and QA.
    // `--layout separate` and `--shorten always` set those two menu bar options for the run.
    if CommandLine.arguments.contains("--demo") {
      let suite = "InformationBar.Demo"
      let defaults = UserDefaults(suiteName: suite)!
      defaults.removePersistentDomain(forName: suite)
      var preferences = DemoData.preferences()
      if let layout = AppInfo.argument("--layout").flatMap(MenuLayout.init(rawValue:)) {
        preferences.menuLayout = layout
      }
      if let shortening = AppInfo.argument("--shorten").flatMap(MenuShortening.init(rawValue:)) {
        preferences.shortening = shortening
      }
      defaults.set(try? JSONEncoder().encode(preferences), forKey: "preferences.v2")
      store = DashboardStore(defaults: defaults)
      store.demo = true
      store.providers = DemoData.providers()
    } else {
      store = DashboardStore()
    }
    super.init()
  }

  private let panel = MenuPanel()
  private lazy var menuBar = MenuBarController(store: store, panel: panel)
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
    menuBar.openSettings = { [weak self] category in
      if let category { self?.store.selectedSettings = category.rawValue }
      self?.openSettings()
    }
    spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.panel.dismiss() }
    }
    store.onUpdate = { [weak self] in self?.updateMenuBar() }
    store.onLivePrices = { [weak self] in self?.menuBar.update() }
    store.start()
    updateMenuBar()
    let arguments = CommandLine.arguments
    // QA: `--panel claude` opens that dropdown at launch and prints its placement;
    // `--exit-after 3` quits after that many seconds, printing the menu bar arrangement.
    if let category = AppInfo.argument("--panel").flatMap(ProviderCategory.init(rawValue:)) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self else { return }
        self.menuBar.open(category)
        let frame = self.panel.frame
        let bar = self.menuBar.itemFrame(category)
        let screen = NSScreen.main?.frame ?? .zero
        print("screen \(Int(screen.width))x\(Int(screen.height))")
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
    if let seconds = AppInfo.argument("--exit-after").flatMap(Double.init) {
      DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, seconds - 0.2)) { [weak self] in
        guard let self else { return }
        print(self.menuBar.layoutDescription)
        fflush(stdout)
      }
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

  private func updateMenuBar() {
    switch store.preferences.theme {
    case .system: NSApp.appearance = nil
    case .light: NSApp.appearance = NSAppearance(named: .aqua)
    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
    }
    menuBar.update()
  }

  @objc func openSettings() {
    menuBar.dismiss()
    if settingsWindow == nil {
      let controller = NSHostingController(
        rootView: SettingsView(
          store: store, openProvider: { [weak self] category in self?.menuBar.toggle(category) }))
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
