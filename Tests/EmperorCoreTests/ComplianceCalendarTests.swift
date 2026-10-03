import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Corporate Calendar, against `ComplianceFeedFixture` — the body `GET /compliance-calendar`
/// really answers, produced by the platform's own feed code over its own seed rows (regenerate
/// with `node scripts/generate-compliance-feed-fixture.mjs <platform>`).
final class ComplianceCalendarTests: XCTestCase {

    /// 3 October 2026, 12:00 IST — the day the fixture was computed for.
    static let fixtureNoon = Date(timeIntervalSince1970: 1_791_009_000)

    static func fixtureRows() throws -> [StatutoryDeadline] {
        try JSONDecoder().decode(
            [StatutoryDeadline].self, from: Data(ComplianceFeedFixture.json.utf8))
    }

    static func row(_ id: String) throws -> StatutoryDeadline {
        try XCTUnwrap(fixtureRows().first { $0.id == id }, "no \(id) in the fixture")
    }

    func testTheClockIsTheFixturesDay() {
        XCTAssertEqual(WireDate.dayKey(Self.fixtureNoon), ComplianceFeedFixture.today)
    }

    // MARK: - Decoding the real body

    func testTheWholeFeedDecodes() throws {
        let rows = try Self.fixtureRows()
        XCTAssertEqual(rows.count, ComplianceFeedFixture.rowCount)
        XCTAssertEqual(rows.filter { $0.dueDay != nil }.count, ComplianceFeedFixture.datedRowCount)
    }

    /// A row that needs company context carries prose where a date would be. It must decode,
    /// and must not be mistaken for a date.
    func testAnUndatedRowDecodesAndHasNoDay() throws {
        let agm = try Self.row("stat:AOC4:na")
        XCTAssertEqual(agm.nextDueDateRaw, "N/A - no company context")
        XCTAssertNil(agm.dateKey)
        XCTAssertNil(agm.dueDay)
        XCTAssertEqual(agm.schedule, .afterAGM(days: 30))
    }

    func testADatedRowCarriesWhatTheDetailScreenNeeds() throws {
        let gstr1 = try Self.row("stat:GSTR1:2026-10-11")
        XCTAssertEqual(gstr1.displayTitle, "GSTR-1")
        XCTAssertEqual(gstr1.regulator, "CBIC")
        XCTAssertEqual(gstr1.category, .gst)
        XCTAssertEqual(gstr1.complianceID, "GSTR1")
        XCTAssertEqual(gstr1.frequencyLabel, "Monthly")
        XCTAssertEqual(gstr1.schedule?.summary, "By the 11th of every month")
        XCTAssertEqual(gstr1.verification, .checked("2026-07-29"))
        XCTAssertTrue(gstr1.note?.hasPrefix("QRMP scheme") == true)
        XCTAssertFalse(gstr1.differsFromUsualSchedule)
    }

    /// The Income Tax Department splits into two categories by obligation, not by body.
    func testTDSIsItsOwnCategoryUnderTheSameRegulator() throws {
        XCTAssertEqual(try Self.row("stat:TDS:2026-10-31").category, .tds)
        XCTAssertEqual(try Self.row("stat:ITR:2026-10-31").category, .incometax)
        XCTAssertEqual(try Self.row("stat:TDS:2026-10-31").regulator, "Income Tax Dept")
    }

    func testAnUnknownCategoryStillDecodes() throws {
        let row = try JSONDecoder().decode(StatutoryDeadline.self, from: Data("""
            {"id":"stat:NEW:2026-11-01","ui_category":"space","dateKey":"2026-11-01",
             "title":"Launch licence"}
            """.utf8))
        XCTAssertNil(row.category)
        XCTAssertEqual(row.dueDay, "2026-11-01")
    }

