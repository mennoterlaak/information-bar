import Foundation
import XCTest
@testable import InformationBarMobile

final class MobileSnapshotTests: XCTestCase {
  private func snapshotData(version: Int = 1, providers: [[String: Any]] = []) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "version": version, "generatedAt": Date().timeIntervalSince1970,
      "providers": providers, "preferences": [:],
    ])
  }

  func testUnknownSchemaAndOversizedSnapshotsAreRejected() throws {
    XCTAssertThrowsError(try MobileSnapshot.decode(snapshotData(version: 2)))
    XCTAssertThrowsError(try MobileSnapshot.decode(Data(repeating: 32, count: 2_000_001)))
  }

  func testDuplicateOrUnknownProvidersAreRejected() throws {
    let provider: [String: Any] = ["id": "pearl", "name": "Pearl", "status": "ok"]
    XCTAssertThrowsError(try MobileSnapshot.decode(snapshotData(providers: [provider, provider])))
    XCTAssertThrowsError(try MobileSnapshot.decode(snapshotData(providers: [
      ["id": "unexpected", "name": "Unexpected", "status": "ok"],
    ])))
  }

  func testExportTimeCannotRefreshOldProviderReadings() throws {
    let old = Date().timeIntervalSince1970 - 86_400
    let snapshot = try MobileSnapshot.decode(snapshotData(providers: [
      ["id": "pearl", "name": "Pearl", "status": "ok", "updatedAt": old,
       "pearl": ["priceUSD": 1.25, "coinsPerDay": 6.0]],
    ]))
    let pearl = try XCTUnwrap(snapshot.provider(.pearl))
    XCTAssertEqual(pearl.updatedAt, old)
    XCTAssertFalse(pearl.isFresh)
    XCTAssertNil(pearl.pearlProjection(snapshot.preferences.provider(.pearl), power: snapshot.power).netPerDay)
  }

  func testMissingPowerNeverBecomesZeroCostOrNetProfit() {
    let snapshot = MobileSnapshot.demo
    let pearl = snapshot.provider(.pearl)!
    let projection = pearl.pearlProjection(snapshot.preferences.provider(.pearl), power: .empty)
    XCTAssertNotNil(projection.revenuePerDay)
    XCTAssertNil(projection.powerPerDay)
    XCTAssertNil(projection.netPerDay)
  }

  func testDemoCoversEveryProviderWithoutPersistingAccountData() {
    let snapshot = MobileSnapshot.demo
    XCTAssertEqual(Set(snapshot.providers.map(\.id)), Set(ProviderCategory.allCases.map(\.rawValue)))
    XCTAssertEqual(snapshot.provider(.kraken)?.kraken?.currency, "EUR")
    XCTAssertEqual(snapshot.provider(.pearl)?.pearl?.effectiveAverageWindow, .week)
  }

  func testExpiredAllowanceIsNotDisplayedAsCurrentUsage() throws {
    let snapshot = try MobileSnapshot.decode(snapshotData(providers: [
      ["id": "codex", "name": "ChatGPT", "status": "ok", "updatedAt": Date().timeIntervalSince1970,
       "windows": [["id": "codex:primary", "label": "Weekly", "usedPercent": 90,
                    "resetAt": Date().timeIntervalSince1970 - 60]]],
    ]))
    XCTAssertNil(snapshot.provider(.codex)?.pool(nil))
  }
}

final class MobilePairingTests: XCTestCase {
  private func data(endpoint: String, token: String = String(repeating: "a", count: 43), pin: String = String(repeating: "f", count: 64)) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "version": 1, "endpoint": endpoint, "token": token, "certificateSHA256": pin,
    ])
  }

  func testLocalTLSConnectionsRequireValidPinAndToken() throws {
    for endpoint in ["https://mac.local:8943", "https://192.168.1.4:8943", "https://10.0.0.1:8943"] {
      XCTAssertNoThrow(try MobilePairing.decode(data(endpoint: endpoint)))
    }
    XCTAssertThrowsError(try MobilePairing.decode(data(endpoint: "http://mac.local:8943")))
    XCTAssertThrowsError(try MobilePairing.decode(data(endpoint: "https://example.com")))
    XCTAssertThrowsError(try MobilePairing.decode(data(endpoint: "https://127.0.x.0.1")))
    XCTAssertThrowsError(try MobilePairing.decode(data(endpoint: "https://mac.local/path")))
    XCTAssertThrowsError(try MobilePairing.decode(data(endpoint: "https://user:pass@mac.local")))
    XCTAssertThrowsError(try MobilePairing.decode(data(endpoint: "https://mac.local", token: "short")))
    XCTAssertThrowsError(try MobilePairing.decode(data(endpoint: "https://mac.local", pin: "invalid")))
  }

  func testPairingURLRoundTripsAndRejectsWrongScheme() throws {
    let config = try data(endpoint: "https://mac.local:8943")
    let payload = config.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    let pairing = try MobilePairing.fromURL(URL(string: "informationbar://pair?payload=" + payload)!)
    XCTAssertEqual(pairing.host, "mac.local")
    XCTAssertThrowsError(try MobilePairing.fromURL(URL(string: "https://pair?payload=" + payload)!))
  }
}
