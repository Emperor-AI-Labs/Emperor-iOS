import XCTest
@testable import EmperorCore

/// What the device schedules from the cause list, and when — the decisions behind every local
/// notification the app sends.
final class NotificationPlannerTests: XCTestCase {

    /// An instant written in UTC, so each test says exactly which moment it means.
    static func at(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    /// 13 Oct 2026, 09:00 IST — after the morning briefing, well before the evening reminder.
    static let midMorning = at("2026-10-13T03:30:00Z")

    static func listing(
        _ day: String, caseID: String = "case_1", title: String = "Bakshi v. State of Maharashtra",
        courtNo: String? = "Court No. 12", itemNo: String? = "7", time: String? = nil,
        source: String = "causelist"
    ) -> CauseListing {
        var listing = CauseListing(date: day, caseID: caseID)
        listing.title = title
        listing.courtName = "Bombay High Court"
        listing.courtNo = courtNo
        listing.itemNo = itemNo
        listing.time = time
        listing.scraped = true
        listing.source = source
        return listing
    }

    static var on: NotificationPreferences {
        var preferences = NotificationPreferences()
        preferences.isEnabled = true
        return preferences
    }

    // MARK: - What a notification says

    func testABriefingNamesTheMatterWithItsCourtAndItem() throws {
        let plan = NotificationPlanner.plan(
            listings: [Self.listing("2026-10-14")], preferences: Self.on, now: Self.midMorning)
        let briefing = try XCTUnwrap(plan.first { $0.kind == .briefing })
        XCTAssertEqual(briefing.title, "1 matter listed today")
        XCTAssertEqual(briefing.body, "Bakshi v. State of Maharashtra — Court 12, item 7")
        XCTAssertEqual(briefing.target, .calendar(day: "2026-10-14"))
        XCTAssertEqual(briefing.identifier, "hearing.briefing.2026-10-14")

        let evening = try XCTUnwrap(plan.first { $0.kind == .evening })
        XCTAssertEqual(evening.title, "Tomorrow: 1 matter listed")
        XCTAssertEqual(evening.body, briefing.body)
        XCTAssertEqual(evening.target, .calendar(day: "2026-10-14"), "opens on the day listed")
    }

    /// A busy day: the count is the headline, three matters are named in the order the day
    /// runs, and the rest are counted rather than dropped silently.
    func testADayWithTwelveListingsNamesThreeAndCountsTheRest() throws {
        let rows = (1...12).map { number in
            Self.listing(
                "2026-10-14", caseID: "case_\(number)", title: "Matter \(number)",
                courtNo: "Court No. 4", itemNo: String(13 - number))
        }
        let plan = NotificationPlanner.plan(
            listings: rows.shuffled(), preferences: Self.on, now: Self.midMorning)
        let briefing = try XCTUnwrap(plan.first { $0.kind == .briefing })
        XCTAssertEqual(briefing.title, "12 matters listed today")
        XCTAssertEqual(briefing.body.components(separatedBy: "\n"), [
            "Matter 12 — Court 4, item 1",
            "Matter 11 — Court 4, item 2",
            "Matter 10 — Court 4, item 3",
            "and 9 more",
        ], "by item, as the day will be called — not the order the server sent")
    }

    /// The Calendar's order: a timed listing before untimed ones, whatever its item number.
    func testMattersAreNamedInTheOrderTheCalendarShowsThem() throws {
        let rows = [
            Self.listing("2026-10-14", caseID: "a", title: "Untimed", itemNo: "1"),
            Self.listing("2026-10-14", caseID: "b", title: "Timed", itemNo: "40", time: "10:30 AM"),
        ]
        let plan = NotificationPlanner.plan(listings: rows, preferences: Self.on, now: Self.midMorning)
        let briefing = try XCTUnwrap(plan.first { $0.kind == .briefing })
        XCTAssertTrue(briefing.body.hasPrefix("Timed —"), briefing.body)
    }

    /// One matter listed twice on a day — the published list and the case's next date — is one
    /// matter, as the Calendar shows it.
    func testAMatterListedTwiceOnADayIsCountedOnce() throws {
        let plan = NotificationPlanner.plan(
            listings: [
                Self.listing("2026-10-14"),
                Self.listing("2026-10-14", courtNo: nil, itemNo: nil, source: "next"),
            ],
            preferences: Self.on, now: Self.midMorning)
        let briefing = try XCTUnwrap(plan.first { $0.kind == .briefing })
        XCTAssertEqual(briefing.title, "1 matter listed today")
        XCTAssertEqual(briefing.body, "Bakshi v. State of Maharashtra — Court 12, item 7",
                       "the row the court's list printed wins")
    }

    func testALineStatesOnlyWhatTheListPrinted() {
        XCTAssertEqual(
            NotificationPlanner.line(Self.listing("2026-10-14", courtNo: nil)),
            "Bakshi v. State of Maharashtra — item 7")
        XCTAssertEqual(
            NotificationPlanner.line(Self.listing("2026-10-14", itemNo: nil)),
            "Bakshi v. State of Maharashtra — Court 12")
        XCTAssertEqual(
            NotificationPlanner.line(Self.listing("2026-10-14", courtNo: nil, itemNo: nil)),
            "Bakshi v. State of Maharashtra", "no room or item is invented")
    }

    func testALongTitleIsClipped() {
        let long = String(repeating: "Very Long Party Name Private Limited ", count: 4)
        let line = NotificationPlanner.line(Self.listing("2026-10-14", title: long))
        let title = line.components(separatedBy: " — ").first ?? ""
        XCTAssertLessThanOrEqual(title.count, NotificationPlanner.titleLength)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertTrue(line.hasSuffix("Court 12, item 7"), "the location survives the clip")
    }

    // MARK: - When

    /// 08:00 in India, as an instant — not 08:00 wherever the phone happens to be.
    func testTheBriefingIsAtTheChosenTimeInIndia() throws {
        let plan = NotificationPlanner.plan(
            listings: [Self.listing("2026-10-14")], preferences: Self.on, now: Self.midMorning)
        XCTAssertEqual(
            plan.first { $0.kind == .briefing }?.fireDate, Self.at("2026-10-14T02:30:00Z"))
        XCTAssertEqual(
            plan.first { $0.kind == .evening }?.fireDate, Self.at("2026-10-13T13:30:00Z"),
            "19:00 IST the day before")
    }

    func testAChosenTimeIsHonoured() {
        var preferences = Self.on
        preferences.briefingMinutes = 6 * 60 + 45
        preferences.reminderMinutes = 21 * 60
        let plan = NotificationPlanner.plan(
            listings: [Self.listing("2026-10-14")], preferences: preferences, now: Self.midMorning)
        XCTAssertEqual(
            plan.first { $0.kind == .briefing }?.fireDate, Self.at("2026-10-14T01:15:00Z"))
        XCTAssertEqual(
            plan.first { $0.kind == .evening }?.fireDate, Self.at("2026-10-13T15:30:00Z"))
    }

    /// One minute before midnight in India, "today" is still the 13th: the 14th's reminder the
    /// evening before has gone, its briefing has not.
    func testJustBeforeMidnightInIndia() {
        let now = Self.at("2026-10-13T18:29:00Z")   // 23:59 IST, 13 Oct
        let plan = NotificationPlanner.plan(
            listings: [Self.listing("2026-10-13"), Self.listing("2026-10-14", caseID: "case_2")],
            preferences: Self.on, now: now)
        XCTAssertEqual(plan.map(\.identifier), ["hearing.briefing.2026-10-14"])
    }

    /// Two minutes later it is the 14th in India — though still the 13th in UTC, and in New
    /// York. Yesterday's listing is gone; today's briefing is still to come; and the two weeks
    /// run from India's today, so they reach the 27th.
    func testJustAfterMidnightInIndia() {
        let now = Self.at("2026-10-13T18:31:00Z")   // 00:01 IST, 14 Oct
        let plan = NotificationPlanner.plan(
            listings: [
                Self.listing("2026-10-13"), Self.listing("2026-10-14", caseID: "case_2"),
                Self.listing("2026-10-15", caseID: "case_3"),
                Self.listing("2026-10-27", caseID: "case_4"),
                Self.listing("2026-10-28", caseID: "case_5"),
            ],
            preferences: Self.on, now: now)
        XCTAssertEqual(plan.map(\.identifier), [
            "hearing.briefing.2026-10-14",
            "hearing.evening.2026-10-15",
            "hearing.briefing.2026-10-15",
            "hearing.evening.2026-10-27",
            "hearing.briefing.2026-10-27",
        ])
    }

    /// Nothing is ever scheduled for a moment already past.
    func testNothingIsScheduledInThePast() {
        let justAfterBriefing = Self.at("2026-10-14T02:31:00Z")   // 08:01 IST, 14 Oct
        let plan = NotificationPlanner.plan(
            listings: [Self.listing("2026-10-14"), Self.listing("2026-10-15", caseID: "case_2")],
            preferences: Self.on, now: justAfterBriefing)
        XCTAssertFalse(plan.contains { $0.identifier == "hearing.briefing.2026-10-14" })
        XCTAssertTrue(plan.allSatisfy { ($0.fireDate ?? .distantPast) > justAfterBriefing })
        XCTAssertEqual(plan.count, 2, "the 15th's evening reminder and briefing")
    }

    func testOnlyTheNextTwoWeeksArePlanned() {
        let plan = NotificationPlanner.plan(
            listings: [Self.listing("2026-10-26"), Self.listing("2026-10-27", caseID: "case_2")],
            preferences: Self.on, now: Self.midMorning)
        // 13 Oct is day 1 of 14, so the 26th is the last day in the window.
        XCTAssertEqual(plan.map(\.identifier),
                       ["hearing.evening.2026-10-26", "hearing.briefing.2026-10-26"])
    }

    func testAListingWithAnUnreadableDateIsSkipped() {
        let plan = NotificationPlanner.plan(
            listings: [Self.listing("2026-10-14T00:00:00"), Self.listing("next week")],
            preferences: Self.on, now: Self.midMorning)
        XCTAssertTrue(plan.isEmpty)
    }

    // MARK: - Nothing to say

    /// A day with nothing listed gets nothing — never a message that the day is clear.
    func testAnEmptyCauseListPlansNothing() {
        XCTAssertTrue(NotificationPlanner.plan(
            listings: [], preferences: Self.on, now: Self.midMorning).isEmpty)
    }

    func testTheSwitchesAreHonoured() {
        let listings = [Self.listing("2026-10-14")]
        var off = Self.on
        off.isEnabled = false
        XCTAssertTrue(NotificationPlanner.plan(
            listings: listings, preferences: off, now: Self.midMorning).isEmpty,
            "the master switch wins over the rest")

        var noBriefing = Self.on
        noBriefing.morningBriefing = false
        XCTAssertEqual(NotificationPlanner.plan(
            listings: listings, preferences: noBriefing, now: Self.midMorning).map(\.kind),
            [.evening])

        var noEvening = Self.on
        noEvening.eveningReminder = false
        XCTAssertEqual(NotificationPlanner.plan(
            listings: listings, preferences: noEvening, now: Self.midMorning).map(\.kind),
            [.briefing])
    }

    // MARK: - Limits and identity

    /// iOS keeps only the soonest 64. The plan stays under that with a margin, and what it gives
    /// up is the furthest away.
    func testThePlanStaysUnderTheSystemLimitAndDropsTheFurthest() throws {
        let days = (0..<60).map { offset in
            WireDate.dayKey(Self.midMorning.addingTimeInterval(TimeInterval(offset) * 86_400))
        }
        let listings = days.enumerated().map { Self.listing($1, caseID: "case_\($0)") }
        let plan = NotificationPlanner.plan(
            listings: listings, preferences: Self.on, now: Self.midMorning, horizonDays: 60)

        XCTAssertEqual(plan.count, NotificationPlanner.pendingLimit)
        XCTAssertLessThan(NotificationPlanner.pendingLimit, 64, "a margin under iOS's limit")
        let fireDates = plan.compactMap(\.fireDate)
        XCTAssertEqual(fireDates, fireDates.sorted(), "soonest first")
        // Everything kept fires before everything dropped.
        let unlimited = NotificationPlanner.plan(
            listings: listings, preferences: Self.on, now: Self.midMorning,
            horizonDays: 60, limit: 1_000)
        let dropped = unlimited.dropFirst(NotificationPlanner.pendingLimit)
        XCTAssertFalse(dropped.isEmpty)
        let lastKept = try XCTUnwrap(fireDates.last)
        XCTAssertTrue(dropped.allSatisfy { ($0.fireDate ?? .distantPast) >= lastKept })
    }

    /// The default two weeks, every day listed, fits without dropping anything.
    func testTwoBusyWeeksFitWhole() {
        let listings = (0..<14).map { offset in
            Self.listing(
                WireDate.dayKey(Self.midMorning.addingTimeInterval(TimeInterval(offset) * 86_400)),
                caseID: "case_\(offset)")
        }
        let plan = NotificationPlanner.plan(listings: listings, preferences: Self.on, now: Self.midMorning)
        // Today's briefing (08:00) has passed; today's "evening before" was yesterday.
        XCTAssertEqual(plan.count, 13 * 2)
        XCTAssertEqual(Set(plan.map(\.identifier)).count, plan.count, "no identifier twice")
    }

    /// The same inputs give the same plan — so a re-plan that changes nothing is recognisable,
    /// and identifiers replace rather than duplicate.
    func testReplanningIsIdempotent() {
        let listings = [Self.listing("2026-10-14"), Self.listing("2026-10-15", caseID: "case_2")]
        let first = NotificationPlanner.plan(listings: listings, preferences: Self.on, now: Self.midMorning)
        let second = NotificationPlanner.plan(
            listings: listings.reversed(), preferences: Self.on, now: Self.midMorning)
        XCTAssertEqual(first, second)

        var later = Self.on
        later.briefingMinutes = 9 * 60
        let moved = NotificationPlanner.plan(listings: listings, preferences: later, now: Self.midMorning)
        XCTAssertEqual(moved.map(\.identifier).sorted(), first.map(\.identifier).sorted(),
                       "a new time moves a notification; it does not add one")
    }

    // MARK: - The test notification

    func testTheTestSaysWhenTheBriefingComes() {
        var preferences = Self.on
        preferences.briefingMinutes = 7 * 60 + 30
        let test = NotificationPlanner.test(preferences: preferences)
        XCTAssertNil(test.fireDate, "at once")
        XCTAssertNil(test.target)
        XCTAssertTrue(test.body.contains("07:30 IST"), test.body)
        XCTAssertFalse(test.identifier.hasPrefix(NotificationPlanner.identifierPrefix),
                       "a re-plan must not withdraw it")
    }

    // MARK: - Taps

    func testATapTargetSurvivesTheRoundTrip() {
        for target in [NotificationTarget.calendar(day: "2026-10-14"), .updates] {
            XCTAssertEqual(NotificationTarget(userInfo: target.userInfo), target)
        }
        XCTAssertNil(NotificationTarget(userInfo: ["target": "calendar", "day": "2026-02-30"]))
        XCTAssertNil(NotificationTarget(userInfo: ["target": "calendar"]))
        XCTAssertNil(NotificationTarget(userInfo: ["target": "somewhere"]))
        XCTAssertNil(NotificationTarget(userInfo: [:]))
    }
}

/// The preferences, as stored.
final class NotificationPreferencesTests: XCTestCase {

