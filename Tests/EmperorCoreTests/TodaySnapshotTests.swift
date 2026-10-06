import XCTest
@testable import EmperorCore

/// The Today widget's half of the core: India's days, the snapshot the app writes, and what the
/// widget decides to show from it at any moment.
final class TodaySnapshotTests: XCTestCase {

    // MARK: - Moments

    /// An instant written in UTC, so each test says exactly which moment it means.
    static func at(_ iso: String) -> Date { NotificationPlannerTests.at(iso) }

    /// 13 Oct 2026, 09:00 IST.
    static let tuesdayMorning = at("2026-10-13T03:30:00Z")
    /// The last second of Tuesday 13 October in India — still Tuesday in court.
    static let lastSecondOfTuesday = at("2026-10-13T18:29:59Z")
    /// Midnight in India: Wednesday 14 October has begun, though it is still the 13th in UTC.
    static let midnightIntoWednesday = at("2026-10-13T18:30:00Z")

    static func listing(
        _ day: String, caseID: String = "case_1", title: String = "Bakshi v. State of Maharashtra",
        itemNo: String? = "7", time: String? = nil
    ) -> CauseListing {
        NotificationPlannerTests.listing(day, caseID: caseID, title: title, itemNo: itemNo, time: time)
    }

    static func matter(_ caseID: String, title: String = "Matter") -> TodayMatter {
        TodayMatter(caseID: caseID, title: title, court: nil, room: nil, item: nil, time: nil)
    }

    static func snapshot(
        first: String = "2026-10-13", last: String = "2026-10-19", days: [TodayDay],
        signedIn: Bool = true
    ) -> TodaySnapshot {
        TodaySnapshot(
            isSignedIn: signedIn, generatedAt: tuesdayMorning, fetchedAt: tuesdayMorning,
            firstDay: first, lastDay: last, days: days)
    }

    static func day(_ key: String, _ caseIDs: String...) -> TodayDay {
        TodayDay(day: key, total: caseIDs.count, matters: caseIDs.map { matter($0) })
    }

    // MARK: - India's days

    /// The day turns at midnight in India, not in UTC and not in the phone's zone.
    func testTheDayTurnsAtMidnightInIndia() {
        XCTAssertEqual(IndianDay.key(Self.lastSecondOfTuesday), "2026-10-13")
        XCTAssertEqual(IndianDay.key(Self.midnightIntoWednesday), "2026-10-14")
    }

    /// The widget's copy of the rule must give `WireDate`'s answers, or the widget and the app
    /// would disagree about which day a hearing is on.
    func testIndianDaysAgreeWithWireDate() {
        let instants = [
            Self.lastSecondOfTuesday, Self.midnightIntoWednesday, Self.tuesdayMorning,
            Self.at("2026-12-31T18:29:59Z"), Self.at("2026-12-31T18:30:00Z"),
            Self.at("2028-02-28T20:00:00Z"), Self.at("2026-03-29T01:00:00Z"),
        ]
        for instant in instants {
            let key = IndianDay.key(instant)
            XCTAssertEqual(key, WireDate.dayKey(instant), "\(instant)")
            XCTAssertEqual(IndianDay.start(of: key), WireDate.parseDay(key), key)
        }
    }

    /// Not a day: refused, rather than rolled into some other day.
    func testOnlyRealDaysAreDays() {
        XCTAssertTrue(IndianDay.isValid("2028-02-29"))
        for bad in ["2026-02-30", "2027-02-29", "2026-10-1", "2026-10-13x", "13-10-2026", ""] {
            XCTAssertFalse(IndianDay.isValid(bad), bad)
        }
    }

    func testDaysAreAddedAcrossMonthsAndYears() {
        XCTAssertEqual(IndianDay.adding(1, to: "2026-12-31"), "2027-01-01")
        XCTAssertEqual(IndianDay.adding(1, to: "2028-02-28"), "2028-02-29")
        XCTAssertEqual(IndianDay.adding(-1, to: "2026-10-01"), "2026-09-30")
        XCTAssertNil(IndianDay.adding(1, to: "not a day"))
    }

