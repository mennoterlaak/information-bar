import AppKit
import Foundation
import Security
import ServiceManagement
import SwiftUI

enum CredentialStore {
  static let service = "dev.starecat.InformationBar"
  static let account = "vastai-api-key"

  static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account,
    ]
  }

  static func read() -> String? {
    var query = self.query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func save(_ key: String) throws {
    let data = Data(key.utf8)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var entry = query
      entry[kSecValueData as String] = data
      entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let added = SecItemAdd(entry as CFDictionary, nil)
      guard added == errSecSuccess else {
        throw AppError.message("macOS could not save the key in Keychain (\(added)).")
      }
    } else if status != errSecSuccess {
      throw AppError.message("macOS could not update the key in Keychain (\(status)).")
    }
  }
}

enum AppError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let text) = self { return text }
    return nil
  }
}

enum AppInfo {
  // Set by the Info.plist that scripts/build-app.sh writes; "dev" under swift run/test.
  static let version =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

  /// A bundled resource, or the checkout's copy when running unbundled (swift run, the QA
  /// renderer). The checkout is located by walking up from the executable to the directory
  /// that holds Package.swift, so no source path is compiled into the binary.
  static func resource(_ bundled: String, development: String) -> URL? {
    let manager = FileManager.default
    if let url = Bundle.main.resourceURL?.appendingPathComponent(bundled),
      manager.fileExists(atPath: url.path)
    {
      return url
    }
    var directory = Bundle.main.executableURL?.resolvingSymlinksInPath()
      .deletingLastPathComponent()
    while let current = directory, current.path != "/" {
      if manager.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
        let url = current.appendingPathComponent(development)
        return manager.fileExists(atPath: url.path) ? url : nil
      }
      directory = current.deletingLastPathComponent()
    }
    return nil
  }
}

enum Collector {
  static func run(arguments: [String], key: String? = nil) throws -> Data {
    let manager = FileManager.default
    let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
    guard let python = candidates.first(where: { manager.isExecutableFile(atPath: $0) }) else {
      throw AppError.message("Python 3 is required. Install it from python.org or Homebrew.")
    }
    guard let script = AppInfo.resource("collect.py", development: "scripts/collect.py") else {
      throw AppError.message("The account collector is missing. Rebuild the app.")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = [script.path] + arguments + ["--credential-stdin"]
    var environment = ProcessInfo.processInfo.environment
    let home = manager.homeDirectoryForCurrentUser.path
    environment["PATH"] =
      "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["INFORMATION_BAR_VERSION"] = AppInfo.version
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let payload = try JSONSerialization.data(withJSONObject: key.map { ["vastKey": $0] } ?? [:])
    try input.fileHandleForWriting.write(contentsOf: payload)
    try input.fileHandleForWriting.close()
    // All network/CLI calls also have their own, shorter timeouts.
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: watchdog)
    defer { watchdog.cancel() }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw AppError.message("The account collector could not finish. Try refreshing.")
    }
    return data
  }
}

extension UserDefaults {
  /// The system icon style chosen in System Settings, Appearance; a global-domain key that
  /// key-value observation reports even when another process changes it.
  @objc dynamic var AppleIconAppearanceTheme: String? { string(forKey: "AppleIconAppearanceTheme") }
}

