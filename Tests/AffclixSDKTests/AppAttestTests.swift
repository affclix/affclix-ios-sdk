import XCTest
@testable import AffclixSDK

/// A stand-in DCAppAttestService.
final class FakeAttestation: AttestationProvider {
    var isSupported = true
    var stall = false
    var failAttest = false
    private(set) var attestedHashes: [Data] = []
    private(set) var assertedHashes: [Data] = []
    private var keys = 0

    func generateKey(_ done: @escaping (Result<String, Error>) -> Void) {
        keys += 1
        done(.success("KEY-\(keys)"))
    }
    func attestKey(_ keyID: String, clientDataHash: Data, _ done: @escaping (Result<Data, Error>) -> Void) {
        attestedHashes.append(clientDataHash)
        if stall { return }
        done(failAttest ? .failure(AffclixError.refused("serverUnavailable")) : .success(Data("ATT-\(keyID)".utf8)))
    }
    func generateAssertion(_ keyID: String, clientDataHash: Data, _ done: @escaping (Result<Data, Error>) -> Void) {
        assertedHashes.append(clientDataHash)
        done(.success(Data("ASSERT-\(keyID)".utf8)))
    }
}

final class AppAttestTests: XCTestCase {

    private func attestConfig(timeout: TimeInterval = 2) -> AffclixConfig {
        var c = Sandbox.config()
        c.appAttest = true
        c.integrityTimeout = timeout
        return c
    }

    private func answering(event: String = #"{"success":true}"#, challenge: String? = #"{"success":true,"challenge":"CHAL","expires_in":2592000}"#) -> MockTransport {
        let t = MockTransport()
        t.respond = { r in
            if r.url.path == "/m/integrity/challenge" {
                guard let c = challenge else { return .failure(.transient("offline")) }
                return .success(Data(c.utf8))
            }
            return .success(Data(event.utf8))
        }
        return t
    }

    private func install(_ t: MockTransport) -> [String: Any]? {
        t.requests.filter { $0.url.path == "/m/ev" }.map(json).first { $0["event"] as? String == "install" }
    }

    func testInstallCarriesAnAttestationBoundToTheChallenge() {
        let box = Sandbox(), t = answering(), att = FakeAttestation()
        let core = box.core(t, config: attestConfig(), attestation: att)
        core.start()
        settle(core, 0.5)

        let challengeReq = t.requests.first { $0.url.path == "/m/integrity/challenge" }
        XCTAssertNotNil(challengeReq)
        XCTAssertEqual(challengeReq.map { query($0, "sig") }, challengeReq.map { RequestSigner.sign(secret: "s3cret", message: $0.body) },
                       "the challenge request is signed like events")
        let p = install(t)
        XCTAssertEqual(p?["integrity_challenge"] as? String, "CHAL")
        XCTAssertEqual(p?["attest_key_id"] as? String, "KEY-1")
        XCTAssertEqual(p?["attestation"] as? String, Data("ATT-KEY-1".utf8).base64EncodedString())
        XCTAssertNil(p?["assertion"])
        XCTAssertEqual(att.attestedHashes, [attestClientDataHash("CHAL")])
        let s = Storage(defaults: box.defaults)
        XCTAssertEqual(s.attestKeyID, "KEY-1")
        XCTAssertTrue(s.attestKeyConfirmed)
    }

    func testClientDataHashIsSHA256OfTheChallenge() {
        // printf CHAL | sha256sum — the MMP hashes the challenge the same way.
        XCTAssertEqual(attestClientDataHash("CHAL").map { String(format: "%02x", $0) }.joined(),
                       "6776e5044aee75bd9eb5aa7101c2714d2749d1d7decb91d4165b90a5d61e5e9a")
    }

    func testNoChallengeSendsTheInstallWithoutEvidence() {
        let box = Sandbox(), t = answering(challenge: nil), att = FakeAttestation()
        let core = box.core(t, config: attestConfig(), attestation: att)
        core.start()
        settle(core, 0.5)
        let p = install(t)
        XCTAssertNotNil(p, "the install still goes")
        XCTAssertNil(p?["attestation"])
        XCTAssertTrue(att.attestedHashes.isEmpty)
    }

    func testAStalledAttestationDoesNotHoldTheInstallUp() {
        let box = Sandbox(), t = answering(), att = FakeAttestation()
        att.stall = true
        let core = box.core(t, config: attestConfig(timeout: 0.2), attestation: att)
        core.start()
        settle(core, 0.6)
        let p = install(t)
        XCTAssertNotNil(p)
        XCTAssertNil(p?["attestation"])
        XCTAssertFalse(Storage(defaults: box.defaults).attestKeyConfirmed)
    }

    func testARefusedInstallDropsItsKeyForAFreshOne() {
        let box = Sandbox(), t = answering(event: #"{"success":false,"code":"TENANT_DISABLED"}"#), att = FakeAttestation()
        let core = box.core(t, config: attestConfig(), attestation: att)
        core.start()
        settle(core, 0.5)
        XCTAssertNil(Storage(defaults: box.defaults).attestKeyID, "Apple attests a key once: the next try needs a new one")

        t.respond = answering().respond
        let next = box.core(t, config: attestConfig(), attestation: att)
        next.start()
        settle(next, 0.5)
        let installs = t.requests.filter { $0.url.path == "/m/ev" }.map(json).filter { $0["event"] as? String == "install" }
        XCTAssertEqual(installs.last?["attest_key_id"] as? String, "KEY-2")
        XCTAssertNotNil(installs.last?["attestation"])
    }

    func testOffByDefaultAndOnUnsupportedDevices() {
        let box = Sandbox(), t = answering(), att = FakeAttestation()
        let core = box.core(t, attestation: att) // appAttest off
        core.start()
        settle(core)
        XCTAssertFalse(t.requests.contains { $0.url.path == "/m/integrity/challenge" })

        let box2 = Sandbox(), t2 = answering(), att2 = FakeAttestation()
        att2.isSupported = false
        let core2 = box2.core(t2, config: attestConfig(), attestation: att2)
        core2.start()
        settle(core2)
        XCTAssertFalse(t2.requests.contains { $0.url.path == "/m/integrity/challenge" })
        XCTAssertNotNil(install(t2))
    }

    func testAdRevenueParameters() {
        let p = AdRevenue(mediation: "applovin_max", revenue: 0.0123, network: "AdMob", adUnitID: "u1",
                          adFormat: "INTER", placement: "level_end", precision: "exact").params
        XCTAssertEqual(p["ad_mediation"] as? String, "applovin_max")
        XCTAssertEqual(p["ad_network"] as? String, "AdMob")
        XCTAssertEqual(p["ad_unit_id"] as? String, "u1")
        XCTAssertEqual(p["ad_placement"] as? String, "level_end")
        XCTAssertEqual(p["revenue_precision"] as? String, "exact")
        XCTAssertEqual(p["revenue"] as? Double, 0.0123)
        XCTAssertNil(p["ad_impressions"])
        XCTAssertEqual(AdRevenue(mediation: "levelplay", revenue: 1, impressions: 3).params["ad_impressions"] as? Int, 3)
    }
}