    /// Off until asked for; everything under the switch on once it is.
    func testTheDefaults() {
        let preferences = NotificationPreferences.stored(in: InMemoryPreferenceStore())
        XCTAssertFalse(preferences.isEnabled, "never on without being asked")
        XCTAssertTrue(preferences.morningBriefing)
        XCTAssertTrue(preferences.eveningReminder)
        XCTAssertTrue(preferences.updates)
        XCTAssertEqual(preferences.briefingMinutes, 8 * 60)
        XCTAssertEqual(preferences.reminderMinutes, 19 * 60)
    }

    func testAChoiceIsStoredAndReadBack() {
        let store = InMemoryPreferenceStore()
        var preferences = NotificationPreferences()
        preferences.isEnabled = true
        preferences.eveningReminder = false
        preferences.briefingMinutes = 7 * 60 + 15
        preferences.save(to: store)
        XCTAssertEqual(NotificationPreferences.stored(in: store), preferences)
    }

    /// A value written before a switch existed keeps every choice it does hold.
    func testAnOlderValueKeepsWhatItHas() {
        let store = InMemoryPreferenceStore()
        store.setString(#"{"isEnabled":true,"updates":false}"#, for: NotificationPreferences.storageKey)
        let preferences = NotificationPreferences.stored(in: store)
        XCTAssertTrue(preferences.isEnabled)
        XCTAssertFalse(preferences.updates)
        XCTAssertTrue(preferences.morningBriefing, "absent, so the default")
    }

    func testAnUnreadableValueFallsBackToTheDefaults() {
        let store = InMemoryPreferenceStore()
        store.setString("not json", for: NotificationPreferences.storageKey)
        XCTAssertEqual(NotificationPreferences.stored(in: store), NotificationPreferences())

        store.setString(#"{"isEnabled":true,"briefingMinutes":5000}"#,
                        for: NotificationPreferences.storageKey)
        XCTAssertEqual(NotificationPreferences.stored(in: store).briefingMinutes, 8 * 60,
                       "a time outside the day would schedule on the wrong date")
    }

    func testClockTimes() {
        XCTAssertEqual(NotificationPreferences.clock(8 * 60), "08:00")
        XCTAssertEqual(NotificationPreferences.clock(19 * 60 + 5), "19:05")
        XCTAssertEqual(NotificationPreferences.minutes(fromClock: "08:00"), 480)
        XCTAssertEqual(NotificationPreferences.minutes(fromClock: "23:59"), 1439)
        XCTAssertNil(NotificationPreferences.minutes(fromClock: "8:00"))
        XCTAssertNil(NotificationPreferences.minutes(fromClock: "24:00"))
        XCTAssertNil(NotificationPreferences.minutes(fromClock: nil))
    }

    /// A time picker showing IST hands back an instant; only its time of day in India is read —
    /// the same whichever zone the phone is in.
    func testATimeOfDayIsReadInIndia() {
        let instant = NotificationPlannerTests.at("2026-10-13T01:15:00Z")
        XCTAssertEqual(NotificationPreferences.minutesInIndia(of: instant), 6 * 60 + 45)
        XCTAssertEqual(
            NotificationPreferences.instant(minutes: 6 * 60 + 45, on: "2026-10-13"), instant)
        XCTAssertNil(NotificationPreferences.instant(minutes: 6 * 60, on: "not a day"))
    }
}

/// What in the feed is announced.
final class UpdateAlertsTests: XCTestCase {

