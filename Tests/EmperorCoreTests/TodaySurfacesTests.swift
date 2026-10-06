import XCTest
@testable import EmperorCore

/// The app's side of "what's listed today" outside the app: keeping the widget's snapshot
/// current, what Siri answers, and the app-icon badge following the Updates screen.
final class TodaySurfacesTests: XCTestCase {

    private static let morning = TodaySnapshotTests.tuesdayMorning

    private static func listing(
        _ day: String, caseID: String = "case_1", title: String = "Bakshi v. State of Maharashtra",
        itemNo: String? = "7", time: String? = nil
    ) -> CauseListing {
        TodaySnapshotTests.listing(day, caseID: caseID, title: title, itemNo: itemNo, time: time)
    }

    // MARK: - The widget's snapshot

    /// The first write lands and asks the widget to redraw.
    func testSavingTheCauseListWritesTheSnapshotAndReloadsTheWidget() async throws {
        let store = try makeStore()
        await onMain {
            let clock = Clock(Self.morning)
            let reloads = Tally()
            let publisher = TodaySnapshotPublisher(store: store, reload: reloads.add, now: clock.read)

            XCTAssertTrue(publisher.publish(listings: [Self.listing("2026-10-13")], fetchedAt: Self.morning))
            XCTAssertEqual(reloads.count, 1)
            XCTAssertEqual(store.read()?.days.map(\.day), ["2026-10-13"])
            XCTAssertEqual(store.read()?.isSignedIn, true)
        }
    }

    /// The same days re-fetched within the hour are left alone — no write, no reload; an hour on,
    /// or with anything changed, they are written again.
    func testAnUnchangedListIsNotRewrittenWithinTheHour() async throws {
        let store = try makeStore()
        await onMain {
            let clock = Clock(Self.morning)
            let reloads = Tally()
            let publisher = TodaySnapshotPublisher(store: store, reload: reloads.add, now: clock.read)
            let rows = [Self.listing("2026-10-13")]

            publisher.publish(listings: rows, fetchedAt: Self.morning)
            clock.advance(30 * 60)
            XCTAssertFalse(publisher.publish(listings: rows, fetchedAt: clock.read()))
            XCTAssertEqual(reloads.count, 1)

            clock.advance(31 * 60)
            XCTAssertTrue(publisher.publish(listings: rows, fetchedAt: clock.read()), "an hour on")
            XCTAssertEqual(reloads.count, 2)

            XCTAssertTrue(publisher.publish(
                listings: rows + [Self.listing("2026-10-14", caseID: "new")], fetchedAt: clock.read()))
            XCTAssertEqual(reloads.count, 3, "a new listing")
        }
    }

    /// Nothing cached is nothing to say — an empty week written for it would read as a free one.
    func testNoCachedCauseListWritesNothing() async throws {
        let store = try makeStore()
        await onMain {
            let reloads = Tally()
            let publisher = TodaySnapshotPublisher(
                store: store, reload: reloads.add, now: { Self.morning })
            XCTAssertFalse(publisher.publish(listings: nil, fetchedAt: nil))
            XCTAssertFalse(publisher.refresh(isSignedIn: true) { nil })
            XCTAssertNil(store.read())
            XCTAssertEqual(reloads.count, 0)
        }
    }

    /// Without an app group — sideloaded without the entitlement — nothing is written and nothing
    /// fails.
    func testNoAppGroupIsQuietlyNothing() async {
        await onMain {
            let reloads = Tally()
            let publisher = TodaySnapshotPublisher(store: nil, reload: reloads.add)
            XCTAssertFalse(publisher.publish(listings: [Self.listing("2026-10-13")], fetchedAt: nil))
            XCTAssertFalse(publisher.signedOut())
            XCTAssertFalse(publisher.refresh(isSignedIn: true) { ([], nil) })
            XCTAssertEqual(reloads.count, 0)
        }
    }

    /// Coming back the same day reads nothing; coming back on a new day moves the week along
    /// from the cached list, with no fetch.
    func testReturningOnANewDayMovesTheWeekAlong() async throws {
        let store = try makeStore()
        await onMain {
            let clock = Clock(Self.morning)
            let publisher = TodaySnapshotPublisher(store: store, reload: {}, now: clock.read)
            let rows = [Self.listing("2026-10-13", caseID: "tue"), Self.listing("2026-10-14", caseID: "wed")]
            publisher.publish(listings: rows, fetchedAt: Self.morning)

            var reads = 0
            XCTAssertFalse(publisher.refresh(isSignedIn: true) { reads += 1; return (rows, Self.morning) })
            XCTAssertEqual(reads, 0, "today's snapshot stands; the cache is not even read")

            clock.set(TodaySnapshotTests.midnightIntoWednesday)
            XCTAssertTrue(publisher.refresh(isSignedIn: true) { reads += 1; return (rows, Self.morning) })
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(store.read()?.firstDay, "2026-10-14")
            XCTAssertEqual(store.read()?.days.map(\.day), ["2026-10-14"])
        }
    }

