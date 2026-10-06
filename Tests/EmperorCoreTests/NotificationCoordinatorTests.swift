import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

/// The device's notification system, recorded.
final class FakeNotificationScheduler: NotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _authorization: NotificationAuthorization
    private var _grants: Bool
    private var _prompts = 0
    private var _pending: [String: PlannedNotification] = [:]
    private var _delivered: [PlannedNotification] = []
    private var _adds = 0
    private var _badge: Int?
    private var _refreshAt: Date?
    private var _refreshCancelled = 0
    private var _removedAll = 0

    init(authorization: NotificationAuthorization = .allowed, grants: Bool = true) {
        _authorization = authorization
        _grants = grants
    }

    var authorizationStatus: NotificationAuthorization {
        get { lock.withLock { _authorization } }
        set { lock.withLock { _authorization = newValue } }
    }
    var prompts: Int { lock.withLock { _prompts } }
    var pending: [String: PlannedNotification] { lock.withLock { _pending } }
    var delivered: [PlannedNotification] { lock.withLock { _delivered } }
    var adds: Int { lock.withLock { _adds } }
    var badge: Int? { lock.withLock { _badge } }
    var refreshAt: Date? { lock.withLock { _refreshAt } }
    var refreshCancelled: Int { lock.withLock { _refreshCancelled } }
    var removedAll: Int { lock.withLock { _removedAll } }

    /// Something another part of the app scheduled, which a re-plan must leave alone.
    func seed(_ notification: PlannedNotification) {
        lock.withLock { _pending[notification.identifier] = notification }
    }

    func authorization() async -> NotificationAuthorization { authorizationStatus }

    func requestAuthorization() async -> Bool {
        lock.withLock {
            _prompts += 1
            if _authorization == .notDetermined { _authorization = _grants ? .allowed : .denied }
            return _authorization == .allowed
        }
    }

    func pendingIdentifiers() async -> [String] { lock.withLock { Array(_pending.keys) } }

    func removePending(identifiers: [String]) async {
        lock.withLock { identifiers.forEach { _pending.removeValue(forKey: $0) } }
    }

    func add(_ notification: PlannedNotification) async {
        lock.withLock {
            _adds += 1
            if notification.fireDate == nil {
                _delivered.append(notification)
            } else {
                _pending[notification.identifier] = notification
            }
        }
    }

    func setBadge(_ count: Int) async { lock.withLock { _badge = count } }

    func removeAll() async {
        lock.withLock {
            _removedAll += 1
            _pending.removeAll()
            _delivered.removeAll()
            _badge = 0
        }
    }

    func scheduleBackgroundRefresh(earliest: Date) { lock.withLock { _refreshAt = earliest } }
    func cancelBackgroundRefresh() {
        lock.withLock {
            _refreshCancelled += 1
            _refreshAt = nil
        }
    }
}

final class FakeEmailBriefing: EmailBriefingProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _status = EmailBriefingStatus(
        asked: true, optedIn: false, pushCount: 0, systemEnabled: true, notifTime: "08:00")
    private var _calls: [String] = []
    private var _error: Error?
    private var _emailed = 1

    var status: EmailBriefingStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var calls: [String] { lock.withLock { _calls } }
    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    var emailed: Int {
        get { lock.withLock { _emailed } }
        set { lock.withLock { _emailed = newValue } }
    }

    private func record(_ call: String) throws {
        try lock.withLock {
            _calls.append(call)
            if let _error { throw _error }
        }
    }

    func status() async throws -> EmailBriefingStatus {
        try record("status")
        return status
    }

    func optIn() async throws {
        try record("optin")
        lock.withLock { _status.optedIn = true }
    }

    func optOut() async throws {
        try record("optout")
        lock.withLock { _status.optedIn = false }
    }

    func sendTest() async throws -> EmailBriefingTestResult {
        try record("test")
        return EmailBriefingTestResult(success: true, emailed: emailed, pushed: 0)
    }
}

