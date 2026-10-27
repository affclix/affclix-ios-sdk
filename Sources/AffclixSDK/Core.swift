import Foundation

/// The SDK's engine. All state is touched on `state`, a serial queue; public
/// calls hop onto it and completions come back on the main queue.
///
/// Installs and events go to the MMP's event endpoint (`POST /m/ev`) as JSON,
/// with the app key and signature in the query string — the same contract as
/// the Android SDK.
final class AffclixCore {
    let config: AffclixConfig
    let state: DispatchQueue

    private let storage: Storage
    private let device: DeviceInfoProvider
    private let tracking: TrackingProvider
    private let skan: ConversionValueUpdating
    private let consent: ConsentReader
    private let pasteboard: PasteboardProvider
    private let sender: RetryingSender
    private let queue: OfflineQueue
    private let now: () -> Date
    /// Delay between checks while the install waits for the ATT answer.
    private let attPollInterval: TimeInterval

    private var draining = false
    /// When the app last went to the background; nil before the first session.
    private var backgroundedAt: Date?
    private var sessionStarted = false
    /// Releases the first install report held for the deferred deep link
    /// lookup; nil when nothing is waiting.
    private var releaseInstall: (() -> Void)?

    init(
        config: AffclixConfig,
        storage: Storage,
        device: DeviceInfoProvider,
        tracking: TrackingProvider,
        skan: ConversionValueUpdating,
        pasteboard: PasteboardProvider,
        tcfDefaults: UserDefaults?,
        transport: Transport,
        queueDirectory: URL,
        retryBaseDelay: TimeInterval = 1,
        attPollInterval: TimeInterval = 0.5,
        now: @escaping () -> Date = Date.init
    ) {
        self.config = config
        self.state = DispatchQueue(label: "com.affclix.sdk")
        self.storage = storage
        self.device = device
        self.tracking = tracking
        self.skan = skan
        self.pasteboard = pasteboard
        self.consent = ConsentReader(storage: storage, tcfDefaults: config.enableTCFDataCollection ? tcfDefaults : nil)
        self.sender = RetryingSender(transport: transport, maxRetries: config.maxRetries, baseDelay: retryBaseDelay, queue: state)
        self.queue = OfflineQueue(directory: queueDirectory)
        self.attPollInterval = attPollInterval
        self.now = now
    }

    // MARK: - Lifecycle

    func start() {
        state.async { [self] in
            if storage.installTimeMs == nil {
                // First open ever.
                storage.installTimeMs = nowMs()
                if config.registerForSKAdNetwork { skan.register() }
            }
            reportInstallIfNeeded()
            startSessionIfNeeded(at: now())
            refreshSKANSchemaIfDue()
            drainQueue()
        }
    }

    /// The app came back to the foreground: a new session after a long
    /// absence, and resend what is queued.
    func didEnterForeground() {
        let at = now() // when it happened, not when the queue gets to it
        state.async { [self] in
            startSessionIfNeeded(at: at)
            drainQueue()
        }
    }

    func didEnterBackground() {
        let at = now()
        state.async { [self] in backgroundedAt = at }
    }

    /// Sends `session_start` for a launch, or a return after `sessionTimeout`.
    private func startSessionIfNeeded(at: Date) {
        guard config.autoSessionTracking else { return }
        if sessionStarted, let bg = backgroundedAt, at.timeIntervalSince(bg) < config.sessionTimeout {
            return
        }
        if sessionStarted && backgroundedAt == nil { return }
        sessionStarted = true
        backgroundedAt = nil
        logEvent("session_start", params: [:], completion: nil)
    }

    // MARK: - Install

    /// Reports the install once. `installReported` is set only when the server
    /// has it or it is in the offline queue; otherwise the next start retries.
    private func reportInstallIfNeeded() {
        guard !storage.installReported else { return }
        let attDeadline = now().addingTimeInterval(config.attWaitTimeout)
        resolveDeferredDeepLinkFirst { [self] in
            waitForTrackingAnswer(deadline: attDeadline, then: sendInstall)
        }
    }

