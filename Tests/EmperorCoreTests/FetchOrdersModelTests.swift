import XCTest
@testable import EmperorCore

/// Hops onto the main actor: the models are `@MainActor`, and a test class is not (Linux XCTest
/// cannot invoke a `@MainActor` test method).
@MainActor
private func onMain(_ body: @MainActor () async throws -> Void) async rethrows {
    try await body()
}


// Fetch Orders (docs/fetch-orders.md): the dossier's words, the recent-lookups list, the "Add to
// Matters" step, and a case recognised as already tracked.

private let recordJSON = #"""
{"success":true,"cached":true,"record":{
 "case":{"title":"M/S PSTGEMS PRIVATE LIMITED vs. ALISHA ENTERPRISES","courtType":"hc","courtName":"Delhi High Court","caseType":"CS(COMM)",
         "caseNumber":"112","caseYear":"2025","cnr":"DLHC010012342025","diaryNumber":null,"status":"Pending","stage":"ARGUMENTS",
         "bench":"HON'BLE MS. JUSTICE A. SHARMA","filingDate":"2025-02-14","category":"Commercial","nextHearing":"2026-10-28"},
 "parties":{"petitioners":["M/S PSTGEMS PRIVATE LIMITED"],"respondents":["ALISHA ENTERPRISES","STATE OF NCT OF DELHI"],"petitionerAdvocates":["R. MEHTA"],"respondentAdvocates":[]},
 "hearings":[{"date":"2026-10-28","purpose":"ARGUMENTS","courtNo":"12","itemNo":"34","time":"10:30"},
             {"date":"2026-09-10","purpose":"ARGUMENTS","bench":"A. Sharma, J.","courtNo":"COURT NO. 12"},
             {"date":"2025-07-01","purpose":"Reply","remarks":"Four weeks"}],
 "orders":[{"date":"2026-09-10","title":"ORDER","url":"https://court.example/o2.pdf"},{"date":"2025-07-01","title":"Order","url":null}],
 "applications":[],"connected":[],"courtFees":[],"fetchedAt":"2026-10-19T04:00:00.000Z"}}
