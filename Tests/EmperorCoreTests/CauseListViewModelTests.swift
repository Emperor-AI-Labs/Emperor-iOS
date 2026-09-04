import XCTest
@testable import EmperorCore

final class CauseListViewModelTests: XCTestCase {

    /// 14 Sept 2026, 06:00 UTC — 11:30 IST, comfortably mid-morning in Delhi.
    private static let midMorningIST = Date(timeIntervalSince1970: 1_789_365_600)

    private static func listing(
        _ day: String, caseID: String = "case_1", source: String = "hearing",
        itemNo: String? = nil, title: String = "Menon vs. Union of India"
    ) -> CauseListing {
        CauseListing(
            date: day, caseID: caseID, teamID: "team_1", title: title,
            courtName: "Delhi High Court", courtType: "hc", caseNumber: "1234",
            caseYear: "2024", cnr: nil, judge: nil, purpose: "For final disposal",
            bench: nil, stage: nil, itemNo: itemNo, remarks: nil, source: source)
    }

    // MARK: - The timezone trap

    /// "Today" means India's today, not the device's.
    ///
    /// The server buckets by `Asia/Kolkata` and the web client filters the same way,
    /// deliberately. A device in New York at 21:00 on the 13th is already the 14th in Delhi —
    /// and the hearings that matter are the 14th's.
    func testTodayIsIndiasTodayNotTheDevices() async {
        // 13 Sept 2026, 20:00 UTC = 14 Sept 01:30 IST.
        let lateNightUTC = Date(timeIntervalSince1970: 1_789_329_600)
        await withCauseList(now: lateNightUTC) { service, model in
            service.listings = [Self.listing("2026-09-14")]
            await model.load()

            XCTAssertEqual(model.selectedDay, "2026-09-14", "already tomorrow in Delhi")
            XCTAssertEqual(model.listingsForSelectedDay.count, 1)
        }
    }

    func testTheDayKeyRoundTripsThroughIndia() {
        XCTAssertEqual(WireDate.dayKey(Self.midMorningIST), "2026-09-14")
    }

    // MARK: - Framing

    /// The safety sentence must survive on every empty state where the user has cases. Without
    /// it, a blank screen reads as "your day is clear".
    func testAnEmptyDayAlwaysTellsTheUserToConfirmWithTheCourt() async {
        await withCauseList { service, model in
            service.listings = [Self.listing("2026-09-20")]   // a different day
            await model.load()

            XCTAssertTrue(model.listingsForSelectedDay.isEmpty)
            XCTAssertEqual(model.emptyTitle, CauseListViewModel.Copy.nothingToday)
            XCTAssertTrue(
                model.emptyDetail.contains(CauseListViewModel.Copy.confirmWithCourt),
                "an empty day must never read as 'you are free'")
        }
    }

    /// With no listings at all, the screen must NOT claim "No cases added yet" — it only ever
    /// receives listings, so it cannot tell an empty docket from matters whose hearing dates
    /// have not come through. And the confirm-with-the-court line still has to be there.
    func testNoListingsAtAllDoesNotClaimTheUserHasNoCases() async {
        await withCauseList { _, model in
            await model.load()

            XCTAssertFalse(model.hasAnyListings)
            XCTAssertEqual(model.emptyTitle, CauseListViewModel.Copy.nothingAtAll)
            XCTAssertFalse(
                model.emptyDetail.lowercased().contains("no cases added"),
                "that would be a guess presented as fact")
            XCTAssertTrue(
                model.emptyDetail.contains(CauseListViewModel.Copy.confirmWithCourt),
                "the safety line is on EVERY empty state, including this one")
        }
    }

    func testTheSubtitleSaysWhoseCasesTheseAre() {
        XCTAssertEqual(CauseListViewModel.Copy.subtitle, "Your cases, by hearing date")
    }

    // MARK: - Day navigation

    /// An empty day is a real answer, so the arrows never skip one — but a blank screen should
    /// still say where the next listing is rather than being a dead end.
    func testJumpingGoesToTheNextListedDayNotTheNextCalendarDay() async {
        await withCauseList { service, model in
            service.listings = [
                Self.listing("2026-09-14"),
                Self.listing("2026-09-21", caseID: "case_2"),
                Self.listing("2026-10-05", caseID: "case_3"),
            ]
            await model.load()

            XCTAssertEqual(model.nextListedDay, "2026-09-21", "not the 15th")
            model.goToNextListedDay()
            XCTAssertEqual(model.selectedDay, "2026-09-21")

            model.goToNextListedDay()
            XCTAssertEqual(model.selectedDay, "2026-10-05")
        }
    }

    func testSteppingMovesOneCalendarDay() async {
        await withCauseList { service, model in
            service.listings = [Self.listing("2026-09-14")]
            await model.load()

            model.step(days: 1)
            XCTAssertEqual(model.selectedDay, "2026-09-15")
            model.step(days: -2)
            XCTAssertEqual(model.selectedDay, "2026-09-13")
        }
    }

    /// Stepping must not drift across a month boundary or a DST-style edge. India has no DST,
    /// but the arithmetic still has to land on the right day.
    func testSteppingCrossesAMonthBoundaryCleanly() async {
        await withCauseList { _, model in
            model.select(day: "2026-09-30")
            model.step(days: 1)
            XCTAssertEqual(model.selectedDay, "2026-10-01")
        }
    }

