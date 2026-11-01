import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(AdSupport)
import AdSupport
#endif
#if canImport(AdServices)
import AdServices
#endif

/// App Tracking Transparency status, as sent in `att_status`.
public enum TrackingStatus: String {
    case notDetermined = "not_determined"
    case restricted
    case denied
    case authorized
    /// Before iOS 14, or a platform without ATT.
    case unavailable
}

/// ATT status, the IDFA and the Apple Search Ads attribution token.
protocol TrackingProvider {
    var status: TrackingStatus { get }
    /// The IDFA, only when the user allowed tracking (and never the zeroed ID).
    var idfa: String? { get }
    /// Apple Search Ads (AdServices) attribution token, sent with the install.
    func searchAdsToken() -> String?
    func requestAuthorization(_ completion: @escaping (TrackingStatus) -> Void)
}

struct SystemTracking: TrackingProvider {
    var status: TrackingStatus {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            switch ATTrackingManager.trackingAuthorizationStatus {
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            case .denied: return .denied
            case .authorized: return .authorized
            @unknown default: return .unavailable
            }
        }
        #endif
        return .unavailable
    }

    var idfa: String? {
        #if canImport(AdSupport)
        let allowed: Bool
        if #available(iOS 14, *) {
            allowed = status == .authorized
        } else {
            allowed = ASIdentifierManager.shared().isAdvertisingTrackingEnabled
        }
        guard allowed else { return nil }
        let id = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        return id == "00000000-0000-0000-0000-000000000000" ? nil : id
        #else
        return nil
        #endif
    }

    func searchAdsToken() -> String? {
        #if canImport(AdServices)
        if #available(iOS 14.3, *) {
            return try? AAAttribution.attributionToken()
        }
        #endif
        return nil
    }

    func requestAuthorization(_ completion: @escaping (TrackingStatus) -> Void) {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            whenAppIsActive {
                ATTrackingManager.requestTrackingAuthorization { _ in
                    DispatchQueue.main.async { completion(self.status) }
                }
            }
            return
        }
        #endif
        DispatchQueue.main.async { completion(.unavailable) }
    }
}

#if canImport(UIKit) && os(iOS)
/// iOS answers an ATT request made while the app is not active with
/// `notDetermined` and shows no prompt, so a call during launch waits.
private func whenAppIsActive(_ work: @escaping () -> Void) {
    DispatchQueue.main.async {
        guard UIApplication.shared.applicationState != .active else { return work() }
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            if let t = token { NotificationCenter.default.removeObserver(t) }
            token = nil
            work()
        }
    }
}
#else
private func whenAppIsActive(_ work: @escaping () -> Void) { work() }
#endif