    /// The next midnight is India's, and strictly after: at midnight itself the next one is a
    /// whole day away.
    func testTheNextMidnightIsIndias() {
        XCTAssertEqual(IndianDay.nextMidnight(after: Self.lastSecondOfTuesday), Self.midnightIntoWednesday)
        XCTAssertEqual(
            IndianDay.nextMidnight(after: Self.midnightIntoWednesday),
            Self.midnightIntoWednesday.addingTimeInterval(86_400))
    }

    func testDaysAreWrittenTheWayTheWidgetAndSiriSayThem() {
        XCTAssertEqual(IndianDay.short("2026-10-15"), "Thu 15 Oct")
        XCTAssertEqual(IndianDay.long("2026-10-15"), "Thursday 15 October")
        XCTAssertEqual(IndianDay.short("nonsense"), "nonsense", "shown as given, never as a guess")
    }

    // MARK: - Building the snapshot

    /// The week from today in India: yesterday's and next month's listings are not carried.
    func testTheSnapshotCarriesTheWeekFromToday() {
        let snapshot = TodaySnapshot.make(
            listings: [
                Self.listing("2026-10-12", caseID: "yesterday"),
                Self.listing("2026-10-13", caseID: "today"),
                Self.listing("2026-10-19", caseID: "sixDaysOn"),
                Self.listing("2026-10-20", caseID: "sevenDaysOn"),
            ],
            fetchedAt: Self.tuesdayMorning, now: Self.tuesdayMorning)

        XCTAssertTrue(snapshot.isSignedIn)
        XCTAssertEqual(snapshot.firstDay, "2026-10-13")
        XCTAssertEqual(snapshot.lastDay, "2026-10-19")
        XCTAssertEqual(snapshot.days.map(\.day), ["2026-10-13", "2026-10-19"])
        XCTAssertEqual(snapshot.days.flatMap { $0.matters.map(\.caseID) }, ["today", "sixDaysOn"])
        XCTAssertEqual(snapshot.fetchedAt, Self.tuesdayMorning)
    }

    /// Built a second before midnight, the week starts on Tuesday; a second after, on Wednesday.
    func testTheWeekStartsOnIndiasToday() {
        let rows = [Self.listing("2026-10-13", caseID: "tue"), Self.listing("2026-10-14", caseID: "wed")]
        let before = TodaySnapshot.make(listings: rows, fetchedAt: nil, now: Self.lastSecondOfTuesday)
        let after = TodaySnapshot.make(listings: rows, fetchedAt: nil, now: Self.midnightIntoWednesday)

        XCTAssertEqual(before.firstDay, "2026-10-13")
        XCTAssertEqual(before.days.map(\.day), ["2026-10-13", "2026-10-14"])
        XCTAssertEqual(after.firstDay, "2026-10-14")
        XCTAssertEqual(after.lastDay, "2026-10-20")
        XCTAssertEqual(after.days.map(\.day), ["2026-10-14"])
    }

    /// The Calendar's order for a day — timed first — and its one row per matter.
    func testADayRunsInTheCalendarsOrderWithOneRowPerMatter() throws {
        let snapshot = TodaySnapshot.make(
            listings: [
                Self.listing("2026-10-13", caseID: "untimed", itemNo: "1"),
                Self.listing("2026-10-13", caseID: "timed", itemNo: "40", time: "10:30 AM"),
                Self.listing("2026-10-13", caseID: "untimed", itemNo: "1"),
            ],
            fetchedAt: nil, now: Self.tuesdayMorning)
        let day = try XCTUnwrap(snapshot.days.first)
        XCTAssertEqual(day.matters.map(\.caseID), ["timed", "untimed"])
        XCTAssertEqual(day.total, 2)
    }

    /// A long day keeps the first few and the true count.
    func testALongDayKeepsTheCount() throws {
        let rows = (1...12).map {
            Self.listing("2026-10-13", caseID: "case_\($0)", itemNo: String($0))
        }
        let snapshot = TodaySnapshot.make(listings: rows, fetchedAt: nil, now: Self.tuesdayMorning)
        let day = try XCTUnwrap(snapshot.days.first)
        XCTAssertEqual(day.total, 12)
        XCTAssertEqual(day.matters.count, TodaySnapshot.mattersPerDay)
        XCTAssertEqual(day.matters.first?.caseID, "case_1", "the first of the day, by item")
    }

