import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Fetch Orders (docs/fetch-orders.md): a case read from the court's own records without being
// added anywhere, and the one button that keeps it.

private let recordJSON = #"""
{"success":true,"cached":false,"record":{
 "case":{"title":"Helios Renewables vs. Northgrid Power","courtType":"hc","courtName":"Delhi High Court","caseType":"ARB.P.",
         "caseNumber":"112","caseYear":"2025","cnr":"DLHC010012342025","diaryNumber":null,"status":"Pending","stage":"Arguments",
         "bench":"Hon'ble Ms. Justice A. Sharma","filingDate":"2025-02-14","category":"Arbitration","nextHearing":"2026-10-28"},
 "parties":{"petitioners":["Helios Renewables Pvt Ltd"],"respondents":["Northgrid Power Ltd","Anr."],"petitionerAdvocates":["R. Mehta"],"respondentAdvocates":[]},
 "hearings":[{"date":"2026-09-10","purpose":"Arguments","bench":"A. Sharma, J.","courtNo":"12","itemNo":"34","time":"10:30"},
             {"date":"2026-07-01","purpose":"Reply","remarks":"Four weeks"}],
 "orders":[{"date":"2026-07-01","title":"Order","url":"https://court.example/o1.pdf"},{"date":"2026-09-10","title":"Order","url":null}],
 "applications":[{"number":"IA 4/2026","particular":"Stay","filedOn":"2026-06-01","status":"Pending"}],
 "connected":[],"courtFees":[],"fetchedAt":"2026-10-19T04:00:00.000Z"}}