    private func sendInstall() {
        var p = basePayload()
        p["event"] = "install"
        if let token = tracking.searchAdsToken() { p["asa_token"] = token }
        let request = prepare(p)
        sender.send(request) { result in
            self.state.async {
                switch self.outcome(result) {
                case .accepted:
                    self.storage.installReported = true
                    Log.debug("install reported")
                    self.drainQueue()
                case .transient:
                    if self.queue.enqueue(request) { self.storage.installReported = true }
                case .refused(let why):
                    Log.error("install refused: \(why)")
                }
            }
        }
    }

    // MARK: - Deferred deep links

    /// Runs `then` (on `state`) once the first launch's deferred deep link
    /// lookup is over — found, nothing to find, or `deferredDeepLinkTimeout`
    /// passed — so the install carries the link's click ID. Immediately when
    /// deferred deep linking is off or the lookup already ran.
    private func resolveDeferredDeepLinkFirst(then: @escaping () -> Void) {
        guard config.deferredDeepLinking != .off, !storage.deferredChecked else { return then() }
        var released = false
        let release = { [self] in
            guard !released else { return }
            released = true
            releaseInstall = nil
            storage.deferredChecked = true
            then()
        }
        releaseInstall = release
        state.asyncAfter(deadline: .now() + config.deferredDeepLinkTimeout) {
            if !released { Log.debug("deferred deep link lookup timed out") }
            release()
        }
        if config.deferredDeepLinking == .automatic {
            pasteboard.probableLink { text in
                self.state.async { self.lookUpDeferredDeepLink(text, fromPasteboard: true) }
            }
        }
    }

    /// Resolves clipboard text the app read itself (`.manual`), and releases
    /// the install waiting for it. nil: nothing to resolve.
    func resolveDeferredDeepLink(_ text: String?) {
        state.async { [self] in lookUpDeferredDeepLink(text, fromPasteboard: false) }
    }

    /// Asks the MMP (`/m/dl`) for the click behind a copied link, once. A
    /// found link sets the click ID (sent with the install and later events)
    /// and goes to `onDeepLink`; the waiting install is released either way.
    private func lookUpDeferredDeepLink(_ text: String?, fromPasteboard: Bool) {
        guard let text = text, let copied = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              DeepLinkResult.deferredToken(in: text) != nil else {
            releaseInstall?()
            return
        }
        var p = basePayload()
        p["url"] = copied.absoluteString
        sender.send(prepare(p, path: "/m/dl")) { result in
            self.state.async {
                defer { self.releaseInstall?() }
                guard case .accepted = self.outcome(result), case .success(let data) = result,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      obj["found"] as? Bool == true else {
                    Log.debug("no deferred deep link")
                    return
                }
                if fromPasteboard { self.pasteboard.clearIfUnchanged() }
                let link = Self.deferredLinkURL(copied, obj)
                let resolved = DeepLinkResult.parse(link, deferred: true)
                if let click = resolved.clickID { self.storage.clickID = click }
                Log.debug("deferred deep link resolved")
                if let cb = self.config.onDeepLink {
                    DispatchQueue.main.async { cb(resolved) }
                }
            }
        }
    }

    /// The copied link with the MMP's answer in place of its token, so a
    /// deferred link reads like one opened directly.
    static func deferredLinkURL(_ copied: URL, _ answer: [String: Any]) -> URL {
        var c = URLComponents(url: copied, resolvingAgainstBaseURL: false) ?? URLComponents()
        var items = (c.queryItems ?? []).filter { $0.name != DeepLinkResult.deferredParam }
        let fields: [(String, String)] = [("click_id", "click_id"), ("deep_link_value", "deep_link_value"),
                                          ("campaign_id", "c"), ("affiliate_id", "a")]
        for (key, name) in fields {
            switch answer[key] {
            case let v as String where !v.isEmpty: items.append(URLQueryItem(name: name, value: v))
            case let v as NSNumber: items.append(URLQueryItem(name: name, value: v.stringValue))
            default: break
            }
        }
        c.queryItems = items.isEmpty ? nil : items
        return c.url ?? copied
    }

