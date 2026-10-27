import XCTest
@testable import AffclixSDK

final class CoreTests: XCTestCase {

    func testInstallReportedOnceAndSigned() {
        let box = Sandbox(), transport = MockTransport(), skan = FakeSKAN()
        let core = box.core(transport, skan: skan)
        core.start()
        settle(core)

        XCTAssertEqual(transport.requests.count, 1)
        let r = transport.requests[0]
        XCTAssertEqual(r.url.host, "acme.affclix.org")
        XCTAssertEqual(r.url.path, "/m/ev")
        XCTAssertEqual(query(r, "ak"), "KEY-1")
        XCTAssertEqual(query(r, "sig"), RequestSigner.sign(secret: "s3cret", message: r.body))
        let p = json(r)
        XCTAssertEqual(p["event"] as? String, "install")
        XCTAssertEqual(p["platform"] as? String, "ios")
        XCTAssertEqual(p["app_id"] as? String, "com.game.ios")
        XCTAssertEqual(p["idfv"] as? String, "IDFV-1")
        XCTAssertEqual(p["asa_token"] as? String, "ASA-TOKEN")
        XCTAssertNotNil(p["vid"] as? String)
        XCTAssertNotNil(p["install_time"])
        XCTAssertNil(p["idfa"], "no IDFA without ATT authorization")
        XCTAssertEqual(skan.updates, [0], "SKAdNetwork registration on first open")

        // A later start does not report the install again.
        let again = box.core(transport, skan: skan)
        again.start()
        settle(again)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(skan.updates, [0])
    }