    private func item(_ id: String, read: Bool = false, title: String? = nil) -> AppNotification {
        AppNotification(id: id, title: title ?? "Update \(id)", read: read ? 1 : 0)
    }

    /// The first look takes the feed as it stands: two hundred rows of history are not news.
    func testTheFirstLookAnnouncesNothing() {
        let feed = (1...200).map { item("n\($0)") }
        let (alerts, seen) = UpdateAlerts.diff(feed: feed, seen: nil)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(seen, feed.map(\.id))
    }

    func testWhatArrivedSinceIsAnnouncedNewestFirst() {
        let (_, seen) = UpdateAlerts.diff(feed: [item("n1")], seen: nil)
        let (alerts, next) = UpdateAlerts.diff(
            feed: [item("n3"), item("n2"), item("n1")], seen: seen)
        XCTAssertEqual(alerts.map(\.id), ["n3", "n2"])
        XCTAssertEqual(next, ["n3", "n2", "n1"])

        let (again, _) = UpdateAlerts.diff(feed: [item("n3"), item("n2"), item("n1")], seen: next)
        XCTAssertTrue(again.isEmpty, "nothing is announced twice")
    }

    /// Read on the web already: seen by the person, if not by this phone.
    func testARowAlreadyReadIsNotAnnounced() {
        let (alerts, seen) = UpdateAlerts.diff(
            feed: [item("n2", read: true), item("n1")], seen: [])
        XCTAssertEqual(alerts.map(\.id), ["n1"])
        XCTAssertEqual(seen, ["n2", "n1"])
    }

