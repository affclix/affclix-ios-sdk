import Foundation
@testable import AffclixSDK

/// Records requests and answers them from `respond`.
final class MockTransport: Transport {
    private let lock = NSLock()
    private var _requests: [PreparedRequest] = []
    var respond: (PreparedRequest) -> Result<Data, DeliveryError> = { _ in .success(Data(#"{"success":true}"#.utf8)) }

    var requests: [PreparedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func post(_ request: PreparedRequest, completion: @escaping (Result<Data, DeliveryError>) -> Void) {
        lock.lock()
        _requests.append(request)
        let r = respond
        lock.unlock()
        completion(r(request))
    }
}

struct FakeDevice: DeviceInfoProvider {
    func collect() -> DeviceInfo {
        DeviceInfo(bundleID: "com.game.ios", appVersion: "1.2", appBuild: "34", model: "iPhone15,2",
                   osVersion: "17.5", locale: "en_US", timezone: "UTC", idfv: "IDFV-1")
    }
}

final class FakeTracking: TrackingProvider {
    var status: TrackingStatus = .unavailable
    var idfa: String? { status == .authorized ? "IDFA-1" : nil }
    func searchAdsToken() -> String? { "ASA-TOKEN" }
    func requestAuthorization(_ completion: @escaping (TrackingStatus) -> Void) { completion(status) }
}

final class FakePasteboard: PasteboardProvider {
    var text: String?
    var cleared = false
    func probableLink(_ completion: @escaping (String?) -> Void) { completion(text) }
    func clearIfUnchanged() { cleared = true }
}

final class FakeSKAN: ConversionValueUpdating {
    var updates: [Int] = []
    var coarse: [CoarseConversionValue?] = []
    func update(fine: Int, coarse: CoarseConversionValue?, lockWindow: Bool, completion: ((Error?) -> Void)?) {
        updates.append(fine)
        self.coarse.append(coarse)
        completion?(nil)
    }
}

/// A fresh UserDefaults suite and queue directory per test.
struct Sandbox {
    let defaults: UserDefaults
    let directory: URL

    init() {
        let name = "affclix-test-" + UUID().uuidString
        defaults = UserDefaults(suiteName: name)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }

    func core(_ transport: Transport, tracking: TrackingProvider = FakeTracking(), skan: ConversionValueUpdating = FakeSKAN(),
              pasteboard: PasteboardProvider = FakePasteboard(),
              config: AffclixConfig = Sandbox.config(), tcf: UserDefaults? = nil,
              now: @escaping () -> Date = Date.init) -> AffclixCore {
        AffclixCore(config: config, storage: Storage(defaults: defaults), device: FakeDevice(), tracking: tracking,
                    skan: skan, pasteboard: pasteboard, tcfDefaults: tcf, transport: transport, queueDirectory: directory,
                    retryBaseDelay: 0.001, attPollInterval: 0.01, now: now)
    }

    /// `skan`: automatic conversion values (and so the schema request) on.
    static func config(attWait: TimeInterval = 0, maxRetries: Int = 1, tcf: Bool = false, sessions: Bool = false,
                       skan: Bool = false) -> AffclixConfig {
        AffclixConfig(appKey: "KEY-1", appSecret: "s3cret", trackingDomain: "acme.affclix.org",
                      attWaitTimeout: attWait, enableTCFDataCollection: tcf, automaticConversionValues: skan,
                      autoSessionTracking: sessions, maxRetries: maxRetries)
    }
}

/// Waits until the core's queue has run everything scheduled so far, including
/// short retry / poll delays.
func settle(_ core: AffclixCore, _ seconds: TimeInterval = 0.2) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        core.state.sync {}
        Thread.sleep(forTimeInterval: 0.01)
    }
    core.state.sync {}
}

func json(_ r: PreparedRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
}

func query(_ r: PreparedRequest, _ name: String) -> String? {
    URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}