    /// Signing out replaces the account's listings with an empty, signed-out snapshot — once.
    func testSigningOutClearsTheSnapshot() async throws {
        let store = try makeStore()
        await onMain {
            let reloads = Tally()
            let publisher = TodaySnapshotPublisher(
                store: store, reload: reloads.add, now: { Self.morning })
            publisher.publish(listings: [Self.listing("2026-10-13")], fetchedAt: Self.morning)

            XCTAssertTrue(publisher.signedOut())
            let cleared = store.read()
            XCTAssertEqual(cleared?.isSignedIn, false)
            XCTAssertEqual(cleared?.days, [])
            XCTAssertNil(cleared?.fetchedAt)
            XCTAssertEqual(TodayGlance.decide(cleared, now: Self.morning), .openApp)
            XCTAssertEqual(reloads.count, 2)

            XCTAssertFalse(publisher.signedOut(), "already clear")
            XCTAssertFalse(publisher.refresh(isSignedIn: false) { nil })
            XCTAssertEqual(reloads.count, 2)
        }
    }

    /// Signed in again after a sign-out, the next return writes the new account's week.
    func testASignInAfterASignOutIsWrittenOnReturn() async throws {
        let store = try makeStore()
        await onMain {
            let publisher = TodaySnapshotPublisher(store: store, reload: {}, now: { Self.morning })
            publisher.signedOut()
            XCTAssertTrue(publisher.refresh(isSignedIn: true) { ([Self.listing("2026-10-13")], Self.morning) })
            XCTAssertEqual(store.read()?.isSignedIn, true)
        }
    }

    // MARK: - What Siri says

    func testSignedOutAsksToSignInFirst() {
        let answer = ListedDayAnswer.make(
            day: .today, isSignedIn: false, listings: [Self.listing("2026-10-13")],
            fetchedAt: Self.morning, now: Self.morning)
        XCTAssertEqual(answer.dialog, "Sign in to Emperor first.")
        XCTAssertTrue(answer.matters.isEmpty, "nothing about the matters to a signed-out phone")
    }

    func testNothingCachedSaysToOpenTheApp() {
        let answer = ListedDayAnswer.make(
            day: .today, isSignedIn: true, listings: nil, fetchedAt: nil, now: Self.morning)
        XCTAssertEqual(answer.dialog, ListedDayAnswer.Copy.notLoaded)
        XCTAssertNil(answer.day)
    }

    func testOneMatterIsNamedWithItsCourtItemAndTime() {
        let answer = ListedDayAnswer.make(
            day: .today, isSignedIn: true,
            listings: [Self.listing("2026-10-13", time: "10:30 AM")],
            fetchedAt: Self.morning, now: Self.morning)
        XCTAssertEqual(
            answer.dialog,
            "1 of your matters is listed today: Bakshi v. State of Maharashtra, Court 12, item 7, at 10:30 AM.")
        XCTAssertEqual(answer.total, 1)
        XCTAssertEqual(answer.day, "2026-10-13")
        XCTAssertNil(answer.age)
    }

    /// A busy day: three named in the day's order, the rest counted; the snippet lists four.
    func testABusyDayNamesThreeAndCountsTheRest() {
        let rows = (1...5).map {
            Self.listing("2026-10-13", caseID: "c\($0)", title: "Matter \($0)", itemNo: String($0))
        }
        let answer = ListedDayAnswer.make(
            day: .today, isSignedIn: true, listings: rows.reversed(), fetchedAt: Self.morning,
            now: Self.morning)
        XCTAssertEqual(answer.dialog, """
            5 of your matters are listed today: Matter 1, Court 12, item 1; Matter 2, Court 12, \
            item 2; Matter 3, Court 12, item 3; and 2 more.
            """)
        XCTAssertEqual(answer.matters.map(\.caseID), ["c1", "c2", "c3", "c4"])
        XCTAssertEqual(answer.total, 5)
    }

    /// Tomorrow is India's tomorrow, on whichever side of India's midnight the question is asked.
    func testTomorrowIsIndiasTomorrow() {
        let rows = [Self.listing("2026-10-14", caseID: "wed"), Self.listing("2026-10-15", caseID: "thu")]
        let beforeMidnight = ListedDayAnswer.make(
            day: .tomorrow, isSignedIn: true, listings: rows, fetchedAt: nil,
            now: TodaySnapshotTests.lastSecondOfTuesday)
        let afterMidnight = ListedDayAnswer.make(
            day: .tomorrow, isSignedIn: true, listings: rows, fetchedAt: nil,
            now: TodaySnapshotTests.midnightIntoWednesday)
        XCTAssertEqual(beforeMidnight.day, "2026-10-14")
        XCTAssertEqual(beforeMidnight.matters.map(\.caseID), ["wed"])
        XCTAssertTrue(beforeMidnight.dialog.contains("listed tomorrow"))
        XCTAssertEqual(afterMidnight.day, "2026-10-15")
        XCTAssertEqual(afterMidnight.matters.map(\.caseID), ["thu"])
    }