"""#

private func card() -> CourtSearchResult {
    var result = CourtSearchResult()
    result.courtType = "hc"
    result.courtCode = "DLHC"
    result.courtName = "Delhi High Court"
    result.caseType = "ARB.P."
    result.caseNumber = "112"
    result.caseYear = "2025"
    result.cnr = "DLHC010012342025"
    result.title = "Helios v. Northgrid"
    result.scrapeRef = .object(["bench": .string("3")])
    return result
}

private final class FakeLookup: CourtLookupProviding, @unchecked Sendable {
    var record: CourtRecord?
    var error: Error?
    private(set) var cards: [CourtSearchResult] = []
    func lookup(_ card: CourtSearchResult) async throws -> CourtRecord {
        cards.append(card)
        if let error { throw error }
        guard let record else { throw APIError.server(status: 404, message: "none") }
        return record
    }
}

private final class FakeTracker: CourtSearching, @unchecked Sendable {
    var outcome: SaveCaseOutcome = .saved(id: "case_9")
    var error: Error?
    private(set) var saved: [CourtSearchResult] = []
    func search(_ query: CourtSearchQuery) async throws -> [CourtSearchResult] { [] }
    func startCaptchaSession() async throws -> SupremeCourtCaptcha { throw APIError.transport("n/a") }
    func submitCaptcha(_ answer: String, for query: CourtSearchQuery, session: String) async throws -> CaptchaOutcome {
        throw APIError.transport("n/a")
    }
    func save(_ result: CourtSearchResult) async throws -> SaveCaseOutcome {
        saved.append(result)
        if let error { throw error }
        return outcome
    }
}

private final class FakeMatterMaker: ProjectProviding, @unchecked Sendable {
    var existed = false
    private(set) var fromCase: [String] = []
    func projects(includeArchived: Bool) async throws -> [Project] { [] }
    func project(id: String) async throws -> ProjectDetail { throw APIError.server(status: 404, message: "n/a") }
    func projectFromCase(caseID: String) async throws -> (project: Project, existed: Bool) {
        fromCase.append(caseID)
        return (Project(id: "prj_\(caseID)", name: "Helios"), existed)
    }
}

private func decodedRecord() throws -> CourtRecord {
    try XCTUnwrap(try JSONDecoder().decode(CourtLookupResponse.self, from: Data(recordJSON.utf8)).record)
}

@MainActor
private func withLookup(
    projects: FakeMatterMaker? = FakeMatterMaker(), today: String = "2026-10-19",
    _ body: @MainActor (FakeLookup, FakeTracker, CourtLookupViewModel) async -> Void
) async {
    let lookup = FakeLookup()
    let tracker = FakeTracker()
    await body(lookup, tracker, CourtLookupViewModel(
        card: card(), lookup: lookup, tracker: tracker, projects: projects, todayKey: { today }))
}

final class CourtRecordTests: XCTestCase {

    func testTheRecordDecodesAndDerivesItsHeadlines() throws {
        let record = try decodedRecord()
        XCTAssertEqual(record.displayTitle, "Helios Renewables vs. Northgrid Power")
        XCTAssertEqual(record.reference, "ARB.P. 112/2025")
        XCTAssertEqual(record.standingLine, "Pending · Arguments")
        XCTAssertEqual(record.holdingsLine, "2 hearings · 2 orders · 1 application")
        XCTAssertEqual(record.latestOrder?.date, "2026-09-10")
        XCTAssertNil(record.latestOrder?.pdfURL)
        XCTAssertEqual(record.lastHearing?.date, "2026-09-10")
        XCTAssertEqual(record.hearings[0].whereLine, "Court 12 · item 34 · 10:30")
        XCTAssertEqual(record.nextHearingKey, "2026-10-28")
    }

    /// A court that sends no advocates sends no key. The parties block must not fail for it.
    func testMissingPartyListsReadAsEmpty() throws {
        let parties = try JSONDecoder().decode(CourtRecord.Parties.self, from: Data(#"{"petitioners":["A"]}"#.utf8))
        XCTAssertEqual(parties.petitioners, ["A"])
        XCTAssertTrue(parties.respondentAdvocates.isEmpty)
    }

    func testATitlelessRecordIsNamedFromItsParties() throws {
        var record = try decodedRecord()
        record.case.title = nil
        XCTAssertEqual(record.displayTitle, "Helios Renewables Pvt Ltd v. Northgrid Power Ltd")
        record.case.caseNumber = nil
        record.case.diaryNumber = "52650/2026"
        XCTAssertEqual(record.reference, "Diary 52650/2026")
    }
}

final class CourtLookupViewModelTests: XCTestCase {

    func testTheFourTilesAnswerPlainly() async throws {
        let record = try decodedRecord()
        await withLookup { lookup, _, model in
            lookup.record = record
            await model.load()
            XCTAssertEqual(model.tiles.map(\.label), ["Next hearing", "Where it stands", "Latest order", "What the court holds"])
            XCTAssertEqual(model.tiles[0].value, "In 9 days")
            XCTAssertEqual(model.tiles[0].detail, "Wednesday, 28 October 2026")
            XCTAssertEqual(model.tiles[1].value, "Pending · Arguments")
            XCTAssertEqual(model.tiles[1].detail, "Before Hon'ble Ms. Justice A. Sharma")
            XCTAssertEqual(model.tiles[2].value, "Thursday, 10 September 2026")
            XCTAssertEqual(model.tiles[3].value, "2 hearings · 2 orders · 1 application")
            XCTAssertEqual(model.subtitle, "ARB.P. 112/2025 · Delhi High Court")
            XCTAssertEqual(model.identifiers.map(\.label), ["CNR", "Filed", "Category"])
        }
    }

    func testNoNextDateSaysSoAndNamesTheLastOne() async throws {
        var record = try decodedRecord()
        record.case.nextHearing = nil
        record.orders = []
        await withLookup { lookup, _, model in
            lookup.record = record
            await model.load()
            XCTAssertEqual(model.tiles[0].value, "Not listed yet")
            XCTAssertEqual(model.tiles[0].detail, "Last heard Thursday, 10 September 2026")
            XCTAssertEqual(model.tiles[2].value, "None on record")
        }
    }

    func testALookupFailureIsWordedAndRetryable() async {
        await withLookup { lookup, _, model in
            lookup.error = APIError.server(status: 502, message: "The court's website did not answer. Try again in a few minutes.")
            await model.load()
            XCTAssertEqual(model.state.failure?.message, "The court's website did not answer. Try again in a few minutes.")
            XCTAssertTrue(model.state.failure?.isRetryable ?? false)
            XCTAssertNotNil(model.presentation.state.failure)
        }
    }

    /// Adding is the existing save, then the matter for the case — so the workspace opens with
    /// the court case already linked.
    func testAddingTracksTheCaseAndOpensItsMatter() async throws {
        let record = try decodedRecord()
        await withLookup { lookup, tracker, model in
            lookup.record = record
            await model.load()
            let id = await model.addToMatters()
            XCTAssertEqual(id, "prj_case_9")
            XCTAssertEqual(tracker.saved.count, 1)
            XCTAssertTrue(model.isTracked)
            XCTAssertEqual(model.notice, "Helios Renewables vs. Northgrid Power is now in your matters.")
            XCTAssertNil(model.addError)
        }
    }

    func testACaseAlreadyTrackedIsTheOutcomeWantedNotAnError() async {
        await withLookup { _, tracker, model in
            tracker.outcome = .alreadySaved(message: "That case is already on your dashboard.")
            let id = await model.addToMatters()
            XCTAssertNil(id)
            XCTAssertTrue(model.isTracked)
            XCTAssertEqual(model.notice, "That case is already on your dashboard. Open it from Matters.")
            XCTAssertNil(model.addError)
        }
    }

    /// The collision refusal means the case is NOT on the docket, and must read as such.
    func testANumberlessCollisionIsARefusal() async {
        await withLookup { _, tracker, model in
            tracker.outcome = .refusedAsIndistinguishable(message: "This court has not numbered the case yet.")
            _ = await model.addToMatters()
            XCTAssertFalse(model.isTracked)
            XCTAssertEqual(model.addError, "This court has not numbered the case yet.")
        }
    }

    func testTheSummaryAndTheQuestionCarryTheRecord() async throws {
        let record = try decodedRecord()
        await withLookup { lookup, _, model in
            lookup.record = record
            await model.load()
            let summary = model.summaryText
            XCTAssertTrue(summary.hasPrefix("Helios Renewables vs. Northgrid Power\nARB.P. 112/2025 · Delhi High Court\nCNR: DLHC010012342025"), summary)
            XCTAssertTrue(summary.contains("- Wednesday, 1 July 2026: Order https://court.example/o1.pdf"), summary)
            XCTAssertTrue(summary.hasSuffix("Confirm with the court before acting on it."), summary)
            XCTAssertEqual(
                model.askPrompt,
                "I am looking at Helios Renewables vs. Northgrid Power (ARB.P. 112/2025 · Delhi High Court) — the court shows it as Pending · Arguments, it is next listed on Wednesday, 28 October 2026 and the latest order is dated Thursday, 10 September 2026. What is this case about, where does it stand, and what should I prepare next?")
        }
    }
}

final class CourtLookupWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() { super.setUp(); HTTPStub.reset() }
    override func tearDown() { HTTPStub.reset(); super.tearDown() }

    private func makeService() async -> CourtLookupService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return CourtLookupService(client: client)
    }

    /// The card goes nested under `card`, with `scrapeRef` verbatim, and the caller beside it.
    func testTheCardTravelsNestedWithItsScrapeRef() async throws {
        let service = await makeService()
        HTTPStub.always(.json(recordJSON))
        let record = try await service.lookup(card())
        XCTAssertEqual(record.reference, "ARB.P. 112/2025")
        let request = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/court/lookup")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["userId"] as? String, "42")
        let sent = try XCTUnwrap(body["card"] as? [String: Any])
        XCTAssertEqual(sent["cnr"] as? String, "DLHC010012342025")
        XCTAssertEqual(sent["courtType"] as? String, "hc")
        XCTAssertEqual((sent["scrapeRef"] as? [String: Any])?["bench"] as? String, "3")
        XCTAssertNil(sent["diaryNumber"])
    }

    func testEachCodeIsWordedForTheReader() async {
        let service = await makeService()
        let cases: [(String, Int, String)] = [
            ("RATE_LIMIT", 429, "That is a lot of lookups at once. Wait a minute and try again."),
            ("NOT_FOUND", 404, "The court returned no details for this case. Check the number and year, or try again later."),
            ("COURT_DOWN", 502, "The court's website did not answer. Try again in a few minutes."),
            ("BAD_REQUEST", 400, "That case could not be read. Search for it again."),
        ]
        for (code, status, message) in cases {
            HTTPStub.always(.json(#"{"success":false,"code":"\#(code)","error":"server words (adapter detail)"}"#, status: status))
            do {
                _ = try await service.lookup(card())
                XCTFail("expected \(code)")
            } catch let error as APIError {
                XCTAssertEqual(error, .server(status: status, message: message), code)
            } catch { XCTFail("\(error)") }
        }
    }

    func testAnAuthRefusalIsASignOut() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"code":"AUTH","error":"Please sign in again"}"#, status: 401))
        do {
            _ = try await service.lookup(card())
            XCTFail("expected 401")
        } catch let error as APIError {
            XCTAssertEqual(error, .invalidCredentials)
        } catch { XCTFail("\(error)") }
    }
}
