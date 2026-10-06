import Foundation
import WidgetKit

/// The app's end of the Today widget: finds the shared app group, keeps the widget's snapshot
/// current, and asks WidgetKit to redraw when it changes.
///
/// Every decision — when to write, what to write, when not to — is `TodaySnapshotPublisher`'s, in
/// the core, where it is tested. This supplies the two things the core cannot: the app-group
/// container and `WidgetCenter`.
///
/// Driven from `AppNotifications`, at the moments the hearing reminders are re-planned — a saved
/// cause list, a return to the app, a sign-in, a sign-out — because those already run with or
/// without a screen, including in a background refresh.
///
/// ## Without an app group
///
/// A build installed without the entitlement — a sideloading tool may drop or rename it — finds
/// no container (`AppGroup`), and then this does nothing at all: no file, no reload, no error. The
/// widget, which looks for the same group, shows "Open Emperor to load your listings".
@MainActor
final class TodayWidgetBridge {
    static let shared = TodayWidgetBridge()

    private let publisher: TodaySnapshotPublisher

    private init() {
        #if DEBUG
        // The UI tests never touch the shared container or WidgetKit.
        if UITestSupport.isActive {
            publisher = TodaySnapshotPublisher(store: nil, reload: {})
            return
        }
        #endif
        let info = Bundle.main.infoDictionary ?? [:]
        let candidates = AppGroup.candidates(
            configured: info[AppGroup.infoKey] as? String,
            hostBundleIdentifier: Bundle.main.bundleIdentifier)
        let resolved = AppGroup.resolve(candidates: candidates, container: AppGroup.systemContainer)
        publisher = TodaySnapshotPublisher(
            store: resolved.map { TodaySnapshotStore(directory: $0.url) },
            reload: { WidgetCenter.shared.reloadAllTimelines() })
    }

    /// The cause list was just saved: write the week it holds. Handed the cached copy the caller
    /// already read, so the whole hearing history is decoded once per save, not twice.
    func causeListSaved(_ cached: CachedValue<[CauseListing]>?) {
        guard let cached else { return }
        publisher.publish(listings: cached.value, fetchedAt: cached.storedAt)
    }

    /// Back in the app, or signed in: bring the snapshot to today and to this sign-in, reading
    /// the cache only if it needs to.
    func refresh(isSignedIn: Bool, cache: ResponseCache?) {
        publisher.refresh(isSignedIn: isSignedIn) {
            cache?.load([CauseListing].self, for: .causeList).map { ($0.value, $0.storedAt) }
        }
    }

    /// Signed out: the account's listings leave the shared container.
    func signedOut() {
        publisher.signedOut()
    }
}

/// The app's own links (`EmperorLink`), opened by `RootView.onOpenURL` and by the "Open my
/// calendar" shortcut.
///
/// A link is handed to the same inbox a tapped notification is (`NotificationInbox`), so the two
/// take one path to the screen: `NotificationTapRouting` opens the Calendar on the day, or Updates
/// once nothing else is presented. A link arriving before anyone is signed in waits there for the
/// tab view — and is dropped, like a notification tap, if the session turns out to be signed out.
@MainActor
enum AppLinks {
    /// Opens `url` if it is one of ours. Returns `false`, touching nothing, for any other URL —
    /// a document handed to the app, say — so its own handler can have it.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard let link = EmperorLink(url: url) else { return false }
        open(link)
        return true
    }

    static func open(_ link: EmperorLink) {
        AppNotifications.shared.inbox.open(link.target(now: Date()))
    }
}
