import Foundation
import CryptoKit

/// One versioned view of the Mac's normalized readings. Source timestamps remain authoritative.
struct MobileSnapshot: Decodable {
  let version: Int
  let generatedAt: Double
  let providers: [Provider]
  let preferences: AppPreferences

  func provider(_ category: ProviderCategory) -> Provider? {
    providers.first { $0.id == category.rawValue }
  }

  var enabledCategories: [ProviderCategory] {
    ProviderCategory.allCases.filter { preferences.provider($0).enabled && provider($0) != nil }
  }

  var power: PowerContext { PowerContext(preferences: preferences.power, provider: provider(.power)) }

  static func decode(_ data: Data) throws -> MobileSnapshot {
    guard data.count <= 2_000_000 else { throw MobileError.invalidSnapshot }
    let value = try JSONDecoder().decode(Self.self, from: data)
    guard value.version == 1, value.generatedAt.isFinite, value.generatedAt > 0,
      value.generatedAt <= Date().timeIntervalSince1970 + 300,
      value.providers.count <= ProviderCategory.allCases.count,
      Set(value.providers.map(\.id)).count == value.providers.count,
      value.providers.allSatisfy({ ProviderCategory(rawValue: $0.id) != nil }),
      [60, 120].contains(value.preferences.refreshInterval)
    else { throw MobileError.invalidSnapshot }
    return value
  }

  static var demo: MobileSnapshot {
    let providers = DemoData.providers()
    return MobileSnapshot(
      version: 1, generatedAt: Date().timeIntervalSince1970,
      providers: ProviderCategory.allCases.compactMap { providers[$0.rawValue] },
      preferences: DemoData.preferences())
  }
}

enum MobileError: LocalizedError {
  case notPaired, invalidPairing, invalidSnapshot, unauthorized, unavailable, storage

  var errorDescription: String? {
    switch self {
    case .notPaired: return "Connect to your Mac to see your readings."
    case .invalidPairing: return "This connection file is invalid. Create a new one on your Mac."
    case .invalidSnapshot: return "The Mac sent an unreadable snapshot. Update the companion and try again."
    case .unauthorized: return "This connection has expired. Connect to your Mac again."
    case .unavailable: return "Your Mac is unavailable. Keep Information Bar running on the same network."
    case .storage: return "Your readings could not be saved. Try reopening Information Bar."
    }
  }
}

enum MobileCache {
  static let group = "group.dev.starecat.InformationBar.mobile"

  private static var file: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
      .appendingPathComponent("snapshot.json")
  }

  static func load() -> MobileSnapshot? {
    guard let pairing = MobileKeychain.load(), let file, let data = try? Data(contentsOf: file),
      let cached = try? JSONDecoder().decode(CacheEnvelope.self, from: data),
      cached.connection == identity(pairing),
      let snapshot = try? MobileSnapshot.decode(cached.payload) else { return nil }
    Freshness.refreshInterval = snapshot.preferences.refreshInterval
    return snapshot
  }

  static func save(_ data: Data, pairing: MobilePairing) throws {
    _ = try MobileSnapshot.decode(data)
    guard let file, MobileKeychain.load() == pairing else { throw MobileError.storage }
    let envelope = CacheEnvelope(connection: identity(pairing), payload: data)
    try JSONEncoder().encode(envelope).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    var excluded = file
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try excluded.setResourceValues(values)
  }

  static func clear() {
    if let file { try? FileManager.default.removeItem(at: file) }
  }

  private struct CacheEnvelope: Codable {
    let connection: String
    let payload: Data
  }

  private static func identity(_ pairing: MobilePairing) -> String {
    SHA256.hash(data: Data((pairing.endpoint + "\n" + pairing.certificateSHA256 + "\n" + pairing.token).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}
