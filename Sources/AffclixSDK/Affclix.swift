import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Affclix iOS SDK — install and in-app event attribution through the Affclix MMP.
///
/// ```swift
/// Affclix.start(AffclixConfig(appKey: "…", appSecret: "…", trackingDomain: "acme.affclix.org"))
/// Affclix.logEvent("level_complete", params: ["level": 3])
/// Affclix.logPurchase(revenue: 4.99, currency: "USD", transactionID: txn.id, eventToken: "purchase")
/// ```
///
/// All methods are safe to call from any thread; completions run on the main queue.
public enum Affclix {
    public static let sdkVersion = "0.2.0"

    private static let lock = NSLock()
    private static var core: AffclixCore?
    private static var foregroundObserver: NSObjectProtocol?
    private static var backgroundObserver: NSObjectProtocol?

    /// Starts the SDK: reports the install on first launch (once delivered or
    /// queued), registers for SKAdNetwork, and resends queued requests. Call once.
    public static func start(_ config: AffclixConfig) {
        lock.lock()
        defer { lock.unlock() }
        guard core == nil else {
            Log.debug("already started")
            return
        }
        Log.verbose = config.debugLogging
        if config.appKey.isEmpty {
            Log.error("appKey is empty: the MMP rejects requests without one")
        }
        let c = AffclixCore(
            config: config,
            storage: Storage(defaults: UserDefaults(suiteName: "com.affclix.sdk") ?? .standard),
            device: SystemDeviceInfo(),
            tracking: SystemTracking(),
            skan: SystemSKAdNetwork(),
            pasteboard: SystemPasteboard(),
            tcfDefaults: .standard,
            transport: URLSessionTransport(timeout: config.requestTimeout),
            queueDirectory: OfflineQueue.defaultDirectory()
        )
        core = c
        #if canImport(UIKit) && !os(watchOS)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { _ in c.didEnterForeground() }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in c.didEnterBackground() }
        #endif
        c.start()
    }

    private static func running() -> AffclixCore? {
        lock.lock()
        defer { lock.unlock() }
        if core == nil { Log.error("Affclix.start was not called") }
        return core
    }

    // MARK: - Events

    /// Logs an in-app event. To have the MMP report it to the tracker (pay the
    /// affiliate), pass the tracker's event token as `"e"` in `params`. Values
    /// should be strings, numbers or booleans. Completion gets the event_id.
    public static func logEvent(_ name: String, params: [String: Any] = [:],
                                completion: ((Result<String, Error>) -> Void)? = nil) {
        guard let c = running() else {
            DispatchQueue.main.async { completion?(.failure(AffclixError.notStarted)) }
            return
        }
        c.logEvent(name, params: params, completion: completion)
    }

    /// Logs a purchase. `transactionID` (e.g. the StoreKit transaction ID) makes a
    /// resent purchase a duplicate; `eventToken` is the tracker event token (`e=`).
    public static func logPurchase(revenue: Double, currency: String, transactionID: String,
                                   eventToken: String? = nil, params: [String: Any] = [:],
                                   completion: ((Result<String, Error>) -> Void)? = nil) {
        var p = params
        p["revenue"] = revenue
        p["currency"] = currency
        p["txid"] = transactionID
        if let token = eventToken { p["e"] = token }
        logEvent("purchase", params: p, completion: completion)
    }

    /// Logs an App Store purchase for server-side validation: the MMP fetches the
    /// transaction from the App Store Server API (when the app's In-App Purchase key
    /// is set in the dashboard) before the revenue counts or the purchase is
    /// reported, and uses Apple's price; renewals and refunds then arrive from App
    /// Store Server Notifications. Pass the StoreKit 2 `Transaction.id`.
    public static func logAppStorePurchase(transactionID: UInt64, productID: String, revenue: Double, currency: String,
                                           isSubscription: Bool = false, eventToken: String? = nil,
                                           params: [String: Any] = [:],
                                           completion: ((Result<String, Error>) -> Void)? = nil) {
        var p = params
        p["revenue"] = revenue
        p["currency"] = currency
        p["iap_transaction_id"] = String(transactionID)
        p["iap_product_id"] = productID
        p["iap_subscription"] = isSubscription ? 1 : 0
        p["txid"] = String(transactionID)
        if let token = eventToken { p["e"] = token }
        logEvent("purchase", params: p, completion: completion)
    }

    /// Logs impression-level ad revenue (e.g. AppLovin MAX, ironSource, AdMob paid
    /// events), reported separately from purchase revenue.
    public static func logAdRevenue(network: String, revenue: Double, currency: String = "USD",
                                    adUnit: String? = nil, adFormat: String? = nil, placement: String? = nil,
                                    params: [String: Any] = [:]) {
        var p = params
        p["revenue"] = revenue
        p["currency"] = currency
        p["ad_network"] = network
        if let v = adUnit { p["ad_unit"] = v }
        if let v = adFormat { p["ad_format"] = v }
        if let v = placement { p["placement"] = v }
        logEvent("ad_revenue", params: p)
    }

