import XCTest
@testable import EmperorCore

// The Matters list's rules, each pinned to what the web's Matters page does with the same rows
// (`src/pages/Projects.jsx`, `src/components/matters/trackedCases.js`).

private func matter(
    _ id: String, name: String, status: String? = nil, area: String? = nil, hearing: String? = nil,
    created: String? = nil, updated: String? = nil, lastActivity: String? = nil, linkedCase: String? = nil,
    caseType: String? = nil, caseNumber: String? = nil, caseYear: String? = nil, client: String? = nil
) -> Project {
    var p = Project(id: id, name: name)
    p.status = status
    p.practiceArea = area
    p.nextHearingDateRaw = hearing
    p.createdAtRaw = created
    p.updatedAtRaw = updated
    p.lastActivityRaw = lastActivity
    p.linkedCaseID = linkedCase
    p.caseType = caseType
    p.caseNumber = caseNumber
    p.caseYear = caseYear
    p.client = client
    return p
}

private func tracked(
    _ id: String, title: String? = "RAJESH KUMAR VS. STATE OF U.P.", status: String? = "Pending",
    hearing: String? = nil, created: String? = nil, teamID: String? = nil
) -> LegalCase {
    var c = LegalCase(id: id)
    c.title = title
    c.status = status
    c.nextHearingDateRaw = hearing
    c.createdAtRaw = created
    c.teamID = teamID
    c.caseType = "W.P.(C)"
    c.caseNumber = "4412"
    c.caseYear = "2025"
    c.courtName = "Delhi High Court"
    return c
}

/// 2026-10-19 at noon in India.
private let noon = Date(timeIntervalSince1970: 1_792_391_400)

final class MatterListingTests: XCTestCase {

    private let today = "2026-10-19"

    // MARK: Status

    func testTheStatusScopeReadsABlankStatusAsActive() {
        let rows = MatterListing.rows(
            projects: [matter("a", name: "A"), matter("h", name: "H", status: "on_hold"), matter("x", name: "X", status: "archived")],
            cases: [], teams: [])
        XCTAssertEqual(MatterListing.scoped(rows, status: .active).map(\.id), ["a"])
        XCTAssertEqual(MatterListing.scoped(rows, status: .onHold).map(\.id), ["h"])
        XCTAssertEqual(MatterListing.scoped(rows, status: .all).count, 3)
        let counts = MatterListing.counts(rows)
        XCTAssertEqual(counts[.active], 1)
        XCTAssertEqual(counts[.archived], 1)
        XCTAssertEqual(counts[.all], 3)
    }

    func testTheStatusLabelsAndScopeWordsAreTheWebs() {
        XCTAssertEqual(MatterStatusFilter.allCases.map(\.label), ["Active", "On hold", "Disposed", "Archived", "All statuses"])
        XCTAssertEqual(MatterStatusFilter.onHold.scopeWords(3), "3 matters on hold")
        XCTAssertEqual(MatterStatusFilter.active.scopeWords(1), "1 active matter")
        XCTAssertEqual(MatterSort.allCases.map(\.label), ["Recent activity", "Next hearing", "Name A–Z"])
    }

    // MARK: Practice areas

    func testTheAreaMenuOffersOnlyAreasPresentInTheVocabularysOrder() {
        let rows = MatterListing.rows(
            projects: [
                matter("1", name: "A", area: "tax"), matter("2", name: "B", area: "civil"),
                matter("3", name: "C", area: "maritime"), matter("4", name: "D"),
            ],
            cases: [], teams: [])
        let options = MatterListing.areaOptions(rows, selected: "")
        XCTAssertEqual(options.map(\.value), ["", "civil", "tax", "maritime", MatterListing.noArea])
        XCTAssertEqual(options.map(\.label), ["All practice areas", "Civil", "Tax", "maritime", "No practice area"])
    }

    func testNoPracticeAreaIsOfferedOnlyBesideARealChoice() {
        let rows = MatterListing.rows(projects: [matter("1", name: "A")], cases: [], teams: [])
        XCTAssertEqual(MatterListing.areaOptions(rows, selected: "").map(\.value), [""])
    }

    func testAChoiceTheDataNoLongerHasStaysInTheMenu() {
        let rows = MatterListing.rows(projects: [matter("1", name: "A", area: "civil")], cases: [], teams: [])
        let options = MatterListing.areaOptions(rows, selected: "tax")
        XCTAssertEqual(options.last, MatterAreaOption(value: "tax", label: "Tax"))
    }