/// Keeping the device's queue in step with the account: what is scheduled, withdrawn and
/// announced, and when nothing is.
@MainActor
final class NotificationCoordinatorTests: XCTestCase {

    nonisolated private static let now = NotificationPlannerTests.midMorning

    private struct Harness {
        let coordinator: NotificationCoordinator
        let scheduler: FakeNotificationScheduler
        let store: InMemoryPreferenceStore
        let cases: FakeCases
        let feed: FakeNotifications
        let cache: ResponseCache
        let account: NotificationAccount
    }

    private func harness(
        enabled: Bool = true,
        authorization: NotificationAuthorization = .allowed,
        cached: [CauseListing]? = [NotificationPlannerTests.listing("2026-10-14")]
    ) -> Harness {
        let store = InMemoryPreferenceStore()
        var preferences = NotificationPreferences()
        preferences.isEnabled = enabled
        preferences.save(to: store)
        let scheduler = FakeNotificationScheduler(authorization: authorization)
        let cache = ResponseCache(store: InMemoryCacheStore())
        if let cached { cache.save(cached, for: .causeList) }
        let cases = FakeCases()
        let feed = FakeNotifications()
        feed.unreadCount = 4
        let coordinator = NotificationCoordinator(
            store: store, scheduler: scheduler, now: { Self.now })
        return Harness(
            coordinator: coordinator, scheduler: scheduler, store: store, cases: cases,
            feed: feed, cache: cache,
            account: NotificationAccount(userID: 42, cases: cases, feed: feed, cache: cache))
    }

    // MARK: - Scheduling

    func testAPassSchedulesFromTheCachedCauseListAndSetsTheBadge() async {
        let h = harness()
        let succeeded = await h.coordinator.refresh(account: h.account)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(Set(h.scheduler.pending.keys),
                       ["hearing.evening.2026-10-14", "hearing.briefing.2026-10-14"])
        XCTAssertEqual(h.cases.causeListCallCount, 0, "the screens keep the cache fresh")
        XCTAssertEqual(h.scheduler.badge, 4, "the unread count")
        XCTAssertEqual(h.scheduler.refreshAt, Self.now.addingTimeInterval(60 * 60))
    }

    /// A background refresh fetches the cause list itself, and leaves it where Home looks.
    func testABackgroundPassFetchesAndCachesTheCauseList() async {
        let h = harness(cached: nil)
        h.cases.listings = [NotificationPlannerTests.listing("2026-10-15")]
        await h.coordinator.refresh(account: h.account, fetching: .background)

        XCTAssertEqual(h.cases.causeListCallCount, 1)
        XCTAssertEqual(h.cache.load([CauseListing].self, for: .causeList)?.value.map(\.date),
                       ["2026-10-15"])
        XCTAssertEqual(Set(h.scheduler.pending.keys),
                       ["hearing.evening.2026-10-15", "hearing.briefing.2026-10-15"])
    }

    /// A failed fetch with nothing cached withdraws nothing: one bad request must not cancel
    /// every reminder already booked.
    func testAFailedFetchLeavesWhatIsPending() async {
        let h = harness(cached: nil)
        let booked = NotificationPlanner.plan(
            listings: [NotificationPlannerTests.listing("2026-10-14")],
            preferences: h.coordinator.preferences, now: Self.now)
        booked.forEach(h.scheduler.seed)
        h.cases.causeListError = APIError.transport("offline")

        let succeeded = await h.coordinator.refresh(account: h.account, fetching: .background)

        XCTAssertFalse(succeeded, "reported to iOS as a failed refresh")
        XCTAssertEqual(Set(h.scheduler.pending.keys), Set(booked.map(\.identifier)))
    }

