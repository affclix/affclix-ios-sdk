import XCTest
@testable import AffclixSDK

final class ShortLinkTests: XCTestCase {
    static let link = URL(string: "https://acme.affclix.org/l/summer-shoes?utm_source=email")!

    static func transport(_ answer: String) -> MockTransport {
        let t = MockTransport()
        t.respond = { r in .success(Data((r.url.path == "/m/link" ? answer : #"{"success":true}"#).utf8)) }
        return t
    }

    func testShortLinkResolvesThroughTheMMP() {
        let box = Sandbox()
        let transport = Self.transport(#"{"success":true,"found":true,"code":"summer-shoes","params":{"deep_link_value":"shoes","campaign_id":"5","utm_source":"insta"}}"#)
        let got = expectation(description: "onDeepLink")
        var link: DeepLinkResult?
        var config = Sandbox.config()
        config.onDeepLink = { link = $0; got.fulfill() }
        let core = box.core(transport, config: config)

        let first = core.handleDeepLink(Self.link)
        XCTAssertNil(first.deepLinkValue, "the returned result is the link as opened")
        wait(for: [got], timeout: 2)
        settle(core)

        XCTAssertEqual(link?.deepLinkValue, "shoes")
        XCTAssertEqual(link?.utmSource, "email", "the URL's own parameters win")
        XCTAssertEqual(link?.parameters["campaign_id"], "5")
        XCTAssertEqual(transport.requests.map { $0.url.path }, ["/m/link", "/m/ev"])
        XCTAssertEqual(json(transport.requests[0])["url"] as? String, Self.link.absoluteString)
        XCTAssertEqual(query(transport.requests[0], "ak"), "KEY-1")
        let event = json(transport.requests[1])
        XCTAssertEqual(event["event"] as? String, "deep_link")
        XCTAssertEqual(event["deep_link_value"] as? String, "shoes")
    }

    func testUnknownShortLinkIsDeliveredAsOpened() {
        let box = Sandbox(), transport = Self.transport(#"{"success":true,"found":false}"#)
        let got = expectation(description: "onDeepLink")
        var link: DeepLinkResult?
        var config = Sandbox.config()
        config.onDeepLink = { link = $0; got.fulfill() }
        let core = box.core(transport, config: config)
        _ = core.handleDeepLink(Self.link)
        wait(for: [got], timeout: 2)
        XCTAssertEqual(link?.url, Self.link)
        XCTAssertNil(link?.deepLinkValue)
    }

    func testNoAnswerInTimeDeliversTheLinkAsOpenedOnce() {
        let box = Sandbox(), transport = MockTransport()
        transport.hold = true // the MMP never answers
        AffclixCore.shortLinkTimeout = 0.3
        defer { AffclixCore.shortLinkTimeout = 10 }
        let got = expectation(description: "onDeepLink")
        got.assertForOverFulfill = true
        var link: DeepLinkResult?
        var config = Sandbox.config()
        config.onDeepLink = { link = $0; got.fulfill() }
        let core = box.core(transport, config: config)
        _ = core.handleDeepLink(Self.link)
        wait(for: [got], timeout: 2)
        XCTAssertEqual(link?.url, Self.link)
        XCTAssertNil(link?.deepLinkValue)
    }

    func testIsShortLink() {
        XCTAssertTrue(DeepLinkResult.isShortLink(Self.link))
        XCTAssertTrue(DeepLinkResult.isShortLink(URL(string: "https://go.brand.com/l/ab3x9kq")!))
        XCTAssertFalse(DeepLinkResult.isShortLink(URL(string: "https://acme.affclix.org/l/com.shoe?deep_link_value=x")!))
        XCTAssertFalse(DeepLinkResult.isShortLink(URL(string: "https://acme.affclix.org/l/summer?click_id=CLK")!))
        XCTAssertFalse(DeepLinkResult.isShortLink(URL(string: "https://acme.affclix.org/l/summer?afdl=J0XRNEvYjARdQAt8pEHsow")!))
        XCTAssertFalse(DeepLinkResult.isShortLink(URL(string: "https://acme.affclix.org/promo/summer")!))
        XCTAssertFalse(DeepLinkResult.isShortLink(URL(string: "shoeapp://l/summer-shoes")!))
    }

    func testCustomSchemeLinkFromTheOpenInAppPage() {
        let box = Sandbox(), transport = MockTransport()
        let core = box.core(transport)
        let result = core.handleDeepLink(URL(string: "shoeapp://l/com.shoe?click_id=CLK9&deep_link_value=shoes&c=5")!)
        XCTAssertEqual(result.clickID, "CLK9")
        XCTAssertEqual(result.deepLinkValue, "shoes")
        settle(core)
        XCTAssertEqual(transport.requests.map { $0.url.path }, ["/m/ev"], "a complete link needs no lookup")
    }
}

final class MatchedDeferredDeepLinkTests: XCTestCase {
    static let matched = #"{"success":true,"event_id":"E1","attributed":false,"attribution":{"method":"organic"},"deferred_deep_link":{"deep_link_value":"shoes","match":"ip"}}"#

    static func transport() -> MockTransport {
        let t = MockTransport()
        t.respond = { r in
            let isInstall = json(r)["event"] as? String == "install"
            return .success(Data((isInstall ? matched : #"{"success":true}"#).utf8))
        }
        return t
    }

    func testInstallWithoutACopiedLinkGetsTheMatchedOne() {
        let box = Sandbox(), transport = Self.transport()
        let got = expectation(description: "onDeepLink")
        var link: DeepLinkResult?
        var config = Sandbox.config()
        config.deferredDeepLinking = .automatic
        config.onDeepLink = { link = $0; got.fulfill() }
        let core = box.core(transport, pasteboard: FakePasteboard(), config: config)
        core.start()
        wait(for: [got], timeout: 3)
        XCTAssertEqual(link?.deepLinkValue, "shoes")
        XCTAssertEqual(link?.isDeferred, true)
        let install = transport.requests.map(json).first { $0["event"] as? String == "install" }
        XCTAssertNil(install?["has_deferred_deep_link"], "an install with no link of its own asks for a match")
    }

    func testMatchedWithTheClipboardHandoffOff() {
        let box = Sandbox(), transport = Self.transport()
        let got = expectation(description: "onDeepLink")
        var config = Sandbox.config()
        config.deferredDeepLinking = .off
        config.onDeepLink = { _ in got.fulfill() }
        let core = box.core(transport, pasteboard: FakePasteboard(), config: config)
        core.start()
        wait(for: [got], timeout: 3)
        XCTAssertTrue(transport.requests.allSatisfy { $0.url.path != "/m/dl" }, "no clipboard lookup")
    }

    func testNoDeepLinkHandlerNeitherAsksNorDelivers() {
        let box = Sandbox(), transport = Self.transport()
        let core = box.core(transport, pasteboard: FakePasteboard(), config: Sandbox.config())
        core.start()
        settle(core, 0.5)
        let install = transport.requests.map(json).first { $0["event"] as? String == "install" }
        XCTAssertEqual(install?["has_deferred_deep_link"] as? Bool, true)
    }
}
