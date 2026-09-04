import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The notification feed and the unread badge.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class NotificationsViewModel {

    private(set) var notifications: [AppNotification] = []
    private(set) var state: LoadState = .idle
    private(set) var cachedAt: Date?
    /// Held separately from the list because the badge is refreshed far more often than the
    /// feed — the count is one row, the feed is up to 200.
    private(set) var unreadCount = 0

    private let service: any NotificationProviding
    private let cache: ResponseCache?

    init(service: any NotificationProviding, cache: ResponseCache? = nil) {
        self.service = service
        self.cache = cache
    }

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: notifications.isEmpty, cachedAt: cachedAt)
    }

    /// Whether the feed may be missing older rows.
    ///
    /// The API has no cursor and clamps at 200 with no truncation signal, so a full page is the
    /// only evidence there might be more — and there is no way to reach them. Saying so is
    /// better than implying the list is complete.
    var mayHaveOlderUnreachable: Bool {
        notifications.count >= NotificationService.maximumLimit
    }

    // MARK: - Loading

    func load() async {
        if state == .idle, notifications.isEmpty,
           let cached = cache?.load([AppNotification].self, for: .notifications) {
            notifications = cached.value
            cachedAt = cached.storedAt
            unreadCount = cached.value.filter { !$0.isRead }.count
        }

        state = .loading
        do {
            notifications = try await service.notifications()
            cachedAt = nil
            cache?.save(notifications, for: .notifications)
            state = .loaded
            await refreshUnreadCount()
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    /// Refreshes just the badge. Cheap enough to call on foreground.
    func refreshUnreadCount() async {
        guard let count = try? await service.unreadCount() else { return }
        unreadCount = count
    }

    // MARK: - Marking read

    /// Marks one row read.
    ///
    /// The local count is recomputed from the list rather than decremented. `markRead` has no
    /// `AND read = 0` predicate (`lib/notifications.js:119`), so marking an already-read row
    /// reports `changed: 1` — a client that decremented on every success would drive its badge
    /// negative on a double tap.
    func markRead(_ notification: AppNotification) async {
        guard !notification.isRead else { return }
        applyReadLocally(id: notification.id)
        do {
            try await service.markRead(id: notification.id)
        } catch {
            // Put it back rather than leaving the UI claiming something that did not happen.
            applyReadLocally(id: notification.id, read: false)
        }
        await refreshUnreadCount()
    }

    func markAllRead() async {
        let previous = notifications
        notifications = notifications.map {
            var copy = $0
            copy.read = 1
            return copy
        }
        unreadCount = 0
        do {
            try await service.markAllRead()
            cache?.save(notifications, for: .notifications)
        } catch {
            notifications = previous
        }
        await refreshUnreadCount()
    }

    private func applyReadLocally(id: String, read: Bool = true) {
        guard let index = notifications.firstIndex(where: { $0.id == id }) else { return }
        notifications[index].read = read ? 1 : 0
        unreadCount = notifications.filter { !$0.isRead }.count
    }
}
