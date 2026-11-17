import Foundation

/// One ad impression's revenue, from the mediation SDK's paid-event callback.
/// Pass it to `Affclix.logAdRevenue(_:)`; the MMP keeps it with the device's
/// attribution, so ad revenue reports per campaign.
///
/// | Field | AppLovin MAX (`MAAd`) | LevelPlay (`ImpressionData`) | AdMob (`GADAdValue` + response info) |
/// |---|---|---|---|
/// | mediation | `"applovin_max"` | `"levelplay"` | `"admob"` |
/// | revenue | `revenue` | `revenue` | `value` |
/// | currency | `"USD"` | `"USD"` | `currencyCode` |
/// | network | `networkName` | `adNetwork` | `loadedAdNetworkResponseInfo.adSourceName` |
/// | adUnitID | `adUnitIdentifier` | `mediationAdUnitId` | the ad unit ID |
/// | adFormat | `format.label` | `adFormat` | the format you loaded |
/// | placement | `placement` | `placement` | — |
/// | precision | `revenuePrecision` | `precision` | `precision` (0–3) |
public struct AdRevenue {
    public var mediation: String
    public var revenue: Double
    public var currency: String
    public var network: String?
    public var adUnitID: String?
    public var adUnitName: String?
    public var adFormat: String?
    public var placement: String?
    /// exact, estimated, publisher_defined or undefined (AdMob's 3, 2, 1, 0 are read too).
    public var precision: String?
    /// Impressions this revenue covers; 1 for a paid-event callback.
    public var impressions: Int

    public init(mediation: String, revenue: Double, currency: String = "USD", network: String? = nil,
                adUnitID: String? = nil, adUnitName: String? = nil, adFormat: String? = nil,
                placement: String? = nil, precision: String? = nil, impressions: Int = 1) {
        self.mediation = mediation
        self.revenue = revenue
        self.currency = currency
        self.network = network
        self.adUnitID = adUnitID
        self.adUnitName = adUnitName
        self.adFormat = adFormat
        self.placement = placement
        self.precision = precision
        self.impressions = impressions
    }

    /// The `/m/ev` parameters of an `ad_revenue` event.
    var params: [String: Any] {
        var p: [String: Any] = ["revenue": revenue, "currency": currency, "ad_mediation": mediation]
        if let v = network { p["ad_network"] = v }
        if let v = adUnitID { p["ad_unit_id"] = v }
        if let v = adUnitName { p["ad_unit_name"] = v }
        if let v = adFormat { p["ad_format"] = v }
        if let v = placement { p["ad_placement"] = v }
        if let v = precision { p["revenue_precision"] = v }
        if impressions != 1 { p["ad_impressions"] = impressions }
        return p
    }
}