    func testABurstIsCapped() {
        let feed = (1...10).reversed().map { item("n\($0)") }
        let (alerts, seen) = UpdateAlerts.diff(feed: feed, seen: [])
        XCTAssertEqual(alerts.map(\.id), ["n10", "n9", "n8"])
        XCTAssertEqual(seen.count, 10, "all of them are accounted for, announced or not")
    }

    /// An empty answer from a server having a bad moment does not wipe the memory — or every
    /// row would be announced as new when it recovers.
    func testAnEmptyFeedForgetsNothing() {
        let (_, seen) = UpdateAlerts.diff(feed: [item("n2"), item("n1")], seen: nil)
        let (blank, afterBlank) = UpdateAlerts.diff(feed: [], seen: seen)
        XCTAssertTrue(blank.isEmpty)
        XCTAssertEqual(afterBlank, ["n2", "n1"])
        let (recovered, _) = UpdateAlerts.diff(feed: [item("n2"), item("n1")], seen: afterBlank)
        XCTAssertTrue(recovered.isEmpty)
    }

    func testTheMemoryIsBounded() {
        let old = (0..<UpdateAlerts.rememberedLimit).map { "old\($0)" }
        let (_, seen) = UpdateAlerts.diff(feed: [item("new")], seen: old)
        XCTAssertEqual(seen.count, UpdateAlerts.rememberedLimit)
        XCTAssertEqual(seen.first, "new", "the current feed is kept first")
    }

