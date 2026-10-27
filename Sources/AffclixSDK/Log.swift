import Foundation

/// Console logging, on only with `AffclixConfig.debugLogging` (errors always).
enum Log {
    static var verbose = false

    static func debug(_ message: @autoclosure () -> String) {
        if verbose { print("[Affclix] \(message())") }
    }

    static func error(_ message: @autoclosure () -> String) {
        print("[Affclix] error: \(message())")
    }
}
