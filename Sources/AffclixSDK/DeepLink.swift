import Foundation

/// A deep link the SDK resolved: a custom-scheme URL or a Universal Link such as
/// a branded link `https://{your Affclix domain}/l/{app}?click_id=…&deep_link_value=…`.
public struct DeepLinkResult {
    public let url: URL
    /// Tracker click ID; kept and sent with later events (re-engagement).
    public let clickID: String?
    /// The advertiser's routing payload (`deep_link_value`, or `deep_link`).
    public let deepLinkValue: String?
    public let utmSource: String?
    public let utmMedium: String?
    public let utmCampaign: String?
    /// Every other query parameter.
    public let parameters: [String: String]
    /// Resolved on first launch from a link copied before the install
    /// (iOS deferred deep linking), not opened directly.
    public let isDeferred: Bool

    /// Query parameter of a copied deferred deep link
    /// (`https://{domain}/l/{app}?afdl=<token>`).
    static let deferredParam = "afdl"

    /// The one-time token of a copied deferred deep link, if `text` is one.
    static func deferredToken(in text: String) -> String? {
        guard let items = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.queryItems,
              let token = items.first(where: { $0.name == deferredParam })?.value, token.count == 22 else { return nil }
        return token
    }

    static func parse(_ url: URL, deferred: Bool = false) -> DeepLinkResult {
        var params: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if let v = item.value, !v.isEmpty, params[item.name] == nil {
                params[item.name] = v
            }
        }
        func take(_ keys: String...) -> String? {
            for k in keys { if let v = params[k] { return v } }
            return nil
        }
        let clickID = take("click_id", "clickid", "affclix_click_id")
        let deepLinkValue = take("deep_link_value", "deep_link")
        let known: Set<String> = ["click_id", "clickid", "affclix_click_id", "deep_link_value", "deep_link",
                                  "utm_source", "utm_medium", "utm_campaign", deferredParam]
        return DeepLinkResult(
            url: url,
            clickID: clickID,
            deepLinkValue: deepLinkValue,
            utmSource: params["utm_source"],
            utmMedium: params["utm_medium"],
            utmCampaign: params["utm_campaign"],
            parameters: params.filter { !known.contains($0.key) },
            isDeferred: deferred
        )
    }
}
