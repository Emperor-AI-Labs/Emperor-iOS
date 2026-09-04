import XCTest
@testable import EmperorCore

final class CaseViewModelTests: XCTestCase {

    /// 14 Sept 2026, 11:30 IST.
    private static let today = Date(timeIntervalSince1970: 1_789_365_600)

    private static func legalCase(
        _ id: String, title: String = "Menon vs. Union of India",
        nextHearing: String? = nil, lastSynced: String? = nil
    ) -> LegalCase {
        LegalCase(
            id: id, teamID: "team_1", cnr: nil, courtType: "hc", courtCode: nil,
            caseNumber: "1234", caseYear: "2024", title: title, parties: nil,
            status: "Pending", stage: "Arguments", nextHearingDateRaw: nextHearing,
            filingDateRaw: nil, judge: nil, courtName: "Delhi High Court",
            caseType: "W.P.(C)", diaryNumber: nil, category: nil,
            lastSyncedAtRaw: lastSynced, createdAtRaw: nil, updatedAtRaw: nil,
            teamName: "My Firm")
    }

    private static func item(
        _ id: String, section: CaseSection, date: String? = nil, source: String = "user"
    ) -> CaseItem {
        CaseItem(
            id: id, caseID: "case_1", section: section.rawValue, title: "Row \(id)",
            subtitle: nil, dataRaw: nil, itemDateRaw: date, status: nil, amount: nil,
            createdByUserID: nil, createdAtRaw: nil, updatedAtRaw: nil,
            extKey: nil, source: source)
    }

    // MARK: - Grouping the docket

    /// Grouped by when the matter is next in court, not by `updated_at` — the server's ordering
    /// (`sync-server.js:9682`) would move a matter to the top of the docket just for having a
    /// note added to it.
    func testCasesGroupByWhenTheyAreNextInCourt() async {
        await withCaseList { service, model in
            service.cases = [
                Self.legalCase("past", nextHearing: "2026-08-01"),
                Self.legalCase("soon", nextHearing: "2026-09-20"),
                Self.legalCase("later", nextHearing: "2026-11-02"),
                Self.legalCase("none"),
            ]
            await model.load()

            XCTAssertEqual(model.groups.map(\.key), ["upcoming", "past", "undated"])
            XCTAssertEqual(model.groups[0].cases.map(\.id), ["soon", "later"],
                           "soonest first")
            XCTAssertEqual(model.groups[1].cases.map(\.id), ["past"])
            XCTAssertEqual(model.groups[2].cases.map(\.id), ["none"])
        }
    }

    /// "Last listed", not "Overdue". A past hearing date usually means the matter was heard and
    /// the next date has not synced yet — calling it overdue is an accusation the data cannot
    /// support.
    func testThePastGroupIsNotCalledOverdue() async {
        await withCaseList { service, model in
            service.cases = [Self.legalCase("past", nextHearing: "2026-08-01")]
            await model.load()

            XCTAssertEqual(model.groups.first?.title, "Last listed")
        }
    }

    /// A hearing today belongs with what is upcoming, not with what has passed.
    func testTodaysHearingCountsAsUpcoming() async {
        await withCaseList { service, model in
            service.cases = [Self.legalCase("today", nextHearing: "2026-09-14")]
            await model.load()

            XCTAssertEqual(model.groups.first?.key, "upcoming")
        }
    }

    func testEmptyGroupsAreOmitted() async {
        await withCaseList { service, model in
            service.cases = [Self.legalCase("only", nextHearing: "2026-09-20")]
            await model.load()

            XCTAssertEqual(model.groups.count, 1)
        }
    }

    // MARK: - Search

    func testSearchMatchesTheThingsAPractitionerReachesFor() async {
        await withCaseList { service, model in
            service.cases = [
                Self.legalCase("a", title: "Menon vs. Union of India"),
                Self.legalCase("b", title: "Sharma partition suit"),
            ]
            await model.load()

            model.query = "menon"
            XCTAssertEqual(model.visible.map(\.id), ["a"], "by party name")

            model.query = "delhi high"
            XCTAssertEqual(model.visible.count, 2, "by court")

            model.query = "1234"
            XCTAssertEqual(model.visible.count, 2, "by case number")

            model.query = "nothing here"
            XCTAssertTrue(model.visible.isEmpty)
            XCTAssertTrue(model.showsNoSearchResults)
            XCTAssertFalse(model.presentation.showsEmptyState, "the docket is not empty")
        }
    }

    // MARK: - Detail

