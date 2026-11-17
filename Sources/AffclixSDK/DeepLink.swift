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
    /// `af_web_id`: the web analytics visitor who tapped the link.
    public let webVisitorID: String?

    /// Query parameter of a copied deferred deep link
    /// (`https://{domain}/l/{app}?afdl=<token>`).
    static let deferredParam = "afdl"

    /// The one-time token of a copied deferred deep link, if `text` is one.
    static func deferredToken(in text: String) -> String? {
        guard let items = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.queryItems,
              let token = items.first(where: { $0.name == deferredParam })?.value, token.count == 22 else { return nil }
        return token
    }

    /// A short link code (the MMP's short code format); a bundle ID has dots.
    private static let shortCode = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9_-]{2,63}$")

    /// Parameters that make a link complete: no lookup needed.
    private static let linkParams: Set<String> = ["click_id", "clickid", "affclix_click_id", "deep_link_value", "deep_link", deferredParam]

    /// A short link, `https://{domain}/l/{code}`, whose parameters the MMP
    /// keeps: a code in place of the bundle ID, and none of the link's own.
    static func isShortLink(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https" || c.scheme == "http" else { return false }
        let parts = c.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "l" else { return false }
        let code = String(parts[1])
        guard shortCode.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil else { return false }
        return !(c.queryItems ?? []).contains { linkParams.contains($0.name) }
    }

    /// `url` with each of `params` it does not already have (the URL's own win).
    static func adding(_ params: [String: Any], to url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = c.queryItems ?? []
        let have = Set(items.map(\.name))
        for key in params.keys.sorted() where !have.contains(key) {
            switch params[key] {
            case let v as String where !v.isEmpty: items.append(URLQueryItem(name: key, value: v))
            case let v as NSNumber: items.append(URLQueryItem(name: key, value: v.stringValue))
            default: break
            }
        }
        c.queryItems = items.isEmpty ? nil : items
        return c.url ?? url
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
        let webVisitorID = take("af_web_id").map { String($0.trimmingCharacters(in: .whitespaces).prefix(128)) }
            .flatMap { $0.isEmpty || $0.hasPrefix("{") ? nil : $0 }
        let known: Set<String> = ["click_id", "clickid", "affclix_click_id", "deep_link_value", "deep_link", "af_web_id",
                                  "utm_source", "utm_medium", "utm_campaign", deferredParam]
        return DeepLinkResult(
            url: url,
            clickID: clickID,
            deepLinkValue: deepLinkValue,
            utmSource: params["utm_source"],
            utmMedium: params["utm_medium"],
            utmCampaign: params["utm_campaign"],
            parameters: params.filter { !known.contains($0.key) },
            isDeferred: deferred,
            webVisitorID: webVisitorID
        )
    }
}
