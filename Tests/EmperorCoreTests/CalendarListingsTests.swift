import XCTest
@testable import EmperorCore

/// The Calendar's case listings: which matters a day carries, and the order it runs in.
final class CalendarListingsTests: XCTestCase {

    /// 3 Oct 2026, 06:00 UTC — 11:30 IST.
    private static let midMorningIST = Date(timeIntervalSince1970: 1_791_007_200)
    /// 3 Oct 2026, 18:45 UTC — already 00:15 on the 4th in Delhi.
    private static let lateEveningUTC = Date(timeIntervalSince1970: 1_791_053_100)

    // MARK: - Fixtures

    private static func listing(
        _ caseID: String, on day: String = "2026-10-03", time: String? = nil,
        court: String? = nil, item: String? = nil, source: String = "causelist",
        forum: String = "Bombay High Court", title: String? = nil
    ) -> CauseListing {
        var listing = CauseListing(date: day, caseID: caseID)
        listing.title = title ?? "Matter \(caseID)"
        listing.courtName = forum
        listing.courtNo = court
        listing.itemNo = item
        listing.time = time
        listing.source = source
        listing.scraped = source == "causelist" ? true : nil
        return listing
    }

    private static func legalCase(
        _ id: String, nextHearing: String?, judge: String? = nil, stage: String? = nil
    ) -> LegalCase {
        LegalCase(
            id: id, teamID: "team_1", cnr: nil, courtType: "hc", courtCode: nil,
            caseNumber: "1234", caseYear: "2024", title: "Menon vs. Union of India",
            parties: nil, status: nil, stage: stage, nextHearingDateRaw: nextHearing,
            filingDateRaw: nil, judge: judge, courtName: "Delhi High Court",
            caseType: "W.P.(C)", diaryNumber: nil, category: nil, lastSyncedAtRaw: nil,
            createdAtRaw: nil, updatedAtRaw: nil, teamName: nil)
    }

    private static func ids(_ listings: [CauseListing]?) -> [String] {
        (listings ?? []).map(\.caseID)
    }

    // MARK: - Two sources, one row per matter per day

    /// A matter on both the cause list and the docket for the same day is listed once — and the
    /// row kept is the cause list's, which carries the room, item and time that day's list
    /// printed. The docket's copy knows none of them.
    func testAMatterInBothSourcesIsListedOnceAndTheCauseListsRowIsKept() {
        let days = CalendarListings.byDay(
            causeList: [Self.listing("case1", time: "10:30 AM", court: "Court No. 12", item: "7")],
            cases: [Self.legalCase("case1", nextHearing: "2026-10-03")])

        let day = days["2026-10-03"] ?? []
        XCTAssertEqual(day.count, 1, "one matter, one day, one row")
        XCTAssertEqual(day.first?.source, "causelist")
        XCTAssertEqual(day.first?.display.time, "10:30 AM")
        XCTAssertEqual(day.first?.display.item, "7")
    }

    /// A next hearing date the cause list does not carry still puts the matter on its day — the
    /// two are separate requests, cached separately, and the Cases tab would otherwise show a
    /// date the Calendar says nothing about.
    func testAMatterOnlyTheDocketKnowsIsListedFromItsNextHearing() throws {
        let days = CalendarListings.byDay(
            causeList: [Self.listing("case1")],
            cases: [Self.legalCase(
                "case2", nextHearing: "2026-10-03",
                judge: "Hon'ble Ms. Justice Prathiba M. Singh", stage: "Arguments")])

        let day = days["2026-10-03"] ?? []
        XCTAssertEqual(Set(Self.ids(day)), ["case1", "case2"])
        let added = try XCTUnwrap(day.first { $0.caseID == "case2" })
        XCTAssertEqual(added.source, "next")
        XCTAssertEqual(added.displayTitle, "Menon vs. Union of India")
        XCTAssertEqual(added.courtName, "Delhi High Court")
        XCTAssertEqual(added.display.reference, "1234/2024")
        XCTAssertEqual(added.display.coram, "Hon'ble Ms. Justice Prathiba M. Singh")
        XCTAssertEqual(added.display.note, "Arguments", "the placeholder purpose is not printed")
    }

