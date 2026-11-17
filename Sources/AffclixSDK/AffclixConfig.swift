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
    /// Host that receives the SDK's requests. Leave the default,
    /// "mmp.affclix.org": every app reports there, whatever domain its links use.
    /// Your Affclix subdomain (acme.affclix.org) and custom tracking domains
    /// (track.yourbrand.com) serve clicks and branded links, not SDK traffic.
    /// Change it only for a staging or self-hosted endpoint.
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
    /// Called once on the main queue when the MMP has attributed the install
    /// (also when the install went out later from the offline queue): how it
    /// was matched — including `probabilistic` and `view_through` — and the
    /// click. Also readable later as `Affclix.attribution`.
    public var onAttribution: ((AttributionResult) -> Void)?

    /// iOS deferred deep links: the click and `deep_link_value` of a branded
    /// link opened before the app was installed, handed over through the
    /// clipboard. Also turn on "iOS deferred deep linking" for the app in the
    /// Affclix dashboard.
    public var deferredDeepLinking: DeferredDeepLinking
    /// Seconds the first install report waits for the deferred deep link
    /// lookup, so the install carries its click. A link resolved later still
    /// reaches `onDeepLink` and later events.
    public var deferredDeepLinkTimeout: TimeInterval
    /// Sends an App Attest attestation with the install: proof to the MMP that
    /// it comes from your genuine app on a genuine iPhone, not a script
    /// replaying SDK calls. Needs iOS 14+ on a real device (the Simulator has
    /// none), the App Attest capability (`com.apple.developer.devicecheck.appattest-environment`
    /// set to `production` in release builds) and the app's Team ID in the
    /// Affclix dashboard. Without support the install goes without it.
    public var appAttest: Bool
    /// Seconds the install waits for its App Attest evidence before going
    /// without it.
    public var integrityTimeout: TimeInterval

    public init(
        appKey: String,
        appSecret: String = "",
        trackingDomain: String = "mmp.affclix.org",
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
        onAttribution: ((AttributionResult) -> Void)? = nil,
        deferredDeepLinking: DeferredDeepLinking = .off,
        deferredDeepLinkTimeout: TimeInterval = 10,
        appAttest: Bool = false,
        integrityTimeout: TimeInterval = 5
    ) {
        self.appAttest = appAttest
        self.integrityTimeout = integrityTimeout
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
        self.onAttribution = onAttribution
        self.deferredDeepLinking = deferredDeepLinking
        self.deferredDeepLinkTimeout = deferredDeepLinkTimeout
    }
}
