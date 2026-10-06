import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks

/// The app's one notification coordinator, and the three ways in from the system: the launch,
/// a background refresh, and a tapped notification.
///
/// A process-wide object rather than something in the view tree, because two of those three
/// arrive with no view tree at all: iOS launches the app in the background to refresh it without
/// connecting a scene, and a tap can launch the app before any screen exists.
@MainActor
final class AppNotifications {
    static let shared = AppNotifications()

    let coordinator: NotificationCoordinator
    /// A tapped notification, waiting for the tab view (`NotificationTapRouting`).
    let inbox = NotificationInbox()
    /// The app's session. Handed over by `EmperorApp.makeSession()`, which runs on every launch
    /// — including a background one, where no view will ever read it.
    var session: Session?

    private init() {
        #if DEBUG
        if UITestSupport.isActive {
            coordinator = NotificationCoordinator(
                store: Preferences(), scheduler: UITestNotificationScheduler())
            return
        }
        #endif
        coordinator = NotificationCoordinator(
            store: Preferences(), scheduler: SystemNotificationScheduler())
    }

    private var account: NotificationAccount? {
        session.flatMap { NotificationAccount(session: $0) }
    }

    // MARK: - Launch

    /// From `application(_:didFinishLaunchingWithOptions:)`. Both of these must be in place
    /// before launching finishes: the tap that launched the app is delivered to whichever
    /// delegate is set by then, and iOS refuses a background task registered any later.
    ///
    /// Nothing here asks for permission — that waits for the switch in Settings.
    static func registerAtLaunch() {
        #if DEBUG
        // The UI tests never touch the real notification centre or background tasks.
        if UITestSupport.isActive { return }
        #endif
        UNUserNotificationCenter.current().delegate = NotificationResponder.shared
        // `@Sendable`, so the handler carries no actor isolation of its own: iOS calls it on a
        // queue of its choosing, and a closure inferred as main-actor would trap there.
        _ = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: NotificationCoordinator.refreshTaskIdentifier,
            using: nil
        ) { @Sendable task in
            AppNotifications.handleRefresh(RefreshTask(task: task))
        }
    }

    // MARK: - Passes

    /// At launch, on returning to the app, and when someone signs in: plan from what is cached,
    /// and bring the badge up to date.
    ///
    /// Signed out, it withdraws instead. Sign-out is normally caught as it happens (`RootView`),
    /// but a session can also end where no screen sees it — a token refused during a background
    /// refresh — and this is the next moment the app is sure of it.
    func refresh() async {
        if session?.state == .signedOut {
            await signedOut()
            return
        }
        await coordinator.refresh(account: account)
    }

    /// The session ended: withdraw everything this device scheduled for that account, and drop
    /// a tap still waiting to be shown — it was about that account's matters.
    func signedOut() async {
        _ = inbox.take()
        await coordinator.signedOut()
    }

    /// A screen saved the cause list into the response cache. Called from the cache's write
    /// observer (`NotifyingCacheStore`), so no screen needs to know notifications exist.
    func causeListChanged() {
        guard let listings = account?.cachedCauseList else { return }
        let coordinator = coordinator
        Task { await coordinator.causeListChanged(listings) }
    }

    // MARK: - Background refresh

    nonisolated private static func handleRefresh(_ refresh: RefreshTask) {
        let work = Task { @MainActor in
            let succeeded = await AppNotifications.shared.runBackgroundRefresh()
            refresh.task.setTaskCompleted(success: succeeded && !Task.isCancelled)
        }
        refresh.task.expirationHandler = { @Sendable in
            work.cancel()
        }
    }

    /// Fetches the cause list and the feed, re-plans, and announces what is new.
    ///
    /// A background launch has no scene, so nothing has restored the session yet. It is restored
    /// here — but only while the device is unlocked: the token is kept "when unlocked, this
    /// device only", so a locked phone cannot read it, and a session restored then would read as
    /// signed out. Doing nothing is the right answer to a locked phone; the reminders already
    /// booked stand.
    func runBackgroundRefresh() async -> Bool {
        guard let session else { return false }
        if session.state == .loading {
            guard UIApplication.shared.isProtectedDataAvailable else { return false }
            await session.restore()
        }
        // Read with the phone unlocked, so this is a real sign-out, not an unreadable Keychain.
        if session.state == .signedOut {
            await signedOut()
            return true
        }
        let wasSignedIn = session.currentUser != nil
        let succeeded = await coordinator.refresh(account: account, fetching: .background)
        // The token was refused during the refresh, and the session signed itself out. No
        // screen is watching to withdraw this account's reminders, so it is done here.
        if wasSignedIn && session.currentUser == nil {
            await coordinator.signedOut()
        }
        return succeeded
    }
}

/// Carries a background task across to the main actor. `BGTask` is not `Sendable`; it is used
/// only to report completion and to be told of expiry, both of which it documents as safe from
/// any thread.
private struct RefreshTask: @unchecked Sendable {
    let task: BGTask
}

/// Receives taps, and lets notifications show while the app is open.
///
/// Not main-actor: iOS calls these on a queue of its choosing. Each method does only what is safe
/// anywhere — reading plain strings out of the notification — and hands the result to the main
/// actor.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationResponder()

    /// Shown as a banner even while Emperor is open — the test notification is sent from inside
    /// the app, and an update announced while the person is looking at another screen is still
    /// news.
    ///
    /// The `async` forms of both delegate methods rather than the completion-handler ones: the
    /// SDK has changed how it annotates those handlers' concurrency, and an optional requirement
    /// that no longer matches is skipped without a word — taps would simply do nothing. The
    /// `async` forms have no handler to annotate.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        var strings: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String {
                strings[key] = value
            }
        }
        guard let target = NotificationTarget(userInfo: strings) else { return }
        await MainActor.run {
            AppNotifications.shared.inbox.open(target)
        }
    }
}

/// Opens where a tapped notification leads: a hearing on the Calendar tab, an update on the
/// Updates screen.
///
/// Applied by `MainTabView`, the one place that holds the `AppNavigator`. A tap that launched the
/// app is waiting in the inbox before this view exists, which is why the change is observed with
/// `initial: true`.
///
/// `AppNavigator` has no way to open the Calendar on a given day yet, so a hearing opens the
/// Calendar tab as it stands; the day is carried in the notification for when it does.
struct NotificationTapRouting: ViewModifier {
    let navigator: AppNavigator

    @State private var isShowingUpdates = false

    func body(content: Content) -> some View {
        content
            .onChange(of: AppNotifications.shared.inbox.tapCount, initial: true) { _, _ in
                route()
            }
            .sheet(isPresented: $isShowingUpdates) {
                NotificationsView()
            }
    }

    private func route() {
        guard let target = AppNotifications.shared.inbox.take() else { return }
        switch target {
        case .calendar:
            navigator.selectedTab = .calendar
        case .updates:
            isShowingUpdates = true
        }
    }
}

extension View {
    /// See `NotificationTapRouting`.
    func routesNotificationTaps(to navigator: AppNavigator) -> some View {
        modifier(NotificationTapRouting(navigator: navigator))
    }
}
