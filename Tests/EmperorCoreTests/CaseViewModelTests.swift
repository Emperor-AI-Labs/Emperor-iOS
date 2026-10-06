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
    ///
    /// The docket is headed by court unless the user chooses otherwise, so these hearing-date
    /// tests choose it; `CaseListOrganisationTests` covers the court headings.
    func testCasesGroupByWhenTheyAreNextInCourt() async {
        await withCaseList { service, model in
            model.grouping = .hearingDate
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
            model.grouping = .hearingDate
            service.cases = [Self.legalCase("past", nextHearing: "2026-08-01")]
            await model.load()

            XCTAssertEqual(model.groups.first?.title, "Last listed")
        }
    }

    /// A hearing today belongs with what is upcoming, not with what has passed.
    func testTodaysHearingCountsAsUpcoming() async {
        await withCaseList { service, model in
            model.grouping = .hearingDate
            service.cases = [Self.legalCase("today", nextHearing: "2026-09-14")]
            await model.load()

            XCTAssertEqual(model.groups.first?.key, "upcoming")
        }
    }

    func testEmptyGroupsAreOmitted() async {
        await withCaseList { service, model in
            model.grouping = .hearingDate
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

            XCTAssertEqual(model.tabs.map(\.id), ["interlocutory_applications_2"])
            XCTAssertEqual(model.tabs.first?.count, 1)
            XCTAssertEqual(model.tabs.first?.label, "Interlocutory Applications 2",
                           "and it is given a readable name rather than the raw wire value")
        }
    }

    // MARK: - Tabs

    private static func event(_ id: String, date: String? = nil) -> CaseEvent {
        CaseEvent(
            id: id, caseID: "case_1", type: "note", title: "Note \(id)", body: "Body \(id)",
            eventDateRaw: date, createdByUserID: nil, createdAtRaw: nil)
    }

    /// Only sections with rows become tabs. An empty tab is worse than an absent one: it costs a
    /// tap to discover there was nothing there, and a matter fresh from a court portal has most
    /// of the taxonomy empty.
    func testOnlyPopulatedSectionsBecomeTabs() async {
        await withCaseDetail { service, model in
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [],
                items: [
                    Self.item("a1", section: .applications),
                    Self.item("o1", section: .orders),
                ])
            await model.load()

            XCTAssertEqual(model.tabs.map(\.id), ["orders", "applications"],
                           "in taxonomy order, not the order the rows arrived")
            XCTAssertEqual(model.tabs.map(\.label), ["Orders", "Applications"])
        }
    }

    /// `hearings` and `causelist` are one tab. Which of the two a row is filed under is the
    /// court's bookkeeping, not a distinction the reader came here for.
    func testHearingsAndCauseListAreOneTab() async {
        await withCaseDetail { service, model in
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [],
                items: [
                    Self.item("h1", section: .hearings, date: "2026-09-01"),
                    Self.item("c1", section: .causelist, date: "2026-09-10"),
                ])
            await model.load()

            XCTAssertEqual(model.tabs.map(\.id), ["hearings"])
            XCTAssertEqual(model.tabs.first?.count, 2, "both rows, under the one tab")
        }
    }

    /// Folding the two must not depend on which one happens to be present.
    func testACauseListOnlyMatterStillHasAHearingsTab() async {
        await withCaseDetail { service, model in
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [],
                items: [Self.item("c1", section: .causelist)])
            await model.load()

            XCTAssertEqual(model.tabs.map(\.id), ["hearings"])
            XCTAssertEqual(model.tabs.first?.count, 1)
        }
    }

    /// The timeline is not backed by `case_items`, so it carries its own id — `section` is an
    /// open string, and a row filed under `notes` must not collide with it.
    func testTheTimelineIsItsOwnTabAndCannotCollide() async {
        await withCaseDetail { service, model in
            var filed = Self.item("n1", section: .orders)
            filed.section = CaseSection.notes.rawValue
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"),
                events: [Self.event("e1")], items: [filed])
            await model.load()

            XCTAssertEqual(model.tabs.map(\.id), ["notes", "timeline"])
            XCTAssertEqual(Set(model.tabs.map(\.id)).count, model.tabs.count,
                           "two tabs may share a label, never an id")
        }
    }

    /// A matter with no rows and no notes has no tabs at all, so the overview stands on its own
    /// rather than above an empty strip.
    func testAMatterWithNothingInItHasNoTabs() async {
        await withCaseDetail { service, model in
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [], items: [])
            await model.load()

            XCTAssertTrue(model.tabs.isEmpty)
            XCTAssertNil(model.selectedTab)
        }
    }

    /// Before anything is chosen the first tab shows, not a blank panel.
    func testTheFirstTabShowsBeforeAnythingIsChosen() async {
        await withCaseDetail { service, model in
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [],
                items: [Self.item("o1", section: .orders), Self.item("t1", section: .tasks)])
            await model.load()

            XCTAssertNil(model.selectedTabID)
            XCTAssertEqual(model.selectedTab?.id, "orders")
        }
    }

    /// A reload can empty the section being read — a task ticked off on the web, the only note
    /// deleted. That must not strand the screen on a blank panel.
    func testSelectionFallsBackWhenItsTabGoesAway() async {
        await withCaseDetail { service, model in
            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [],
                items: [Self.item("o1", section: .orders), Self.item("t1", section: .tasks)])
            await model.load()
            model.selectedTabID = CaseSection.tasks.rawValue
            XCTAssertEqual(model.selectedTab?.id, "tasks")

            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [],
                items: [Self.item("o1", section: .orders)])
            await model.load()

            XCTAssertEqual(model.selectedTab?.id, "orders")
        }
    }

    /// …and the choice comes back when the section does. It is remembered rather than corrected,
    /// so a section that reappears finds the reader where they left off.
    func testSelectionReturnsWhenItsTabComesBack() async {
        await withCaseDetail { service, model in
            let withTask = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [],
                items: [Self.item("o1", section: .orders), Self.item("t1", section: .tasks)])
            service.detail = withTask
            await model.load()
            model.selectedTabID = CaseSection.tasks.rawValue

            service.detail = CaseDetail(
                legalCase: Self.legalCase("case_1"), events: [],
                items: [Self.item("o1", section: .orders)])
            await model.load()
            XCTAssertEqual(model.selectedTab?.id, "orders", "gone for now")

            service.detail = withTask
            await model.load()
            XCTAssertEqual(model.selectedTab?.id, "tasks", "and back where the reader left it")
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
