import Combine
import Darwin
import Foundation

/// A resolved HomeWizard Bonjour advertisement. Discovery never reads measurements or tokens.
struct DiscoveredHomeWizard: Identifiable, Equatable {
  static let serviceTypes = ["_hwenergy._tcp.", "_homewizard._tcp."]
  let device: HomeWizardDevice
  let apiEnabled: Bool
  var endpointAliases: Set<String>
  var id: String { device.serial }

  init?(type: String, host: String, port: Int, txt: [String: String], addresses: [String] = []) {
    guard Self.serviceTypes.contains(type), (1...65535).contains(port),
      let serial = txt["serial"]?.lowercased(), serial.count == 12,
      serial.allSatisfy(\.isHexDigit)
    else { return nil }
    let secure = type == "_homewizard._tcp."
    let productTypes = [
      "HWE-P1": "p1dongle", "HWE-SKT": "energysocket", "HWE-BAT": "battery",
      "HWE-KWH1": "energymeter", "HWE-KWH3": "energymeter",
      "SDM230-wifi": "energymeter", "SDM630-wifi": "energymeter",
      "HWE-WTR": "watermeter", "HWE-DSP": "display",
    ]
    var product = productTypes[txt["product_type"] ?? ""] ?? txt["product_type"] ?? ""
    if secure {
      let identity = (txt["id"] ?? "").split(separator: "/", omittingEmptySubsequences: false)
      guard identity.count == 3, identity[0] == "appliance", !identity[1].isEmpty,
        identity[2].lowercased() == serial
      else { return nil }
      // The certificate's product type differs from the marketing product code.
      product = String(identity[1])
    } else if let path = txt["path"], path != "/api/v1" {
      return nil
    }
    var url = URLComponents()
    url.scheme = secure ? "https" : "http"
    url.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    url.port = port == (secure ? 443 : 80) ? nil : port
    guard !host.isEmpty, let address = url.string else { return nil }
    let name = txt["product_name"].flatMap { $0.isEmpty ? nil : $0 } ?? "HomeWizard"
    device = HomeWizardDevice(
      name: name, address: address, apiVersion: secure ? "v2" : "v1",
      productType: product, serial: serial)
    guard device.validationError == nil else { return nil }
    apiEnabled = secure || txt["api_enabled"] != "0"
    endpointAliases = Set(
      ([host] + addresses).compactMap { hostname in
        var endpoint = url
        endpoint.host = hostname.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return endpoint.string.flatMap { HomeWizardDevice(address: $0).endpointIdentity }
      })
  }

  var measuresPower: Bool { !["watermeter", "display"].contains(device.productType) }

  var setupHint: String {
    if !measuresPower { return "No electricity measurement" }
    if device.apiVersion == "v2" { return "v2 · API token required" }
    return apiEnabled ? "v1 · Local API enabled" : "v1 · Enable Local API in HomeWizard first"
  }

  func isConfigured(in preferences: PowerPreferences) -> Bool {
    preferences.devices.contains {
      $0.serial.lowercased() == id
        || $0.endpointIdentity.map { endpointAliases.contains($0) } == true
    }
  }

  /// One row per physical device, even when both API versions are advertised.
  func merging(_ other: Self) -> Self {
    var preferred = device.apiVersion == "v2" ? self : other
    preferred.endpointAliases = endpointAliases.union(other.endpointAliases)
    return preferred
  }
}

/// Native Bonjour browsing runs on the main run loop and stops after a bounded search.
@MainActor
final class HomeWizardDiscovery: NSObject, ObservableObject,
  @preconcurrency NetServiceBrowserDelegate,
  @preconcurrency NetServiceDelegate
{
  @Published private(set) var devices: [DiscoveredHomeWizard] = []
  @Published private(set) var isSearching = false
  @Published private(set) var hasSearched = false
  @Published private(set) var error: String?
  private var browsers: [NetServiceBrowser] = []
  private var services: [ObjectIdentifier: NetService] = [:]
  private var timeout: Timer?

  func start(demo: Bool = false) {
    stop()
    devices = []
    error = nil
    hasSearched = true
    if demo {
      devices = DemoData.discoveredMeters()
      return
    }
    isSearching = true
    for type in DiscoveredHomeWizard.serviceTypes {
      let browser = NetServiceBrowser()
      browser.delegate = self
      browsers.append(browser)
      browser.searchForServices(ofType: type, inDomain: "local.")
    }
    let timer = Timer(timeInterval: 12, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.stop() }
    }
    timeout = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func stop() {
    timeout?.invalidate()
    timeout = nil
    for browser in browsers {
      browser.delegate = nil
      browser.stop()
    }
    for service in services.values {
      service.delegate = nil
      service.stop()
    }
    browsers.removeAll()
    services.removeAll()
    isSearching = false
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool
  ) {
    guard isSearching, browsers.contains(where: { $0 === browser }), services.count < 128 else {
      return
    }
    services[ObjectIdentifier(service)] = service
    service.delegate = self
    service.resolve(withTimeout: 5)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
    guard isSearching, browsers.contains(where: { $0 === browser }) else { return }
    error =
      "Network search could not finish. Check Information Bar's Local Network access in System Settings."
    browser.delegate = nil
    browser.stop()
    browsers.removeAll { $0 === browser }
    if browsers.isEmpty { stop() }
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard isSearching, services[ObjectIdentifier(sender)] != nil, let host = sender.hostName,
      let data = sender.txtRecordData()
    else { return }
    let txt = NetService.dictionary(fromTXTRecord: data).compactMapValues {
      String(data: $0, encoding: .utf8)
    }
    guard
      let found = DiscoveredHomeWizard(
        type: sender.type, host: host, port: sender.port, txt: txt,
        addresses: (sender.addresses ?? []).compactMap(Self.numericAddress))
    else { return }
    if let index = devices.firstIndex(where: { $0.id == found.id }) {
      devices[index] = devices[index].merging(found)
    } else {
      devices.append(found)
    }
    devices.sort {
      ($0.device.name.localizedLowercase, $0.id) < ($1.device.name.localizedLowercase, $1.id)
    }
  }

  private static func numericAddress(_ data: Data) -> String? {
    data.withUnsafeBytes { bytes in
      guard bytes.count >= MemoryLayout<sockaddr>.size,
        let pointer = bytes.baseAddress?.assumingMemoryBound(to: sockaddr.self)
      else { return nil }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          pointer, socklen_t(data.count), &host, socklen_t(host.count), nil, 0,
          NI_NUMERICHOST) == 0
      else { return nil }
      return String(cString: host)
    }
  }
}