    /// The room, item and time are the ones the app's own row prints — never invented.
    func testAMatterSaysWhatTheAppsRowSays() throws {
        var unnumbered = Self.listing("2026-10-13", caseID: "b", itemNo: nil)
        unnumbered.courtNo = nil
        // A roster line, not a room: a court-published row never has a room read out of it.
        unnumbered.bench = "Court 236"
        let snapshot = TodaySnapshot.make(
            listings: [Self.listing("2026-10-13", caseID: "a", time: "10:30 AM"), unnumbered],
            fetchedAt: nil, now: Self.tuesdayMorning)
        let matters = try XCTUnwrap(snapshot.days.first?.matters)

        XCTAssertEqual(matters[0], TodayMatter(
            caseID: "a", title: "Bakshi v. State of Maharashtra", court: "Bombay High Court",
            room: "Court 12", item: "7", time: "10:30 AM"))
        XCTAssertNil(matters[1].room)
        XCTAssertNil(matters[1].item)
        XCTAssertNil(matters[1].time)
    }

    func testAVeryLongTitleIsClipped() {
        let title = String(repeating: "M/s. Something Private Limited & Ors. ", count: 10)
        let matter = TodayMatter(Self.listing("2026-10-13", title: title))
        XCTAssertLessThanOrEqual(matter.title.count, TodayMatter.titleLength)
        XCTAssertGreaterThan(matter.title.count, TodayMatter.titleLength - 5)
        XCTAssertTrue(matter.title.hasSuffix(".…"), "cut at a word, with no space before the ellipsis")
    }

    // MARK: - On disk