    /// Runs `then` on `state` once the user answered the ATT prompt (so the
    /// install can carry the IDFA) or `deadline` passed.
    private func waitForTrackingAnswer(deadline: Date, then: @escaping () -> Void) {
        guard tracking.status == .notDetermined, now() < deadline else {
            then()
            return
        }
        state.asyncAfter(deadline: .now() + attPollInterval) { [self] in
            waitForTrackingAnswer(deadline: deadline, then: then)
        }
    }

    // MARK: - Events

    /// Sends an event; completion gets the event_id, on the main queue.
    func logEvent(_ name: String, params: [String: Any], completion: ((Result<String, Error>) -> Void)?) {
        state.async { [self] in
            let eventID = UUID().uuidString.lowercased()
            var p = basePayload()
            p["event"] = name
            // Idempotency key: the MMP records and reports an event once per
            // event_id, so retries and offline replays are not counted twice.
            p["event_id"] = eventID
            p["ts"] = nowMs()
            for (k, v) in params { p[k] = jsonValue(v) }
            trackConversionValue(name, params: params)
            let request = prepare(p)
            sender.send(request) { result in
                self.state.async {
                    let out = self.outcome(result)
                    if case .transient = out { self.queue.enqueue(request) }
                    if case .accepted = out { self.drainQueue() }
                    guard let completion = completion else { return }
                    DispatchQueue.main.async {
                        switch out {
                        case .accepted: completion(.success(eventID))
                        case .transient(let why): completion(.failure(AffclixError.queued(why)))
                        case .refused(let why): completion(.failure(AffclixError.refused(why)))
                        }
                    }
                }
            }
        }
    }

    // MARK: - SKAdNetwork conversion values

    /// How often the schema is asked for again.
    static let skanSchemaRefresh: TimeInterval = 24 * 3600

    /// Within the measurement window, fetches the dashboard's conversion-value
    /// schema when it was last asked for over a day ago (or never), then applies
    /// it to what the user did so far. Not queued offline: the next launch asks.
    private func refreshSKANSchemaIfDue() {
        guard config.automaticConversionValues, inSKANWindow() else { return }
        if let at = storage.skanSchemaFetchedAt, now().timeIntervalSince1970 - at < Self.skanSchemaRefresh { return }
        storage.skanSchemaFetchedAt = now().timeIntervalSince1970
        var p: [String: Any] = ["platform": "ios", "app_id": device.collect().bundleID]
        if !config.appKey.isEmpty { p["ak"] = config.appKey }
        sender.send(prepare(p, path: "/m/skan-schema")) { result in
            self.state.async {
                guard case .accepted = self.outcome(result), case .success(let data) = result,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                let schema = (obj["schema"] as? [String: Any]).flatMap {
                    (try? JSONSerialization.data(withJSONObject: $0)).flatMap { try? JSONDecoder().decode(SKANSchema.self, from: $0) }
                }
                self.storage.skanSchema = schema
                if let schema = schema { self.applySKAN(schema) }
            }
        }
    }

    /// Records an in-app event toward the schema and raises the conversion
    /// value when it earns a higher one.
    private func trackConversionValue(_ name: String, params: [String: Any]) {
        guard config.automaticConversionValues, inSKANWindow(), let schema = storage.skanSchema else { return }
        var progress = storage.skanProgress
        SKANConversion.record(name, params: params, schema: schema, into: &progress)
        storage.skanProgress = progress
        applySKAN(schema)
    }

    private func applySKAN(_ schema: SKANSchema) {
        var progress = storage.skanProgress
        guard let update = SKANConversion.nextUpdate(schema, &progress) else { return }
        storage.skanProgress = progress
        skan.update(fine: update.fine, coarse: update.coarse, lockWindow: false) { error in
            if let error = error { Log.error("conversion value update failed: \(error)") }
        }
        Log.debug("conversion value \(update.fine) coarse \(String(describing: update.coarse))")
    }