"""#

private func record() throws -> CourtRecord {
    try XCTUnwrap(try JSONDecoder().decode(CourtLookupResponse.self, from: Data(recordJSON.utf8)).record)
}

private func card() -> CourtSearchResult {
    var result = CourtSearchResult()
    result.courtType = "hc"
    result.courtCode = "hc-delhi"
    result.courtName = "Delhi High Court"
    result.caseType = "CS(COMM)"
    result.caseNumber = "112"
    result.caseYear = "2025"
    result.cnr = "DLHC010012342025"
    result.title = "M/S PSTGEMS PRIVATE LIMITED vs. ALISHA ENTERPRISES"
    return result
}

final class FetchOrdersCourtNamesTests: XCTestCase {

    func testShoutedNamesReadInTitleCaseWithTheAbbreviationsKept() {
        XCTAssertEqual(CourtNames.tidy("M/S PSTGEMS PRIVATE LIMITED"), "M/s Pstgems Private Limited")
        XCTAssertEqual(CourtNames.tidy("STATE OF NCT OF DELHI & ANR."), "State of NCT of Delhi & Anr.")
        XCTAssertEqual(CourtNames.tidy("UNION OF INDIA THROUGH ITS SECRETARY"), "Union of India through Its Secretary")
        XCTAssertEqual(CourtNames.tidy("U.P. STATE ROAD TRANSPORT CORPORATION"), "U.P. State Road Transport Corporation")
        XCTAssertEqual(CourtNames.tidy("DR. RK SHARMA"), "Dr. RK Sharma")
        XCTAssertEqual(CourtNames.tidy("Already Tidy Name"), "Already Tidy Name", "a name that is not shouting is left alone")
        XCTAssertEqual(CourtNames.tidy("SBI"), "SBI", "three letters are not shouting")
        XCTAssertEqual(CourtNames.tidy(nil), "")
    }

    func testACauseTitleGetsItsVersus() {
        XCTAssertEqual(CourtNames.tidy("M/S PSTGEMS PRIVATE LIMITED vs. ALISHA ENTERPRISES", title: true), "M/s Pstgems Private Limited v. Alisha Enterprises")
        XCTAssertEqual(CourtNames.tidy("STATE V. RAM", title: true), "State v. Ram")
        XCTAssertEqual(CourtNames.tidy("K. V. RAO VERSUS STATE", title: true), "K. V. Rao v. State", "an initial V is not a versus when the title has its separator")
        XCTAssertEqual(CourtNames.tidy("A vs B"), "A vs B", "a single party is read without it")
        let long = String(repeating: "ABCDEFGHIJ ", count: 25)
        XCTAssertEqual(CourtNames.tidy(long, title: true).count, 198)
        XCTAssertTrue(CourtNames.tidy(long, title: true).hasSuffix("…"))
    }
}

final class LookupModelTests: XCTestCase {

    func testTheCaseIsNamedAndNumbered() throws {
        let r = try record()
        XCTAssertEqual(LookupModel.caseNumber(of: r.case), "CS(COMM) 112/2025")
        XCTAssertEqual(LookupModel.title(of: r.case), "M/s Pstgems Private Limited v. Alisha Enterprises")
        XCTAssertFalse(LookupModel.isDisposed(r.case))
        XCTAssertEqual(LookupModel.statusWord("Pending"), "Still going")
        XCTAssertEqual(LookupModel.statusWord("Part Heard"), "Part Heard")
        XCTAssertNil(LookupModel.statusWord(""))
        var bare = r.case
        bare.title = nil
        bare.caseNumber = nil
        XCTAssertEqual(LookupModel.title(of: bare), "CS(COMM)")
        bare.caseType = nil
        XCTAssertEqual(LookupModel.title(of: bare), "Untitled case")
    }

    func testSidesRoomsAndCourtText() throws {
        let r = try record()
        let sides = LookupModel.sides(of: r.parties)
        XCTAssertEqual(sides.first.lead, "M/s Pstgems Private Limited")
        XCTAssertEqual(sides.second.names, ["Alisha Enterprises", "State of NCT of Delhi"])
        XCTAssertEqual(sides.first.counsel, ["R. Mehta"])
        XCTAssertEqual(LookupModel.room("12"), "Court 12")
        XCTAssertEqual(LookupModel.room("COURT NO. 12"), "Court 12")
        XCTAssertEqual(LookupModel.room("Registrar (Judicial)"), "Registrar (Judicial)")
        XCTAssertEqual(LookupModel.room(nil), "")
        XCTAssertEqual(LookupModel.plainCourtText("LISTED FOR ARGUMENTS"), "Listed for arguments")
        XCTAssertEqual(LookupModel.plainCourtText("Item NO.94)"), "Item NO.94")
        XCTAssertEqual(LookupModel.identifierLabel("52650/2026"), "Diary no.")
        XCTAssertEqual(LookupModel.identifierLabel("DLHC010012342025"), "CNR")
    }

    func testAgoAndCountdownInAClientsWords() {
        let today = "2026-10-19"
        XCTAssertEqual(LookupModel.ago("2026-10-19", today: today), "today")
        XCTAssertEqual(LookupModel.ago("2026-10-18", today: today), "1 day ago")
        XCTAssertEqual(LookupModel.ago("2026-10-05", today: today), "2 weeks ago")
        XCTAssertEqual(LookupModel.ago("2026-07-01", today: today), "3 months ago")
        XCTAssertEqual(LookupModel.ago("2024-10-01", today: today), "2 years ago")
        XCTAssertEqual(LookupModel.ago("2026-10-28", today: today), "in 9 days")
        XCTAssertEqual(LookupModel.ago("n/a", today: today), "")
        XCTAssertEqual(LookupModel.countdown(to: "2026-10-20", today: today), "Tomorrow")
    }

    func testTheTimelineMixesHearingsAndOrdersNewestFirst() throws {
        let rows = LookupModel.timeline(of: try record(), today: "2026-10-19")
        XCTAssertEqual(rows.map(\.day), ["2026-10-28", "2026-09-10", "2026-09-10", "2025-07-01", "2025-07-01"])
        XCTAssertEqual(rows[0].kind, .next)
        XCTAssertEqual(rows[0].title, "Arguments")
        XCTAssertEqual(rows[0].subtitle, "Court 12")
        XCTAssertTrue(rows.contains { $0.kind == .order && $0.day == "2026-09-10" })
        XCTAssertEqual(LookupModel.years(of: try record().orders), ["2026", "2025"])
    }

    func testTheSidesTakeTheirWordsFromTheKindOfCase() {
        XCTAssertEqual(LookupModel.sideKeys(for: "CS(COMM)").first, "plaintiff")
        XCTAssertEqual(LookupModel.sideKeys(for: "RFA").first, "appellant")
        XCTAssertEqual(LookupModel.sideKeys(for: "Crl.A.").first, "appellant")
        XCTAssertEqual(LookupModel.sideKeys(for: "W.P.(C)").first, "petitioner")
        XCTAssertEqual(LookupModel.sideKeys(for: nil).second, "respondent")
    }
}

final class AddToMattersDraftTests: XCTestCase {

    func testTheDraftOpensNamedWithTheSidesOffered() throws {
        var draft = AddToMattersDraft(record: try record())
        XCTAssertEqual(draft.name, "M/s Pstgems Private Limited v. Alisha Enterprises")
        XCTAssertEqual(draft.sideTitle(.first), "I act for the plaintiff side")
        XCTAssertEqual(draft.sideTitle(.second), "I act for the defendant side")
        XCTAssertEqual(draft.sideDetail(.first), "M/s Pstgems Private Limited")
        XCTAssertEqual(draft.sideDetail(.second), "Alisha Enterprises")
        XCTAssertNil(draft.sideDetail(.none))
        XCTAssertTrue(draft.patchFields.isEmpty, "not sure yet writes nothing")
        draft.side = .second
        XCTAssertEqual(draft.patchFields["ourSide"], .string("defendant"))
        XCTAssertEqual(draft.patchFields["client"], .string("Alisha Enterprises"))
        XCTAssertEqual(draft.patchFields["oppositeParty"], .string("M/s Pstgems Private Limited"))
        draft.name = "   "
        XCTAssertFalse(draft.canSubmit)
    }
}

final class RecentLookupsTests: XCTestCase {

    func testTheListRemembersSixNewestFirstWithoutRepeats() {
        let store = InMemoryPreferenceStore()
        final class Tick: @unchecked Sendable { var n = 0 }
        let tick = Tick()
        let recent = RecentLookups(store: store, now: { tick.n += 1; return Date(timeIntervalSince1970: Double(tick.n) * 86_400) })
        XCTAssertTrue(recent.read().isEmpty)
        for n in 1...7 {
            var c = card()
            c.cnr = "CNR\(n)"
            recent.remember(c, title: "Case \(n)")
        }
        let list = recent.read()
        XCTAssertEqual(list.count, 6)
        XCTAssertEqual(list.first?.title, "Case 7")
        XCTAssertEqual(list.last?.title, "Case 2")
        var again = card()
        again.cnr = "CNR3"
        recent.remember(again, title: "Case 3 again")
        XCTAssertEqual(recent.read().map(\.title).prefix(2), ["Case 3 again", "Case 7"])
        XCTAssertEqual(recent.read().count, 6)
        recent.forget("CNR3")
        XCTAssertFalse(recent.read().contains { $0.key == "CNR3" })
        XCTAssertEqual(recent.read().first?.displayTitle, "Case 7")
        XCTAssertTrue(recent.read().first?.detailLine.hasPrefix("Delhi High Court · CS(COMM) 112/2025 · ") ?? false)
    }

    func testACardWithoutACNRIsKeyedByItsNumber() {
        var c = card()
        c.cnr = nil
        XCTAssertEqual(RecentLookups.key(for: c), "Delhi High Court|CS(COMM)|112|2025")
        c.diaryNumber = "52650/2026"
        XCTAssertEqual(RecentLookups.key(for: c), "52650/2026")
        var entry = RecentLookup(key: "k", card: c, title: "", at: "2026-10-19T00:00:00Z")
        XCTAssertEqual(entry.displayTitle, "CS(COMM) 112/2025")
        entry.title = "A vs B"
        XCTAssertEqual(entry.displayTitle, "A v. B")
    }
}

final class TrackedCasesTests: XCTestCase {

    private func legal(_ id: String, cnr: String? = nil, diary: String? = nil, type: String? = nil, number: String? = nil, year: String? = nil, court: String? = nil, name: String? = nil) -> LegalCase {
        var c = LegalCase(id: id)
        c.cnr = cnr
        c.diaryNumber = diary
        c.caseType = type
        c.caseNumber = number
        c.caseYear = year
        c.courtCode = court
        c.courtName = name
        return c
    }

    func testACaseIsRecognisedByCNRThenByItsNumber() {
        let byCNR = legal("c1", cnr: "dlhc010012342025")
        XCTAssertEqual(TrackedCases.find(card(), in: [byCNR])?.id, "c1", "case-insensitive")
        var numbered = card()
        numbered.cnr = nil
        let byNumber = legal("c2", type: "CS (COMM)", number: "112", year: "2025", court: "hc-delhi")
        XCTAssertEqual(TrackedCases.find(numbered, in: [byNumber])?.id, "c2", "punctuation is ignored")
        let otherCourt = legal("c3", type: "CS(COMM)", number: "112", year: "2025", court: "hc-madras", name: "Madras High Court")
        XCTAssertNil(TrackedCases.find(numbered, in: [otherCourt]))
        var diary = CourtSearchResult()
        diary.diaryNumber = "52650/2026"
        XCTAssertEqual(TrackedCases.find(diary, in: [legal("c4", diary: "52650/2026")])?.id, "c4")
        XCTAssertNil(TrackedCases.find(CourtSearchResult(), in: [legal("c5")]), "no number is no identity")
    }
}

private final class FakeLookupService: CourtLookupProviding, @unchecked Sendable {
    var record: CourtRecord?
    func lookup(_ card: CourtSearchResult) async throws -> CourtRecord {
        guard let record else { throw APIError.server(status: 404, message: "none") }
        return record
    }
}

private final class FakeTrackerService: CourtSearching, @unchecked Sendable {
    var outcome: SaveCaseOutcome = .saved(id: "case_9")
    private(set) var saved: [CourtSearchResult] = []
    func search(_ query: CourtSearchQuery) async throws -> [CourtSearchResult] { [] }
    func startCaptchaSession() async throws -> SupremeCourtCaptcha { throw APIError.transport("n/a") }
    func submitCaptcha(_ answer: String, for query: CourtSearchQuery, session: String) async throws -> CaptchaOutcome { throw APIError.transport("n/a") }
    func save(_ result: CourtSearchResult) async throws -> SaveCaseOutcome { saved.append(result); return outcome }
}

private final class FakeMatters: ProjectProviding, @unchecked Sendable {
    var existing: [Project] = []
    var existed = false
    private(set) var fromCase: [String] = []
    private(set) var patches: [(id: String, fields: [String: JSONValue])] = []
    func projects(includeArchived: Bool) async throws -> [Project] { existing }
    func project(id: String) async throws -> ProjectDetail { throw APIError.server(status: 404, message: "n/a") }
    func projectFromCase(caseID: String) async throws -> (project: Project, existed: Bool) {
        fromCase.append(caseID)
        return (Project(id: "prj_\(caseID)", name: "Pstgems"), existed)
    }
    func patch(projectID: String, fields: [String: JSONValue]) async throws -> Project {
        patches.append((projectID, fields))
        return Project(id: projectID, name: "Pstgems")
    }
}

@MainActor
private func makeLookup(tracked: [LegalCase] = [], matters: [Project] = []) throws -> (FakeTrackerService, FakeMatters, FakeCases, InMemoryPreferenceStore, CourtLookupViewModel) {
        let lookup = FakeLookupService()
        lookup.record = try record()
        let tracker = FakeTrackerService()
        let projects = FakeMatters()
        projects.existing = matters
        let cases = FakeCases()
        cases.cases = tracked
        let store = InMemoryPreferenceStore()
        let model = CourtLookupViewModel(
            card: card(), lookup: lookup, tracker: tracker, projects: projects, cases: cases,
            recent: RecentLookups(store: store), todayKey: { "2026-10-19" })
        return (tracker, projects, cases, store, model)
}

final class FetchOrdersLookupTests: XCTestCase {

    func testTheDossierReadsTheRecordInAClientsWords() async throws {
        try await onMain {
        let (_, _, _, store, model) = try await makeLookup()
        await model.load()
        XCTAssertEqual(model.tidyTitle, "M/s Pstgems Private Limited v. Alisha Enterprises")
        XCTAssertEqual(model.statusWord, "Still going")
        XCTAssertEqual(model.sides?.second.names.count, 2)
        XCTAssertEqual(model.timeline.count, 5)
        XCTAssertEqual(model.sinceLine, "Filed 14 Feb 2025 · 1 year ago")
        XCTAssertEqual(model.orderYears, ["2026", "2025"])
        model.orderYear = "2025"
        XCTAssertEqual(model.filteredOrders.count, 1)
        XCTAssertEqual(model.orderLine(model.filteredOrders[0]), "1 Jul 2025 · 1 year ago")
        XCTAssertTrue(model.isUpcoming(try record().hearings[0]))
        XCTAssertEqual(model.hearingWhere(try record().hearings[0]), "Court 12 · Item 34")
        XCTAssertEqual(model.hearingWhere(try record().hearings[2]), "—")
        XCTAssertEqual(model.hearingWhat(try record().hearings[1]), "Arguments")
        XCTAssertEqual(model.tiles[0].hint, CourtLookupViewModel.Hints.nextHearing)
        XCTAssertEqual(model.keepLabel, "Add to Matters")
        XCTAssertEqual(model.provenanceLine, "Read from the court just now · not saved to your account")
        XCTAssertEqual(RecentLookups(store: store).read().first?.title, "M/S PSTGEMS PRIVATE LIMITED vs. ALISHA ENTERPRISES", "a read case is remembered")
        }
    }

    /// A case already on the docket is recognised, and its matter found: the offer becomes
    /// "Open in Matters".
    func testACaseAlreadyTrackedOffersItsMatter() async throws {
        try await onMain {
        var tracked = LegalCase(id: "case_1")
        tracked.cnr = "DLHC010012342025"
        var matter = Project(id: "prj_1", name: "Pstgems")
        matter.linkedCaseID = "case_1"
        let (tracker, projects, _, _, model) = try await makeLookup(tracked: [tracked], matters: [matter])
        await model.load()
        XCTAssertTrue(model.isTracked)
        XCTAssertEqual(model.matterID, "prj_1")
        XCTAssertEqual(model.keepLabel, "Open in Matters")
        XCTAssertEqual(model.keepTitle, "This case is already in your Matters.")
        let id = await model.addToMatters(draft: nil)
        XCTAssertEqual(id, "prj_case_1", "the known case is used, nothing is saved again")
        XCTAssertTrue(tracker.saved.isEmpty)
        XCTAssertEqual(projects.fromCase, ["case_1"])
        }
    }

    func testAddingWithASideNamesTheMatterAndItsClient() async throws {
        try await onMain {
        let (tracker, projects, _, _, model) = try await makeLookup()
        await model.load()
        var draft = try XCTUnwrap(model.addDraft)
        draft.side = .first
        draft.name = "Pstgems — recovery suit"
        let id = await model.addToMatters(draft: draft)
        XCTAssertEqual(id, "prj_case_9")
        XCTAssertEqual(tracker.saved.count, 1)
        XCTAssertEqual(projects.patches.count, 1)
        XCTAssertEqual(projects.patches.first?.fields["ourSide"], .string("plaintiff"))
        XCTAssertEqual(projects.patches.first?.fields["client"], .string("M/s Pstgems Private Limited"))
        XCTAssertEqual(projects.patches.first?.fields["name"], .string("Pstgems — recovery suit"))
        XCTAssertEqual(model.notice, "\(model.title) is now in your matters.")
        XCTAssertTrue(model.isTracked)
        }
    }

    /// "Already on the dashboard" with the docket in reach: the id is looked up and the matter
    /// still opens.
    func testAnAlreadySavedCaseIsFoundOnTheDocketAndOpened() async throws {
        try await onMain {
        let (tracker, projects, cases, _, model) = try await makeLookup()
        tracker.outcome = .alreadySaved(message: "That case is already on your dashboard.")
        await model.load()
        var known = LegalCase(id: "case_7")
        known.cnr = "DLHC010012342025"
        cases.cases = [known]
        let id = await model.addToMatters(draft: nil)
        XCTAssertEqual(id, "prj_case_7")
        XCTAssertEqual(projects.fromCase, ["case_7"])
        XCTAssertTrue(model.isTracked)
        }
    }
}
