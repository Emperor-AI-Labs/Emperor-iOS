import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Whether iOS will show this app's notifications.
enum NotificationAuthorization: Equatable, Sendable {
    /// Never asked. Asking shows the system prompt — once per install.
    case notDetermined
    /// Refused, at the prompt or later in iOS Settings. Only the person can undo it, there.
    case denied
    /// Allowed, fully or provisionally.
    case allowed
}

/// The device's notification system, as the coordinator needs it.
///
/// A protocol so every decision about what to schedule is made — and tested — in the core. The
/// app's implementation wraps `UNUserNotificationCenter` and `BGTaskScheduler`; the UI tests
/// use one that never touches either.
protocol NotificationScheduling: Sendable {
    func authorization() async -> NotificationAuthorization
    /// Shows the system prompt if iOS still allows it. Returns whether notifications are allowed
    /// afterwards.
    func requestAuthorization() async -> Bool
    /// Identifiers of every request still waiting to fire.
    func pendingIdentifiers() async -> [String]
    func removePending(identifiers: [String]) async
    /// Adds a request, replacing any pending one with the same identifier.
    func add(_ notification: PlannedNotification) async
    func setBadge(_ count: Int) async
    /// Everything this app has pending or delivered, and the badge.
    func removeAll() async
    /// Asks iOS for a background refresh no earlier than `earliest`, replacing any earlier ask.
    func scheduleBackgroundRefresh(earliest: Date)
    func cancelBackgroundRefresh()
}

/// What a refresh needs from the signed-in account.
struct NotificationAccount: Sendable {
    let userID: Int
    let cases: any CaseProviding
    let feed: any NotificationProviding
    /// Where the screens leave the cause list they last loaded — the same entry Home and the
    /// Calendar open on.
    let cache: ResponseCache?

    var cachedCauseList: [CauseListing]? {
        cache?.load([CauseListing].self, for: .causeList)?.value
    }
}

extension NotificationAccount {
    /// The signed-in account, or `nil` when nobody is — in which case nothing is scheduled.
    @MainActor
    init?(session: Session) {
        guard let user = session.currentUser else { return nil }
        self.init(
            userID: user.id, cases: session.cases, feed: session.notifications,
            cache: session.cache)
    }
}

