import Foundation
import XCTest

@testable import InformationBar

final class HomeWizardDiscoveryTests: XCTestCase {
  private let serial = "aabbccddeeff"

  private func advertisement(secure: Bool = false, extra: [String: String] = [:])
    -> DiscoveredHomeWizard?
  {
    let txt = [
      "serial": serial, "product_name": "P1 Meter", "product_type": "HWE-P1",
      "path": "/api/v1", "api_enabled": "1", "api_version": "2.3.0",
      "id": "appliance/p1dongle/\(serial)",
    ].merging(extra) { _, value in value }
    return DiscoveredHomeWizard(
      type: secure ? "_homewizard._tcp." : "_hwenergy._tcp.",
      host: "P1-Meter.local.", port: secure ? 443 : 80, txt: txt,
      addresses: ["192.168.1.17"])
  }

  func testV1AdvertisementPrefillsSetupAndReportsDisabledAPI() throws {
    let found = try XCTUnwrap(advertisement(extra: ["api_enabled": "0"]))
    XCTAssertEqual(found.device.address, "http://P1-Meter.local")
    XCTAssertEqual(found.device.apiVersion, "v1")
    XCTAssertEqual(found.device.serial, serial)
    XCTAssertEqual(found.device.assignment, .none)
    XCTAssertFalse(found.apiEnabled)
    XCTAssertTrue(found.measuresPower)
    XCTAssertNil(found.device.validationError)
  }

  func testV2UsesAdvertisedCertificateIdentityRatherThanProductCode() throws {
    let found = try XCTUnwrap(advertisement(secure: true))
    XCTAssertEqual(found.device.address, "https://P1-Meter.local")
    XCTAssertEqual(found.device.apiVersion, "v2")
    XCTAssertEqual(found.device.productType, "p1dongle")
    XCTAssertNil(found.device.validationError)
    // A future certificate type is preserved instead of silently identifying it as a P1.
    let future = try XCTUnwrap(
      advertisement(secure: true, extra: ["id": "appliance/new-meter/\(serial)"]))
    XCTAssertEqual(future.device.productType, "new-meter")
  }

  func testDualAdvertisementsPreferV2RegardlessOfArrivalOrder() throws {
    let v1 = try XCTUnwrap(advertisement())
    let v2 = try XCTUnwrap(advertisement(secure: true))
    for found in [v1.merging(v2), v2.merging(v1)] {
      XCTAssertEqual(found.id, serial)
      XCTAssertEqual(found.device.apiVersion, "v2")
      XCTAssertTrue(found.endpointAliases.contains("192.168.1.17"))
      XCTAssertTrue(found.endpointAliases.contains("p1-meter.local"))
    }
  }

  func testAlreadyAddedMatchesSerialHostnameAndResolvedAddress() throws {
    let found = try XCTUnwrap(advertisement())
    var power = PowerPreferences()
    for device in [
      HomeWizardDevice(address: "192.168.1.17/api/v1/data"),
      HomeWizardDevice(address: "http://P1-METER.LOCAL.:80/"),
      HomeWizardDevice(address: "192.168.1.99", serial: serial.uppercased()),
    ] {
      power.devices = [device]
      XCTAssertTrue(found.isConfigured(in: power))
    }
    power.devices = [HomeWizardDevice(address: "192.168.1.18")]
    XCTAssertFalse(found.isConfigured(in: power))
  }

  func testInvalidAdvertisementsAreIgnoredAndWaterMetersCannotBeAddedForPower() throws {
    XCTAssertNil(advertisement(extra: ["serial": "bad"]))
    XCTAssertNil(advertisement(extra: ["path": "/unsupported"]))
    XCTAssertNil(advertisement(secure: true, extra: ["id": "appliance/p1dongle/000000000000"]))
    XCTAssertNil(advertisement(secure: true, extra: ["id": "appliance//\(serial)"]))
    let water = try XCTUnwrap(advertisement(extra: ["product_type": "HWE-WTR"]))
    XCTAssertFalse(water.measuresPower)
  }

  func testAdvertisedNonstandardPortIsPreserved() throws {
    let found = try XCTUnwrap(
      DiscoveredHomeWizard(
        type: "_hwenergy._tcp.", host: "socket.local.", port: 8080,
        txt: ["serial": serial, "product_type": "HWE-SKT"], addresses: ["192.168.1.18"]))
    XCTAssertEqual(found.device.address, "http://socket.local:8080")
    XCTAssertTrue(found.endpointAliases.contains("192.168.1.18:8080"))
  }
}