    /// Written and read back whole — and nothing in the file but what the widget draws.
    func testTheSnapshotRoundTripsAndCarriesNothingElse() throws {
        let directory = try temporaryDirectory()
        let store = TodaySnapshotStore(directory: directory)
        let snapshot = TodaySnapshot.make(
            listings: [Self.listing("2026-10-13", time: "10:30 AM")],
            fetchedAt: Self.tuesdayMorning, now: Self.tuesdayMorning)

        XCTAssertTrue(store.write(snapshot))
        XCTAssertEqual(store.read(), snapshot)

        let data = try Data(contentsOf: store.fileURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "version", "isSignedIn", "generatedAt", "fetchedAt", "firstDay", "lastDay", "days",
        ])
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["token", "userID", "userId", "email", "teamId"] {
            XCTAssertFalse(text.contains(forbidden), "the snapshot carries \(forbidden)")
        }
    }

    /// Anything unreadable is simply no snapshot — never a crash.
    func testAMissingOrForeignFileIsNoSnapshot() throws {
        let directory = try temporaryDirectory()
        let store = TodaySnapshotStore(directory: directory)
        XCTAssertNil(store.read(), "no file")

        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertNil(store.read(), "garbage")

        var future = Self.snapshot(days: [])
        future.version = TodaySnapshot.currentVersion + 1
        try TodaySnapshotStore.encoder.encode(future).write(to: store.fileURL)
        XCTAssertNil(store.read(), "a shape this build does not know")
    }

    /// A directory that cannot be written is a failed write, not a crash.
    func testAnUnwritableDirectoryFailsQuietly() throws {
        let file = try temporaryDirectory().appendingPathComponent("a-file")
        try Data().write(to: file)
        let store = TodaySnapshotStore(directory: file.appendingPathComponent("inside"))
        XCTAssertFalse(store.write(Self.snapshot(days: [])))
        XCTAssertNil(store.read())
    }

    // MARK: - What the widget shows

    func testNoSnapshotOrNobodySignedInSaysOpenTheApp() {
        XCTAssertEqual(TodayGlance.decide(nil, now: Self.tuesdayMorning), .openApp)
        XCTAssertEqual(
            TodayGlance.decide(.signedOut(at: Self.tuesdayMorning), now: Self.tuesdayMorning),
            .openApp)
        let signedOutWithDays = Self.snapshot(days: [Self.day("2026-10-13", "a")], signedIn: false)
        XCTAssertEqual(TodayGlance.decide(signedOutWithDays, now: Self.tuesdayMorning), .openApp)
    }

    func testTodaysListingsAreShownFirst() {
        let today = Self.day("2026-10-13", "a", "b")
        let snapshot = Self.snapshot(days: [today, Self.day("2026-10-15", "c")])
        XCTAssertEqual(TodayGlance.decide(snapshot, now: Self.tuesdayMorning), .today(today))
    }

    /// Nothing today: the next day with listings, and the line that says so.
    func testAQuietDayShowsTheNextListedDay() {
        let thursday = Self.day("2026-10-15", "a", "b")
        let snapshot = Self.snapshot(days: [thursday])
        let glance = TodayGlance.decide(snapshot, now: Self.tuesdayMorning)
        XCTAssertEqual(glance, .next(thursday))
        XCTAssertEqual(TodayCopy.next(thursday), "Next: Thu 15 Oct, 2 matters")
        XCTAssertEqual(glance.day, "2026-10-15", "a tap opens the day it shows")
    }

    /// Nothing on any day it knows: says so up to the last of them — never beyond.
    func testAnEmptyWeekIsClearOnlyThroughItsLastDay() {
        let glance = TodayGlance.decide(Self.snapshot(days: []), now: Self.tuesdayMorning)
        XCTAssertEqual(glance, .clear(through: "2026-10-19"))
        XCTAssertEqual(TodayCopy.clear(through: "2026-10-19"), "None of your matters through Mon 19 Oct")
        XCTAssertNil(glance.day)
    }

    /// Past the last day it speaks for, a snapshot knows nothing about today — and a day it does
    /// not know about must never read as a free one.
    func testAnOutOfDateSnapshotSaysOpenTheAppRatherThanNothingListed() {
        let snapshot = Self.snapshot(last: "2026-10-19", days: [])
        XCTAssertEqual(TodayGlance.decide(snapshot, now: Self.at("2026-10-19T18:29:59Z")),
                       .clear(through: "2026-10-19"), "the last second of its last day")
        XCTAssertEqual(TodayGlance.decide(snapshot, now: Self.at("2026-10-19T18:30:00Z")), .openApp)
        XCTAssertEqual(
            TodayGlance.decide(Self.snapshot(first: "2026-10-14", days: []), now: Self.tuesdayMorning),
            .openApp, "a clock moved back before its first day")
    }

    /// At midnight in India the widget moves from "next: Wednesday" to "today".
    func testMidnightInIndiaTurnsTheNextDayIntoToday() {
        let wednesday = Self.day("2026-10-14", "a")
        let snapshot = Self.snapshot(days: [Self.day("2026-10-12", "past"), wednesday])
        XCTAssertEqual(TodayGlance.decide(snapshot, now: Self.lastSecondOfTuesday), .next(wednesday))
        XCTAssertEqual(TodayGlance.decide(snapshot, now: Self.midnightIntoWednesday), .today(wednesday))
    }

    /// A tap opens the Calendar on the day shown, or on today when none is.
    func testTheWidgetLinksToTheDayItShows() {
        let today = Self.day("2026-10-13", "a")
        XCTAssertEqual(TodayGlance.today(today).link.url.absoluteString, "emperor://calendar?day=2026-10-13")
        XCTAssertEqual(TodayGlance.openApp.link.url.absoluteString, "emperor://calendar")
    }

    // MARK: - Words

    func testTheWordsForCountsAndPlaces() {
        XCTAssertEqual(TodayCopy.listedToday(1), "1 matter listed today")
        XCTAssertEqual(TodayCopy.listedToday(3), "3 matters listed today")
        let full = TodayMatter(
            caseID: "a", title: "T", court: nil, room: "Court 12", item: "7", time: "10:30 AM")
        XCTAssertEqual(TodayCopy.location(full), "Court 12 · Item 7 · 10:30 AM")
        XCTAssertEqual(TodayCopy.spokenLocation(full), "Court 12, item 7, at 10:30 AM")
        var itemOnly = full
        itemOnly.room = nil
        itemOnly.time = nil
        XCTAssertEqual(TodayCopy.location(itemOnly), "Item 7")
        XCTAssertNil(TodayCopy.location(Self.matter("bare")), "nothing guessed for a bare row")
        XCTAssertEqual(TodayCopy.more(shown: 3, of: 5), "and 2 more")
        XCTAssertNil(TodayCopy.more(shown: 3, of: 3))
    }

    /// Fresh lists say nothing about their age; stale ones say how stale, in India's days.
    func testAStaleListSaysHowOldItIs() {
        let fetched = Self.tuesdayMorning
        XCTAssertNil(TodayCopy.age(fetchedAt: fetched, now: fetched.addingTimeInterval(5 * 3_600 + 3_599)))
        XCTAssertEqual(
            TodayCopy.age(fetchedAt: fetched, now: fetched.addingTimeInterval(6 * 3_600)),
            "Updated 6 hours ago")
        // 09:00 Tuesday to 08:00 Wednesday is under a day, but Wednesday is the next day in court.
        XCTAssertEqual(
            TodayCopy.age(fetchedAt: fetched, now: Self.at("2026-10-14T02:30:00Z")),
            "Updated 23 hours ago")
        XCTAssertEqual(
            TodayCopy.age(fetchedAt: fetched, now: Self.at("2026-10-14T05:30:00Z")),
            "Updated yesterday")
        XCTAssertEqual(
            TodayCopy.age(fetchedAt: fetched, now: Self.at("2026-10-16T05:30:00Z")),
            "Updated 3 days ago")
        XCTAssertNil(TodayCopy.age(fetchedAt: nil, now: fetched), "an unknown age is not made up")
    }

    /// The Lock Screen line names no matter — a locked phone says nothing about a client.
    func testTheInlineLineCarriesCountsAndDaysOnly() {
        let secret = TodayDay(
            day: "2026-10-15", total: 2,
            matters: [Self.matter("a", title: "Confidential Client v. Someone")])
        XCTAssertEqual(TodayCopy.inline(.today(secret)), "2 matters listed today")
        XCTAssertEqual(TodayCopy.inline(.next(secret)), "Next listed: Thu 15 Oct")
        XCTAssertEqual(TodayCopy.inline(.clear(through: "2026-10-19")), "Nothing listed today")
        XCTAssertEqual(TodayCopy.inline(.openApp), "Open Emperor")
        XCTAssertEqual(TodayCopy.heading(at: Self.lastSecondOfTuesday), "Tue 13 Oct")
        XCTAssertEqual(TodayCopy.heading(at: Self.midnightIntoWednesday), "Wed 14 Oct")
    }

    // MARK: - The timeline

    /// Now, then every midnight in India for the week — when the widget's "today" changes.
    func testTheTimelineTurnsAtEachIndianMidnight() {
        let dates = TodayTimeline.entryDates(now: Self.tuesdayMorning)
        XCTAssertEqual(dates.count, TodaySnapshot.horizonDays + 1)
        XCTAssertEqual(dates.first, Self.tuesdayMorning)
        XCTAssertEqual(dates[1], Self.midnightIntoWednesday)
        for (earlier, later) in zip(dates.dropFirst(), dates.dropFirst(2)) {
            XCTAssertEqual(later.timeIntervalSince(earlier), 86_400)
            XCTAssertEqual(IndianDay.key(later.addingTimeInterval(-1)), IndianDay.key(earlier))
        }
        XCTAssertEqual(TodayTimeline.entryDates(now: Self.midnightIntoWednesday)[1],
                       Self.midnightIntoWednesday.addingTimeInterval(86_400))
    }

    // MARK: - Colours

    /// The widget's restated colours are the app's palette, both appearances.
    func testTheWidgetsColoursAreThePalettes() {
        func hex(_ color: PaletteColor) -> UInt32 {
            UInt32((color.red * 255).rounded()) << 16
                | UInt32((color.green * 255).rounded()) << 8
                | UInt32((color.blue * 255).rounded())
        }
        let pairs: [(TodayWidgetColors, Palette)] = [(.dark, .dark), (.light, .light)]
        for (widget, palette) in pairs {
            XCTAssertEqual(widget.canvas, hex(palette.canvas))
            XCTAssertEqual(widget.textPrimary, hex(palette.textPrimary))
            XCTAssertEqual(widget.textSecondary, hex(palette.textSecondary))
            XCTAssertEqual(widget.textTertiary, hex(palette.textTertiary))
            XCTAssertEqual(widget.accent, hex(palette.accent))
            XCTAssertEqual(widget.accentText, hex(palette.accentText))
        }
        let parts = TodayWidgetColors.components(0x5A64AD)
        XCTAssertEqual(parts.red, 90.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(parts.blue, 173.0 / 255, accuracy: 0.0001)
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("today-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
