import XCTest
@testable import AffclixSDK

final class BackupRestoreTests: XCTestCase {
    private func installs(_ t: MockTransport) -> Int {
        t.requests.filter { json($0)["event"] as? String == "install" }.count
    }

    func testRestoreOntoAnotherDeviceIsReportedAsAnInstall() {
        let box = Sandbox()
        let first = MockTransport()
        let core1 = box.core(first, device: FakeDevice(idfv: "IDFV-OLD"))
        core1.start()
        settle(core1)
        XCTAssertEqual(installs(first), 1)
        let storage = Storage(defaults: box.defaults)
        let oldVid = storage.visitorID
        storage.clickID = "CLK-OLD"
        storage.userID = "user-1"

        // The same suite, restored from a backup onto a new iPhone.
        let second = MockTransport()
        let core2 = box.core(second, device: FakeDevice(idfv: "IDFV-NEW"))
        core2.start()
        settle(core2)

        XCTAssertEqual(installs(second), 1, "the install is reported on the new device")
        let install = second.requests.first { json($0)["event"] as? String == "install" }!
        XCTAssertNotEqual(json(install)["vid"] as? String, oldVid, "a new visitor ID")
        XCTAssertNil(json(install)["click_id"], "the old device's click is not carried")
        XCTAssertNil(storage.userID)
        XCTAssertEqual(box.defaults.string(forKey: "affclix_idfv"), "IDFV-NEW")
    }

    func testRelaunchOnTheSameDeviceKeepsState() {
        let box = Sandbox()
        let core1 = box.core(MockTransport())
        core1.start()
        settle(core1)
        let storage = Storage(defaults: box.defaults)
        let vid = storage.visitorID

        let second = MockTransport()
        let core2 = box.core(second)
        core2.start()
        settle(core2)

        XCTAssertEqual(installs(second), 0)
        XCTAssertEqual(storage.visitorID, vid)
    }

    func testStateFromAnOlderSDKIsKept() {
        // 0.2.1 recorded no vendor ID: an update must not look like a restore.
        let box = Sandbox()
        let storage = Storage(defaults: box.defaults)
        storage.installTimeMs = 1_700_000_000_000
        storage.installReported = true
        let vid = storage.visitorID

        XCTAssertFalse(storage.resetIfRestored(vendorID: "IDFV-1"))
        XCTAssertTrue(storage.installReported)
        XCTAssertEqual(storage.visitorID, vid)
        XCTAssertEqual(box.defaults.string(forKey: "affclix_idfv"), "IDFV-1")
    }

    func testUnknownVendorIDDecidesNothing() {
        let box = Sandbox()
        let storage = Storage(defaults: box.defaults)
        XCTAssertFalse(storage.resetIfRestored(vendorID: "IDFV-1"))
        storage.installReported = true

        XCTAssertFalse(storage.resetIfRestored(vendorID: nil))
        XCTAssertTrue(storage.installReported)
        XCTAssertEqual(box.defaults.string(forKey: "affclix_idfv"), "IDFV-1")
    }

    func testTrackingDomainDefaultsToTheMMPHost() {
        XCTAssertEqual(AffclixConfig(appKey: "KEY-1").trackingDomain, "mmp.affclix.org")
    }
}
