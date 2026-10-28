import CryptoKit
import Foundation
import Security
import OSLog

struct MobilePairing: Codable, Equatable {
  let version: Int
  let endpoint: String
  let token: String
  let certificateSHA256: String

  var host: String { URLComponents(string: endpoint)?.host ?? "Mac" }

  static func decode(_ data: Data) throws -> Self {
    guard data.count < 16_384 else { throw MobileError.invalidPairing }
    let value = try JSONDecoder().decode(Self.self, from: data)
    guard value.version == 1,
      let url = URLComponents(string: value.endpoint), url.scheme == "https",
      let host = url.host, isLocalHost(host),
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.isEmpty || url.path == "/",
      url.port == nil || (1...65535).contains(url.port!),
      (32...256).contains(value.token.utf8.count),
      value.token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }),
      value.certificateSHA256.count == 64,
      value.certificateSHA256.allSatisfy(\.isHexDigit)
    else { throw MobileError.invalidPairing }
    return value
  }

  static func fromURL(_ url: URL) throws -> Self {
    guard url.scheme == "informationbar", url.host == "pair",
      url.absoluteString.utf8.count < 24_000,
      let payload = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "payload" })?.value else {
      throw MobileError.invalidPairing
    }
    var base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64) else { throw MobileError.invalidPairing }
    return try decode(data)
  }

  private static func isLocalHost(_ input: String) -> Bool {
    let host = input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
    if host.contains(":"), host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") {
      return true
    }
    let components = host.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 4, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
    let parts = components.compactMap { Int($0) }
    guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
    return parts[0] == 10 || parts[0] == 127
      || (parts[0] == 192 && parts[1] == 168)
      || (parts[0] == 172 && (16...31).contains(parts[1]))
      || (parts[0] == 169 && parts[1] == 254)
  }
}

/// App and extension share only this new companion credential, never provider credentials.
enum MobileKeychain {
  private static var query: [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.starecat.InformationBar.mobile",
      kSecAttrAccount as String: "companion",
    ]
    if let group = Bundle.main.object(forInfoDictionaryKey: "SharedKeychainGroup") as? String,
      !group.isEmpty, !group.contains("$(") { query[kSecAttrAccessGroup as String] = group }
    return query
  }

  static func load() -> MobilePairing? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data else { return nil }
    return try? MobilePairing.decode(data)
  }

  static func save(_ pairing: MobilePairing) throws {
    let data = try JSONEncoder().encode(pairing)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if result == errSecItemNotFound {
      let item = query.merging(attributes) { _, new in new }
      guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw MobileError.storage }
    } else if result != errSecSuccess { throw MobileError.storage }
  }

  static func clear() throws {
    let result = SecItemDelete(query as CFDictionary)
    guard result == errSecSuccess || result == errSecItemNotFound else { throw MobileError.storage }
  }
}

/// Self-signed companion certificates are trusted only after an exact out-of-band SHA-256 pin.
final class PinnedSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let pairing: MobilePairing
  init(_ pairing: MobilePairing) { self.pairing = pairing }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let logger = Logger(subsystem: "dev.starecat.InformationBar.mobile", category: "sync")
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      challenge.protectionSpace.host.caseInsensitiveCompare(pairing.host) == .orderedSame,
      let trust = challenge.protectionSpace.serverTrust,
      let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let certificate = certificates.first else {
      logger.error("Companion trust rejected: missing certificate or host mismatch")
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
      .map { String(format: "%02x", $0) }.joined()
    guard digest == pairing.certificateSHA256.lowercased() else {
      logger.error("Companion trust rejected: certificate pin mismatch")
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    logger.notice("Companion certificate pin verified")
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    urlSession(session, didReceive: challenge, completionHandler: completionHandler)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

enum MobileSync {
  static func fetch(_ pairing: MobilePairing) async throws -> (MobileSnapshot, Data) {
    guard let base = URL(string: pairing.endpoint) else { throw MobileError.invalidPairing }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 12
    configuration.timeoutIntervalForResource = 20
    configuration.waitsForConnectivity = false
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let delegate = PinnedSessionDelegate(pairing)
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: base.appendingPathComponent("v1/snapshot"))
    request.setValue("Bearer " + pairing.token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do { (bytes, response) = try await session.bytes(for: request, delegate: delegate) }
    catch {
      let failure = error as NSError
      Logger(subsystem: "dev.starecat.InformationBar.mobile", category: "sync")
        .error("Companion request failed: domain=\(failure.domain, privacy: .public) code=\(failure.code)")
      throw error
    }
    guard let response = response as? HTTPURLResponse else { throw MobileError.unavailable }
    if response.statusCode == 401 || response.statusCode == 403 { throw MobileError.unauthorized }
    guard response.statusCode == 200, response.mimeType == "application/json",
      response.expectedContentLength <= 2_000_000 else { throw MobileError.invalidSnapshot }
    var data = Data()
    for try await byte in bytes {
      guard data.count < 2_000_000 else { throw MobileError.invalidSnapshot }
      data.append(byte)
    }
    let snapshot = try MobileSnapshot.decode(data)
    return (snapshot, data)
  }

  static func refresh() async throws -> MobileSnapshot {
    guard let pairing = MobileKeychain.load() else { throw MobileError.notPaired }
    let (snapshot, data) = try await fetch(pairing)
    // A disconnect or re-pair during the request must not restore the old cache.
    guard MobileKeychain.load() == pairing else { throw MobileError.notPaired }
    try MobileCache.save(data, pairing: pairing)
    Freshness.refreshInterval = snapshot.preferences.refreshInterval
    return snapshot
  }
}