    func testAKeyThatPassesTheServersRegexButIsNoDayIsRejected() throws {
        let row = try JSONDecoder().decode(StatutoryDeadline.self, from: Data("""
            {"id":"stat:X:2026-02-30","dateKey":"2026-02-30"}
            """.utf8))
        XCTAssertNil(row.dueDay)
    }

    // MARK: - A date moved off its rule

    /// GSTR-3B is "by the 20th"; the fixture's circular moved it to the 25th. The screen must
    /// not print both without saying why.
    func testAFixedRuleWithAMovedDateIsRecognised() throws {
        let moved = try Self.row("stat:GSTR3B:2026-10-25")
        XCTAssertEqual(moved.schedule?.summary, "By the 20th of every month")
        XCTAssertTrue(moved.differsFromUsualSchedule)
        XCTAssertEqual(moved.verification, .checked("2026-10-03"), "publish() stamps it")
    }

    /// A relative rule has no date without company context, so a date on one was given to it.
    func testARelativeRuleWithADateIsRecognised() throws {
        let dated = try Self.row("stat:DIR12:2026-10-20")
        XCTAssertTrue(dated.differsFromUsualSchedule)
        XCTAssertEqual(
            dated.schedule?.summary, "Within 30 days of the event (director change)")
    }

    func testEveryUnmovedFixedRuleAgreesWithItsDate() throws {
        let moved: Set = ["stat:GSTR3B:2026-10-25", "stat:DIR12:2026-10-20"]
        for row in try Self.fixtureRows() where row.dueDay != nil && !moved.contains(row.id) {
            XCTAssertFalse(row.differsFromUsualSchedule, "\(row.id) read as moved")
        }
    }

    // MARK: - Schedules

    func testScheduleSummaries() {
        XCTAssertEqual(
            DeadlineSchedule(type: "fixed_annual_date", value: "06-30")?.summary,
            "By 30 June every year")
        XCTAssertEqual(
            DeadlineSchedule(type: "quarterly_fixed_dates", value: "07-31,10-31,01-31,05-31")?
                .summary,
            "On 31 July, 31 October, 31 January and 31 May each year")
        XCTAssertEqual(
            DeadlineSchedule(type: "half_yearly_fixed_dates", value: "04-30,10-31")?.summary,
            "On 30 April and 31 October each year")
        XCTAssertEqual(
            DeadlineSchedule(type: "annual_window", value: "06-01:08-31")?.summary,
            "Between 1 June and 31 August every year")
        XCTAssertEqual(
            DeadlineSchedule(type: "hours_after_event", value: "6:cyber_incident_detected")?
                .summary,
            "Within 6 hours of the event (cyber incident detected)")
        XCTAssertEqual(
            DeadlineSchedule(type: "days_after_fy_end", value: "60")?.summary,
            "Within 60 days of the financial year end")
        XCTAssertEqual(
            DeadlineSchedule(type: "monthly_fixed_day", value: "1")?.summary,
            "By the 1st of every month")
    }

    /// The platform's own "not fixed" marker, and anything it would refuse, say nothing.
    func testAnUnusableRuleSaysNothing() {
        XCTAssertNil(DeadlineSchedule(type: "fixed_annual_date", value: "NA"))
        XCTAssertNil(DeadlineSchedule(type: "monthly_fixed_day", value: "32"))
        XCTAssertNil(DeadlineSchedule(type: "quarterly_fixed_dates", value: "07-31,banana"))
        XCTAssertNil(DeadlineSchedule(type: "lunar", value: "3"))
        XCTAssertNil(DeadlineSchedule(type: nil, value: "3"))
    }