    /// The cause list changed: what is no longer listed is withdrawn, the rest replaced in place
    /// — and anything not scheduled by the planner is left alone.
    func testAReplanWithdrawsOnlyWhatItNoLongerWants() async {
        let h = harness(cached: [NotificationPlannerTests.listing("2026-10-14")])
        await h.coordinator.refresh(account: h.account)
        let foreign = PlannedNotification(
            identifier: "something.else", kind: .test, title: "", body: "",
            fireDate: Self.now.addingTimeInterval(600), target: nil)
        h.scheduler.seed(foreign)

        await h.coordinator.causeListChanged([NotificationPlannerTests.listing("2026-10-16")])

        XCTAssertEqual(Set(h.scheduler.pending.keys), [
            "hearing.evening.2026-10-16", "hearing.briefing.2026-10-16", "something.else",
        ])
    }

    /// An empty cause list withdraws every hearing reminder — nothing is listed, so nothing is
    /// due — and adds nothing in their place.
    func testAnEmptyCauseListWithdrawsTheHearings() async {
        let h = harness()
        await h.coordinator.refresh(account: h.account)
        await h.coordinator.causeListChanged([])
        XCTAssertTrue(h.scheduler.pending.isEmpty)
    }

    /// Re-planning with nothing changed leaves the queue alone.
    func testANoChangePassAddsNothing() async {
        let h = harness()
        await h.coordinator.refresh(account: h.account)
        let adds = h.scheduler.adds
        await h.coordinator.refresh(account: h.account)
        await h.coordinator.causeListChanged(
            h.cache.load([CauseListing].self, for: .causeList)?.value ?? [])
        XCTAssertEqual(h.scheduler.adds, adds)
        XCTAssertEqual(h.scheduler.pending.count, 2, "replaced, never duplicated")
    }

    // MARK: - When nothing is scheduled

    func testTurnedOffWithdrawsTheHearingsAndTheBadge() async {
        let h = harness()
        await h.coordinator.refresh(account: h.account)
        h.coordinator.update { $0.isEnabled = false }
        await h.coordinator.refresh(account: h.account)

        XCTAssertTrue(h.scheduler.pending.isEmpty)
        XCTAssertEqual(h.scheduler.badge, 0)
        XCTAssertNil(h.scheduler.refreshAt, "no background refresh is asked for")
    }

    /// Refused in iOS Settings after being turned on here: treated as off.
    func testRefusedInSettingsIsTreatedAsOff() async {
        let h = harness(authorization: .denied)
        await h.coordinator.refresh(account: h.account, fetching: .background)
        XCTAssertTrue(h.scheduler.pending.isEmpty)
        XCTAssertEqual(h.cases.causeListCallCount, 0, "nothing is fetched for nothing")
        XCTAssertGreaterThan(h.scheduler.refreshCancelled, 0)
    }

    /// Signed out: everything goes — pending, delivered, the badge, the background refresh and
    /// what was remembered about the feed.
    func testSignedOutClearsEverything() async {
        let h = harness()
        await h.coordinator.refresh(account: h.account)
        SeenUpdates(userID: 42, ids: ["n1"]).save(to: h.store)

        await h.coordinator.signedOut()

        XCTAssertTrue(h.scheduler.pending.isEmpty)
        XCTAssertEqual(h.scheduler.badge, 0)
        XCTAssertEqual(h.scheduler.removedAll, 1)
        XCTAssertNil(h.scheduler.refreshAt)
        XCTAssertNil(SeenUpdates.stored(in: h.store, userID: 42))
    }

    /// A pass that can see no account — a background launch with the phone locked cannot read
    /// the Keychain — is not a sign-out, and wipes nothing.
    func testAPassWithNoAccountTouchesNothing() async {
        let h = harness()
        await h.coordinator.refresh(account: h.account)
        SeenUpdates(userID: 42, ids: ["n1"]).save(to: h.store)
        let pending = h.scheduler.pending

        let succeeded = await h.coordinator.refresh(account: nil, fetching: .background)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(h.scheduler.pending, pending)
        XCTAssertEqual(h.scheduler.removedAll, 0)
        XCTAssertEqual(SeenUpdates.stored(in: h.store, userID: 42), ["n1"])
        XCTAssertEqual(h.cases.causeListCallCount, 0)
    }