    func testInstallQueuedOfflineThenResentByteForByte() {
        let box = Sandbox(), transport = MockTransport()
        transport.respond = { _ in .failure(.transient("offline")) }
        let core = box.core(transport)
        core.start()
        settle(core)
        // One try plus one retry, then queued — and counted as reported.
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(Storage(defaults: box.defaults).installReported)

        transport.respond = { _ in .success(Data(#"{"success":true}"#.utf8)) }
        core.didEnterForeground()
        settle(core)
        let sent = transport.requests
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent[2], sent[0], "the queued install is resent unchanged")

        core.didEnterForeground()
        settle(core)
        XCTAssertEqual(transport.requests.count, 3, "queue is empty")
    }

    func testRefusedInstallRetriedNextStart() {
        let box = Sandbox(), transport = MockTransport()
        transport.respond = { _ in .success(Data(#"{"success":false,"code":"INVALID_APP_KEY"}"#.utf8)) }
        let core = box.core(transport)
        core.start()
        settle(core)
        XCTAssertFalse(Storage(defaults: box.defaults).installReported)

        transport.respond = { _ in .success(Data(#"{"success":true}"#.utf8)) }
        let next = box.core(transport)
        next.start()
        settle(next)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(Storage(defaults: box.defaults).installReported)
    }

    func testInstallWaitsForATTAnswer() {
        let box = Sandbox(), transport = MockTransport(), tracking = FakeTracking()
        tracking.status = .notDetermined
        let core = box.core(transport, tracking: tracking, config: Sandbox.config(attWait: 5))
        core.start()
        settle(core, 0.1)
        XCTAssertTrue(transport.requests.isEmpty, "install held while the user has not answered")

        tracking.status = .authorized
        settle(core, 0.1)
        XCTAssertEqual(transport.requests.count, 1)
        let p = json(transport.requests[0])
        XCTAssertEqual(p["idfa"] as? String, "IDFA-1")
        XCTAssertEqual(p["att_status"] as? String, "authorized")
    }

    func testDeepLinkClickIDCarriedByEvents() {
        let box = Sandbox(), transport = MockTransport()
        let core = box.core(transport)
        let link = URL(string: "https://acme.affclix.org/l/com.game?click_id=CLK&deep_link_value=myapp%3A%2F%2Fp%2F42&promo=x")!
        let result = core.handleDeepLink(link)
        XCTAssertEqual(result.clickID, "CLK")
        XCTAssertEqual(result.deepLinkValue, "myapp://p/42")
        XCTAssertEqual(result.parameters, ["promo": "x"])

        let done = expectation(description: "event")
        var eventID: String?
        core.logEvent("purchase", params: ["e": "buy", "revenue": 4.99, "txid": "T1"]) { r in
            eventID = try? r.get()
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        let events = transport.requests.map(json)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0]["event"] as? String, "deep_link")
        XCTAssertEqual(events[0]["deep_link_value"] as? String, "myapp://p/42")
        XCTAssertEqual(events[0]["click_id"] as? String, "CLK")
        let purchase = events[1]
        XCTAssertEqual(purchase["event"] as? String, "purchase")
        XCTAssertEqual(purchase["click_id"] as? String, "CLK")
        XCTAssertEqual(purchase["e"] as? String, "buy")
        XCTAssertEqual(purchase["txid"] as? String, "T1")
        XCTAssertEqual(purchase["event_id"] as? String, eventID)
        XCTAssertNotEqual(events[0]["event_id"] as? String, eventID, "each event gets its own event_id")
    }

    func testConsentInPayload() {
        let box = Sandbox(), transport = MockTransport()
        let core = box.core(transport)
        core.setConsent(ConsentData(gdprApplies: true, adUserData: false, adPersonalization: nil))
        core.logEvent("x", params: [:], completion: nil)
        settle(core)
        let p = json(transport.requests[0])
        XCTAssertEqual(p["gdpr_applies"] as? Int, 1)
        XCTAssertEqual(p["ad_user_data"] as? Int, 0)
        XCTAssertNil(p["ad_personalization"])
    }

    func testPushTokenRegisteredOncePerToken() {
        let box = Sandbox(), transport = MockTransport()
        let core = box.core(transport)
        core.setPushToken("a1b2c3", sandbox: true)
        settle(core)
        XCTAssertEqual(transport.requests.count, 1)
        let r = transport.requests[0]
        XCTAssertEqual(r.url.path, "/m/token")
        XCTAssertEqual(query(r, "sig"), RequestSigner.sign(secret: "s3cret", message: r.body))
        let p = json(r)
        XCTAssertEqual(p["push_token"] as? String, "a1b2c3")
        XCTAssertEqual(p["push_sandbox"] as? Int, 1)
        XCTAssertEqual(p["platform"] as? String, "ios")
        XCTAssertNotNil(p["vid"] as? String)

        core.setPushToken("a1b2c3", sandbox: true)
        settle(core)
        XCTAssertEqual(transport.requests.count, 1, "same token: not sent again")
        core.setPushToken("d4e5f6", sandbox: true)
        settle(core)
        XCTAssertEqual(transport.requests.count, 2, "new token: sent")
    }

    func testUninstallCheckPush() {
        XCTAssertTrue(Affclix.isUninstallCheck(["aps": ["content-available": 1], "affclix_uninstall_check": 1]))
        XCTAssertTrue(Affclix.isUninstallCheck(["affclix_uninstall_check": "1"]))
        XCTAssertFalse(Affclix.isUninstallCheck(["aps": ["alert": "hi"]]))
    }

    func testDataDeletionForgetsIdentifiersButKeepsInstall() {
        let box = Sandbox(), transport = MockTransport()
        transport.respond = { r in
            r.url.path == "/m/forget" ? .success(Data(#"{"success":true,"request_id":"R-1"}"#.utf8))
                                      : .success(Data(#"{"success":true}"#.utf8))
        }
        let core = box.core(transport)
        core.start()
        settle(core)
        let storage = Storage(defaults: box.defaults)
        let vidBefore = storage.visitorID
        storage.clickID = "CLK"

        let done = expectation(description: "deleted")
        var requestID: String?
        core.requestDataDeletion { r in requestID = try? r.get(); done.fulfill() }
        wait(for: [done], timeout: 2)

        XCTAssertEqual(requestID, "R-1")
        let forget = transport.requests.last!
        XCTAssertEqual(forget.url.path, "/m/forget")
        XCTAssertEqual(json(forget)["vid"] as? String, vidBefore)
        XCTAssertEqual(json(forget)["idfv"] as? String, "IDFV-1")
        XCTAssertNil(storage.clickID)
        XCTAssertNotEqual(storage.visitorID, vidBefore, "a new visitor ID after erasure")
        XCTAssertTrue(storage.installReported, "install state kept")
    }

    func testSessionStartOnLaunchAndAfterTimeout() {
        let box = Sandbox(), transport = MockTransport()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let core = box.core(transport, config: Sandbox.config(sessions: true), now: { clock })
        func sessions() -> Int { transport.requests.filter { json($0)["event"] as? String == "session_start" }.count }

        core.start()
        settle(core)
        XCTAssertEqual(sessions(), 1, "launch starts a session")

        core.didEnterBackground(); clock += 5 * 60
        core.didEnterForeground()
        settle(core)
        XCTAssertEqual(sessions(), 1, "back within 30 minutes: same session")

        core.didEnterBackground(); clock += 31 * 60
        core.didEnterForeground()
        settle(core)
        XCTAssertEqual(sessions(), 2, "back after 30 minutes: new session")
    }

    // MARK: - SKAdNetwork conversion values

    private static let schemaJSON = #"""
    {"success":true,"schema":{"version":7,"currency":"USD",
     "fine":[{"value":1,"event":"registration"},{"value":10,"event":"purchase"},{"value":20,"event":"*","min_revenue":50}],
     "coarse":[{"value":"low","event":"*"},{"value":"high","event":"purchase","min_revenue":50}]}}
    """#

    func testConversionValuesFollowTheDashboardSchema() {
        let box = Sandbox(), transport = MockTransport(), skan = FakeSKAN()
        transport.respond = { r in
            .success(Data((r.url.path == "/m/skan-schema" ? Self.schemaJSON : #"{"success":true}"#).utf8))
        }
        let core = box.core(transport, skan: skan, config: Sandbox.config(skan: true))
        core.start()
        settle(core)
        let schemaRequests = transport.requests.filter { $0.url.path == "/m/skan-schema" }
        XCTAssertEqual(schemaRequests.count, 1)
        XCTAssertEqual(query(schemaRequests[0], "ak"), "KEY-1")
        XCTAssertEqual(skan.updates, [0], "registration only: nothing earned yet")

        core.logEvent("session_start", params: [:], completion: nil)
        settle(core)
        XCTAssertEqual(skan.updates, [0], "SDK events are not in-app actions")

        core.logEvent("registration", params: [:], completion: nil)
        settle(core)
        XCTAssertEqual(skan.updates, [0, 1])
        XCTAssertEqual(skan.coarse.last!, .low)

        core.logEvent("purchase", params: ["revenue": 30.0, "currency": "usd"], completion: nil)
        // Revenue in another currency counts the event, not the money.
        core.logEvent("purchase", params: ["revenue": 999, "currency": "EUR"], completion: nil)
        settle(core)
        XCTAssertEqual(skan.updates, [0, 1, 10], "the second purchase earns nothing new")

        core.logEvent("purchase", params: ["revenue": "25", "currency": "USD"], completion: nil)
        settle(core)
        XCTAssertEqual(skan.updates, [0, 1, 10, 20], "55 USD since install")
        XCTAssertEqual(skan.coarse.last!, .high)

        // The schema is asked for at most daily; progress survives a restart.
        let again = box.core(transport, skan: skan, config: Sandbox.config(skan: true))
        again.start()
        again.logEvent("registration", params: [:], completion: nil)
        settle(again)
        XCTAssertEqual(transport.requests.filter { $0.url.path == "/m/skan-schema" }.count, 1)
        XCTAssertEqual(skan.updates, [0, 1, 10, 20])
    }

    func testNoConversionValuesAfterTheMeasurementWindow() {
        let box = Sandbox(), transport = MockTransport(), skan = FakeSKAN()
        transport.respond = { r in
            .success(Data((r.url.path == "/m/skan-schema" ? Self.schemaJSON : #"{"success":true}"#).utf8))
        }
        var clock = Date()
        let core = box.core(transport, skan: skan, config: Sandbox.config(skan: true), now: { clock })
        core.start()
        settle(core)

        clock = clock.addingTimeInterval(36 * 24 * 3600)
        core.logEvent("purchase", params: ["revenue": 100.0], completion: nil)
        settle(core)
        XCTAssertEqual(skan.updates, [0], "Apple stops measuring after 35 days")
    }

    func testAppWithoutSchemaOnlyRegisters() {
        let box = Sandbox(), transport = MockTransport(), skan = FakeSKAN()
        transport.respond = { r in
            .success(Data((r.url.path == "/m/skan-schema" ? #"{"success":true,"schema":null}"# : #"{"success":true}"#).utf8))
        }
        let core = box.core(transport, skan: skan, config: Sandbox.config(skan: true))
        core.start()
        core.logEvent("purchase", params: ["revenue": 100.0], completion: nil)
        settle(core)
        XCTAssertEqual(skan.updates, [0])
    }
}