    func testOrdinals() {
        XCTAssertEqual(
            [1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31].map(CourtCalendar.ordinal),
            ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "31st"])
    }

    func testVerification() {
        XCTAssertEqual(DeadlineVerification(raw: "NEEDS_VERIFICATION"), .unconfirmed)
        XCTAssertEqual(DeadlineVerification(raw: "2026-07-29"), .checked("2026-07-29"))
        XCTAssertEqual(DeadlineVerification(raw: nil), .unknown)
        XCTAssertEqual(DeadlineVerification(raw: "soon"), .unknown)
    }

    // MARK: - Urgency (the web's thresholds)

    func testUrgencyThresholds() {
        XCTAssertEqual(DeadlineUrgency(daysUntilDue: -1, isDone: false), .overdue(days: 1))
        XCTAssertEqual(DeadlineUrgency(daysUntilDue: 0, isDone: false), .dueSoon(days: 0))
        XCTAssertEqual(DeadlineUrgency(daysUntilDue: 7, isDone: false), .dueSoon(days: 7))
        XCTAssertEqual(DeadlineUrgency(daysUntilDue: 8, isDone: false), .upcoming(days: 8))
        XCTAssertEqual(DeadlineUrgency(daysUntilDue: -30, isDone: true), .done)
    }

    func testUrgencyLabelsAndEmphasis() {
        XCTAssertEqual(DeadlineUrgency.overdue(days: 1).label, "1 day overdue")
        XCTAssertEqual(DeadlineUrgency.overdue(days: 3).label, "3 days overdue")
        XCTAssertEqual(DeadlineUrgency.dueSoon(days: 0).label, "Due today")
        XCTAssertEqual(DeadlineUrgency.dueSoon(days: 1).label, "Due tomorrow")
        XCTAssertEqual(DeadlineUrgency.dueSoon(days: 6).label, "Due in 6 days")
        XCTAssertEqual(DeadlineUrgency.upcoming(days: 40).label, "In 40 days")
        XCTAssertEqual(DeadlineUrgency.overdue(days: 1).emphasis, .danger)
        XCTAssertEqual(DeadlineUrgency.dueSoon(days: 1).emphasis, .warning)
        XCTAssertEqual(DeadlineUrgency.done.emphasis, .success)
        XCTAssertEqual(DeadlineUrgency.upcoming(days: 9).emphasis, .neutral)
    }

    func testDayArithmeticIsInIndia() {
        XCTAssertEqual(CourtCalendar.days(from: "2026-10-03", to: "2026-10-11"), 8)
        XCTAssertEqual(CourtCalendar.days(from: "2026-10-03", to: "2026-09-30"), -3)
        XCTAssertEqual(CourtCalendar.days(from: "2026-12-31", to: "2027-01-01"), 1)
        XCTAssertEqual(CourtCalendar.monthTitle("2026-10"), "October 2026")
        XCTAssertEqual(CourtCalendar.tile("2026-10-31")?.weekday, "Sat")
        XCTAssertEqual(CourtCalendar.tile("2026-10-31")?.month, "Oct")
    }

    // MARK: - Who gets the tab

    /// `MobileNav.jsx`: `['corporate', 'counsel', 'litigator'].includes(uiRole)`.
    func testTheCorporateTabIsExactlyTheWebsRoleSet() {
        XCTAssertEqual(
            Set(PractitionerRole.allCases.filter(\.hasCorporateTab)),
            [.corporateCounsel, .seniorCounsel, .litigator])
    }

    // MARK: - The service, on the wire

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService() async -> ComplianceCalendarService {
        let client = APIClient(
            config: APIConfig(baseURL: URL(string: "https://example.test/api")!),
            session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok", userID: 42))
        return ComplianceCalendarService(client: client)
    }

    func testTheFeedIsABareArrayAtTheApiPath() async throws {
        let service = await makeService()
        HTTPStub.always(.json(ComplianceFeedFixture.json))

        let rows = try await service.deadlines()

        XCTAssertEqual(rows.count, ComplianceFeedFixture.rowCount)
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/compliance-calendar")
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.header("Authorization"), "Bearer tok")
    }

    /// The route's failure body is `{error}` with a 500, and that is an error here — never an
    /// empty calendar.
    func testAFailedFeedThrowsTheServersMessage() async {
        let service = await makeService()
        HTTPStub.always(.json(
            #"{"error":"Failed to load compliance calendar: unavailable"}"#, status: 404))
        do {
            _ = try await service.deadlines()
            XCTFail("a failed feed must throw")
        } catch {
            XCTAssertEqual(
                DisplayText.message(for: error),
                "Failed to load compliance calendar: unavailable")
        }
    }

    /// Only the `stat:` rows; the diary's own entries are not markers.
    func testMarkersAreOnlyTheStatutoryRows() async throws {
        let service = await makeService()
        HTTPStub.always(.json("""
            {"success":true,"events":[
              {"id":"stat:GSTR1:2026-10-11","title":"GSTR-1","type":"gst","due_date":"2026-10-11","status":"done"},
              {"id":"cmpl_1","title":"File reply","type":"filing","due_date":"2026-10-12","status":"open"}
            ]}
            """))
        let markers = try await service.statutoryMarkers()
        XCTAssertEqual(markers.map(\.id), ["stat:GSTR1:2026-10-11"])
        XCTAssertEqual(HTTPStub.lastRequest?.path, "/api/compliance")
    }
}

// MARK: - The screen's view model

final class ComplianceCalendarViewModelTests: XCTestCase {

    func testFirstLoadSpinsThenShowsTheAgenda() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompliance { service, model in
            service.rows = rows
            XCTAssertTrue(model.presentation.showsLoadingPlaceholder, "nothing yet means a spinner")
            await model.load()
            XCTAssertEqual(model.deadlines.count, ComplianceFeedFixture.datedRowCount)
            XCTAssertEqual(model.undatedCount, ComplianceFeedFixture.rowCount - ComplianceFeedFixture.datedRowCount)
            XCTAssertEqual(
                model.undatedFootnote?.hasPrefix("\(model.undatedCount) more tracked obligations"),
                true)
            XCTAssertFalse(model.presentation.showsEmptyState)
        }
    }

    /// Next 7 days is 0–7 inclusive (the web's "soon"); later deadlines go under their month,
    /// in month order, soonest first within each.
    func testGroupsAreNextSevenDaysThenMonths() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompliance { service, model in
            service.rows = rows
            await model.load()

            let groups = model.groups
            XCTAssertEqual(groups.first?.kind, .dueSoon)
            XCTAssertEqual(
                groups.first?.deadlines.map(\.id), ["stat:ECB2:2026-10-07"],
                "7 Oct is 4 days out; 11 Oct is 8 and is not 'soon'")
            XCTAssertEqual(groups[1].title, "October 2026")
            XCTAssertEqual(groups[1].deadlines.first?.id, "stat:GSTR1:2026-10-11")
            let months = groups.compactMap { group -> String? in
                if case .month(let key) = group.kind { return key }
                return nil
            }
            XCTAssertEqual(months, months.sorted())
            for group in groups {
                let days = group.deadlines.compactMap(\.dueDay)
                XCTAssertEqual(days, days.sorted(), "\(group.title) is out of order")
            }
        }
    }

    /// A deadline the team marked done on the web is "Done", not overdue — and is not counted
    /// as open.
    func testAMarkerFromTheWebMarksADeadlineDone() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompliance(now: Date(timeIntervalSince1970: 1_791_009_000 + 10 * 86_400)) {
            service, model in
            // 13 October: GSTR-1 (11 Oct) is two days past; ECB-2 (7 Oct) six.
            service.rows = rows
            service.markers = [
                ComplianceEvent(id: "stat:GSTR1:2026-10-11", status: "done"),
                ComplianceEvent(id: "stat:ECB2:2026-10-07", status: "open"),
            ]
            await model.load()

            let gstr1 = try! XCTUnwrap(model.deadlines.first { $0.id == "stat:GSTR1:2026-10-11" })
            let ecb2 = try! XCTUnwrap(model.deadlines.first { $0.id == "stat:ECB2:2026-10-07" })
            XCTAssertEqual(model.urgency(of: gstr1), .done)
            XCTAssertEqual(model.urgency(of: ecb2), .overdue(days: 6), "an open marker is not done")

            let overdue = model.groups.first { $0.kind == .overdue }
            XCTAssertEqual(overdue?.deadlines.map(\.id), ["stat:ECB2:2026-10-07"])
            let doneEarlier = model.groups.first { $0.kind == .doneEarlier }
            XCTAssertEqual(doneEarlier?.deadlines.map(\.id), ["stat:GSTR1:2026-10-11"])
            XCTAssertEqual(model.summary.overdue, 1)
        }
    }

    func testTheSummaryCountsOnlyOpenDeadlines() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompliance { service, model in
            service.rows = rows
            service.markers = [ComplianceEvent(id: "stat:ECB2:2026-10-07", status: "done")]
            await model.load()

            XCTAssertEqual(
                model.summary,
                .init(overdue: 0, dueSoon: 0, open: ComplianceFeedFixture.datedRowCount - 1))
        }
    }

    // MARK: - Filters

    func testCategoryChipsAreTheOnesWithDeadlinesInTheWebsOrder() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompliance { service, model in
            service.rows = rows
            await model.load()
            XCTAssertEqual(
                model.availableCategories,
                [.mca, .incometax, .tds, .gst, .epf, .fema, .trade, .licensing])
        }
    }

    func testFilteringByCategoryAndRegulator() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompliance { service, model in
            service.rows = rows
            await model.load()

            model.select(category: .epf)
            XCTAssertEqual(Set(model.visibleDeadlines.map(\.regulator)), ["EPFO", "ESIC"])
            XCTAssertEqual(model.availableRegulators, ["EPFO", "ESIC"])

            model.select(regulator: "ESIC")
            XCTAssertEqual(model.visibleDeadlines.map(\.id), ["stat:ESIC:2026-10-15"])
            XCTAssertTrue(model.hasActiveFilters)

            model.clearFilters()
            XCTAssertEqual(model.visibleDeadlines.count, ComplianceFeedFixture.datedRowCount)
            XCTAssertFalse(model.hasActiveFilters)
        }
    }

    /// Choosing a category that the chosen regulator has nothing in drops the regulator, so the
    /// two filters never cancel out into an empty list.
    func testAnIncompatibleRegulatorIsDroppedWhenTheCategoryChanges() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompliance { service, model in
            service.rows = rows
            await model.load()
            model.select(regulator: "RBI")
            model.select(category: .gst)
            XCTAssertNil(model.regulator)
            XCTAssertFalse(model.visibleDeadlines.isEmpty)
        }
    }

    /// Hiding everything with a filter is not "nothing tracked": the screen keeps its chips and
    /// says so in place.
    func testAFilterThatHidesEverythingIsNotTheEmptyState() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompliance { service, model in
            service.rows = rows
            await model.load()
            model.select(status: .done)
            XCTAssertTrue(model.isFilteredToNothing)
            XCTAssertFalse(model.presentation.showsEmptyState)
            XCTAssertTrue(model.groups.isEmpty)
        }
    }

    // MARK: - Empty, failed, cached

    /// The feed answering "nothing dated" is the empty state…
    func testAFeedWithNoDatedRowsIsEmpty() async throws {
        let undated = try ComplianceCalendarTests.fixtureRows().filter { $0.dueDay == nil }
        await withCompliance { service, model in
            service.rows = undated
            await model.load()
            XCTAssertTrue(model.presentation.showsEmptyState)
        }
    }

    /// …and a failed request never is.
    func testAFailedLoadIsAFailureNotAnEmptyCalendar() async {
        await withCompliance { service, model in
            service.error = APIError.server(status: 500, message: "down")
            await model.load()
            XCTAssertTrue(model.presentation.showsFailureState)
            XCTAssertFalse(model.presentation.showsEmptyState)
        }
    }

    /// The markers are half the answer: without them a filed deadline would read as overdue,
    /// so their failure fails the load rather than showing a calendar that is wrong.
    func testAFailedMarkerRequestFailsTheLoad() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompliance { service, model in
            service.rows = rows
            service.markerError = APIError.transport("offline")
            await model.load()
            XCTAssertTrue(model.presentation.showsFailureState)
        }
    }

    func testACachedCalendarShowsWithItsAgeWhileOffline() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        let store = InMemoryCacheStore()
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let cache = ResponseCache(store: store, now: { stamp })
        await withCompliance(cache: cache) { service, model in
            service.rows = rows
            service.markers = [ComplianceEvent(id: "stat:GSTR1:2026-10-11", status: "done")]
            await model.load()
        }
        await withCompliance(cache: cache) { service, model in
            service.error = APIError.transport("The Internet connection appears to be offline.")
            await model.load()
            XCTAssertEqual(model.deadlines.count, ComplianceFeedFixture.datedRowCount)
            XCTAssertTrue(model.presentation.showsStaleBanner)
            XCTAssertEqual(model.presentation.cachedAt, stamp)
            XCTAssertTrue(
                model.deadlines.contains { $0.id == "stat:GSTR1:2026-10-11" && model.isDone($0) },
                "the done-markers come back with the cache")
        }
    }

    // MARK: - Detail

    func testTheDetailOfAMovedDeadline() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompliance { service, model in
            service.rows = rows
            await model.load()
            let moved = try! XCTUnwrap(model.deadlines.first { $0.complianceID == "GSTR3B" })
            let detail = model.detail(for: moved)

            XCTAssertEqual(detail.title, "GSTR-3B")
            XCTAssertEqual(detail.dueLong, "Sunday, 25 October 2026")
            XCTAssertEqual(detail.urgency, .upcoming(days: 22))
            XCTAssertTrue(detail.differsFromUsualSchedule)
            XCTAssertEqual(detail.code, "GSTR3B")
            XCTAssertEqual(detail.verificationText, "Last verified on Saturday, 3 October 2026.")
            XCTAssertTrue(detail.shareText.contains("GSTR-3B — due Sunday, 25 October 2026"))
            XCTAssertTrue(detail.shareText.contains("This date differs from it."))
            XCTAssertTrue(detail.shareText.hasSuffix(ComplianceCalendarViewModel.Copy.shareFooter))
        }
    }

    func testAnUnconfirmedDeadlineSaysSo() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompliance { service, model in
            service.rows = rows
            await model.load()
            let itr = try! XCTUnwrap(model.deadlines.first { $0.complianceID == "ITR" })
            XCTAssertEqual(model.detail(for: itr).verification, .unconfirmed)
            XCTAssertTrue(model.detail(for: itr).verificationText?.hasPrefix("Not yet verified") == true)
        }
    }
}

// MARK: - Stand-ins

final class FakeComplianceCalendar: ComplianceCalendarProviding, @unchecked Sendable {
    var rows: [StatutoryDeadline] = []
    var markers: [ComplianceEvent] = []
    var error: Error?
    var markerError: Error?

    func deadlines() async throws -> [StatutoryDeadline] {
        if let error { throw error }
        return rows
    }

    func statutoryMarkers() async throws -> [ComplianceEvent] {
        if let error { throw error }
        if let markerError { throw markerError }
        return markers
    }
}

@MainActor
private func withCompliance(
    now: Date = ComplianceCalendarTests.fixtureNoon,
    cache: ResponseCache? = nil,
    _ body: @MainActor (FakeComplianceCalendar, ComplianceCalendarViewModel) async -> Void
) async {
    let service = FakeComplianceCalendar()
    let stamp = now
    await body(service, ComplianceCalendarViewModel(service: service, cache: cache, now: { stamp }))
}