@MainActor
final class DashboardStore: ObservableObject {
  @Published var providers = Dictionary(
    uniqueKeysWithValues: ProviderCategory.allCases.map {
      ($0.rawValue, Provider.placeholder($0.rawValue))
    })
  @Published var refreshing: Set<String> = []
  // Collector process failures per provider id (missing Python, crash, timeout).
  @Published var collectorErrors: [String: String] = [:]
  @Published var settingsMessage: String?
  @Published var loginMessage: String?
  @Published var validatingKey = false
  @Published var keyConnected = false
  @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
  @Published private(set) var preferences: AppPreferences
  @Published var selectedSettings = "global"
  @Published var tick = Date()
  /// Synthetic data only: no collector runs, no Keychain reads.
  var demo = false
  /// Current system icon style, published so tiles redraw the moment it changes.
  @Published var iconTheme = UserDefaults.standard.AppleIconAppearanceTheme ?? "Regular"
  private var iconThemeObservation: NSKeyValueObservation?
  var onUpdate: (() -> Void)?
  private var timer: Timer?
  private var lastRefresh = Date.distantPast
  private var wakeObserver: NSObjectProtocol?
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    preferences = .load(from: defaults)
    Freshness.refreshInterval = preferences.refreshInterval
    iconThemeObservation = UserDefaults.standard.observe(
      \.AppleIconAppearanceTheme, options: [.new]
    ) { [weak self] _, change in
      let theme = change.newValue.flatMap { $0 } ?? "Regular"
      Task { @MainActor in self?.iconTheme = theme }
    }
  }

  func update(_ category: ProviderCategory, _ change: (inout ProviderPreferences) -> Void) {
    var item = preferences.provider(category)
    change(&item)
    preferences.providers[category.rawValue] = item
    persistPreferences()
    if item.enabled { refresh(only: category.rawValue) }
  }

  func setTheme(_ value: AppTheme) {
    preferences.theme = value
    persistPreferences()
  }

  func setGaugeStyle(_ value: GaugeStyle) {
    preferences.gaugeStyle = value
    persistPreferences()
  }

  func setRefreshInterval(_ value: Int) {
    preferences.refreshInterval = value == 120 ? 120 : 60
    Freshness.refreshInterval = preferences.refreshInterval
    persistPreferences()
  }

  private func persistPreferences() {
    if let data = try? JSONEncoder().encode(preferences) {
      defaults.set(data, forKey: "preferences.v2")
    }
    onUpdate?()
  }

  func start() {
    keyConnected = demo || CredentialStore.read() != nil
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.tick = Date()
        self.onUpdate?()
        if Date().timeIntervalSince(self.lastRefresh) >= Double(self.preferences.refreshInterval) {
          self.refresh()
        }
      }
    }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  func refresh(force: Bool = false, only: String? = nil) {
    guard !demo else { return }
    if only == nil { lastRefresh = Date() }
    for id in only.map({ [$0] }) ?? ProviderCategory.allCases.map(\.rawValue)
    where !refreshing.contains(id) {
      refreshing.insert(id)
      collectorErrors[id] = nil
      let key = id == "vast" ? CredentialStore.read() : nil
      var arguments = ["--provider", id] + (force ? ["--force"] : [])
      if id == "vast" {
        let vast = preferences.provider(.vast)
        arguments += [
          "--currency", vast.currency, "--utilization-days", String(vast.utilizationPeriod.days),
        ]
      }
      Task {
        do {
          let data = try await Task.detached(priority: .utility) {
            try Collector.run(arguments: arguments, key: key)
          }.value
          providers[id] = try JSONDecoder().decode(Provider.self, from: data)
        } catch {
          collectorErrors[id] = error.localizedDescription
        }
        refreshing.remove(id)
        onUpdate?()
      }
    }
  }

  func saveKey(_ raw: String) async -> Bool {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      settingsMessage = "Enter a Vast.ai API key."
      return false
    }
    validatingKey = true
    settingsMessage = nil
    defer { validatingKey = false }
    do {
      let data = try await Task.detached(priority: .utility) {
        try Collector.run(arguments: ["--validate-vast-key"], key: key)
      }.value
      let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard response?["valid"] as? Bool == true else {
        settingsMessage = response?["error"] as? String ?? "Could not validate the API key."
        return false
      }
      try CredentialStore.save(key)
      keyConnected = true
      // Only this app's sanitized Vast cache is invalidated after changing its credential.
      let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/Information Bar/Cache/vast.json")
      try? FileManager.default.removeItem(at: cache)
      settingsMessage = "Connected. Your key is stored in macOS Keychain."
      refresh(force: true, only: "vast")
      return true
    } catch {
      settingsMessage = error.localizedDescription
      return false
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLogin = SMAppService.mainApp.status == .enabled
      loginMessage =
        enabled && !launchAtLogin
        ? "Approve Information Bar under System Settings > General > Login Items." : nil
    } catch { loginMessage = error.localizedDescription }
  }
}
