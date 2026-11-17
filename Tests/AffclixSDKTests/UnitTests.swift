import XCTest
@testable import AffclixSDK

final class SignerTests: XCTestCase {
    /// Reference values from Python's hmac (the Go MMP uses the same HMAC-SHA256).
    func testMatchesReferenceHMAC() {
        let body = Data(#"{"event":"install","vid":"v1"}"#.utf8)
        XCTAssertEqual(RequestSigner.sign(secret: "s3cret", message: body),
                       "37f71fd2cbf36df67907e858188ac3968d781b9eac515ea7e14e525ede9d2482")
        // The MMP's per-app secret: HMAC(signing key, app key).
        XCTAssertEqual(RequestSigner.sign(secret: "server-signing-key", message: Data("KEY-1".utf8)),
                       "ba5aae7952cf0abfb907182256463f4df709c346b5464859ab7c94cb25766b9e")
    }
}

final class ConsentTests: XCTestCase {
    private func reader(_ box: Sandbox, tcf: [String: Any]?) -> ConsentReader {
        var tcfDefaults: UserDefaults?
        if let tcf = tcf {
            tcfDefaults = UserDefaults(suiteName: "tcf-" + UUID().uuidString)!
            for (k, v) in tcf { tcfDefaults!.set(v, forKey: k) }
        }
        return ConsentReader(storage: Storage(defaults: box.defaults), tcfDefaults: tcfDefaults)
    }

    func testTCFMapsToGoogleConsentMode() {
        // Purposes 1, 3, 4 consented, 7 refused.
        let p = reader(Sandbox(), tcf: ["IABTCF_gdprApplies": 1, "IABTCF_PurposeConsents": "1011000000",
                                        "IABTCF_TCString": "CPtcf"]).payload()
        XCTAssertEqual(p["gdpr_applies"] as? Int, 1)
        XCTAssertEqual(p["ad_user_data"] as? Int, 0)
        XCTAssertEqual(p["ad_personalization"] as? Int, 1)
        XCTAssertEqual(p["tcf_string"] as? String, "CPtcf")
    }

    func testExplicitWinsAndOutsideGDPR() {
        let box = Sandbox()
        Storage(defaults: box.defaults).consent = ConsentData(gdprApplies: true, adUserData: false, adPersonalization: nil)
        let p = reader(box, tcf: ["IABTCF_gdprApplies": 1, "IABTCF_PurposeConsents": "1111111111"]).payload()
        XCTAssertEqual(p["ad_user_data"] as? Int, 0)
        XCTAssertEqual(p["ad_personalization"] as? Int, 1)

        let out = reader(Sandbox(), tcf: ["IABTCF_gdprApplies": 0, "IABTCF_PurposeConsents": "0000000000"]).payload()
        XCTAssertEqual(out["gdpr_applies"] as? Int, 0)
        XCTAssertNil(out["ad_user_data"])
        XCTAssertTrue(reader(Sandbox(), tcf: nil).payload().isEmpty, "nothing known, nothing sent")
    }
}

final class OfflineQueueTests: XCTestCase {
    private func req(_ n: Int) -> PreparedRequest {
        PreparedRequest(url: URL(string: "https://x/m/ev")!, body: Data("{\"n\":\(n)}".utf8))
    }

    func testPersistsCapsAndDropsAfterMaxAttempts() {
        let dir = Sandbox().directory
        let q = OfflineQueue(directory: dir, capacity: 3, maxAttempts: 2)
        for n in 1...4 { q.enqueue(req(n)) }
        XCTAssertEqual(q.entries.map(\.request), [req(2), req(3), req(4)], "oldest dropped at capacity")

        let reloaded = OfflineQueue(directory: dir, capacity: 3, maxAttempts: 2)
        XCTAssertEqual(reloaded.entries, q.entries, "survives a restart")

        let first = reloaded.entries[0].id
        reloaded.markFailed(first)
        XCTAssertEqual(reloaded.entries.count, 3)
        reloaded.markFailed(first)
        XCTAssertEqual(reloaded.entries.map(\.request), [req(3), req(4)])
    }
}

final class SKANConversionTests: XCTestCase {
    private let schema = SKANSchema(version: 1, currency: "USD",
        fine: [.init(value: 3, event: "tutorial", min_revenue: nil), .init(value: 9, event: "*", min_revenue: 4.99)],
        coarse: [.init(value: "medium", event: "tutorial", min_revenue: nil), .init(value: "low", event: "*", min_revenue: nil)])

    func testEvaluateTakesTheHighestMatchingRules() {
        var p = SKANProgress()
        XCTAssertEqual(SKANConversion.evaluate(schema, p).fine, 0)
        XCTAssertNil(SKANConversion.evaluate(schema, p).coarse)

        SKANConversion.record("level_up", params: [:], schema: schema, into: &p)
        XCTAssertEqual(SKANConversion.evaluate(schema, p).fine, 0, "\"*\" needs revenue here")
        XCTAssertEqual(SKANConversion.evaluate(schema, p).coarse, "low")

        SKANConversion.record("tutorial", params: [:], schema: schema, into: &p)
        XCTAssertEqual(SKANConversion.evaluate(schema, p).fine, 3)
        XCTAssertEqual(SKANConversion.evaluate(schema, p).coarse, "medium", "medium outranks low whatever the rule order")

        SKANConversion.record("purchase", params: ["revenue": NSNumber(value: 4.99)], schema: schema, into: &p)
        XCTAssertEqual(SKANConversion.evaluate(schema, p).fine, 9)
    }

    func testNextUpdateOnlyGoesUp() {
        var p = SKANProgress()
        SKANConversion.record("tutorial", params: [:], schema: schema, into: &p)
        let first = SKANConversion.nextUpdate(schema, &p)
        XCTAssertEqual(first?.fine, 3)
        XCTAssertEqual(first?.coarse, .medium)
        XCTAssertNil(SKANConversion.nextUpdate(schema, &p), "nothing new")

        // A schema change that would lower the value sends nothing.
        let lower = SKANSchema(version: 2, currency: "USD", fine: [.init(value: 1, event: "tutorial", min_revenue: nil)], coarse: [])
        XCTAssertNil(SKANConversion.nextUpdate(lower, &p))
        XCTAssertEqual(p.fine, 3)
    }
}