    func testThereIsNoNextDayBeyondTheLastListing() async {
        await withCauseList { service, model in
            service.listings = [Self.listing("2026-09-14")]
            await model.load()

            XCTAssertNil(model.nextListedDay)
            model.goToNextListedDay()
            XCTAssertEqual(model.selectedDay, "2026-09-14", "stays put rather than jumping")
        }
    }

    func testGoToTodayReturnsToIndiasToday() async {
        await withCauseList { _, model in
            model.select(day: "2026-01-01")
            XCTAssertFalse(model.isShowingToday)

            model.goToToday()
            XCTAssertEqual(model.selectedDay, "2026-09-14")
            XCTAssertTrue(model.isShowingToday)
        }
    }

    // MARK: - Ordering

    /// The server's pass-1 query has no `ORDER BY`, so row order is engine-dependent. Item
    /// numbers are sorted numerically: item 2 comes before item 10.
    /// **The comparator used to contain a cycle.** Mixing numeric and alphanumeric item numbers
    /// and falling through to the title gave `20 < x`, `x < 3` and `3 < 20` simultaneously —
    /// `sort` is undefined on that and can trap. "12A"-style items are routine here.
    func testMixedAlphanumericItemNumbersSortWithoutACycle() async {
        await withCauseList { service, model in
            service.listings = [
                Self.listing("2026-09-14", caseID: "c1", itemNo: "20", title: "A"),
                Self.listing("2026-09-14", caseID: "c2", itemNo: "x", title: "M"),
                Self.listing("2026-09-14", caseID: "c3", itemNo: "3", title: "Z"),
                Self.listing("2026-09-14", caseID: "c4", itemNo: "12A", title: "Q"),
                Self.listing("2026-09-14", caseID: "c5", itemNo: "12", title: "P"),
            ]
            await model.load()

            // Numeric order first, "12" before "12A", and the unnumbered row last.
            XCTAssertEqual(
                model.listingsForSelectedDay.map(\.itemNo),
                ["3", "12", "12A", "20", "x"])
        }
    }

    /// A listing with no item number at all sorts last — it is not item zero.
    func testUnnumberedListingsSortLast() async {
        await withCauseList { service, model in
            service.listings = [
                Self.listing("2026-09-14", caseID: "c1", itemNo: nil, title: "A"),
                Self.listing("2026-09-14", caseID: "c2", itemNo: "5", title: "Z"),
            ]
            await model.load()

            XCTAssertEqual(model.listingsForSelectedDay.map(\.itemNo), ["5", nil])
        }
    }

    func testListingsSortByItemNumberNumerically() async {
        await withCauseList { service, model in
            service.listings = [
                Self.listing("2026-09-14", caseID: "c3", itemNo: "10"),
                Self.listing("2026-09-14", caseID: "c1", itemNo: "2"),
                Self.listing("2026-09-14", caseID: "c2", itemNo: "7"),
            ]
            await model.load()

            XCTAssertEqual(model.listingsForSelectedDay.map(\.itemNo), ["2", "7", "10"])
        }
    }

    // MARK: - Loading

    /// A failed load must never render as "nothing listed" — that is the web bug, and on this
    /// screen it is the most dangerous version of it.
    func testAFailedLoadIsAFailureNotAnEmptyDay() async {
        await withCauseList { service, model in
            service.error = APIError.server(status: 500, message: "too many SQL variables")
            await model.load()

            XCTAssertTrue(model.presentation.showsFailureState)
            XCTAssertFalse(model.presentation.showsEmptyState)
        }
    }

    func testTheWholeListIsFetchedOnceAndWindowedLocally() async {
        await withCauseList { service, model in
            service.listings = [
                Self.listing("2020-01-01"), Self.listing("2026-09-14", caseID: "c2"),
                Self.listing("2030-12-31", caseID: "c3"),
            ]
            await model.load()

            XCTAssertEqual(service.causeListCallCount, 1)
            XCTAssertEqual(model.listings.count, 3, "the whole history is held")
            XCTAssertEqual(model.listingsForSelectedDay.count, 1, "one day is shown")

            model.select(day: "2030-12-31")
            XCTAssertEqual(
                service.causeListCallCount, 1,
                "changing day must not re-fetch — the route has no date parameter")
        }
    }

    // MARK: - Sharing

    func testShareTextCarriesTheDayAndTheConfirmLine() async {
        await withCauseList { service, model in
            service.listings = [Self.listing("2026-09-14")]
            await model.load()

            let text = model.shareText()
            XCTAssertTrue(text.contains("Menon vs. Union of India"))
            XCTAssertTrue(text.contains("Delhi High Court"))
            XCTAssertTrue(text.contains("14 September 2026"))
            XCTAssertTrue(text.contains(CauseListViewModel.Copy.confirmWithCourt))
        }
    }

    func testSharingAnEmptyDaySaysSoRatherThanSharingAHeadingAlone() async {
        await withCauseList { service, model in
            service.listings = [Self.listing("2026-10-01")]
            await model.load()

            let text = model.shareText()
            XCTAssertTrue(text.contains(CauseListViewModel.Copy.confirmWithCourt))
        }
    }
}

@MainActor
private func withCauseList(
    now: Date = Date(timeIntervalSince1970: 1_789_365_600),
    _ body: @MainActor (FakeCases, CauseListViewModel) async -> Void
) async {
    let service = FakeCases()
    let stamp = now
    await body(service, CauseListViewModel(service: service, now: { stamp }))
}