    /// Nothing listed is never "you're free": it names the next listed day and says to confirm
    /// with the court.
    func testAnEmptyDayNamesTheNextAndSaysToConfirm() {
        let answer = ListedDayAnswer.make(
            day: .today, isSignedIn: true,
            listings: [
                Self.listing("2026-10-10", caseID: "past"),
                Self.listing("2026-10-15", caseID: "a"), Self.listing("2026-10-15", caseID: "b"),
                Self.listing("2026-11-02", caseID: "later"),
            ],
            fetchedAt: Self.morning, now: Self.morning)
        XCTAssertEqual(answer.dialog, """
            None of your matters are listed today. The next is on Thursday 15 October: 2 matters. \
            Always confirm against the court's official cause list.
            """)
        XCTAssertEqual(answer.next?.day, "2026-10-15")
        XCTAssertEqual(answer.total, 0)
    }

    func testAnEmptyDayWithNothingAheadStillSaysToConfirm() {
        let answer = ListedDayAnswer.make(
            day: .tomorrow, isSignedIn: true, listings: [Self.listing("2026-10-01")],
            fetchedAt: Self.morning, now: Self.morning)
        XCTAssertEqual(answer.dialog, """
            None of your matters are listed tomorrow. Always confirm against the court's official \
            cause list.
            """)
        XCTAssertNil(answer.next)
    }

    /// A list older than six hours says how old.
    func testAStaleCacheSaysHowOld() {
        let answer = ListedDayAnswer.make(
            day: .today, isSignedIn: true, listings: [Self.listing("2026-10-13")],
            fetchedAt: TodaySnapshotTests.at("2026-10-11T03:30:00Z"), now: Self.morning)
        XCTAssertTrue(
            answer.dialog.hasSuffix("These listings were last updated 2 days ago."), answer.dialog)
        XCTAssertEqual(answer.age, "Updated 2 days ago")
    }

    // MARK: - The app-icon badge

    /// Marking read on the Updates screen brings the badge to the server's new count at once.
    func testTheBadgeFollowsTheUpdatesScreen() async {
        await onMain {
            let (coordinator, scheduler) = Self.coordinator(enabled: true)
            await coordinator.unreadCountChanged(2)
            XCTAssertEqual(scheduler.badge, 2)
            await coordinator.unreadCountChanged(0)
            XCTAssertEqual(scheduler.badge, 0)
        }
    }

    /// With notifications off, or refused in iOS Settings, the badge stays as it was cleared.
    func testTheBadgeIsLeftAloneWhileNotificationsAreOff() async {
        await onMain {
            let (off, offScheduler) = Self.coordinator(enabled: false)
            await off.unreadCountChanged(3)
            XCTAssertNil(offScheduler.badge)

            let (denied, deniedScheduler) = Self.coordinator(enabled: true, authorization: .denied)
            await denied.unreadCountChanged(3)
            XCTAssertNil(deniedScheduler.badge)
        }
    }

    /// The Updates screen reports each count the server gives — after loading, after marking
    /// one read, after marking all read — and not the optimistic ones in between.
    func testTheUpdatesScreenReportsTheServersCount() async {
        await onMain {
            let service = FakeNotifications()
            service.notifications = [
                AppNotification(id: "n1", read: 0), AppNotification(id: "n2", read: 0),
            ]
            service.unreadCount = 2
            let reported = Tally()
            let model = NotificationsViewModel(service: service, onUnreadCount: reported.record)

            await model.load()
            service.unreadCount = 1
            await model.markRead(model.notifications[0])
            service.unreadCount = 0
            await model.markAllRead()
            XCTAssertEqual(reported.values, [2, 1, 0])

            // A count the server could not give is not reported.
            service.error = APIError.server(status: 500, message: "down")
            await model.refreshUnreadCount()
            XCTAssertEqual(reported.values, [2, 1, 0])
        }
    }

    // MARK: - Helpers

    @MainActor
    private static func coordinator(
        enabled: Bool, authorization: NotificationAuthorization = .allowed
    ) -> (NotificationCoordinator, FakeNotificationScheduler) {
        let store = InMemoryPreferenceStore()
        var preferences = NotificationPreferences()
        preferences.isEnabled = enabled
        preferences.save(to: store)
        let scheduler = FakeNotificationScheduler(authorization: authorization)
        return (NotificationCoordinator(store: store, scheduler: scheduler), scheduler)
    }

    private func makeStore() throws -> TodaySnapshotStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("today-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return TodaySnapshotStore(directory: url)
    }
}

/// Counts calls, and keeps what they were called with.
@MainActor
private final class Tally {
    private(set) var count = 0
    private(set) var values: [Int] = []

    func add() { count += 1 }
    func record(_ value: Int) { values.append(value) }
}

/// A clock a test moves by hand.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(_ start: Date) { now = start }

    var read: @Sendable () -> Date { { [self] in lock.withLock { now } } }
    func advance(_ seconds: TimeInterval) { lock.withLock { now += seconds } }
    func set(_ date: Date) { lock.withLock { now = date } }
}

/// Linux XCTest cannot call a `@MainActor` test method, so each test hops here instead.
@MainActor
private func onMain(_ body: @MainActor () async -> Void) async {
    await body()
}