    // MARK: - Updates

    func testTheFirstLookIsSilentAndTheNextAnnouncesWhatIsNew() async {
        let h = harness()
        h.feed.notifications = [AppNotification(id: "n1", title: "Old", read: 0)]
        await h.coordinator.refresh(account: h.account, fetching: .feed)
        XCTAssertTrue(h.scheduler.delivered.isEmpty, "history is not news")

        h.feed.notifications.insert(AppNotification(id: "n2", title: "Hearing listed", read: 0), at: 0)
        await h.coordinator.refresh(account: h.account, fetching: .feed)
        XCTAssertEqual(h.scheduler.delivered.map(\.identifier), ["update.n2"])
        XCTAssertEqual(h.scheduler.delivered.first?.title, "Hearing listed")

        await h.coordinator.refresh(account: h.account, fetching: .feed)
        XCTAssertEqual(h.scheduler.delivered.count, 1, "not announced twice")
    }

    /// Opening the app does not announce anything: the bell on Home is the record once the
    /// person is looking. The feed is left for the next background refresh.
    func testAForegroundPassDoesNotReadTheFeed() async {
        let h = harness()
        await h.coordinator.refresh(account: h.account, fetching: .feed)
        h.feed.notifications = [AppNotification(id: "n2", read: 0)]

        await h.coordinator.refresh(account: h.account)

        XCTAssertTrue(h.scheduler.delivered.isEmpty)
        XCTAssertEqual(SeenUpdates.stored(in: h.store, userID: 42), [],
                       "the next background look still sees n2 as new")
        XCTAssertEqual(h.scheduler.badge, 4, "the badge is brought up to date regardless")
    }

    func testWithUpdatesOffTheFeedIsNotRead() async {
        let h = harness()
        h.coordinator.update { $0.updates = false }
        h.feed.notifications = [AppNotification(id: "n1", read: 0)]
        await h.coordinator.refresh(account: h.account, fetching: .background)
        XCTAssertNil(SeenUpdates.stored(in: h.store, userID: 42))
        XCTAssertTrue(h.scheduler.delivered.isEmpty)
        XCTAssertEqual(h.scheduler.badge, 4, "the badge still counts what is unread")
    }

    /// Turning updates back on starts a fresh look, so a month off is not announced as a month
    /// of news.
    func testTurningUpdatesOnForgetsTheOldLook() async {
        let h = harness()
        SeenUpdates(userID: 42, ids: ["n1"]).save(to: h.store)
        h.coordinator.update { $0.updates = false }
        XCTAssertNotNil(SeenUpdates.stored(in: h.store, userID: 42))
        h.coordinator.update { $0.updates = true }
        XCTAssertNil(SeenUpdates.stored(in: h.store, userID: 42))

        h.feed.notifications = [AppNotification(id: "n2", read: 0), AppNotification(id: "n1", read: 0)]
        await h.coordinator.refresh(account: h.account, fetching: .feed)
        XCTAssertTrue(h.scheduler.delivered.isEmpty)
    }

    // MARK: - Asking and testing

    /// The system prompt is shown only when iOS has never been asked.
    func testPermissionIsAskedOnlyOnce() async {
        let h = harness(enabled: false, authorization: .notDetermined)
        XCTAssertEqual(h.scheduler.prompts, 0, "never asked on its own")
        let first = await h.coordinator.requestAuthorization()
        let second = await h.coordinator.requestAuthorization()
        XCTAssertEqual(first, .allowed)
        XCTAssertEqual(second, .allowed)
        XCTAssertEqual(h.scheduler.prompts, 1)
    }