    /// A row read off the case states no room of its own: a case's bench can be a roster code —
    /// Delhi's "Court 236" is one — and this row comes from no day's list to say otherwise. A
    /// bench that is only a room number is not a coram either.
    func testARowReadOffTheCaseMakesNoRoomOutOfItsBench() throws {
        let days = CalendarListings.byDay(
            causeList: [],
            cases: [Self.legalCase("case2", nextHearing: "2026-10-03", judge: "Court 236")])

        let row = try XCTUnwrap(days["2026-10-03"]?.first)
        XCTAssertNil(row.display.room)
        XCTAssertNil(row.display.item)
        XCTAssertNil(row.display.coram)
    }

    /// De-duplication is per matter **and day**. A matter listed on the 3rd whose next date is
    /// the 9th belongs on both; collapsing by matter alone drops a hearing.
    func testOneMatterOnTwoDaysIsListedOnBoth() {
        let days = CalendarListings.byDay(
            causeList: [Self.listing("case1", on: "2026-10-03")],
            cases: [Self.legalCase("case1", nextHearing: "2026-10-09")])

        XCTAssertEqual(Self.ids(days["2026-10-03"]), ["case1"])
        XCTAssertEqual(Self.ids(days["2026-10-09"]), ["case1"])
    }

    /// The server keeps the first `(case, date)` it pushes. Should a duplicate ever reach the
    /// client — two cached copies, an older server — the first still wins, rather than the same
    /// matter printed twice on one day.
    func testWithinTheCauseListTheFirstRowForAMatterAndDayWins() {
        let days = CalendarListings.byDay(
            causeList: [
                Self.listing("case1", time: "10:30 AM", item: "7"),
                Self.listing("case1", item: "99", source: "hearing"),
            ],
            cases: [])

        XCTAssertEqual(days["2026-10-03"]?.count, 1)
        XCTAssertEqual(days["2026-10-03"]?.first?.display.item, "7")
    }

    /// A case with no usable next date adds nothing.
    func testACaseWithoutAUsableDateAddsNothing() {
        let days = CalendarListings.byDay(
            causeList: [],
            cases: [
                Self.legalCase("a", nextHearing: nil),
                Self.legalCase("b", nextHearing: ""),
                Self.legalCase("c", nextHearing: "14/09/2026"),
            ])
        XCTAssertTrue(days.isEmpty)
    }

    // MARK: - Every date is a day in India

    /// A next hearing date is the day its date says, read as the server's `toDay` reads it: the
    /// leading `YYYY-MM-DD`, no zone conversion. Anything that does not start with a real date
    /// is left to the cause list.
    func testAHearingDayIsTheDateTheValueStartsWith() {
        func day(_ raw: String?) -> String? {
            CalendarListings.hearingDay(of: Self.legalCase("x", nextHearing: raw))
        }
        XCTAssertEqual(day("2026-10-04"), "2026-10-04")
        XCTAssertEqual(day(" 2026-10-04 "), "2026-10-04")
        XCTAssertEqual(day("2026-10-04T00:00:00.000Z"), "2026-10-04")
        XCTAssertEqual(day("2026-10-03T18:30:00.000Z"), "2026-10-03")
        XCTAssertNil(day("14/09/2026"))
        XCTAssertNil(day("2026-02-30"), "not a day, however it is shaped")
        XCTAssertNil(day("2026-10"))
        XCTAssertNil(day(""))
        XCTAssertNil(day(nil))
    }

    /// A next hearing stored as a timestamp just before midnight UTC — which is the next morning
    /// in Delhi — stays on the day its date says, because that is the day the server's cause
    /// list puts it on. Moving it through a zone here would print the same hearing twice, a day
    /// apart.
    func testAStoredTimestampDoesNotSplitAHearingAcrossTwoDays() {
        let stored = "2026-10-03T18:30:00.000Z"
        let days = CalendarListings.byDay(
            // What the server's own `toDay(stored)` produces.
            causeList: [Self.listing("case1", on: "2026-10-03", source: "next")],
            cases: [Self.legalCase("case1", nextHearing: stored)])

        XCTAssertEqual(Self.ids(days["2026-10-03"]), ["case1"])
        XCTAssertNil(days["2026-10-04"], "the same hearing, a day later")
    }

