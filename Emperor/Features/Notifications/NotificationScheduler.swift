import Foundation
import UserNotifications
import BackgroundTasks

/// `NotificationScheduling` over `UNUserNotificationCenter` and `BGTaskScheduler`.
///
/// Deliberately a thin translation: every decision — what to schedule, when, what to withdraw —
/// is made by `NotificationCoordinator` in the core, where it is tested. This only says it to the
/// system.
///
/// **Local notifications only.** There is no Push Notifications capability and no
/// `aps-environment`: the platform has no channel to an iPhone, and a free signing identity
/// cannot carry the entitlement anyway. Everything the person is told is scheduled here, from
/// data the app already holds.
struct SystemNotificationScheduler: NotificationScheduling {

    func authorization() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .allowed
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        let granted = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        return granted ?? false
    }

    func pendingIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }

    func removePending(identifiers: [String]) async {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func add(_ notification: PlannedNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.threadIdentifier
        if let target = notification.target {
            content.userInfo = target.userInfo
        }

        // An interval from now rather than calendar components: the planner hands over an
        // instant computed in India, and a calendar trigger would re-read it as a wall-clock
        // time in whatever zone the phone is in.
        var trigger: UNNotificationTrigger?
        if let fireDate = notification.fireDate {
            trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, fireDate.timeIntervalSinceNow), repeats: false)
        }
        let request = UNNotificationRequest(
            identifier: notification.identifier, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }

    func removeAll() async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        try? await center.setBadgeCount(0)
    }

    func scheduleBackgroundRefresh(earliest: Date) {
        let request = BGAppRefreshTaskRequest(identifier: NotificationCoordinator.refreshTaskIdentifier)
        request.earliestBeginDate = earliest
        // Refused on the simulator, and when the person has turned Background App Refresh off.
        // Either way the reminders already booked stand, and the next launch re-plans.
        try? BGTaskScheduler.shared.submit(request)
    }

    func cancelBackgroundRefresh() {
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: NotificationCoordinator.refreshTaskIdentifier)
    }
}

#if DEBUG
/// The scheduler the UI tests run with: it never asks iOS for permission, never schedules a real
/// notification and never books a background task — but it answers like a device that was asked
/// and said yes, so Settings → Notifications can be driven end to end.
final class UITestNotificationScheduler: NotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var status: NotificationAuthorization = .notDetermined
    private var pending: Set<String> = []

    func authorization() async -> NotificationAuthorization { lock.withLock { status } }

    func requestAuthorization() async -> Bool {
        lock.withLock {
            status = .allowed
            return true
        }
    }

    func pendingIdentifiers() async -> [String] { lock.withLock { Array(pending) } }

    func removePending(identifiers: [String]) async {
        lock.withLock { pending.subtract(identifiers) }
    }

    func add(_ notification: PlannedNotification) async {
        guard notification.fireDate != nil else { return }
        lock.withLock { _ = pending.insert(notification.identifier) }
    }

    func setBadge(_ count: Int) async {}

    func removeAll() async { lock.withLock { pending.removeAll() } }

    func scheduleBackgroundRefresh(earliest: Date) {}
    func cancelBackgroundRefresh() {}
}
#endif