    func testTheAreaFilterFilesAMatterWithNoneUnderNoPracticeArea() {
        let rows = MatterListing.rows(projects: [matter("1", name: "A", area: "civil"), matter("2", name: "B")], cases: [], teams: [])
        let shown = MatterListing.shown(rows, status: .active, area: MatterListing.noArea, query: "", sort: .name, todayKey: today)
        XCTAssertEqual(shown.map(\.id), ["2"])
    }

    // MARK: Search

    func testACaseNumberWrittenAnotherWayStillFindsTheMatter() {
        let rows = MatterListing.rows(
            projects: [matter("1", name: "Menon", caseType: "W.P.(C)", caseNumber: "4412", caseYear: "2025"), matter("2", name: "Other")],
            cases: [], teams: [])
        let shown = MatterListing.shown(rows, status: .active, area: "", query: "wpc 4412/2025", sort: .name, todayKey: today)
        XCTAssertEqual(shown.map(\.id), ["1"])
    }

    func testOneCharacterOfBareSearchIsNotEnoughToMatchLoosely() {
        let rows = MatterListing.rows(projects: [matter("1", name: "Alpha")], cases: [], teams: [])
        XCTAssertTrue(MatterListing.shown(rows, status: .active, area: "", query: "(", sort: .name, todayKey: today).isEmpty)
    }

    // MARK: Sorts

    func testRecentActivityIgnoresAChronologyDateStillToCome() {
        let rows = MatterListing.rows(
            projects: [
                matter("future", name: "Future", created: "2026-01-01 10:00:00", lastActivity: "2026-12-01"),
                matter("edited", name: "Edited", created: "2026-01-01 10:00:00", updated: "2026-10-01T09:00:00.000Z"),
            ],
            cases: [], teams: [], now: noon)
        let shown = MatterListing.sorted(rows, by: .recent, todayKey: today)
        XCTAssertEqual(shown.map(\.id), ["edited", "future"])
    }

    func testRecentActivityBreaksATieByName() {
        let rows = MatterListing.rows(
            projects: [matter("b", name: "Beta", created: "2026-01-01"), matter("a", name: "alpha", created: "2026-01-01")],
            cases: [], teams: [], now: noon)
        XCTAssertEqual(MatterListing.sorted(rows, by: .recent, todayKey: today).map(\.id), ["a", "b"])
    }

    func testNextHearingPutsUpcomingThenPastThenUndated() {
        let rows = MatterListing.rows(
            projects: [
                matter("none", name: "None"),
                matter("past-old", name: "Old", hearing: "2026-09-01"),
                matter("soon", name: "Soon", hearing: "2026-10-21"),
                matter("past-recent", name: "Recent", hearing: "2026-10-15"),
                matter("today", name: "Today", hearing: "2026-10-19"),
            ],
            cases: [], teams: [])
        XCTAssertEqual(
            MatterListing.sorted(rows, by: .hearing, todayKey: today).map(\.id),
            ["today", "soon", "past-recent", "past-old", "none"])
    }

    func testNamesCompareAsNumbersAndIgnoreCase() {
        let rows = MatterListing.rows(
            projects: [matter("10", name: "Suit 10"), matter("2", name: "suit 2"), matter("b", name: "Bail")],
            cases: [], teams: [])
        XCTAssertEqual(MatterListing.sorted(rows, by: .name, todayKey: today).map(\.id), ["b", "2", "10"])
    }

    func testHearingsSoonCountsTodayToSevenDaysOut() {
        let rows = MatterListing.rows(
            projects: [
                matter("1", name: "A", hearing: "2026-10-19"), matter("2", name: "B", hearing: "2026-10-26"),
                matter("3", name: "C", hearing: "2026-10-27"), matter("4", name: "D", hearing: "2026-10-18"),
            ],
            cases: [], teams: [])
        XCTAssertEqual(MatterListing.hearingsSoon(rows, todayKey: today), 2)
    }

    // MARK: Tracked cases

    func testATrackedCaseALinkedMatterAlreadyCoversIsNotListedTwiceEvenWhenArchived() {
        let rows = MatterListing.rows(
            projects: [matter("p1", name: "Menon", status: "archived", linkedCase: "c1")],
            cases: [tracked("c1"), tracked("c2")], teams: [])
        XCTAssertEqual(rows.map(\.id), ["p1", "case:c2"])
    }

