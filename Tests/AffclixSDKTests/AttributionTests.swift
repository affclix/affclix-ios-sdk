import XCTest
@testable import AffclixSDK

final class AttributionTests: XCTestCase {

    private func answer(_ s: String) -> Result<Data, DeliveryError> { .success(Data(s.utf8)) }

    func testInstallAnswerIsKeptAndDeliveredOnce() {
        let box = Sandbox(), transport = MockTransport()
        transport.respond = { _ in
            self.answer(#"{"success":true,"event_id":"E1","attributed":true,"attribution":{"method":"probabilistic"},"click_id":"CLK-9"}"#)
        }
        var got: [AttributionResult] = []
        let done = expectation(description: "onAttribution")
        var config = Sandbox.config()
        config.onAttribution = { got.append($0); done.fulfill() }
        let core = box.core(transport, config: config)
        core.start()
        settle(core)
        wait(for: [done], timeout: 1)

        let want = AttributionResult(isAttributed: true, method: "probabilistic", clickID: "CLK-9")
        XCTAssertEqual(got, [want])
        XCTAssertEqual(core.attribution, want)
        XCTAssertNil(Storage(defaults: box.defaults).clickID,
                     "the install's click is not resent as a deep-link click: later events keep their own method")

        // Later events answer too, but are not the install's attribution.
        core.logEvent("purchase", params: [:], completion: nil)
        settle(core)
        XCTAssertEqual(got.count, 1)
    }

    func testOrganicAnswer() {
        let r = AttributionResult.parse(Data(#"{"success":true,"attributed":false,"attribution":{"method":"organic"}}"#.utf8))
        XCTAssertEqual(r, AttributionResult(isAttributed: false, method: "organic", clickID: nil))
        XCTAssertNil(AttributionResult.parse(Data(#"{"success":false,"code":"TENANT_DISABLED"}"#.utf8)))
    }

    func testInstallSentFromTheQueueStillDeliversItsAttribution() {
        let box = Sandbox(), transport = MockTransport()
        transport.respond = { _ in .failure(.transient("offline")) }
        var got: [AttributionResult] = []
        let done = expectation(description: "onAttribution")
        var config = Sandbox.config()
        config.onAttribution = { got.append($0); done.fulfill() }
        let core = box.core(transport, config: config)
        core.start()
        settle(core)
        XCTAssertNil(core.attribution)

        transport.respond = { _ in
            self.answer(#"{"success":true,"attributed":true,"attribution":{"method":"view_through"},"click_id":"IMP-1"}"#)
        }
        core.didEnterForeground()
        settle(core)
        wait(for: [done], timeout: 1)
        XCTAssertEqual(core.attribution?.method, "view_through")
        XCTAssertEqual(got.map(\.method), ["view_through"])
    }

    func testErasureForgetsTheAttribution() {
        let box = Sandbox()
        let storage = Storage(defaults: box.defaults)
        storage.attribution = AttributionResult(isAttributed: true, method: "device_id", clickID: "C")
        storage.clearIdentifiers()
        XCTAssertNil(storage.attribution)
    }
}