    func testATestIsSentOnlyWhenNotificationsAreOn() async {
        let off = harness(enabled: false)
        let refused = await off.coordinator.sendTest()
        XCTAssertFalse(refused)
        XCTAssertTrue(off.scheduler.delivered.isEmpty)

        let on = harness()
        let sent = await on.coordinator.sendTest()
        XCTAssertTrue(sent)
        XCTAssertEqual(on.scheduler.delivered.map(\.kind), [.test])
    }

    // MARK: - The account

    func testTheAccountIsTheSignedInOne() async {
        let signedOut = Session(
            store: InMemoryCredentialStore(), cache: ResponseCache(store: InMemoryCacheStore()))
        await signedOut.restore()
        XCTAssertNil(NotificationAccount(session: signedOut))

        let user = User(id: 42, email: "adv@example.test", name: "R. Iyer")
        let encoded = String(decoding: try! JSONEncoder().encode(user), as: UTF8.self)
        let signedIn = Session(
            store: InMemoryCredentialStore(["auth.token": "tok", "auth.user": encoded]),
            cache: ResponseCache(store: InMemoryCacheStore()))
        await signedIn.restore()
        XCTAssertEqual(NotificationAccount(session: signedIn)?.userID, 42)
    }

    /// Writing the cause list into the cache is how a screen's load reaches the coordinator.
    func testACacheWriteIsReported() {
        let keys = Keys()
        let cache = ResponseCache(store: NotifyingCacheStore(
            base: InMemoryCacheStore(), onWrite: { keys.append($0) }))
        cache.save([NotificationPlannerTests.listing("2026-10-14")], for: .causeList)
        XCTAssertEqual(keys.values, [ResponseCache.Key.causeList.rawValue])
        XCTAssertEqual(cache.load([CauseListing].self, for: .causeList)?.value.count, 1)
    }

    private final class Keys: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [String] = []
        var values: [String] { lock.withLock { _values } }
        func append(_ key: String) { lock.withLock { _values.append(key) } }
    }

    // MARK: - The tap

    func testATapIsTakenOnce() {
        let inbox = NotificationInbox()
        inbox.open(.calendar(day: "2026-10-14"))
        XCTAssertEqual(inbox.tapCount, 1)
        XCTAssertEqual(inbox.take(), .calendar(day: "2026-10-14"))
        XCTAssertNil(inbox.take(), "returning to the app does not open it again")
        inbox.open(.calendar(day: "2026-10-14"))
        XCTAssertEqual(inbox.tapCount, 2, "the same target twice is still a new tap")
    }
}

/// Settings → Notifications.
@MainActor
final class NotificationSettingsViewModelTests: XCTestCase {

    private func model(
        authorization: NotificationAuthorization = .notDetermined,
        grants: Bool = true,
        cached: Bool = true,
        email: FakeEmailBriefing? = FakeEmailBriefing()
    ) -> (NotificationSettingsViewModel, FakeNotificationScheduler, FakeCases) {
        let store = InMemoryPreferenceStore()
        let scheduler = FakeNotificationScheduler(authorization: authorization, grants: grants)
        let cache = ResponseCache(store: InMemoryCacheStore())
        if cached { cache.save([NotificationPlannerTests.listing("2026-10-14")], for: .causeList) }
        let cases = FakeCases()
        cases.listings = [NotificationPlannerTests.listing("2026-10-15")]
        let coordinator = NotificationCoordinator(
            store: store, scheduler: scheduler, now: { NotificationPlannerTests.midMorning })
        let model = NotificationSettingsViewModel(
            coordinator: coordinator, emailService: email,
            account: NotificationAccount(userID: 42, cases: cases, feed: FakeNotifications(), cache: cache),
            emailAddress: "adv@example.test")
        return (model, scheduler, cases)
    }

