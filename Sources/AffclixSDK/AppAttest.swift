import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Apple App Attest, injectable for tests: a hardware-backed key per install,
/// attested once by Apple, then used to sign (assert) requests.
protocol AttestationProvider {
    var isSupported: Bool { get }
    func generateKey(_ done: @escaping (Result<String, Error>) -> Void)
    func attestKey(_ keyID: String, clientDataHash: Data, _ done: @escaping (Result<Data, Error>) -> Void)
    func generateAssertion(_ keyID: String, clientDataHash: Data, _ done: @escaping (Result<Data, Error>) -> Void)
}

/// No App Attest: older iOS, the Simulator, Linux.
struct NoAttestation: AttestationProvider {
    var isSupported: Bool { false }
    func generateKey(_ done: @escaping (Result<String, Error>) -> Void) { done(.failure(AffclixError.refused("unsupported"))) }
    func attestKey(_ keyID: String, clientDataHash: Data, _ done: @escaping (Result<Data, Error>) -> Void) {
        done(.failure(AffclixError.refused("unsupported")))
    }
    func generateAssertion(_ keyID: String, clientDataHash: Data, _ done: @escaping (Result<Data, Error>) -> Void) {
        done(.failure(AffclixError.refused("unsupported")))
    }
}

#if canImport(DeviceCheck) && os(iOS)
/// DCAppAttestService (iOS 14+, real devices).
struct SystemAppAttest: AttestationProvider {
    var isSupported: Bool {
        if #available(iOS 14.0, *) { return DCAppAttestService.shared.isSupported }
        return false
    }

    func generateKey(_ done: @escaping (Result<String, Error>) -> Void) {
        guard #available(iOS 14.0, *) else { return NoAttestation().generateKey(done) }
        DCAppAttestService.shared.generateKey { id, err in done(id.map { .success($0) } ?? .failure(err ?? AffclixError.refused("no key"))) }
    }

    func attestKey(_ keyID: String, clientDataHash: Data, _ done: @escaping (Result<Data, Error>) -> Void) {
        guard #available(iOS 14.0, *) else { return NoAttestation().attestKey(keyID, clientDataHash: clientDataHash, done) }
        DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash) { obj, err in
            done(obj.map { .success($0) } ?? .failure(err ?? AffclixError.refused("no attestation")))
        }
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data, _ done: @escaping (Result<Data, Error>) -> Void) {
        guard #available(iOS 14.0, *) else { return NoAttestation().generateAssertion(keyID, clientDataHash: clientDataHash, done) }
        DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash) { obj, err in
            done(obj.map { .success($0) } ?? .failure(err ?? AffclixError.refused("no assertion")))
        }
    }
}
#endif

/// The App Attest client data hash: SHA-256 of the MMP's challenge, which the
/// MMP hashes the same way.
func attestClientDataHash(_ challenge: String) -> Data {
    Data(SHA256.hash(data: Data(challenge.utf8)))
}

extension AffclixCore {
    /// App Attest evidence for the install, then `then` with it (on `state`).
    /// Best effort under `integrityTimeout`: no support, no challenge, an Apple
    /// error or the deadline send the install without evidence.
    ///
    /// A key is attested once — with the install that first carries it. Until
    /// that install is accepted or queued (`confirmAttested`), a retry attests the
    /// same key again only if Apple never attested it; a key Apple did attest but
    /// the MMP never received is dropped for a fresh one (`dropUnconfirmedKey`).
    func collectAttestation(then: @escaping ([String: Any]) -> Void) {
        guard config.appAttest, attestation.isSupported else { return then([:]) }
        var done = false
        let finish: ([String: Any]) -> Void = { [self] evidence in
            state.async {
                guard !done else { return }
                done = true
                then(evidence)
            }
        }
        state.asyncAfter(deadline: .now() + config.integrityTimeout) {
            if !done { Log.debug("App Attest: no evidence within \(self.config.integrityTimeout)s") }
            finish([:])
        }
        fetchIntegrityChallenge { [self] challenge in
            guard let challenge = challenge else { return finish([:]) }
            let hash = attestClientDataHash(challenge)
            state.async { [self] in
                if let key = storage.attestKeyID, storage.attestKeyConfirmed {
                    attestation.generateAssertion(key, clientDataHash: hash) { result in
                        switch result {
                        case .success(let a):
                            finish(["integrity_challenge": challenge, "attest_key_id": key, "assertion": a.base64EncodedString()])
                        case .failure(let e):
                            // The key is gone (restored backup, OS reset): start over next time.
                            Log.error("App Attest assertion failed: \(e)")
                            self.state.async { self.storage.attestKeyID = nil; self.storage.attestKeyConfirmed = false }
                            finish([:])
                        }
                    }
                    return
                }
                attestation.generateKey { result in
                    guard case .success(let key) = result else { return finish([:]) }
                    self.state.async { self.storage.attestKeyID = key; self.storage.attestKeyConfirmed = false }
                    self.attestation.attestKey(key, clientDataHash: hash) { result in
                        switch result {
                        case .success(let obj):
                            finish(["integrity_challenge": challenge, "attest_key_id": key, "attestation": obj.base64EncodedString()])
                        case .failure(let e):
                            Log.error("App Attest attestation failed: \(e)")
                            self.state.async { self.storage.attestKeyID = nil }
                            finish([:])
                        }
                    }
                }
            }
        }
    }

    /// The install carrying an attestation reached the MMP or the offline queue:
    /// its key is the install's, and later requests assert with it.
    func confirmAttested(_ evidence: [String: Any]) {
        if evidence["attestation"] != nil { storage.attestKeyConfirmed = true }
    }

    /// The install carrying an attestation was refused: the MMP never recorded
    /// the key, and Apple attests a key only once, so the next try needs a new one.
    func dropUnconfirmedKey(_ evidence: [String: Any]) {
        if evidence["attestation"] != nil { storage.attestKeyID = nil; storage.attestKeyConfirmed = false }
    }

    /// A challenge from the MMP (`POST /m/integrity/challenge`, signed like
    /// events); nil when it cannot be had.
    func fetchIntegrityChallenge(_ done: @escaping (String?) -> Void) {
        sender.send(prepare(["app_id": device.collect().bundleID], path: "/m/integrity/challenge")) { result in
            guard case .success(let data) = result,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["success"] as? Bool != false,
                  let challenge = obj["challenge"] as? String, !challenge.isEmpty else {
                Log.debug("App Attest: no challenge from the MMP")
                return done(nil)
            }
            done(challenge)
        }
    }
}
