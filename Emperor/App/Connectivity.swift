import Foundation
import Network

/// The system's word on whether this device has a network path — see `ConnectivityReporting`
/// for why the screens that keep offline copies ask.
///
/// Started at launch (`EmperorApp.makeSession`), so a reading is in by the time anyone opens a
/// conversation, a document or a matter. Until the first one arrives the answer is "not known to
/// be offline", and a conversation still waiting on its request when the reading comes in is told
/// then (`.emperorConnectivityChanged`).
final class NetworkConnectivity: ConnectivityReporting, @unchecked Sendable {
    static let shared = NetworkConnectivity()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.emperorailabs.emperor.connectivity")
    private let lock = NSLock()
    private var offline = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Only `unsatisfied` is offline. A path that needs a connection to be brought up —
            // a VPN on demand — may still work, and "unknown" is never offline.
            self?.update(isOffline: path.status == .unsatisfied)
        }
        monitor.start(queue: queue)
    }

    var isOffline: Bool { lock.withLock { offline } }

    private func update(isOffline value: Bool) {
        let changed = lock.withLock { () -> Bool in
            defer { offline = value }
            return offline != value
        }
        guard changed else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .emperorConnectivityChanged, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted on the main queue when the device gains or loses its network path.
    static let emperorConnectivityChanged = Notification.Name("EmperorConnectivityChanged")
}

/// What the screens are given to ask.
enum AppConnectivity {
    static var current: any ConnectivityReporting {
        #if DEBUG
        // The UI tests' network is the stub, which answers whatever the simulator's own path is.
        // Going by the real path would make a run on a machine with no network behave as
        // offline; `-UITestOffline` drives the offline screens through the stub instead.
        if UITestSupport.isActive { return NeverOffline() }
        #endif
        return NetworkConnectivity.shared
    }

    private struct NeverOffline: ConnectivityReporting {
        var isOffline: Bool { false }
    }
}
