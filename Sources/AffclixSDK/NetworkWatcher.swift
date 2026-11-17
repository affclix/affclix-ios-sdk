import Foundation
#if canImport(Network)
import Network
#endif

/// Tells the core when the device gets a connection back, so what is queued
/// goes out without waiting for the next launch or return to the foreground.
final class NetworkWatcher {
    #if canImport(Network)
    private var monitor: NWPathMonitor?
    private var wasOnline = true
    #endif

    func start(onReconnect: @escaping () -> Void) {
        #if canImport(Network)
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let online = path.status == .satisfied
            if online && !self.wasOnline { onReconnect() }
            self.wasOnline = online
        }
        monitor.start(queue: DispatchQueue(label: "com.affclix.sdk.network"))
        self.monitor = monitor
        #endif
    }
}