    func testAnUpdateSaysWhatTheFeedSays() {
        var row = item("n9", title: "  Order uploaded  ")
        row.body = "Bakshi v. State — order dated 12 Oct"
        let notification = UpdateAlerts.notification(for: row)
        XCTAssertEqual(notification.title, "Order uploaded")
        XCTAssertEqual(notification.body, "Bakshi v. State — order dated 12 Oct")
        XCTAssertEqual(notification.identifier, "update.n9")
        XCTAssertEqual(notification.target, .updates)
        XCTAssertNil(notification.fireDate)

        let untitled = UpdateAlerts.notification(
            for: AppNotification(id: "n10", type: "auction", title: " "))
        XCTAssertEqual(untitled.title, "Auction", "falls back to the kind")
    }

    /// Remembered per account: someone else signing in on this phone starts from a first look.
    func testWhatWasSeenBelongsToOneAccount() {
        let store = InMemoryPreferenceStore()
        SeenUpdates(userID: 1, ids: ["n1"]).save(to: store)
        XCTAssertEqual(SeenUpdates.stored(in: store, userID: 1), ["n1"])
        XCTAssertNil(SeenUpdates.stored(in: store, userID: 2))
        SeenUpdates.forget(in: store)
        XCTAssertNil(SeenUpdates.stored(in: store, userID: 1))
    }
}
