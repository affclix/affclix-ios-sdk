import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Request signatures: `sig=` is the hex HMAC-SHA256 of the raw JSON body under
/// the app secret. The MMP checks it against the secret it derives from the
/// app key — the same scheme as the Android SDK's RequestSigner.
enum RequestSigner {
    static func sign(secret: String, message: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(secret.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
