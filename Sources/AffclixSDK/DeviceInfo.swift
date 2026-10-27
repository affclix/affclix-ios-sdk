import Foundation
#if canImport(Glibc)
import Glibc
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Device and app attributes sent with every request.
struct DeviceInfo {
    var bundleID: String
    var appVersion: String
    var appBuild: String
    var model: String
    var osVersion: String
    var locale: String
    var timezone: String
    /// Vendor ID: stable per vendor while one of its apps is installed.
    var idfv: String?
}

protocol DeviceInfoProvider {
    func collect() -> DeviceInfo
}

struct SystemDeviceInfo: DeviceInfoProvider {
    func collect() -> DeviceInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        var idfv: String?
        var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #if canImport(UIKit) && !os(watchOS)
        idfv = UIDevice.current.identifierForVendor?.uuidString
        osVersion = UIDevice.current.systemVersion
        #endif
        return DeviceInfo(
            bundleID: Bundle.main.bundleIdentifier ?? "",
            appVersion: info["CFBundleShortVersionString"] as? String ?? "",
            appBuild: info["CFBundleVersion"] as? String ?? "",
            model: hardwareModel(),
            osVersion: osVersion,
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            idfv: idfv
        )
    }

    /// "iPhone15,2" — the hardware identifier, not the marketing name.
    private func hardwareModel() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