    private func inSKANWindow() -> Bool {
        guard let installed = storage.installTimeMs else { return false }
        return now().timeIntervalSince1970 - Double(installed) / 1000 < SKANConversion.measurementWindow
    }

    // MARK: - Uninstall tracking

    /// Registers the APNs device token (hex) with the MMP (`POST /m/token`),
    /// once per token: the MMP sends a daily silent push and records an
    /// uninstall when APNs reports the token gone.
    func setPushToken(_ hex: String, sandbox: Bool) {
        state.async { [self] in
            let marker = "\(hex)|\(sandbox)"
            guard storage.pushToken != marker else { return }
            var p = basePayload()
            p["push_token"] = hex
            p["push_sandbox"] = sandbox ? 1 : 0
            let request = prepare(p, path: "/m/token")
            sender.send(request) { result in
                self.state.async {
                    switch self.outcome(result) {
                    case .accepted:
                        self.storage.pushToken = marker
                        Log.debug("push token registered")
                    case .transient:
                        if self.queue.enqueue(request) { self.storage.pushToken = marker }
                    case .refused(let why):
                        Log.error("push token refused: \(why)")
                    }
                }
            }
        }
    }

    // MARK: - Erasure

    /// Right to erasure: asks the MMP (`POST /m/forget`) to delete everything
    /// it holds for this device, then forgets the identifiers locally. Queued
    /// when there is no connection. Completion gets the MMP's request ID, or
    /// "queued".
    func requestDataDeletion(completion: ((Result<String, Error>) -> Void)?) {
        state.async { [self] in
            let d = device.collect()
            var p: [String: Any] = ["platform": "ios", "app_id": d.bundleID, "vid": storage.visitorID]
            if !config.appKey.isEmpty { p["ak"] = config.appKey }
            if let v = d.idfv { p["idfv"] = v }
            if let v = tracking.idfa { p["idfa"] = v }
            let request = prepare(p, path: "/m/forget")
            sender.send(request) { result in
                self.state.async {
                    var answer: Result<String, Error>
                    switch self.outcome(result) {
                    case .accepted:
                        let id = (try? result.get()).flatMap {
                            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
                        }?["request_id"] as? String ?? ""
                        self.storage.clearIdentifiers()
                        answer = .success(id)
                    case .transient(let why):
                        if self.queue.enqueue(request) {
                            self.storage.clearIdentifiers()
                            answer = .success("queued")
                        } else {
                            answer = .failure(AffclixError.queued(why))
                        }
                    case .refused(let why):
                        answer = .failure(AffclixError.refused(why))
                    }
                    if let completion = completion {
                        DispatchQueue.main.async { completion(answer) }
                    }
                }
            }
        }
    }

    // MARK: - Identity, consent, deep links

    func setUserID(_ id: String?) {
        state.async { [self] in storage.userID = id }
    }

    func setConsent(_ c: ConsentData) {
        state.async { [self] in storage.consent = c }
    }

    func handleDeepLink(_ url: URL) -> DeepLinkResult {
        let result = DeepLinkResult.parse(url)
        // A copied deferred link opened as a Universal Link (app installed
        // meanwhile): its click comes from the MMP, then to onDeepLink.
        if result.clickID == nil, DeepLinkResult.deferredToken(in: url.absoluteString) != nil {
            resolveDeferredDeepLink(url.absoluteString)
            return result
        }
        state.async { [self] in
            if let click = result.clickID { storage.clickID = click }
        }
        var params: [String: Any] = ["deep_link_url": url.absoluteString]
        if let v = result.deepLinkValue { params["deep_link_value"] = v }
        if let v = result.utmSource { params["utm_source"] = v }
        if let v = result.utmCampaign { params["utm_campaign"] = v }
        // Carries the click ID (set above, same queue) for re-engagement.
        logEvent("deep_link", params: params, completion: nil)
        if let cb = config.onDeepLink {
            DispatchQueue.main.async { cb(result) }
        }
        return result
    }

    // MARK: - Payload and requests