    /// Turning the switch on is the one moment iOS is asked — and the first reminders are booked
    /// straight away.
    func testTurningOnAsksAndSchedules() async {
        let (model, scheduler, _) = model()
        await model.load()
        XCTAssertFalse(model.isOn)
        XCTAssertEqual(scheduler.prompts, 0, "opening the screen does not ask")

        await model.setEnabled(true)

        XCTAssertEqual(scheduler.prompts, 1)
        XCTAssertTrue(model.isOn)
        XCTAssertTrue(model.switchIsOn)
        XCTAssertFalse(model.isTurningOn, "no longer waiting on the prompt")
        XCTAssertTrue(model.preferences.isEnabled)
        XCTAssertEqual(scheduler.pending.count, 2)
    }

    /// With nothing cached yet, the cause list is fetched once so the first briefing is booked
    /// now rather than at the next refresh.
    func testTurningOnWithNothingCachedFetchesOnce() async {
        let (model, scheduler, cases) = model(cached: false)
        await model.setEnabled(true)
        XCTAssertEqual(cases.causeListCallCount, 1)
        XCTAssertTrue(scheduler.pending.keys.contains("hearing.briefing.2026-10-15"))
    }

    /// Refused at the prompt: nothing is switched on, and the screen says where to change it.
    func testARefusalLeavesItOffAndSaysWhy() async {
        let (model, scheduler, _) = model(grants: false)
        await model.setEnabled(true)
        XCTAssertFalse(model.isOn)
        XCTAssertFalse(model.switchIsOn, "the switch goes back to off")
        XCTAssertFalse(model.preferences.isEnabled)
        XCTAssertTrue(model.isBlocked)
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    /// Already refused before: no second prompt — iOS would not show one — and still off.
    func testAlreadyRefusedIsNotAskedAgain() async {
        let (model, scheduler, _) = model(authorization: .denied)
        await model.load()
        XCTAssertTrue(model.isBlocked)
        await model.setEnabled(true)
        XCTAssertEqual(scheduler.prompts, 0)
        XCTAssertFalse(model.isOn)
    }

    func testTheSwitchesReplan() async {
        let (model, scheduler, _) = model(authorization: .allowed)
        await model.load()
        await model.setEnabled(true)
        XCTAssertEqual(scheduler.pending.count, 2)

        await model.setEveningReminder(false)
        XCTAssertEqual(Array(scheduler.pending.keys), ["hearing.briefing.2026-10-14"])

        let nine = NotificationPlannerTests.at("2026-10-13T03:30:00Z")   // 09:00 IST
        await model.setBriefingTime(nine)
        XCTAssertEqual(model.preferences.briefingMinutes, 9 * 60)
        XCTAssertEqual(scheduler.pending["hearing.briefing.2026-10-14"]?.fireDate,
                       NotificationPlannerTests.at("2026-10-14T03:30:00Z"))

        await model.setEnabled(false)
        XCTAssertTrue(scheduler.pending.isEmpty)
        XCTAssertFalse(model.isOn)
    }

    func testTheTestSaysWhetherItWasSent() async {
        let (model, scheduler, _) = model(authorization: .allowed)
        await model.sendTest()
        XCTAssertEqual(model.notice, NotificationSettingsViewModel.Copy.testNotSent)
        await model.setEnabled(true)
        await model.sendTest()
        XCTAssertEqual(model.notice, NotificationSettingsViewModel.Copy.testSent)
        XCTAssertEqual(scheduler.delivered.map(\.kind), [.test])
    }

    // MARK: - The account's email

    func testTheEmailSwitchIsReadFromTheAccountAndWrittenBack() async {
        let email = FakeEmailBriefing()
        let (model, _, _) = model(email: email)
        await model.load()
        XCTAssertEqual(model.emailOptedIn, false)
        XCTAssertFalse(model.offersTestEmail)

        await model.setEmailBriefing(true)
        XCTAssertEqual(email.calls, ["status", "optin", "status"], "read back, not assumed")
        XCTAssertEqual(model.emailOptedIn, true)
        XCTAssertTrue(model.emailSwitchIsOn)
        XCTAssertNil(model.pendingEmail)
        XCTAssertTrue(model.offersTestEmail)

        await model.setEmailBriefing(false)
        XCTAssertEqual(email.calls.suffix(2), ["optout", "status"])
        XCTAssertEqual(model.emailOptedIn, false)
    }

    /// The test email is never offered while the daily email is off — the route that sends it
    /// switches the daily email on.
    func testTheTestEmailIsNotSentWhileTheEmailIsOff() async {
        let email = FakeEmailBriefing()
        let (model, _, _) = model(email: email)
        await model.load()
        await model.sendTestEmail()
        XCTAssertFalse(email.calls.contains("test"))

        await model.setEmailBriefing(true)
        await model.sendTestEmail()
        XCTAssertEqual(email.calls.last, "test")
        XCTAssertEqual(model.emailNotice, "A test email is on its way to adv@example.test.")

        email.emailed = 0
        await model.sendTestEmail()
        XCTAssertEqual(model.emailNotice, NotificationSettingsViewModel.Copy.testEmailFailed,
                       "a run that emailed nobody is not reported as sent")
    }

    func testAFailedReadSaysSo() async {
        let email = FakeEmailBriefing()
        email.error = APIError.server(status: 500, message: "Down")
        let (model, _, _) = model(email: email)
        await model.load()
        XCTAssertEqual(model.email, .failed("Down"))
        XCTAssertNil(model.emailOptedIn)
    }

    func testAFailedWriteSaysSoAndShowsTheTruth() async {
        let email = FakeEmailBriefing()
        let (model, _, _) = model(email: email)
        await model.load()
        email.error = APIError.server(status: 500, message: "Could not save")
        await model.setEmailBriefing(true)
        XCTAssertEqual(model.emailNotice, "Could not save")
        XCTAssertEqual(model.emailOptedIn, false, "still what the account last said")
        XCTAssertFalse(model.emailSwitchIsOn, "the switch goes back to the truth")
    }

    /// The footer says when, to whom, what turning it off also does — and when it is paused.
    func testTheEmailFooter() async {
        let email = FakeEmailBriefing()
        email.status = EmailBriefingStatus(
            asked: true, optedIn: true, pushCount: 2, systemEnabled: false, notifTime: "07:30")
        let (model, _, _) = model(email: email)
        await model.load()
        XCTAssertTrue(model.emailFooter.contains("07:30 IST to adv@example.test"), model.emailFooter)
        XCTAssertTrue(model.emailFooter.contains("also stops the web's browser alerts"))
        XCTAssertTrue(model.emailFooter.hasSuffix(NotificationSettingsViewModel.Copy.paused))
    }

    func testWithNoEmailServiceTheEmailIsNotOffered() async {
        let (model, _, _) = model(email: nil)
        await model.load()
        await model.setEmailBriefing(true)
        XCTAssertNil(model.emailOptedIn)
        XCTAssertFalse(model.offersTestEmail)
    }
}

/// The `/notif/*` routes, on the wire.
@MainActor
final class NotificationOptInWireTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func signedInClient() async -> APIClient {
        let user = User(id: 42, email: "adv@example.test", name: "R. Iyer")
        let encoded = String(decoding: try! JSONEncoder().encode(user), as: UTF8.self)
        let session = Session(
            store: InMemoryCredentialStore(["auth.token": "tok", "auth.user": encoded]),
            cache: ResponseCache(store: InMemoryCacheStore()),
            urlSession: HTTPStub.session())
        await session.restore()
        return session.client
    }

