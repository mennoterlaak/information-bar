import CryptoKit
import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class MobileStore: ObservableObject {
  @Published var snapshot: MobileSnapshot?
  @Published var syncing = false
  @Published var error: String?
  @Published var paired = false
  @Published var showPairing = false
  @Published var pendingPairing: MobilePairing?
  @Published var endpointHost: String?
  @Published var selectedProvider: ProviderCategory?
  let demo: Bool
  private var bootstrapDigest: String?
  private var connectionGeneration = 0
  private var automaticallyConnect = false

  init() {
    let arguments = ProcessInfo.processInfo.arguments
    demo = arguments.contains("--demo")
    if arguments.contains("--accept-pairing-launch"), let index = arguments.firstIndex(of: "--pairing-digest"),
      arguments.indices.contains(index + 1) { bootstrapDigest = arguments[index + 1] }
    if demo { snapshot = .demo; return }
    let pairing = MobileKeychain.load()
    paired = pairing != nil
    endpointHost = pairing?.host
    snapshot = pairing == nil ? nil : MobileCache.load()
  }

  func refresh() async {
    guard !demo, paired, !syncing else { return }
    syncing = true
    defer { finishSync() }
    do {
      snapshot = try await MobileSync.refresh()
      error = nil
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      if error is CancellationError { return }
      self.error = (error as? MobileError)?.localizedDescription ?? MobileError.unavailable.localizedDescription
    }
  }

  func receive(_ url: URL) {
    if url.host == "provider", let category = ProviderCategory(rawValue: url.lastPathComponent) {
      selectedProvider = category
      return
    }
    do {
      pendingPairing = try MobilePairing.fromURL(url)
      let receivedDigest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
      let expectedDigest = bootstrapDigest
      bootstrapDigest = nil
      connectionGeneration += 1
      if expectedDigest == receivedDigest {
        automaticallyConnect = true
        Task { await connect() }
      } else { automaticallyConnect = false; showPairing = true }
    } catch {
      self.error = MobileError.invalidPairing.localizedDescription
      showPairing = true
    }
  }

  func importPairing(_ url: URL) {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    do {
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      guard (values.fileSize ?? Int.max) < 16_384 else { throw MobileError.invalidPairing }
      pendingPairing = try MobilePairing.decode(Data(contentsOf: url))
      connectionGeneration += 1
      error = nil
    } catch { self.error = MobileError.invalidPairing.localizedDescription }
  }

  func connect() async {
    guard let candidate = pendingPairing, !syncing, !demo else { return }
    automaticallyConnect = false
    let generation = connectionGeneration
    syncing = true
    defer { finishSync() }
    do {
      let (snapshot, data) = try await MobileSync.fetch(candidate)
      guard generation == connectionGeneration else { return }
      let previous = MobileKeychain.load()
      try MobileKeychain.save(candidate)
      do { try MobileCache.save(data, pairing: candidate) }
      catch {
        if let previous { try? MobileKeychain.save(previous) }
        else { try? MobileKeychain.clear() }
        throw error
      }
      Freshness.refreshInterval = snapshot.preferences.refreshInterval
      self.snapshot = snapshot
      paired = true
      endpointHost = candidate.host
      pendingPairing = nil
      showPairing = false
      error = nil
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      self.error = (error as? MobileError)?.localizedDescription ?? MobileError.unavailable.localizedDescription
      showPairing = true
    }
  }

  func disconnect() {
    connectionGeneration += 1
    automaticallyConnect = false
    do { try MobileKeychain.clear() }
    catch { self.error = MobileError.storage.localizedDescription; return }
    MobileCache.clear()
    snapshot = nil
    endpointHost = nil
    pendingPairing = nil
    paired = false
    error = nil
    WidgetCenter.shared.reloadAllTimelines()
  }

  private func finishSync() {
    syncing = false
    if automaticallyConnect, pendingPairing != nil {
      automaticallyConnect = false
      Task { await connect() }
    }
  }
}