    /// Fields every request carries.
    private func basePayload() -> [String: Any] {
        let d = device.collect()
        var p: [String: Any] = [
            "platform": "ios",
            "os": "ios",
            "sdk_version": Affclix.sdkVersion,
            "app_id": d.bundleID,
            "app_version": d.appVersion,
            "app_build": d.appBuild,
            "device_model": d.model,
            "os_version": d.osVersion,
            "lang": d.locale,
            "tz": d.timezone,
            "vid": storage.visitorID,
            "att_status": tracking.status.rawValue,
        ]
        if !config.appKey.isEmpty { p["ak"] = config.appKey }
        if let v = d.idfv { p["idfv"] = v }
        if let v = tracking.idfa { p["idfa"] = v }
        if let v = storage.installTimeMs { p["install_time"] = v }
        if let v = storage.clickID { p["click_id"] = v }
        if let v = storage.userID { p["customer_user_id"] = v }
        p.merge(consent.payload()) { _, new in new }
        return p
    }

    /// A POST to the MMP (event endpoint by default): JSON body, `ak` and
    /// `sig` in the URL.
    func prepare(_ payload: [String: Any], path: String = "/m/ev") -> PreparedRequest {
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        var c = URLComponents()
        c.scheme = isLocal(config.trackingDomain) ? "http" : "https"
        let hostPort = config.trackingDomain.split(separator: ":", maxSplits: 1).map(String.init)
        c.host = hostPort.first
        if hostPort.count == 2 { c.port = Int(hostPort[1]) }
        c.path = path
        var items: [URLQueryItem] = []
        if !config.appKey.isEmpty { items.append(URLQueryItem(name: "ak", value: config.appKey)) }
        if !config.appSecret.isEmpty {
            items.append(URLQueryItem(name: "sig", value: RequestSigner.sign(secret: config.appSecret, message: body)))
        }
        c.queryItems = items.isEmpty ? nil : items
        return PreparedRequest(url: c.url!, body: body)
    }

    private enum Outcome {
        case accepted
        case transient(String)
        case refused(String)
    }

    /// The MMP answers 200 for every decision; `{"success":false,"code":…}`
    /// is a refusal (bad app key, signature, …) that retrying will not fix.
    private func outcome(_ result: Result<Data, DeliveryError>) -> Outcome {
        switch result {
        case .failure(.transient(let why)):
            return .transient(why)
        case .failure(.rejected(let code)):
            return .refused("HTTP \(code)")
        case .success(let data):
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               obj["success"] as? Bool == false {
                return .refused(obj["code"] as? String ?? "refused")
            }
            return .accepted
        }
    }

    // MARK: - Offline queue

    /// Resends queued requests in order, one at a time, until one fails
    /// transiently (the connection is still down) or the queue is empty.
    private func drainQueue() {
        guard !draining, let entry = queue.entries.first else { return }
        draining = true
        sender.send(entry.request) { result in
            self.state.async {
                self.draining = false
                switch self.outcome(result) {
                case .accepted, .refused:
                    self.queue.remove(entry.id)
                    self.drainQueue()
                case .transient:
                    self.queue.markFailed(entry.id)
                }
            }
        }
    }

    // MARK: - Helpers

    private func nowMs() -> Int64 {
        Int64(now().timeIntervalSince1970 * 1000)
    }

    private func isLocal(_ host: String) -> Bool {
        ["localhost", "127.", "10.", "192.168."].contains { host.hasPrefix($0) }
    }

    /// Event parameter values as JSON: strings, numbers and booleans as they
    /// are, anything else as its description.
    private func jsonValue(_ v: Any) -> Any {
        switch v {
        case is String, is Bool, is Int, is Int64, is Double, is Float, is NSNumber: return v
        default: return String(describing: v)
        }
    }
}

/// Why `logEvent`'s completion failed.
public enum AffclixError: Error {
    /// Not delivered now (no connection, server busy); queued and resent later.
    case queued(String)
    /// The server refused it (e.g. INVALID_APP_KEY, INVALID_SIGNATURE).
    case refused(String)
    /// `Affclix.start` was not called.
    case notStarted
}