    func testATrackedCaseReadsLikeTheMatterItWouldBecome() throws {
        let row = try XCTUnwrap(MatterListing.rows(projects: [], cases: [tracked("c2", status: "Disposed")], teams: []).first)
        XCTAssertEqual(row.name, "Rajesh Kumar v. State of U.P.")
        XCTAssertEqual(row.status, "disposed")
        XCTAssertNil(row.practiceArea)
        XCTAssertEqual(row.caseReference, "W.P.(C) 4412/2025")
        XCTAssertEqual(row.forumName, "Delhi High Court")
        XCTAssertEqual(row.trackedCaseID, "c2")
    }

    func testATrackedCasesActivityIsWhenItWasAddedNotTheHourlyRefresh() throws {
        var kase = tracked("c3", created: "2026-03-01T00:00:00.000Z")
        kase.updatedAtRaw = "2026-10-19T05:00:00.000Z"
        let row = try XCTUnwrap(MatterListing.rows(projects: [], cases: [kase], teams: []).first)
        XCTAssertEqual(row.activity, MatterListing.activityDate("2026-03-01T00:00:00.000Z"))
    }

    func testTheTeamIsNamedOnlyWhenTheCaseIsShared() {
        let teams = [Team(id: "solo", name: "My Firm", memberCount: 1), Team(id: "firm", name: "Litigation", memberCount: 3)]
        let rows = MatterListing.rows(projects: [], cases: [tracked("a", teamID: "solo"), tracked("b", teamID: "firm")], teams: teams)
        XCTAssertEqual(rows.map(\.sharedWith), [nil, "Litigation"])
    }

    func testWhenTwoMattersLinkOneCaseTheOldestWins() {
        let map = MatterListing.matterByCase([
            matter("new", name: "N", created: "2026-05-01 10:00:00", linkedCase: "c1"),
            matter("old", name: "O", created: "2026-01-01 10:00:00", linkedCase: "c1"),
        ])
        XCTAssertEqual(map["c1"]?.id, "old")
    }

    /// FNV-1a over the id, as the web hashes it, so a case wears the same banner everywhere.
    func testACaseAlwaysWearsTheSameBanner() {
        XCTAssertEqual(MatterListing.banner(forCase: "c1"), MatterListing.banner(forCase: "c1"))
        // h = (2166136261 ^ 0x63) * 16777619, then ^ 0x31 and again — mod 8 picks the preset.
        var hash: UInt32 = 2_166_136_261
        for scalar in "case_42".unicodeScalars { hash = (hash ^ scalar.value) &* 16_777_619 }
        XCTAssertEqual(MatterListing.banner(forCase: "case_42"), MatterListing.bannerOrder[Int(hash % 8)])
    }
}

// MARK: - The view model

private final class ListFakes: ProjectProviding, CaseProviding, TeamProviding, @unchecked Sendable {
    var list: [Project] = []
    var cases: [LegalCase] = []
    var teamList: [Team] = []
    var casesError: Error?
    var fromCaseError: Error?
    private(set) var fromCase: [(caseID: String, seed: MatterSeed)] = []

    func projects(includeArchived: Bool) async throws -> [Project] { list }
    func project(id: String) async throws -> ProjectDetail { throw APIError.server(status: 404, message: "no") }
    func projectFromCase(caseID: String) async throws -> (project: Project, existed: Bool) {
        try await projectFromCase(caseID: caseID, seed: MatterSeed())
    }
    func projectFromCase(caseID: String, seed: MatterSeed) async throws -> (project: Project, existed: Bool) {
        if let fromCaseError { throw fromCaseError }
        fromCase.append((caseID, seed))
        let made = matter("prj_\(caseID)", name: "Made", linkedCase: caseID)
        list.append(made)
        return (made, false)
    }

    func cases() async throws -> [LegalCase] {
        if let casesError { throw casesError }
        return cases
    }
    func caseDetail(id: String) async throws -> CaseDetail { throw APIError.server(status: 404, message: "no") }
    func causeList() async throws -> [CauseListing] { [] }
    func addNote(caseID: String, title: String?, body: String) async throws {}
    func addTask(caseID: String, title: String, dueDate: Date?) async throws {}
    func orderDocument(for item: CaseItem, in legalCase: LegalCase) async throws -> Data { Data() }

    func teams() async throws -> [Team] { teamList }
    func createTeam(named name: String) async throws -> String { "t" }
    func addMember(teamID: String, email: String) async throws {}
}

