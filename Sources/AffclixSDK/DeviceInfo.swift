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
    /// Signs of a jailbreak (sent as is_rooted, for validation rules).
    var isJailbroken = false
    /// Running in the iOS Simulator (sent as is_emulator).
    var isSimulator = false
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
            idfv: idfv,
            isJailbroken: Self.jailbroken,
            isSimulator: Self.simulator
        )
    }

    #if targetEnvironment(simulator)
    static let simulator = true
    #else
    static let simulator = false
    #endif

    /// Worked out once per process: files a jailbreak leaves behind, or a
    /// sandbox that lets the app write outside its container.
    static let jailbroken: Bool = {
        #if os(iOS) && !targetEnvironment(simulator)
        let paths = ["/Applications/Cydia.app", "/Applications/Sileo.app", "/var/jb",
                     "/Library/MobileSubstrate/MobileSubstrate.dylib", "/usr/sbin/sshd",
                     "/bin/bash", "/etc/apt", "/private/var/lib/apt/"]
        if paths.contains(where: { FileManager.default.fileExists(atPath: $0) }) { return true }
        let probe = "/private/affclix_jb_probe.txt"
        if (try? "x".write(toFile: probe, atomically: true, encoding: .utf8)) != nil {
            try? FileManager.default.removeItem(atPath: probe)
            return true
        }
        #endif
        return false
    }()

    /// "iPhone15,2" — the hardware identifier, not the marketing name.
    private func hardwareModel() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
