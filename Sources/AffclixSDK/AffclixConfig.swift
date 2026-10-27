import Foundation

/// SDK configuration. Pass to `Affclix.start(_:)` once, from
/// `application(_:didFinishLaunchingWithOptions:)`.
public struct AffclixConfig {
    /// App key from the Affclix dashboard (`ak=`). Required: the MMP resolves the
    /// tenant and app from it.
    public var appKey: String
    /// SDK signing secret from the Affclix dashboard. When set, every request
    /// carries `sig=` (hex HMAC-SHA256 of the JSON body under this secret). Keep it
    /// out of source control; like any secret shipped in an app it raises the bar
    /// rather than making extraction impossible.
    public var appSecret: String
    /// Host of your Affclix domain, e.g. "acme.affclix.org" or "go.yourbrand.com".
    public var trackingDomain: String

    /// Seconds the install report waits for the App Tracking Transparency answer
    /// while the user has not been asked yet, so the install can carry the IDFA.
    /// Call `Affclix.requestTrackingAuthorization` during that time. 0: don't wait.
    public var attWaitTimeout: TimeInterval
    /// Read the IAB TCF v2 consent your CMP stores (`IABTCF_*` in
    /// `UserDefaults.standard`) and send it as gdpr_applies / ad_user_data /
    /// ad_personalization / tcf_string. Values set with `Affclix.setConsentData`
    /// take precedence.
    public var enableTCFDataCollection: Bool
    /// Register the app for SKAdNetwork attribution on first launch (conversion
    /// value 0).
    public var registerForSKAdNetwork: Bool
    /// Set SKAdNetwork conversion values from the schema configured in the
    /// Affclix dashboard (fetched at most daily). Turn off if the app calls
    /// `Affclix.updateConversionValue` itself; the two would compete.
    public var automaticConversionValues: Bool

    /// Send a `session_start` event when a session begins — a launch, or a
    /// return to the foreground after `sessionTimeout` — which the MMP's DAU and
    /// retention reports count.
    public var autoSessionTracking: Bool
    public var sessionTimeout: TimeInterval

    public var requestTimeout: TimeInterval
    /// Retries of a request that failed for a transient reason (no connection,
    /// 429, 5xx) before it goes to the offline queue.
    public var maxRetries: Int
    public var debugLogging: Bool

    /// Called on the main queue for every deep link `handleDeepLink` /
    /// `continueUserActivity` resolves, and for a deferred deep link
    /// (`isDeferred` true) resolved on first launch.
    public var onDeepLink: ((DeepLinkResult) -> Void)?

    /// iOS deferred deep links: the click and `deep_link_value` of a branded
    /// link opened before the app was installed, handed over through the
    /// clipboard. Also turn on "iOS deferred deep linking" for the app in the
    /// Affclix dashboard.
    public var deferredDeepLinking: DeferredDeepLinking
    /// Seconds the first install report waits for the deferred deep link
    /// lookup, so the install carries its click. A link resolved later still
    /// reaches `onDeepLink` and later events.
    public var deferredDeepLinkTimeout: TimeInterval

    public init(
        appKey: String,
        appSecret: String = "",
        trackingDomain: String,
        attWaitTimeout: TimeInterval = 0,
        enableTCFDataCollection: Bool = false,
        registerForSKAdNetwork: Bool = true,
        automaticConversionValues: Bool = true,
        autoSessionTracking: Bool = true,
        sessionTimeout: TimeInterval = 30 * 60,
        requestTimeout: TimeInterval = 10,
        maxRetries: Int = 3,
        debugLogging: Bool = false,
        onDeepLink: ((DeepLinkResult) -> Void)? = nil,
        deferredDeepLinking: DeferredDeepLinking = .off,
        deferredDeepLinkTimeout: TimeInterval = 10
    ) {
        self.appKey = appKey
        self.appSecret = appSecret
        self.trackingDomain = trackingDomain
        self.attWaitTimeout = attWaitTimeout
        self.enableTCFDataCollection = enableTCFDataCollection
        self.registerForSKAdNetwork = registerForSKAdNetwork
        self.automaticConversionValues = automaticConversionValues
        self.autoSessionTracking = autoSessionTracking
        self.sessionTimeout = sessionTimeout
        self.requestTimeout = requestTimeout
        self.maxRetries = maxRetries
        self.debugLogging = debugLogging
        self.onDeepLink = onDeepLink
        self.deferredDeepLinking = deferredDeepLinking
        self.deferredDeepLinkTimeout = deferredDeepLinkTimeout
    }
}
