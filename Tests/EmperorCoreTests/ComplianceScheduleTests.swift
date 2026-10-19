import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The company-profile half of the Corporate Calendar: `ComplianceSchedule` against the web's own
/// `complianceSchedule.js` (regenerate with
/// `node scripts/generate-compliance-schedule-fixtures.mjs <platform>`), the merge with the feed,
/// the companies kept on the device, and marking a deadline done.
final class ComplianceScheduleGoldenTests: XCTestCase {

    struct Fixture: Decodable {
        struct Obligation: Decodable {
            struct Schedule: Decodable {
                struct MonthDay: Decodable { let month: Int; let day: Int }
                struct Override: Decodable { let day: Int; let note: String }
                let kind: String
                let month: Int?
                let day: Int?
                let offsetDays: Int?
                let dates: [MonthDay]?
                let overrides: [String: Override]?
            }
            let id: String
            let category: String
            let name: String
            let frequency: String
            let authority: String
            let description: String
            let schedule: Schedule
            let conditional: Bool
        }
        struct Event: Decodable { let id: String; let overrideNote: String? }
        struct Case: Decodable {
            let name: String
            let from: String
            let to: String
            let summary: String
            let events: [Event]
        }
        let categoryOrder: [String]
        let categoryLabels: [String: String]
        let ptStates: [String]
        let indianStates: [String]
        let obligations: [Obligation]
        let cases: [Case]
    }

    static func data() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "schedule", withExtension: "json", subdirectory: "compliance-schedule"))
        return try Data(contentsOf: url)
    }

    static func fixture() throws -> Fixture { try JSONDecoder().decode(Fixture.self, from: data()) }

    /// Each case's profile, which has no `id` in the fixture (the web adds one on save).
    static func profiles() throws -> [String: CompanyProfile] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        var out: [String: CompanyProfile] = [:]
        for item in cases {
            var profile = try XCTUnwrap(item["profile"] as? [String: Any])
            profile["id"] = "co-test"
            let json = try JSONSerialization.data(withJSONObject: profile)
            out[try XCTUnwrap(item["name"] as? String)] = try JSONDecoder().decode(CompanyProfile.self, from: json)
        }
        return out
    }

    func testTheCategoriesAreTheWebs() throws {
        let fixture = try Self.fixture()
        XCTAssertEqual(ComplianceCategory.allCases.map(\.rawValue), fixture.categoryOrder)
        for category in ComplianceCategory.allCases {
            XCTAssertEqual(category.label, fixture.categoryLabels[category.rawValue])
        }
    }

    func testTheStatesAreTheWebs() throws {
        let fixture = try Self.fixture()
        XCTAssertEqual(ComplianceSchedule.professionalTaxStates, fixture.ptStates)
        XCTAssertEqual(ComplianceSchedule.indianStates, fixture.indianStates)
    }

    func testANewCompanyAssumesNothing() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.data()) as? [String: Any])
        var web = try XCTUnwrap(root["newCompany"] as? [String: Any])
        web["id"] = "co-x"
        let decoded = try JSONDecoder().decode(
            CompanyProfile.self, from: JSONSerialization.data(withJSONObject: web))
        XCTAssertEqual(decoded, CompanyProfile(id: "co-x"))
    }

    func testEveryObligationIsTheWebs() throws {
        let fixture = try Self.fixture()
        XCTAssertEqual(ComplianceSchedule.obligations.map(\.id), fixture.obligations.map(\.id))
        for (ours, web) in zip(ComplianceSchedule.obligations, fixture.obligations) {
            XCTAssertEqual(ours.category.rawValue, web.category, ours.id)
            XCTAssertEqual(ours.name, web.name, ours.id)
            XCTAssertEqual(ours.frequency, web.frequency, ours.id)
            XCTAssertEqual(ours.authority, web.authority, ours.id)
            XCTAssertEqual(ours.description, web.description, ours.id)
            XCTAssertEqual(ours.condition != nil, web.conditional, ours.id)
            let s = web.schedule
            switch ours.rule {
            case .annual(let month, let day):
                XCTAssertEqual(s.kind, "annual", ours.id)
                XCTAssertEqual([month, day], [s.month, s.day].compactMap { $0 }, ours.id)
            case .afterAGM(let days):
                XCTAssertEqual(s.kind, "agm", ours.id)
                XCTAssertEqual(days, s.offsetDays, ours.id)
            case .dates(let dates):
                XCTAssertTrue(["quarterly", "custom"].contains(s.kind), ours.id)
                XCTAssertEqual(dates.map { [$0.month, $0.day] }, (s.dates ?? []).map { [$0.month, $0.day] }, ours.id)
            case .monthly(let day, let overrides):
                XCTAssertEqual(s.kind, "monthly", ours.id)
                XCTAssertEqual(day, s.day, ours.id)
                XCTAssertEqual(
                    overrides.mapValues { "\($0.day)|\($0.note)" },
                    Dictionary(uniqueKeysWithValues: (s.overrides ?? [:]).map { (Int($0.key)!, "\($0.value.day)|\($0.value.note)") }),
                    ours.id)
            }
        }
    }

    /// The generator, profile by profile and window by window, against the web's own output.
    func testTheGeneratorMatchesTheWebForEveryCase() throws {
        let fixture = try Self.fixture()
        let profiles = try Self.profiles()
        XCTAssertGreaterThan(fixture.cases.count, 20)
        for item in fixture.cases {
            let profile = try XCTUnwrap(profiles[item.name])
            let ours = ComplianceSchedule.generate(from: item.from, to: item.to, profile: profile)
            XCTAssertEqual(ours.map(\.id), item.events.map(\.id), item.name)
            XCTAssertEqual(ours.map(\.overrideNote), item.events.map(\.overrideNote), item.name)
            XCTAssertEqual(profile.summary, item.summary, item.name)
        }
    }

    func testTheWindowIsTheWebs() throws {
        let window = try XCTUnwrap(ComplianceSchedule.window(around: "2026-10-19"))
        let fixture = try Self.fixture()
        let page = try XCTUnwrap(fixture.cases.first { $0.name.hasPrefix("page-window-2026-10-19/") })
        XCTAssertEqual(window.from, page.from)
        XCTAssertEqual(window.to, page.to)
    }

    func testCivilDaysRollOverAsJavaScriptDatesDo() {
        XCTAssertEqual(CivilDay(year: 2026, month: 4, day: 31).key, "2026-05-01")
        XCTAssertEqual(CivilDay(year: 2026, month: 13, day: 1).key, "2027-01-01")
        XCTAssertEqual(CivilDay(year: 2024, month: 2, day: 29).key, "2024-02-29")
        XCTAssertEqual(CivilDay(year: 2026, month: 12, day: 31).adding(days: 60).key, "2027-03-01")
        XCTAssertNil(CivilDay(key: "2026-02-30"))
        XCTAssertNil(CivilDay(key: "26-02-03"))
    }
}