    func testTheStatusIsReadForTheSignedInAccount() async throws {
        let service = NotificationOptInService(client: await signedInClient())
        HTTPStub.always(.json(
            #"{"asked":true,"optedIn":true,"pushCount":1,"systemEnabled":true,"notifTime":"08:00"}"#))

        let status = try await service.status()

        XCTAssertTrue(status.isOptedIn)
        XCTAssertFalse(status.isPaused)
        XCTAssertEqual(status.pushCount, 1)
        XCTAssertEqual(status.sendTime, "08:00")
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.url?.path, "/api/notif/status")
        let query = URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "userId" }?.value, "42")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    /// No `success` key on this route; and a time the server cannot express falls back to 08:00.
    func testAStatusWithMissingFieldsStillReads() async throws {
        let service = NotificationOptInService(client: await signedInClient())
        HTTPStub.always(.json(#"{"asked":false,"optedIn":false,"notifTime":"8am"}"#))
        let status = try await service.status()
        XCTAssertFalse(status.isOptedIn)
        XCTAssertFalse(status.isPaused, "absent reads as running")
        XCTAssertEqual(status.sendTime, "08:00")
    }

    func testAStatusRefusalThrows() async {
        let service = NotificationOptInService(client: await signedInClient())
        HTTPStub.always(.json(#"{"error":"Missing userId"}"#, status: 400))
        do {
            _ = try await service.status()
            XCTFail("a refusal is not a status")
        } catch {}
    }

    /// The id goes in the body, as every POST here sends it — and never a browser subscription.
    func testOptInAndOutSendTheAccountInTheBody() async throws {
        let service = NotificationOptInService(client: await signedInClient())
        HTTPStub.always(.json(#"{"success":true}"#))

        try await service.optIn()
        var sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/api/notif/optin")
        XCTAssertEqual(sent.bodyJSON["userId"] as? String, "42")
        XCTAssertNil(sent.bodyJSON["subscription"], "a phone has no web-push subscription")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        try await service.optOut()
        sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.url?.path, "/api/notif/optout")
        XCTAssertEqual(sent.bodyJSON["userId"] as? String, "42")
    }

    func testAWriteThatSaysItFailedThrows() async {
        let service = NotificationOptInService(client: await signedInClient())
        HTTPStub.always(.json(#"{"success":false,"error":"Not saved"}"#))
        do {
            try await service.optIn()
            XCTFail("a 200 that says it failed has failed")
        } catch {
            XCTAssertEqual(DisplayText.message(for: error), "Not saved")
        }
    }

    func testTheTestReportsWhetherAnEmailWent() async throws {
        let service = NotificationOptInService(client: await signedInClient())
        HTTPStub.always(.json(
            #"{"success":true,"day":"2026-10-13","emailed":1,"pushed":0,"skipped":0,"errors":[]}"#))
        let result = try await service.sendTest()
        XCTAssertTrue(result.didEmail)
        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/notif/test")
        XCTAssertEqual(HTTPStub.lastRequest?.bodyJSON["userId"] as? String, "42")
    }

    func testSignedOutNothingIsSent() async {
        let session = Session(
            store: InMemoryCredentialStore(), cache: ResponseCache(store: InMemoryCacheStore()),
            urlSession: HTTPStub.session())
        await session.restore()
        let service = NotificationOptInService(client: session.client)
        HTTPStub.always(.json(#"{"success":true}"#))
        do {
            try await service.optOut()
            XCTFail("signed out")
        } catch {
            XCTAssertEqual(error as? APIError, .notAuthenticated)
        }
        XCTAssertTrue(HTTPStub.seen.isEmpty)
    }
}

/// The background refresh only runs if the identifier the app asks for is one its Info.plist
/// permits — a mismatch is not an error anywhere, just a refresh that never happens.
final class BackgroundRefreshConfigurationTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // EmperorCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the repository
    }

    func testTheRefreshIdentifierIsPermittedByTheApp() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("Emperor/Resources/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(
            plist["BGTaskSchedulerPermittedIdentifiers"] as? [String],
            [NotificationCoordinator.refreshTaskIdentifier])
        XCTAssertEqual(plist["UIBackgroundModes"] as? [String], ["fetch"])

        // `project.yml` regenerates that file, so it must say the same.
        let spec = try String(
            contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(spec.contains("- \(NotificationCoordinator.refreshTaskIdentifier)"))
        XCTAssertFalse(spec.contains("aps-environment:"), "local notifications only — no push")
    }
}
