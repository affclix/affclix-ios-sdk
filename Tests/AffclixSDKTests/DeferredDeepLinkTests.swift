import XCTest
@testable import AffclixSDK

final class DeferredDeepLinkTests: XCTestCase {
    static let copied = "https://acme.affclix.org/l/com.game.ios?afdl=J0XRNEvYjARdQAt8pEHsow"

    static func config(_ mode: DeferredDeepLinking, timeout: TimeInterval = 2,
                       onDeepLink: ((DeepLinkResult) -> Void)? = nil) -> AffclixConfig {
        var c = Sandbox.config()
        c.deferredDeepLinking = mode
        c.deferredDeepLinkTimeout = timeout
        c.onDeepLink = onDeepLink
        return c
    }

    /// Answers /m/dl with `answer`, everything else with success.
    static func transport(_ answer: String) -> MockTransport {
        let t = MockTransport()
        t.respond = { r in
            .success(Data((r.url.path == "/m/dl" ? answer : #"{"success":true}"#).utf8))
        }
        return t
    }

    static let found = #"{"success":true,"found":true,"click_id":"50001-CLK","deep_link_value":"kol_RIYA10","campaign_id":50001,"affiliate_id":70001}"#

    func testAutomaticResolvesBeforeTheInstall() {
        let box = Sandbox(), transport = Self.transport(Self.found), board = FakePasteboard()
        board.text = Self.copied
        let got = expectation(description: "onDeepLink")
        var link: DeepLinkResult?
        let core = box.core(transport, pasteboard: board, config: Self.config(.automatic) { link = $0; got.fulfill() })
        core.start()
        wait(for: [got], timeout: 2)
        settle(core)

        XCTAssertEqual(transport.requests.map { $0.url.path }, ["/m/dl", "/m/ev"])
        let lookup = json(transport.requests[0])
        XCTAssertEqual(lookup["url"] as? String, Self.copied)
        XCTAssertEqual(query(transport.requests[0], "ak"), "KEY-1")
        XCTAssertNotNil(query(transport.requests[0], "sig"), "the lookup is signed")

        let install = json(transport.requests[1])
        XCTAssertEqual(install["event"] as? String, "install")
        XCTAssertEqual(install["click_id"] as? String, "50001-CLK", "the install carries the deferred click")

        XCTAssertEqual(link?.isDeferred, true)
        XCTAssertEqual(link?.clickID, "50001-CLK")
        XCTAssertEqual(link?.deepLinkValue, "kol_RIYA10")
        XCTAssertEqual(link?.parameters["c"], "50001")
        XCTAssertEqual(link?.parameters["a"], "70001")
        XCTAssertNil(link?.parameters["afdl"])
        XCTAssertTrue(board.cleared, "the copied link is taken off the clipboard")
    }

    func testOnlyFirstLaunchLooksUp() {
        let box = Sandbox(), transport = Self.transport(Self.found), board = FakePasteboard()
        board.text = Self.copied
        let first = box.core(transport, pasteboard: board, config: Self.config(.automatic))
        first.start()
        settle(first, 0.3)
        let second = box.core(transport, pasteboard: board, config: Self.config(.automatic))
        second.start()
        settle(second, 0.3)
        XCTAssertEqual(transport.requests.filter { $0.url.path == "/m/dl" }.count, 1)
        XCTAssertEqual(transport.requests.filter { json($0)["event"] as? String == "install" }.count, 1)
    }

    func testUnrelatedClipboardIsNotSent() {
        let box = Sandbox(), transport = Self.transport(Self.found), board = FakePasteboard()
        board.text = "https://example.com/an/article"
        let core = box.core(transport, pasteboard: board, config: Self.config(.automatic))
        core.start()
        settle(core, 0.3)
        XCTAssertEqual(transport.requests.map { $0.url.path }, ["/m/ev"], "only the install, at once")
        XCTAssertNil(json(transport.requests[0])["click_id"])
        XCTAssertFalse(board.cleared)
    }

    func testNotFoundReleasesTheInstallWithoutClick() {
        let box = Sandbox(), transport = Self.transport(#"{"success":true,"found":false}"#), board = FakePasteboard()
        board.text = Self.copied
        var called = false
        let core = box.core(transport, pasteboard: board, config: Self.config(.automatic) { _ in called = true })
        core.start()
        settle(core, 0.3)
        XCTAssertEqual(transport.requests.map { $0.url.path }, ["/m/dl", "/m/ev"])
        XCTAssertNil(json(transport.requests[1])["click_id"])
        XCTAssertFalse(called)
        XCTAssertFalse(board.cleared)
    }

    func testManualHoldsTheInstallUntilTheAppPastes() {
        let box = Sandbox(), transport = Self.transport(Self.found)
        let core = box.core(transport, config: Self.config(.manual, timeout: 5))
        core.start()
        settle(core, 0.3)
        XCTAssertTrue(transport.requests.isEmpty, "install waits for the paste")

        core.resolveDeferredDeepLink(Self.copied)
        settle(core, 0.3)
        XCTAssertEqual(transport.requests.map { $0.url.path }, ["/m/dl", "/m/ev"])
        XCTAssertEqual(json(transport.requests[1])["click_id"] as? String, "50001-CLK")
    }

    func testManualSkippedOrTimedOut() {
        let skipped = Sandbox(), t1 = Self.transport(Self.found)
        let c1 = skipped.core(t1, config: Self.config(.manual, timeout: 5))
        c1.start()
        c1.resolveDeferredDeepLink(nil)
        settle(c1, 0.3)
        XCTAssertEqual(t1.requests.map { $0.url.path }, ["/m/ev"])

        let timedOut = Sandbox(), t2 = Self.transport(Self.found)
        let c2 = timedOut.core(t2, config: Self.config(.manual, timeout: 0.1))
        c2.start()
        settle(c2, 0.4)
        XCTAssertEqual(t2.requests.map { $0.url.path }, ["/m/ev"])
        XCTAssertNil(json(t2.requests[0])["click_id"])

        // A paste after the install still sets the click for later events.
        c2.resolveDeferredDeepLink(Self.copied)
        settle(c2, 0.3)
        let done = expectation(description: "event")
        c2.logEvent("signup", params: ["e": "signup"]) { _ in done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(json(t2.requests.last!)["click_id"] as? String, "50001-CLK")
    }

    func testOffNeverLooksUp() {
        let box = Sandbox(), transport = Self.transport(Self.found), board = FakePasteboard()
        board.text = Self.copied
        let core = box.core(transport, pasteboard: board, config: Self.config(.off))
        core.start()
        settle(core, 0.3)
        XCTAssertEqual(transport.requests.map { $0.url.path }, ["/m/ev"])
    }

    func testCopiedLinkOpenedAsUniversalLink() {
        let box = Sandbox(), transport = Self.transport(Self.found)
        let got = expectation(description: "onDeepLink")
        var link: DeepLinkResult?
        let core = box.core(transport, config: Self.config(.off) { link = $0; got.fulfill() })
        _ = core.handleDeepLink(URL(string: Self.copied)!)
        wait(for: [got], timeout: 2)
        XCTAssertEqual(transport.requests.map { $0.url.path }, ["/m/dl"], "no deep_link event for the bare token")
        XCTAssertEqual(link?.clickID, "50001-CLK")
        XCTAssertEqual(link?.isDeferred, true)
    }

    func testDeferredToken() {
        XCTAssertEqual(DeepLinkResult.deferredToken(in: Self.copied), "J0XRNEvYjARdQAt8pEHsow")
        XCTAssertEqual(DeepLinkResult.deferredToken(in: " \(Self.copied)\n"), "J0XRNEvYjARdQAt8pEHsow")
        XCTAssertNil(DeepLinkResult.deferredToken(in: "https://acme.affclix.org/l/x?afdl=short"))
        XCTAssertNil(DeepLinkResult.deferredToken(in: "hello"))
    }
}