    func testDetailSplitsHearingsOrdersAndTasks() async {
        await withCaseDetail { service, model in
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"),
                events: [],
                items: [
                    Self.item("h1", section: .hearings, date: "2026-09-14"),
                    Self.item("h2", section: .causelist, date: "2026-09-20"),
                    Self.item("o1", section: .orders, date: "2026-08-01"),
                    Self.item("t1", section: .tasks, date: "2026-09-18"),
                ])
            await model.load()

            XCTAssertEqual(model.hearings.map(\.id), ["h2", "h1"], "newest first")
            XCTAssertEqual(model.orders.map(\.id), ["o1"])
            XCTAssertEqual(model.tasks.map(\.id), ["t1"])
        }
    }

    /// `section` is an unvalidated open string server-side, so a value this build does not know
    /// can appear at any time. Dropping those rows would hide real case data.
    func testUnknownSectionsAreSurfacedRatherThanDropped() async {
        await withCaseDetail { service, model in
            var exotic = Self.item("x1", section: .orders)
            exotic.section = "interlocutory_applications_2"
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [], items: [exotic])
            await model.load()

            XCTAssertEqual(model.otherSections.map(\.section), ["interlocutory_applications_2"])
            XCTAssertEqual(model.otherSections.first?.items.count, 1)
        }
    }

    /// A scraped row is deleted and re-inserted wholesale on every refresh, so an edit survives
    /// only until the next sync and is then removed with no error. Offering the edit is a lie.
    func testScrapedRowsAreNotEditable() async {
        await withCaseDetail { service, model in
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [], items: [])
            await model.load()

            XCTAssertFalse(model.isEditable(Self.item("s", section: .hearings, source: "scrape")))
            XCTAssertTrue(model.isEditable(Self.item("u", section: .tasks, source: "user")))
        }
    }

    /// `last_synced_at` null means **never synced**, not "synced a long time ago". The
    /// difference decides whether a practitioner trusts the hearing date on screen.
    func testNeverSyncedSaysSoRatherThanImplyingAStaleSync() async {
        await withCaseDetail { service, model in
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1", lastSynced: nil), events: [], items: [])
            await model.load()

            XCTAssertFalse(model.isCourtSynced)
            XCTAssertTrue(model.syncDescription.contains("Not synced from the court"))
            XCTAssertTrue(model.syncDescription.contains("entered by hand"))
        }
    }

    func testASyncedCaseReportsWhen() async {
        await withCaseDetail { service, model in
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1", lastSynced: "2026-09-14T04:15:09.882Z"),
                events: [], items: [])
            await model.load()

            XCTAssertTrue(model.isCourtSynced)
            XCTAssertTrue(model.syncDescription.contains("Last synced from the court"))
        }
    }

    // MARK: - Writes

    func testAddingANoteSendsItAndRefreshes() async {
        await withCaseDetail { service, model in
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [], items: [])
            await model.load()

            await model.addNote(title: "Conference", body: "Client confirmed the facts.")

            XCTAssertEqual(service.notesAdded.count, 1)
            XCTAssertEqual(service.notesAdded.first?.body, "Client confirmed the facts.")
            XCTAssertNil(model.writeError)
        }
    }

    func testAnEmptyNoteIsIgnored() async {
        await withCaseDetail { service, model in
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [], items: [])
            await model.load()

            await model.addNote(title: nil, body: "   \n  ")

            XCTAssertTrue(service.notesAdded.isEmpty)
        }
    }

    /// Deleting or writing against an unknown id returns **403, never 404**
    /// (`sync-server.js:9846-9850`), so a stale id reads as a permissions problem. The message
    /// still has to reach the user rather than failing silently.
    func testAWriteFailureIsSurfaced() async {
        await withCaseDetail { service, model in
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [], items: [])
            await model.load()
            service.error = APIError.server(status: 403, message: "Forbidden")

            await model.addNote(title: nil, body: "A note")

            XCTAssertEqual(model.writeError, "Forbidden")
        }
    }

    func testOpeningAnOrderProducesADocument() async {
        await withCaseDetail { service, model in
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [], items: [])
            await model.load()

            await model.openOrder(Self.item("o1", section: .orders, date: "2026-08-01"))

            XCTAssertNotNil(model.openDocument)
            XCTAssertTrue(CaseService.looksLikePDF(model.openDocument?.data ?? Data()))
        }
    }
}

@MainActor
private func withCaseList(
    _ body: @MainActor (FakeCases, CaseListViewModel) async -> Void
) async {
    let service = FakeCases()
    let stamp = Date(timeIntervalSince1970: 1_789_365_600)
    await body(service, CaseListViewModel(service: service, now: { stamp }))
}

@MainActor
private func withCaseDetail(
    _ body: @MainActor (FakeCases, CaseDetailViewModel) async -> Void
) async {
    let service = FakeCases()
    await body(service, CaseDetailViewModel(caseID: "case_1", service: service))
}