    /// "Today" is India's today. Late on the 3rd in UTC is already the 4th in Delhi, and the
    /// listings that matter are the 4th's.
    func testTheCalendarOpensOnIndiasTodayNearMidnightUTC() async {
        await withCalendar(now: Self.lateEveningUTC) { _, cases, model in
            cases.listings = [
                Self.listing("yesterday", on: "2026-10-03"),
                Self.listing("today", on: "2026-10-04"),
            ]
            await model.load()

            XCTAssertEqual(model.selectedDay, "2026-10-04", "already tomorrow in Delhi")
            XCTAssertEqual(Self.ids(model.selectedCalendarDay.listings), ["today"])
            XCTAssertEqual(model.month?.title, "October 2026")
        }
    }

    // MARK: - The order of a day

    /// By sitting time, earliest first — and the afternoon after the morning, which a string
    /// comparison of "2:00 PM" and "10:30 AM" gets backwards.
    func testTimedListingsRunInClockOrder() {
        let sorted = CalendarListings.sorted([
            Self.listing("two", time: "2:00 PM"),
            Self.listing("half-ten", time: "10:30 AM"),
            Self.listing("noon", time: "12:15 PM"),
            Self.listing("eleven", time: "11:00 AM"),
        ])
        XCTAssertEqual(Self.ids(sorted), ["half-ten", "eleven", "noon", "two"])
    }

    /// A listing whose list printed no time comes after every timed one. "No time printed" is not
    /// "first thing in the morning".
    func testUntimedListingsComeAfterTimedOnes() {
        let sorted = CalendarListings.sorted([
            Self.listing("untimed", court: "Court No. 1", item: "1"),
            Self.listing("late", time: "4:30 PM", court: "Court No. 40", item: "90"),
        ])
        XCTAssertEqual(Self.ids(sorted), ["late", "untimed"])
    }

    /// The untimed rows run by courtroom — by number, so Court 4 precedes Court 12 — and then by
    /// item number, so item 2 precedes item 10. That is Home's order, reused.
    func testUntimedListingsRunByRoomThenItem() {
        let sorted = CalendarListings.sorted([
            Self.listing("c12-i3", court: "Court No. 12", item: "3"),
            Self.listing("c4-i10", court: "Court No. 4", item: "10"),
            Self.listing("c4-i2", court: "Court No. 4", item: "2"),
        ])
        XCTAssertEqual(Self.ids(sorted), ["c4-i2", "c4-i10", "c12-i3"])
    }

    /// Two benches sitting at the same time fall back to the same rule.
    func testListingsAtTheSameTimeRunByRoomThenItem() {
        let sorted = CalendarListings.sorted([
            Self.listing("c12", time: "10:30 AM", court: "Court No. 12", item: "1"),
            Self.listing("c4-i9", time: "10:30 AM", court: "Court No. 4", item: "9"),
            Self.listing("c4-i3", time: "10:30 AM", court: "Court No. 4", item: "3"),
        ])
        XCTAssertEqual(Self.ids(sorted), ["c4-i3", "c4-i9", "c12"])
    }

    /// A time that cannot be read is ordered with the untimed — and still printed as the list
    /// wrote it, because only the order is ours.
    func testAnUnreadableTimeIsOrderedAsUntimedButStillShown() {
        let sorted = CalendarListings.sorted([
            Self.listing("after-lunch", time: "After lunch", court: "Court No. 1", item: "1"),
            Self.listing("timed", time: "3:00 PM", court: "Court No. 9", item: "50"),
        ])
        XCTAssertEqual(Self.ids(sorted), ["timed", "after-lunch"])
        XCTAssertEqual(sorted.last?.display.time, "After lunch")
    }

