import Foundation
import XCTest
@testable import InformationBarMobile

final class MobilePresentationTests: XCTestCase {
  private let reference = Date(timeIntervalSince1970: 1_700_000_000)

  private func provider(_ id: String, updatedAt: Double, extra: [String: Any] = [:]) throws -> Provider {
    var object: [String: Any] = ["id": id, "name": id, "status": "ok", "updatedAt": updatedAt]
    object.merge(extra) { _, new in new }
    return try JSONDecoder().decode(Provider.self, from: JSONSerialization.data(withJSONObject: object))
  }

  private func snapshot(_ providers: [Provider], preferences: AppPreferences = .init()) -> MobileSnapshot {
    MobileSnapshot(version: 1, generatedAt: reference.timeIntervalSince1970 + 600,
      providers: providers, preferences: preferences)
  }

  func testTimelineExpiresAtSourceBoundaryEvenWithNewExportDate() throws {
    let pearl = try provider("pearl", updatedAt: reference.timeIntervalSince1970,
      extra: ["pearl": ["priceUSD": 1.25, "coinsPerDay": 6]])
    let snapshot = snapshot([pearl])
    let fresh = MobileSummary(snapshot: snapshot, category: .pearl, date: reference.addingTimeInterval(179))
    let expired = MobileSummary(snapshot: snapshot, category: .pearl, date: reference.addingTimeInterval(180))
    XCTAssertTrue(fresh.isFresh)
    XCTAssertEqual(fresh.projection.revenuePerDay, 7.5)
    XCTAssertFalse(expired.isFresh)
    XCTAssertNil(expired.projection.revenuePerDay)
    XCTAssertNil(expired.projection.netPerDay)
    XCTAssertEqual(expired.sourceDate, reference)
    XCTAssertTrue(expired.freshness.hasPrefix("Stale"))
  }

  func testMissingAssignedMeterNeverBecomesZeroPowerCost() throws {
    let pearl = try provider("pearl", updatedAt: reference.timeIntervalSince1970,
      extra: ["pearl": ["priceUSD": 1.25, "coinsPerDay": 6]])
    let power = try provider("power", updatedAt: reference.timeIntervalSince1970,
      extra: ["powerDevices": []])
    var preferences = AppPreferences()
    preferences.power.pricePerKWh = 0.25
    preferences.power.devices = [HomeWizardDevice(id: "missing-meter", name: "Miner", assignment: .pearl)]
    let summary = MobileSummary(snapshot: snapshot([pearl, power], preferences: preferences),
      category: .pearl, date: reference)
    XCTAssertEqual(summary.projection.revenuePerDay, 7.5)
    XCTAssertNil(summary.assignedWatts(.pearl))
    XCTAssertNil(summary.projection.powerPerDay)
    XCTAssertNil(summary.projection.netPerDay)
  }

  func testFarFutureProviderAndMeterTimestampsAreNotCurrent() throws {
    let pearl = try provider("pearl", updatedAt: reference.timeIntervalSince1970 + 3600,
      extra: ["pearl": ["priceUSD": 1.25, "coinsPerDay": 6]])
    let power = try provider("power", updatedAt: reference.timeIntervalSince1970,
      extra: ["powerDevices": [["id": "future-meter", "name": "Miner", "status": "ok",
        "updatedAt": reference.timeIntervalSince1970 + 3600, "watts": 450]]])
    let summary = MobileSummary(snapshot: snapshot([pearl, power]), category: .pearl, date: reference)
    XCTAssertFalse(summary.isFresh)
    XCTAssertNil(summary.projection.revenuePerDay)
    XCTAssertNil(summary.watts("future-meter"))
  }

  func testAllowanceExpiresAtResetWithoutWaitingForNewSnapshot() throws {
    let provider = try provider("codex", updatedAt: reference.timeIntervalSince1970,
      extra: ["windows": [["id": "codex:primary", "label": "Weekly", "main": true,
        "usedPercent": 90, "resetAt": reference.timeIntervalSince1970 + 60]]])
    let snapshot = snapshot([provider])
    let before = MobileSummary(snapshot: snapshot, category: .codex, date: reference.addingTimeInterval(59))
    let after = MobileSummary(snapshot: snapshot, category: .codex, date: reference.addingTimeInterval(60))
    XCTAssertEqual(before.primary, "90%")
    XCTAssertTrue(after.isFresh)
    XCTAssertNil(after.selectedWindow)
    XCTAssertEqual(after.primary, "—")
    XCTAssertEqual(after.metrics.first?.value, "Awaiting reset")
  }
}