// MARK: - The screen, with companies

final class ComplianceCompanyViewModelTests: XCTestCase {

    /// 3 October 2026, 12:00 IST, as `ComplianceCalendarTests`.
    static let noon = ComplianceCalendarTests.fixtureNoon

    static func company(_ name: String = "Acme Private Limited", gst: Bool = false) -> CompanyProfile {
        var company = CompanyProfile(id: "co-acme", name: name)
        company.gstRegistered = gst
        return company
    }

    func testWithNoCompanyTheScreenIsTheGeneralCalendar() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompanies { service, model, _ in
            service.rows = rows
            await model.load()
            XCTAssertNil(model.activeCompany)
            XCTAssertEqual(model.deadlines.count, ComplianceFeedFixture.datedRowCount)
            XCTAssertFalse(model.deadlines.contains(where: \.fromCompanyProfile))
            XCTAssertTrue(model.companyLine.hasPrefix("Showing the general statutory calendar."))
        }
    }

    /// With a company, its own deadlines join the feed's, and the feed's copy of anything the
    /// generator produces is dropped — one filing, one row.
    func testACompanysDeadlinesReplaceTheFeedsCopies() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompanies { service, model, _ in
            service.rows = rows
            await model.load()
            XCTAssertNil(model.saveCompany(Self.company(gst: true)))

            XCTAssertEqual(model.activeCompany?.name, "Acme Private Limited")
            XCTAssertFalse(model.deadlines.contains { $0.complianceID == "GSTR1" },
                           "the feed's GSTR-1 gives way to the company's")
            XCTAssertTrue(model.deadlines.contains { $0.id == "stat:gstr1:2026-10-11" })
            XCTAssertTrue(model.deadlines.contains { $0.complianceID == "ECB2" },
                          "an obligation the generator does not produce stays")
            let generated = model.deadlines.filter(\.fromCompanyProfile)
            XCTAssertEqual(
                generated.map(\.id).sorted(),
                ComplianceSchedule.generate(from: "2026-08-04", to: "2027-10-04", profile: Self.company(gst: true))
                    .map(\.id).sorted())
            let days = model.deadlines.compactMap(\.dueDay)
            XCTAssertEqual(days, days.sorted())
        }
    }

    func testAGeneratedRowReadsLikeTheWebsEventRow() throws {
        let deadline = try XCTUnwrap(ComplianceSchedule.generate(
            from: "2027-04-01", to: "2027-04-30", profile: Self.company()
        ).first { $0.obligationID == "tdspay" })
        let row = try XCTUnwrap(ComplianceSchedule.row(for: deadline))
        XCTAssertEqual(row.id, "stat:tdspay:2027-04-30")
        XCTAssertEqual(row.displayTitle, "TDS Payment")
        XCTAssertEqual(row.category, .tds)
        XCTAssertEqual(row.regulator, "Income-tax Act, s.200")
        XCTAssertEqual(row.frequencyLabel, "Monthly")
        XCTAssertEqual(row.dueDay, "2027-04-30")
        XCTAssertEqual(
            row.note,
            "Deposit TDS by the 7th of the following month (March deductions by 30 April). TDS deducted in March is due 30 April.")
        XCTAssertFalse(row.differsFromUsualSchedule)
    }

    func testCompaniesAreKeptOnTheDeviceAndTheChoiceIsRemembered() async {
        let prefs = InMemoryPreferenceStore()
        await withCompanies(prefs: prefs) { _, model, _ in
            model.saveCompany(Self.company())
            var second = CompanyProfile(id: "co-two", name: "  Beta LLP  ")
            second.listed = true
            model.saveCompany(second)
            XCTAssertEqual(model.activeCompanyID, "co-two", "a saved company becomes the chosen one")
            XCTAssertEqual(model.activeCompany?.name, "Beta LLP", "the name is trimmed")
            model.selectCompany("co-acme")
        }
        XCTAssertEqual(prefs.string(for: "emperor-compliance-active"), "co-acme")
        await withCompanies(prefs: prefs) { _, model, _ in
            XCTAssertEqual(model.companies.map(\.id), ["co-acme", "co-two"])
            XCTAssertEqual(model.activeCompanyID, "co-acme")
            XCTAssertTrue(model.companies[1].listed)

            model.deleteCompany(id: "co-acme")
            XCTAssertEqual(model.activeCompanyID, "co-two", "the first remaining company is chosen")
            model.deleteCompany(id: "co-two")
            XCTAssertNil(model.activeCompany)
        }
        XCTAssertEqual(prefs.string(for: "emperor-compliance-companies"), "[]")
        XCTAssertEqual(prefs.string(for: "emperor-compliance-active"), "")
    }

    func testANamelessCompanyIsRefused() async {
        await withCompanies { _, model, _ in
            XCTAssertEqual(model.saveCompany(CompanyProfile(id: "co-x", name: "   ")), "Enter a company name.")
            XCTAssertTrue(model.companies.isEmpty)
        }
    }

    /// The web's storage, read as the web wrote it — extra keys ignored, a broken entry skipped.
    func testTheWebsStoredShapeIsRead() async {
        let prefs = InMemoryPreferenceStore()
        prefs.setString("""
            [{"id":"co-1","name":"Acme","listed":true,"hasEmployees":false,"gstRegistered":true,
              "foreignDealings":false,"taxAudit":false,"csr":false,"state":"Kerala","agmMonth":12,"agmDay":15,"_extra":1},
             {"name":"no id"}]
            """, for: CompanyProfileStore.companiesKey)
        prefs.setString("co-gone", for: CompanyProfileStore.activeKey)
        let store = CompanyProfileStore(store: prefs)
        let list = store.companies()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.state, "Kerala")
        XCTAssertEqual(list.first?.agmLabel, "15 December")
        XCTAssertEqual(list.first?.summary, "Listed company · GST-registered · Kerala")
        await withCompanies(prefs: prefs) { _, model, _ in
            XCTAssertEqual(model.activeCompanyID, "co-1", "a remembered id that is gone falls back")
        }
    }

    func testNewIDsHaveTheWebsShape() {
        XCTAssertEqual(CompanyProfile.newID(now: Date(timeIntervalSince1970: 1_791_009_000), random: 42),
                       "co-" + String(Int64(1_791_009_000_000), radix: 36) + "-42")
        XCTAssertEqual(CompanyProfile.agmDays(inMonth: 2), 1...28)
        XCTAssertEqual(CompanyProfile.agmDays(inMonth: 9), 1...30)
    }

    // MARK: - Done

    func testTickingADeadlineSendsTheWebsMarker() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompanies { service, model, _ in
            service.rows = rows
            service.markers = [ComplianceEvent(id: "stat:GSTR1:2026-10-11", status: "open", notes: "Filed by CA")]
            await model.load()
            let gstr1 = try! XCTUnwrap(model.deadline(id: "stat:GSTR1:2026-10-11"))
            XCTAssertFalse(model.isDone(gstr1))

            await model.toggleDone(gstr1)

            XCTAssertTrue(model.isDone(gstr1))
            XCTAssertNil(model.writeError)
            XCTAssertEqual(service.savedMarkers, [StatutoryMarker(deadline: gstr1, done: true, notes: "Filed by CA")])
            let marker = service.savedMarkers[0]
            XCTAssertEqual(marker.id, "stat:GSTR1:2026-10-11")
            XCTAssertEqual(marker.type, "gst")
            XCTAssertEqual(marker.dueDate, "2026-10-11")
            XCTAssertEqual(marker.title, "GSTR-1")

            await model.toggleDone(gstr1)
            XCTAssertFalse(model.isDone(gstr1))
            XCTAssertEqual(service.savedMarkers.last?.isDone, false)
        }
    }

    func testAGeneratedDeadlineIsTickedUnderItsOwnID() async throws {
        await withCompanies { _, model, _ in
            await model.load()
            model.saveCompany(Self.company())
            let aoc4 = try! XCTUnwrap(model.deadlines.first { $0.id.hasPrefix("stat:aoc4:") })
            let marker = StatutoryMarker(deadline: aoc4, done: true, notes: nil)
            XCTAssertEqual(marker.id, "stat:aoc4:2026-10-30")
            XCTAssertEqual(marker.type, "mca")
            XCTAssertEqual(marker.title, "AOC-4 — Financial Statements")
        }
    }

    func testARefusedTickIsTakenBack() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        await withCompanies { service, model, _ in
            service.rows = rows
            await model.load()
            let gstr1 = try! XCTUnwrap(model.deadline(id: "stat:GSTR1:2026-10-11"))
            service.saveError = APIError.server(status: 403, message: "Not a team member")
            await model.toggleDone(gstr1)
            XCTAssertFalse(model.isDone(gstr1))
            XCTAssertEqual(model.writeError, "Could not mark this done. Not a team member")
            XCTAssertFalse(model.isWriting(gstr1))
        }
    }

    func testATickSurvivesInTheCache() async throws {
        let rows = try ComplianceCalendarTests.fixtureRows()
        let cache = ResponseCache(store: InMemoryCacheStore(), now: { Self.noon })
        await withCompanies(cache: cache) { service, model, _ in
            service.rows = rows
            await model.load()
            await model.toggleDone(try! XCTUnwrap(model.deadline(id: "stat:GSTR1:2026-10-11")))
        }
        await withCompanies(cache: cache) { service, model, _ in
            service.error = APIError.transport("offline")
            await model.load()
            XCTAssertTrue(model.doneIDs.contains("stat:GSTR1:2026-10-11"))
        }
    }

    // MARK: - On the wire

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

    func testTheMarkerIsTheWebsBody() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"id":"stat:GSTR1:2026-10-11"}"#))
        let row = try ComplianceCalendarTests.row("stat:GSTR1:2026-10-11")
        try await service.saveMarker(StatutoryMarker(deadline: row, done: true, notes: nil))

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.path, "/api/compliance-event")
        let body = sent.bodyJSON
        XCTAssertEqual(body["userId"] as? String, "42")
        XCTAssertEqual(body["id"] as? String, "stat:GSTR1:2026-10-11")
        XCTAssertEqual(body["title"] as? String, "GSTR-1")
        XCTAssertEqual(body["type"] as? String, "gst")
        XCTAssertEqual(body["dueDate"] as? String, "2026-10-11")
        XCTAssertEqual(body["status"] as? String, "done")
        XCTAssertTrue(body["notes"] is NSNull)
        XCTAssertTrue(body["remindDays"] is NSNull)
        XCTAssertNil(body["teamId"], "no team chosen: the server files it under the user's own")
    }

    func testARowWithNoCategoryIsAFiling() throws {
        let row = try JSONDecoder().decode(StatutoryDeadline.self, from: Data("""
            {"id":"stat:X:2026-11-01","dateKey":"2026-11-01","title":"Something"}
            """.utf8))
        XCTAssertEqual(StatutoryMarker(deadline: row, done: false, notes: "").type, "filing")
        XCTAssertNil(StatutoryMarker(deadline: row, done: false, notes: "").notes)
    }

    func testARefusalThrowsTheServersWords() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":"Not a team member"}"#, status: 403))
        let row = try ComplianceCalendarTests.row("stat:GSTR1:2026-10-11")
        do {
            try await service.saveMarker(StatutoryMarker(deadline: row, done: true, notes: nil))
            XCTFail("a refusal must throw")
        } catch {
            XCTAssertEqual(DisplayText.message(for: error), "Not a team member")
        }
    }
}

@MainActor
private func withCompanies(
    prefs: InMemoryPreferenceStore = InMemoryPreferenceStore(),
    cache: ResponseCache? = nil,
    _ body: @MainActor (FakeComplianceCalendar, ComplianceCalendarViewModel, CompanyProfileStore) async -> Void
) async {
    let service = FakeComplianceCalendar()
    let store = CompanyProfileStore(store: prefs)
    let stamp = ComplianceCompanyViewModelTests.noon
    await body(service, ComplianceCalendarViewModel(
        service: service, cache: cache, companies: store, now: { stamp }), store)
}