    // MARK: - Identity and consent

    /// Your own user ID, sent with every later request (nil clears it).
    public static func setUserId(_ id: String?) {
        running()?.setUserID(id)
    }

    /// Google consent mode (EU DMA), sent with every request; nil = unknown. Under
    /// GDPR, `hasConsentForDataUsage: false` makes the MMP skip device-ID matching
    /// and keep the IP out of the advertiser postback.
    public static func setConsentData(isUserSubjectToGDPR: Bool?,
                                      hasConsentForDataUsage: Bool?,
                                      hasConsentForAdsPersonalization: Bool?) {
        running()?.setConsent(ConsentData(gdprApplies: isUserSubjectToGDPR,
                                          adUserData: hasConsentForDataUsage,
                                          adPersonalization: hasConsentForAdsPersonalization))
    }

    // MARK: - Uninstall tracking

    /// Registers the APNs device token for uninstall tracking: the MMP sends the
    /// app a daily silent (content-available) push and records an uninstall when
    /// APNs reports the token unregistered. Call from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`; pass
    /// `sandbox: true` for development builds (APNs sandbox environment). The app
    /// needs the Push Notifications capability and Background Modes → Remote
    /// notifications; its APNs auth key goes in the Affclix dashboard.
    public static func setPushToken(_ deviceToken: Data, sandbox: Bool = false) {
        running()?.setPushToken(deviceToken.map { String(format: "%02x", $0) }.joined(), sandbox: sandbox)
    }

    /// True for the MMP's silent uninstall-check push: in
    /// `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`, call
    /// the completion handler with `.noData` and return.
    public static func isUninstallCheck(_ userInfo: [AnyHashable: Any]) -> Bool {
        switch userInfo["affclix_uninstall_check"] {
        case let n as NSNumber: return n.intValue == 1
        case let s as String: return s == "1"
        default: return false
        }
    }

    // MARK: - Erasure

    /// Right to erasure (GDPR / CCPA): asks the MMP to delete everything it holds
    /// for this device (visitor ID, IDFV, IDFA), then forgets the identifiers on the
    /// device; the install state is kept. Queued without a connection. Completion
    /// gets the MMP's request ID, or "queued".
    public static func requestDataDeletion(completion: ((Result<String, Error>) -> Void)? = nil) {
        guard let c = running() else {
            DispatchQueue.main.async { completion?(.failure(AffclixError.notStarted)) }
            return
        }
        c.requestDataDeletion(completion: completion)
    }

    // MARK: - App Tracking Transparency

    /// Shows the ATT prompt (iOS 14+; needs `NSUserTrackingUsageDescription` in
    /// Info.plist, and the app must be active). With `attWaitTimeout` set, the
    /// install waits for this answer so it can carry the IDFA.
    public static func requestTrackingAuthorization(completion: @escaping (TrackingStatus) -> Void) {
        SystemTracking().requestAuthorization(completion)
    }

    public static var trackingStatus: TrackingStatus { SystemTracking().status }

    // MARK: - SKAdNetwork

    /// Updates the SKAdNetwork conversion value (fine 0–63; coarse and lockWindow
    /// on iOS 16.1+). Map your funnel to values in your SKAdNetwork schema.
    public static func updateConversionValue(_ fine: Int, coarse: CoarseConversionValue? = nil,
                                             lockWindow: Bool = false,
                                             completion: ((Error?) -> Void)? = nil) {
        SystemSKAdNetwork().update(fine: fine, coarse: coarse, lockWindow: lockWindow) { error in
            DispatchQueue.main.async { completion?(error) }
        }
    }

    // MARK: - Deep links

    /// Resolves a deep link (custom scheme or Universal Link): keeps its click ID
    /// for later events, logs a `deep_link` event, and calls
    /// `AffclixConfig.onDeepLink`. Call from `application(_:open:options:)` /
    /// `scene(_:openURLContexts:)`.
    @discardableResult
    public static func handleDeepLink(_ url: URL) -> DeepLinkResult? {
        running()?.handleDeepLink(url)
    }

    /// iOS deferred deep linking with `DeferredDeepLinking.manual`: pass the
    /// text your `UIPasteControl` (or onboarding paste button) received, or nil
    /// when the user skipped it — either releases the first install report. A
    /// resolved link goes to `AffclixConfig.onDeepLink` with `isDeferred` true.
    public static func resolveDeferredDeepLink(_ pastedText: String?) {
        running()?.resolveDeferredDeepLink(pastedText)
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Universal Links: call from `application(_:continue:restorationHandler:)` /
    /// `scene(_:continue:)`. True when the activity was a web link it resolved.
    @discardableResult
    public static func continueUserActivity(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL else {
            return false
        }
        return handleDeepLink(url) != nil
    }
    #endif
}