/// Keeps this device's local notifications in step with the account.
///
/// ## When it runs
///
/// - At launch and on every return to the app, from the cause list the screens last cached.
/// - Whenever a screen loads the cause list (`causeListChanged`).
/// - From a background refresh, which fetches the cause list and reads the feed itself.
/// - Whenever a setting changes.
///
/// Every pass is the same idea: decide what should be pending (`NotificationPlanner`), make the
/// system's queue match, and set the badge to the unread count. A background pass also announces
/// what is new in the feed (`UpdateAlerts`).
///
/// Only a background pass reads the feed. An announcement is for something that happened while
/// the person was not looking; once they have opened the app, the Updates bell on Home is the
/// record, and a banner for it on arrival would only repeat it.
///
/// ## When it does nothing
///
/// With notifications turned off here, or refused in iOS Settings, what this app scheduled is
/// withdrawn and the badge cleared.
///
/// Signing out withdraws everything (`signedOut`) — a reminder naming a client's matter must not
/// fire on a phone its owner has signed out of. That is done when the session actually ends, not
/// whenever a pass finds no account: a background launch with the phone locked cannot read the
/// Keychain, and taking that for a sign-out would wipe every reminder each time it happened.
///
/// Passes run one at a time, in the order asked for: two arriving together — a background
/// refresh and a screen loading the cause list — would otherwise interleave their removals and
/// additions and leave the queue holding a mixture of both.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class NotificationCoordinator {

    /// The `BGAppRefreshTask` identifier. Must match `BGTaskSchedulerPermittedIdentifiers` in
    /// `Info.plist`, or iOS refuses the request.
    nonisolated static let refreshTaskIdentifier = "com.emperorailabs.emperor.refresh"

    /// The earliest the next background refresh is asked for. iOS decides when it actually runs —
    /// it learns when the app is used — so this is a floor, not a schedule.
    nonisolated static let refreshInterval: TimeInterval = 60 * 60

    private(set) var preferences: NotificationPreferences

    private let store: any PreferenceStore
    private let scheduler: any NotificationScheduling
    private let now: @Sendable () -> Date

    /// The plan last handed to the system, so a pass that would change nothing leaves the queue
    /// alone. `nil` whenever the queue may hold something else — at launch, after a withdrawal.
    private var applied: [PlannedNotification]?
    private var lastPass: Task<Void, Never>?

    init(
        store: any PreferenceStore,
        scheduler: any NotificationScheduling,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.scheduler = scheduler
        self.now = now
        self.preferences = NotificationPreferences.stored(in: store)
    }

    // MARK: - Settings

    /// Changes the stored preferences. The caller re-plans afterwards.
    ///
    /// Turning updates on — directly, or by turning notifications on with updates already
    /// selected — forgets what the feed held before, so the next look takes the feed as it
    /// stands and announces only what arrives after. Otherwise switching on after a month off
    /// would announce a month of history.
    func update(_ change: (inout NotificationPreferences) -> Void) {
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        let wasAnnouncing = preferences.isEnabled && preferences.updates
        if next.isEnabled && next.updates && !wasAnnouncing {
            SeenUpdates.forget(in: store)
        }
        preferences = next
        next.save(to: store)
    }

    func authorization() async -> NotificationAuthorization {
        await scheduler.authorization()
    }

    /// Asks iOS, if it will still ask. Called only from the switch that turns notifications on —
    /// never at launch.
    func requestAuthorization() async -> NotificationAuthorization {
        if await scheduler.authorization() == .notDetermined {
            _ = await scheduler.requestAuthorization()
        }
        return await scheduler.authorization()
    }

    /// Whether anything may be scheduled: on here, and allowed by iOS.
    func isActive() async -> Bool {
        guard preferences.isEnabled else { return false }
        return await scheduler.authorization() == .allowed
    }

    // MARK: - Passes

    /// What a pass fetches for itself, beyond the unread count.
    struct Fetch: OptionSet, Sendable {
        let rawValue: Int

        /// `/cause-list`, rather than planning from the cached copy. The route returns the whole
        /// hearing history, so only a background refresh — when no screen is loading it — asks
        /// for it; otherwise the screens' own loads keep the cache fresh and reach here through
        /// `causeListChanged`.
        static let causeList = Fetch(rawValue: 1)
        /// The feed, to announce what is new in it.
        static let feed = Fetch(rawValue: 2)

        /// A background refresh: everything.
        static let background: Fetch = [.causeList, .feed]
    }

    /// One pass. Returns whether every fetch it attempted succeeded — what a background refresh
    /// reports to iOS.
    @discardableResult
    func refresh(account: NotificationAccount?, fetching: Fetch = []) async -> Bool {
        await serially { [self] in
            // No account this pass can see. Not a sign-out — see the type's notes — so nothing
            // is touched.
            guard let account else { return true }
            guard await isActive() else {
                await withdraw()
                return true
            }
            // Asked for first, as iOS recommends: a refresh that runs out of time still leaves
            // the next one booked.
            scheduler.scheduleBackgroundRefresh(earliest: now().addingTimeInterval(Self.refreshInterval))

            var succeeded = true
            var listings = account.cachedCauseList
            if fetching.contains(.causeList) {
                do {
                    let fetched = try await account.cases.causeList()
                    // Saved where Home and the Calendar look first, so they open on it too.
                    account.cache?.save(fetched, for: .causeList)
                    listings = fetched
                } catch {
                    succeeded = false
                }
            }
            // No cause list at all — never loaded, or the fetch failed with nothing cached —
            // leaves what is pending alone. A stale reminder is better than none, and an empty
            // plan here would withdraw every hearing because of one failed request.
            if let listings {
                await apply(plan(listings))
            }

            if fetching.contains(.feed), preferences.updates {
                if !(await announceUpdates(account)) { succeeded = false }
            }
            if let unread = try? await account.feed.unreadCount() {
                await scheduler.setBadge(unread)
            }
            return succeeded
        }
    }

    /// A screen loaded the cause list and left it in the cache: plan from it.
    func causeListChanged(_ listings: [CauseListing]) async {
        await serially { [self] in
            guard await isActive() else { return true }
            await apply(plan(listings))
            return true
        }
    }

    /// "Send a test notification". Returns whether it was sent.
    func sendTest() async -> Bool {
        guard await isActive() else { return false }
        await scheduler.add(NotificationPlanner.test(preferences: preferences))
        return true
    }

    /// Signed out: nothing pending, nothing delivered, no badge, no background refresh — and
    /// nothing remembered about the account's feed.
    func signedOut() async {
        await serially { [self] in
            await clearEverything()
            return true
        }
    }

    // MARK: - Steps

    func plan(_ listings: [CauseListing]) -> [PlannedNotification] {
        NotificationPlanner.plan(listings: listings, preferences: preferences, now: now())
    }

    /// Makes the system's queue match the plan: removes what this planner scheduled and no
    /// longer wants, and adds — or, by identifier, replaces — the rest.
    private func apply(_ plan: [PlannedNotification]) async {
        guard plan != applied else { return }
        let wanted = Set(plan.map(\.identifier))
        let stale = await scheduler.pendingIdentifiers().filter {
            $0.hasPrefix(NotificationPlanner.identifierPrefix) && !wanted.contains($0)
        }
        if !stale.isEmpty {
            await scheduler.removePending(identifiers: stale)
        }
        for notification in plan {
            await scheduler.add(notification)
        }
        applied = plan
    }

    /// Looks at the feed and announces what is new. Returns whether the feed could be read.
    private func announceUpdates(_ account: NotificationAccount) async -> Bool {
        guard let feed = try? await account.feed.notifications() else { return false }
        let seen = SeenUpdates.stored(in: store, userID: account.userID)
        let (alerts, remembered) = UpdateAlerts.diff(feed: feed, seen: seen)
        SeenUpdates(userID: account.userID, ids: remembered).save(to: store)
        // Oldest of the new first, so the newest lands on top of the stack.
        for alert in alerts.reversed() {
            await scheduler.add(UpdateAlerts.notification(for: alert))
        }
        return true
    }

    /// Turned off, or refused in iOS Settings: what this planner scheduled goes, and the badge.
    /// Delivered notifications stay — they are already the person's to dismiss.
    private func withdraw() async {
        let ours = await scheduler.pendingIdentifiers().filter {
            $0.hasPrefix(NotificationPlanner.identifierPrefix)
        }
        if !ours.isEmpty {
            await scheduler.removePending(identifiers: ours)
        }
        await scheduler.setBadge(0)
        scheduler.cancelBackgroundRefresh()
        applied = nil
    }

    private func clearEverything() async {
        await scheduler.removeAll()
        scheduler.cancelBackgroundRefresh()
        SeenUpdates.forget(in: store)
        applied = nil
    }

    /// Runs one pass after the previous one has finished.
    @discardableResult
    private func serially(_ work: @escaping @MainActor () async -> Bool) async -> Bool {
        let previous = lastPass
        let pass = Task { @MainActor in
            await previous?.value
            return await work()
        }
        lastPass = Task { @MainActor in _ = await pass.value }
        return await pass.value
    }
}

/// A notification the person tapped, waiting for the signed-in app to show where it leads.
///
/// The tap can arrive before any screen exists — it is what launched the app — so it is held
/// here until the tab view takes it.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class NotificationInbox {
    private(set) var pending: NotificationTarget?
    /// Counts taps, so the same target tapped twice is still a change to observe.
    private(set) var tapCount = 0

    init() {}

    func open(_ target: NotificationTarget) {
        pending = target
        tapCount += 1
    }

    /// The waiting target, once. Taking it clears it, so returning to the app later does not
    /// open it again.
    func take() -> NotificationTarget? {
        defer { pending = nil }
        return pending
    }
}

/// A `CacheStore` that says when something is written — how the coordinator learns a screen has
/// loaded the cause list, without any screen having to know notifications exist.
struct NotifyingCacheStore: CacheStore {
    let base: any CacheStore
    /// Called with the key after each write, on whichever thread wrote it.
    let onWrite: @Sendable (String) -> Void

    func read(_ key: String) -> Data? { base.read(key) }

    func write(_ data: Data, for key: String) {
        base.write(data, for: key)
        onWrite(key)
    }

    func remove(_ key: String) { base.remove(key) }
    func removeAll() { base.removeAll() }
}
