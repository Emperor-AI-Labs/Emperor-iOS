import SwiftUI
import UIKit

/// Exists for two callbacks: launching, where notifications register what must be in place
/// before launch finishes (`AppNotifications.registerAtLaunch`), and background uploads.
///
/// When a background upload finishes while the app is suspended or dead, the system relaunches
/// the app and calls `handleEventsForBackgroundURLSession`. There is no SwiftUI equivalent that
/// covers the relaunch case: `.backgroundTask(.urlSession)` handles the app being *woken*, but
/// the delegate method is what the system actually calls, and skipping it means the completion
/// handler is never invoked.
///
/// Not invoking that handler is not a cosmetic failure. The system times the app out, marks it
/// as misbehaving, and becomes progressively less willing to relaunch it for later transfers —
/// so a large scan silently stops being reliable after a few of them.
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// The notification delegate and the background refresh task, which both have to be in
    /// place before launching finishes — see `AppNotifications.registerAtLaunch`. Neither asks
    /// the person for anything.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppNotifications.registerAtLaunch()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Only ours. Another identifier belongs to some other session and its handler must not
        // be consumed here.
        guard identifier == BackgroundUploader.sessionIdentifier else {
            completionHandler()
            return
        }

        // Touching `shared` is what re-creates the `URLSession` for this identifier in the new
        // process. Without that the system has events to deliver and nothing to deliver them
        // to, and this launch accomplishes nothing.
        Task { @MainActor in
            BackgroundUploader.shared.backgroundCompletionHandler = completionHandler
        }
    }
}