@MainActor
private func withMatters(_ body: @MainActor (ListFakes, ProjectListViewModel) async -> Void) async {
    let fake = ListFakes()
    await body(fake, ProjectListViewModel(service: fake, cases: fake, teams: fake, now: { noon }))
}

final class MatterListViewModelTests: XCTestCase {

    func testTrackedCasesAreListedBesideTheMatters() async {
        await withMatters { fake, model in
            fake.list = [matter("p1", name: "Alpha", created: "2026-01-01")]
            fake.cases = [tracked("c9", created: "2026-02-01T00:00:00.000Z")]
            await model.load()
            XCTAssertEqual(model.visible.map(\.id), ["case:c9", "p1"])
            XCTAssertEqual(model.summary, "2 active matters")
        }
    }

    func testTheSummaryCountsOfTheScopeWhileFiltering() async {
        await withMatters { fake, model in
            fake.list = [matter("p1", name: "Alpha", area: "tax"), matter("p2", name: "Beta", area: "civil")]
            await model.load()
            model.practiceArea = "tax"
            XCTAssertEqual(model.summary, "1 of 2 active matters")
            XCTAssertEqual(model.emptyTitle, ProjectListViewModel.Copy.firstMatterTitle)
            model.query = "beta"
            XCTAssertEqual(model.emptyTitle, "No active matter matches “beta”")
            model.clearFilters()
            XCTAssertEqual(model.visible.count, 2)
        }
    }

    func testNoCountsAreShownBeforeTheListIsIn() async {
        await withMatters { _, model in
            XCTAssertEqual(model.statusOptions.first?.label, "Active")
            XCTAssertEqual(model.summary, "")
        }
    }

    func testStatusCountsOnceLoaded() async {
        await withMatters { fake, model in
            fake.list = [matter("p1", name: "A"), matter("p2", name: "B", status: "archived")]
            await model.load()
            XCTAssertEqual(model.statusOptions.map(\.label), [
                "Active · 1", "On hold · 0", "Disposed · 0", "Archived · 1", "All statuses · 2",
            ])
        }
    }

    func testANoMatterHiddenByStatusPointsAtTheStatusMenu() async {
        await withMatters { fake, model in
            fake.list = [matter("p1", name: "A", status: "archived")]
            await model.load()
            XCTAssertTrue(model.showsNoSearchResults)
            XCTAssertEqual(model.emptyTitle, "No active matters")
            XCTAssertEqual(model.emptyDetail, ProjectListViewModel.Copy.otherStatusesDetail)
        }
    }

    func testACaseThatCouldNotBeReadStillListsTheMatters() async {
        await withMatters { fake, model in
            fake.list = [matter("p1", name: "A")]
            fake.casesError = APIError.transport("offline")
            await model.load()
            XCTAssertEqual(model.visible.map(\.id), ["p1"])
            XCTAssertTrue(model.state.hasLoaded)
        }
    }

    func testOpeningATrackedCaseMakesItsMatterInTheRowsBanner() async {
        await withMatters { fake, model in
            fake.cases = [tracked("c9")]
            await model.load()
            let id = await model.openTrackedCase("c9")
            XCTAssertEqual(id, "prj_c9")
            XCTAssertEqual(fake.fromCase.first?.seed.banner, MatterListing.banner(forCase: "c9").rawValue)
            // Opened, it is a matter now and no longer a tracked-case row.
            XCTAssertEqual(model.visible.map(\.id), ["prj_c9"])
        }
    }

    func testACaseAMatterAlreadyLinksOpensItWithoutARequest() async {
        await withMatters { fake, model in
            fake.list = [matter("p1", name: "A", linkedCase: "c9")]
            fake.cases = [tracked("c9")]
            await model.load()
            let id = await model.openTrackedCase("c9")
            XCTAssertEqual(id, "p1")
            XCTAssertTrue(fake.fromCase.isEmpty)
        }
    }

    func testARefusalToOpenIsTheServersWordsAndAnOutageIsWorded() async {
        await withMatters { fake, model in
            fake.fromCaseError = APIError.server(status: 403, message: "You are not a member of the team that tracks that case")
            let refused = await model.openTrackedCase("c9")
            XCTAssertNil(refused)
            XCTAssertEqual(model.openError, "You are not a member of the team that tracks that case")

            fake.fromCaseError = APIError.transport("The Internet connection appears to be offline.")
            _ = await model.openTrackedCase("c9")
            XCTAssertEqual(model.openError, ProjectListViewModel.Copy.couldNotOpen)
        }
    }
}