    /// The shapes Indian lists print a sitting time in.
    func testSittingTimesAreReadAsMinutesAfterMidnight() {
        let cases: [(String?, Int?)] = [
            ("10:30 AM", 630),
            ("2:00 PM", 840),
            ("12:00 PM", 720),
            ("12:15 AM", 15),
            ("10.30 a.m.", 630),
            ("3 PM", 900),
            ("Not before 2:30 P.M.", 870),
            ("(TIME : 10:30 AM)", 630),
            ("14:30", 870),
            ("9.15", 555),
            ("After lunch", nil),
            ("25:00", nil),
            ("10:75 AM", nil),
            ("", nil),
            (nil, nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(
                CalendarListings.minutes(fromSittingTime: text), expected,
                "\(text ?? "nil")")
        }
    }

    // MARK: - The screen

    /// The selected day lists its matters in the order the day runs, and its diary entries
    /// separately after them.
    func testTheSelectedDayCarriesItsListingsInOrderAndItsDiary() async {
        await withCalendar(now: Self.midMorningIST) { calendar, cases, model in
            calendar.events = [Self.event("e1", due: "2026-10-03")]
            cases.listings = [
                Self.listing("untimed", court: "Court No. 2", item: "4"),
                Self.listing("afternoon", time: "2:15 PM"),
                Self.listing("morning", time: "10:30 AM"),
            ]
            cases.cases = [Self.legalCase("docket-only", nextHearing: "2026-10-03")]
            await model.load()

            let day = model.selectedCalendarDay
            XCTAssertEqual(day.key, "2026-10-03")
            XCTAssertEqual(
                Self.ids(day.listings), ["morning", "afternoon", "untimed", "docket-only"])
            XCTAssertEqual(day.events.map(\.id), ["e1"])
            XCTAssertEqual(day.itemCount, 5)
        }
    }

    /// The grid marks a day with a listing as listed, whatever else is on it; a day with only
    /// diary entries is marked as such; a day reached only through the docket counts as listed.
    func testTheMonthMarksListedDaysAndDiaryDays() async {
        await withCalendar(now: Self.midMorningIST) { calendar, cases, model in
            calendar.events = [
                Self.event("diary-only", due: "2026-10-05"),
                Self.event("with-hearing", due: "2026-10-07"),
            ]
            cases.listings = [Self.listing("case1", on: "2026-10-07")]
            cases.cases = [Self.legalCase("case2", nextHearing: "2026-10-12")]
            await model.load()

            let marks = model.marks
            XCTAssertEqual(marks["2026-10-05"], .diary)
            XCTAssertEqual(marks["2026-10-07"], .listed)
            XCTAssertEqual(marks["2026-10-12"], .listed)
            XCTAssertNil(marks["2026-10-06"])
            XCTAssertEqual(
                model.populatedDays, ["2026-10-05", "2026-10-07", "2026-10-12"])
        }
    }

    /// The agenda below the grid carries listings too, so a hearing next week is visible
    /// without tapping through the month.
    func testTheAgendaCarriesListings() async {
        await withCalendar(now: Self.midMorningIST) { _, cases, model in
            cases.listings = [
                Self.listing("past", on: "2026-09-30"),
                Self.listing("next-week", on: "2026-10-09", time: "10:30 AM"),
            ]
            await model.load()

            let agenda = model.upcoming(excluding: model.selectedDay)
            XCTAssertEqual(agenda.map(\.key), ["2026-10-09"])
            XCTAssertEqual(Self.ids(agenda.first?.listings), ["next-week"])
            XCTAssertFalse(model.hasNothingToShow)
        }
    }

    /// The cause list is the whole history and takes no range: fetched once, windowed locally,
    /// however many days are looked at.
    func testTheCauseListIsFetchedOncePerLoad() async {
        await withCalendar(now: Self.midMorningIST) { _, cases, model in
            cases.listings = [Self.listing("case1")]
            await model.load()
            model.select(day: "2026-10-09")
            model.step(months: 1)
            _ = model.upcoming()

            XCTAssertEqual(cases.causeListCallCount, 1)
        }
    }

    /// The cause list failing is the calendar failing — never a day that simply looks free.
    func testAFailedCauseListIsAFailureNotAnEmptyDay() async {
        await withCalendar(now: Self.midMorningIST) { calendar, cases, model in
            calendar.events = [Self.event("e1", due: "2026-10-03")]
            cases.cases = [Self.legalCase("case1", nextHearing: "2026-10-03")]
            cases.causeListError = APIError.transport("offline")
            await model.load()

            XCTAssertTrue(model.presentation.showsFailureState)
            XCTAssertFalse(model.presentation.showsEmptyState)
            XCTAssertTrue(
                model.selectedCalendarDay.isEmpty,
                "nothing half-loaded is presented as the day — the docket alone is not the day")
        }
    }

    /// A refresh that fails keeps the day's listings on screen, under the stale banner.
    func testAFailedRefreshKeepsTheListingsUnderABanner() async {
        await withCalendar(now: Self.midMorningIST) { _, cases, model in
            cases.listings = [Self.listing("case1", time: "10:30 AM")]
            await model.load()

            cases.causeListError = APIError.transport("offline")
            await model.load()

            XCTAssertTrue(model.presentation.showsStaleBanner)
            XCTAssertEqual(Self.ids(model.selectedCalendarDay.listings), ["case1"])
        }
    }

    /// Opened offline, the calendar shows what was last loaded — listings included — stamped
    /// with the oldest of the three copies, since that is how stale the screen is.
    func testTheCalendarOpensOnWhatWasLastLoaded() async {
        let older = Date(timeIntervalSince1970: 1_790_000_000)
        let newer = Date(timeIntervalSince1970: 1_790_500_000)
        let store = InMemoryCacheStore()
        ResponseCache(store: store, now: { newer })
            .save([Self.listing("cached", time: "10:30 AM")], for: .causeList)
        ResponseCache(store: store, now: { older })
            .save([Self.legalCase("docket", nextHearing: "2026-10-03")], for: .caseList)

        await withCalendar(now: Self.midMorningIST, cache: ResponseCache(store: store)) {
            _, cases, model in
            cases.error = APIError.transport("offline")
            await model.load()

            XCTAssertTrue(model.presentation.showsStaleBanner)
            XCTAssertEqual(model.presentation.cachedAt, older)
            XCTAssertEqual(Self.ids(model.selectedCalendarDay.listings), ["cached", "docket"])
        }
    }

    /// An empty day says which kind of nothing it is, and the framing under the listings —
    /// whose cases these are, and to confirm with the court — is the same as Home's.
    func testAnEmptyDaySaysWhichKindOfNothingItIs() async {
        XCTAssertTrue(
            CalendarViewModel.Copy.listingsFooter.contains(
                CauseListViewModel.Copy.confirmWithCourt),
            "an empty day must never read as a free one")
        XCTAssertTrue(
            CalendarViewModel.Copy.listingsFooter.hasPrefix(CauseListViewModel.Copy.subtitle))

        await withCalendar(now: Self.midMorningIST) { _, cases, model in
            await model.load()
            XCTAssertEqual(model.selectedDayEmptyText, CalendarViewModel.Copy.nothingScheduled)

            cases.listings = [Self.listing("case1", on: "2026-10-09")]
            await model.load()
            XCTAssertEqual(model.selectedDayEmptyText, CauseListViewModel.Copy.nothingToday)

            model.select(day: "2026-10-08")
            XCTAssertEqual(model.selectedDayEmptyText, CauseListViewModel.Copy.nothingThisDay)
        }
    }

    private static func event(_ id: String, due: String) -> ComplianceEvent {
        ComplianceEvent(
            id: id, teamID: "team_1", caseID: nil, title: "File the rejoinder", type: "filing",
            dueDateRaw: due, status: "open", notes: nil, remindDays: nil,
            createdByUserID: "42", createdAtRaw: nil, updatedAtRaw: nil)
    }
}

@MainActor
private func withCalendar(
    now: Date, cache: ResponseCache? = nil,
    _ body: @MainActor (FakeCalendar, FakeCases, CalendarViewModel) async -> Void
) async {
    let calendar = FakeCalendar()
    let cases = FakeCases()
    await body(calendar, cases, CalendarViewModel(
        calendar: calendar, caseService: cases, cache: cache, now: { now }))
}
