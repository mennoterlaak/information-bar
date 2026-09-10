// Off-screen visual QA with synthetic metrics. Does not read credentials or call providers.
import AppKit
import SwiftUI

@main
struct RenderViews {
  @MainActor
  static func main() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let defaultsName = "InformationBar.VisualQA.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsName)!
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    defaults.set(try JSONEncoder().encode(DemoData.preferences()), forKey: "preferences.v2")
    let store = DashboardStore(defaults: defaults)
    store.providers = DemoData.providers()
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for (label, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
      NSApp.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
      store.selectedSettings = "global"
      try save(
        SettingsView(store: store).environment(\.colorScheme, scheme),
        to: output.appendingPathComponent("settings-\(label).png"))
      for category in ProviderCategory.allCases {
        // The app draws the panel on a glass window; give the render an opaque backdrop.
        try save(
          ProviderPanel(store: store, category: category, openSettings: {})
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme),
          to: output.appendingPathComponent("\(category.rawValue)-\(label).png"))
      }
      store.selectedSettings = "vast"
      try save(
        SettingsView(store: store).environment(\.colorScheme, scheme),
        to: output.appendingPathComponent("settings-vast-\(label).png"))
      // Gauge style variants.
      for style in [GaugeStyle.ringValue, .bar] {
        store.setGaugeStyle(style)
        for category in [ProviderCategory.claude, .vast] {
          try save(
            ProviderPanel(store: store, category: category, openSettings: {})
              .background(Color(nsColor: .windowBackgroundColor))
              .environment(\.colorScheme, scheme),
            to: output.appendingPathComponent(
              "\(category.rawValue)-\(style.rawValue.lowercased())-\(label).png"))
        }
      }
      store.setGaugeStyle(.ring)
      // Every icon style value macOS writes, as the tiles draw it in this appearance.
      let themes = [
        "Regular", "RegularDark", "RegularAutomatic", "ClearLight", "ClearDark",
        "ClearAutomatic", "TintedLight", "TintedDark", "TintedAutomatic",
      ]
      try save(
        VStack(alignment: .leading, spacing: 10) {
          ForEach(themes, id: \.self) { theme in
            HStack(spacing: 12) {
              Text(theme).font(.system(size: 12, design: .monospaced))
                .frame(width: 150, alignment: .leading)
              IconTile(symbol: "gearshape", color: .gray, size: 28, theme: theme)
              ForEach(ProviderCategory.allCases) { category in
                IconTile(id: category.rawValue, size: 28, theme: theme)
              }
            }
          }
        }
        .padding(20).background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme),
        to: output.appendingPathComponent("icon-styles-\(label).png"))
    }
    print("Rendered 22 QA images with synthetic data to \(output.path)")
  }

  @MainActor
  static func save<V: View>(_ view: V, to url: URL) throws {
    let hosting = NSHostingView(rootView: view)
    let size = hosting.fittingSize
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.contentView = hosting
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      throw AppError.message("Could not render \(url.lastPathComponent)")
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw AppError.message("Could not encode \(url.lastPathComponent)")
    }
    try png.write(to: url)
    window.close()
  }
}
