import Foundation

/// How the MMP attributed this install, as it answered the install report.
/// Delivered once to `AffclixConfig.onAttribution` and kept in
/// `Affclix.attribution`.
public struct AttributionResult: Codable, Equatable {
    /// The install was credited to a click or view (not organic, not blocked).
    public let isAttributed: Bool
    /// How it was matched: `click_id` (deep link or deferred link),
    /// `device_id` (IDFA / IDFV on a click), `probabilistic` (same IP address
    /// and platform shortly after a click, when the app turns it on),
    /// `view_through`, `ad_network`, `apple_search_ads`, or `organic`.
    /// Matching methods the SDK does not know yet arrive as the MMP names them.
    public let method: String
    /// The tracker click it was credited to; nil when not attributed.
    public let clickID: String?

    /// Reads the MMP's answer to an install (`/m/ev`); nil when it is not one.
    static func parse(_ data: Data) -> AttributionResult? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["success"] as? Bool == true else { return nil }
        let method = (obj["attribution"] as? [String: Any])?["method"] as? String
        let click = (obj["click_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let attributed = obj["attributed"] as? Bool ?? (click != nil)
        return AttributionResult(isAttributed: attributed,
                                 method: (method?.isEmpty == false ? method! : (attributed ? "click_id" : "organic")),
                                 clickID: click)
    }
}
