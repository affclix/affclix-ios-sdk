import Foundation

/// Consent the app set with `Affclix.setConsentData`; nil = not set.
struct ConsentData: Equatable {
    var gdprApplies: Bool?
    var adUserData: Bool?
    var adPersonalization: Bool?
}

/// The user's consent as sent with every request, in Google consent mode terms
/// (EU DMA) — gdpr_applies, ad_user_data, ad_personalization — plus the IAB TCF
/// v2 string. Mirrors the Android SDK's ConsentManager.
///
/// Explicit values win. Otherwise, when TCF collection is on, they are derived
/// from what the app's TCF CMP stored in `UserDefaults.standard`, with Google's
/// mapping: ad_user_data = purposes 1 and 7, ad_personalization = purposes 3
/// and 4. Under GDPR an explicit ad_user_data=0 makes the MMP skip device-ID
/// matching and keep the IP out of the advertiser postback. Unknown values are
/// not sent; outside GDPR only gdpr_applies=0 is.
struct ConsentReader {
    let storage: Storage
    /// Where the CMP writes IABTCF_*; nil when TCF collection is off.
    let tcfDefaults: UserDefaults?

    func payload() -> [String: Any] {
        let explicit = storage.consent
        let tcf = tcfDefaults.map(readTCF)

        var out: [String: Any] = [:]
        guard let applies = explicit.gdprApplies ?? tcf?.gdprApplies else { return out }
        out["gdpr_applies"] = applies ? 1 : 0
        guard applies else { return out }
        if let v = explicit.adUserData ?? tcf?.adUserData { out["ad_user_data"] = v ? 1 : 0 }
        if let v = explicit.adPersonalization ?? tcf?.adPersonalization { out["ad_personalization"] = v ? 1 : 0 }
        if let s = tcf?.tcString, !s.isEmpty { out["tcf_string"] = s }
        return out
    }

    private struct TCF {
        var gdprApplies: Bool?
        var tcString: String?
        var adUserData: Bool?
        var adPersonalization: Bool?
    }

    private func readTCF(_ d: UserDefaults) -> TCF {
        var applies: Bool?
        switch d.object(forKey: "IABTCF_gdprApplies") {
        case let n as Int: applies = n == 1 ? true : (n == 0 ? false : nil)
        case let s as String: applies = s == "1" ? true : (s == "0" ? false : nil)
        default: break
        }
        // "1010…": character n-1 is purpose n's consent.
        let purposes = Array(d.string(forKey: "IABTCF_PurposeConsents") ?? "")
        func consented(_ ids: Int...) -> Bool? {
            guard !purposes.isEmpty else { return nil }
            return ids.allSatisfy { $0 - 1 < purposes.count && purposes[$0 - 1] == "1" }
        }
        return TCF(gdprApplies: applies,
                   tcString: d.string(forKey: "IABTCF_TCString"),
                   adUserData: consented(1, 7),
                   adPersonalization: consented(3, 4))
    }
}
