import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

/// The Limitation Radar held to the platform's own JavaScript.
///
/// `Resources/limitation-radar.json` is produced by running `src/features/limitation-radar/audit.js`
/// under Node (`scripts/generate-limitation-fixtures.mjs`): the suit types the web offers, and the
/// audit's answer for a spread of timelines with the lines the web's result card draws from it.
/// When this fails after a platform change, regenerate the fixture and bring the Swift to it.
final class LimitationRadarGoldenTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Profile: Decodable, Equatable {
            let key: String
            let label: String
            let article: String
            let years: Int
            let runsFrom: String
        }
        struct Display: Decodable {
            let days: String
            let lastDay: String
            let mediationExcluded: String?
            let withExclusion: String?
        }
        struct Case: Decodable {
            let name: String
            let input: [String: String]
            let output: JSONValue
            let display: Display
        }
        let profiles: [Profile]
        let defaultKey: String
        let cases: [Case]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "limitation-radar", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func audit(_ output: JSONValue) throws -> LimitationAudit {
        try JSONDecoder().decode(LimitationAudit.self, from: JSONEncoder().encode(output))
    }

    /// `PROFILES`, entry for entry and in the web picker's order, with its default.
    func testTheSuitTypesAreThePlatformsInItsOrder() throws {
        let web = try fixture()
        XCTAssertEqual(
            LimitationProfile.all.map {
                Fixture.Profile(key: $0.key, label: $0.label, article: $0.article, years: $0.years, runsFrom: $0.runsFrom)
            },
            web.profiles)
        XCTAssertEqual(LimitationProfile.defaultKey, web.defaultKey)
    }

    /// Every case decodes into the typed audit with nothing lost that the screen draws.
    func testEveryAnswerDecodes() throws {
        for item in try fixture().cases {
            let audit = try audit(item.output)
            guard case .object(let raw) = item.output else { return XCTFail(item.name) }
            XCTAssertEqual(audit.status, raw["status"]?.stringValue, item.name)
            XCTAssertEqual(audit.statusColor, raw["status_color"]?.stringValue, item.name)
            XCTAssertEqual(audit.bareDeadline, raw["bare_deadline"]?.stringValue, item.name)
            XCTAssertEqual(audit.adjustedDeadline, raw["adjusted_deadline"]?.stringValue, item.name)
            XCTAssertFalse(audit.fatalFlaw.isEmpty, item.name)
            XCTAssertFalse(audit.curativeStrategies.isEmpty, item.name)
            XCTAssertEqual(audit.mediation == nil, raw["mediation"] == nil || raw["mediation"] == .null, item.name)
            XCTAssertEqual(LimitationTone(rawValue: audit.statusColor), audit.tone, item.name)
        }
    }

    /// The result card's lines, worded exactly as the web words them.
    func testTheResultLinesAreTheWebs() throws {
        for item in try fixture().cases {
            let audit = try audit(item.output)
            XCTAssertEqual(audit.daysLine, item.display.days, item.name)
            XCTAssertEqual(audit.lastDayLine, item.display.lastDay, item.name)
            XCTAssertEqual(audit.mediationLine, item.display.mediationExcluded, item.name)
            XCTAssertEqual(audit.withExclusionLine, item.display.withExclusion, item.name)
        }
    }

    /// The fixture covers the outcomes the screen distinguishes, so a regenerated fixture that
    /// lost one would be noticed.
    func testTheCasesCoverEveryOutcome() throws {
        let audits = try fixture().cases.map { try audit($0.output) }
        XCTAssertEqual(Set(audits.map(\.tone)), [.emerald, .amber, .red])
        XCTAssertTrue(audits.contains { $0.mediation?.capped == true })
        XCTAssertTrue(audits.contains { $0.mediation?.beganAfterExpiry == true })
        XCTAssertTrue(audits.contains { $0.mediation?.endAssumed == true })
    }

    /// The request built from each case's input is the body the platform was run with.
    func testTheRequestCarriesTheInputsAsSent() throws {
        for item in try fixture().cases {
            let request = LimitationRequest(
                profile: item.input["profile"] ?? LimitationProfile.defaultKey,
                causeOfAction: item.input["cause_of_action"] ?? "",
                intendedFiling: item.input["intended_filing"] ?? "",
                mediationStart: item.input["mediation_start"] ?? "",
                mediationEnd: item.input["mediation_end"] ?? "")
            var body = request.body(userID: nil)
            if item.input["profile"] == nil { body["profile"] = nil }
            XCTAssertEqual(body, item.input.mapValues { JSONValue.string($0) }, item.name)
        }
    }
}

/// `POST /limitation-radar` on the wire, and the form in front of it.
final class LimitationRadarServiceTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService() async -> LimitationRadarService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return LimitationRadarService(client: client)
    }

    private static let answer = #"""
    {"success":true,"status":"SAFE / WITHIN TIME","status_color":"emerald",
     "statute_applied":"Article 55, Limitation Act, 1963 — 3 years (Compensation for breach of contract)",
     "days_overdue":-10,"fatal_flaw":"In time.","curative_strategies":["File."],
     "period_runs_from":"When the contract is broken.","bare_deadline":"2026-01-15","mediation":null,
     "adjusted_deadline":"2026-01-15","adjusted_days_overdue":-10,"relies_on_mediation_exclusion":false,
     "computed_at":"2026-01-05T10:00:00.000Z"}
    """#

    func testTheTimelineIsPostedWithBlankDatesLeftOut() async throws {
        let service = await makeService()
        HTTPStub.always(.json(Self.answer))

        let audit = try await service.audit(LimitationRequest(
            profile: "money_lent", causeOfAction: "2023-01-15", intendedFiling: "2026-01-05",
            mediationStart: " ", mediationEnd: ""))

        XCTAssertEqual(audit.daysLine, "10 days remaining")
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.path, "/api/limitation-radar")
        XCTAssertEqual(sent.header("Authorization"), "Bearer tok-abc")
        let body = sent.bodyJSON
        XCTAssertEqual(Set(body.keys), ["userId", "profile", "cause_of_action", "intended_filing"])
        XCTAssertEqual(body["profile"] as? String, "money_lent")
        XCTAssertEqual(body["cause_of_action"] as? String, "2023-01-15")
    }

    func testTheEnvelopesMessageIsShownAsWritten() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":{"code":"INVALID_TIMELINE","message":"The filing date is earlier than the cause of action. Check both dates.","detail":{"field":"intended_filing"}}}"#, status: 400))
        do {
            _ = try await service.audit(LimitationRequest(profile: "residuary", causeOfAction: "2024-01-01", intendedFiling: "2023-01-01"))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? APIError, .server(status: 400, message: "The filing date is earlier than the cause of action. Check both dates."))
        }
    }

    func testAnAnswerWithNoSentenceIsWordedAsTheWebWordsIt() {
        XCTAssertThrowsError(try LimitationRadarService.decode(status: 500, data: Data("oops".utf8))) { error in
            XCTAssertEqual(error as? APIError, .server(status: 500, message: "The audit service responded with HTTP 500."))
        }
        XCTAssertThrowsError(try LimitationRadarService.decode(status: 502, data: Data())) { error in
            XCTAssertEqual(error as? APIError, .maintenance(message: APIError.unreachableMessage))
        }
        XCTAssertThrowsError(try LimitationRadarService.decode(status: 200, data: Data("{}".utf8))) { error in
            guard case .decoding = error as? APIError else { return XCTFail("\(error)") }
        }
    }

    /// An unknown colour is drawn in the cautious red.
    func testAnUnknownToneIsRed() {
        XCTAssertEqual(LimitationTone(wire: "violet"), .red)
        XCTAssertEqual(LimitationTone(wire: nil), .red)
        XCTAssertEqual(LimitationTone(wire: "amber"), .amber)
    }

    // MARK: - The form

    func testAnIncompleteFormIsCaughtBeforeAnythingIsSent() async {
        await withRadar { service, model in
            await model.run()
            XCTAssertEqual(model.error, "Enter the date time began to run and the filing date.")
            model.causeOfAction = "2023-01-15"
            await model.run()
            XCTAssertEqual(model.error, "Enter the filing date.")
            model.causeOfAction = ""
            model.intendedFiling = "2026-01-05"
            await model.run()
            XCTAssertEqual(model.error, "Enter the date time began to run.")
            XCTAssertTrue(service.requests.isEmpty)
            XCTAssertNil(model.result)
        }
    }

    func testARunSendsTheFormAndKeepsTheAnswer() async throws {
        let audit = try JSONDecoder().decode(LimitationAudit.self, from: Data(Self.answer.utf8))
        await withRadar { service, model in
            service.audit = audit
            model.profileKey = "declaration"
            model.causeOfAction = "2023-01-15"
            model.intendedFiling = "2026-01-05"
            model.mediationStart = "2024-01-01"
            await model.run()
            XCTAssertEqual(model.result, audit)
            XCTAssertNil(model.error)
            XCTAssertFalse(model.isRunning)
            XCTAssertEqual(service.requests, [LimitationRequest(
                profile: "declaration", causeOfAction: "2023-01-15", intendedFiling: "2026-01-05",
                mediationStart: "2024-01-01", mediationEnd: "")])
            XCTAssertEqual(model.profile.article, "Article 58")
            XCTAssertEqual(model.profile.runsFromHint, "Under Article 58: When the right to sue first accrues.")
        }
    }

    func testAFailureClearsTheAnswerAndSaysWhy() async throws {
        let audit = try JSONDecoder().decode(LimitationAudit.self, from: Data(Self.answer.utf8))
        await withRadar { service, model in
            service.audit = audit
            model.causeOfAction = "2023-01-15"
            model.intendedFiling = "2026-01-05"
            await model.run()
            service.error = APIError.server(status: 400, message: "Mediation ends before it begins. Check both dates.")
            await model.run()
            XCTAssertNil(model.result)
            XCTAssertEqual(model.error, "Mediation ends before it begins. Check both dates.")
            service.error = APIError.transport("The Internet connection appears to be offline.")
            await model.run()
            XCTAssertEqual(model.error, LimitationRadarViewModel.unreachableMessage)
        }
    }

    /// The picker's day is the day sent, in India's zone, both ways.
    func testDaysRoundTripThroughThePicker() throws {
        let date = try XCTUnwrap(LimitationRadarViewModel.date(forDay: "2024-02-29"))
        XCTAssertEqual(LimitationRadarViewModel.day(for: date), "2024-02-29")
        XCTAssertEqual(LimitationProfile.profile(for: "nope").key, LimitationProfile.defaultKey)
        XCTAssertEqual(LimitationProfile.all[0].pickerLabel, "Compensation for breach of contract — Article 55, 3 years")
    }
}

@MainActor
private func withRadar(_ body: @MainActor (FakeLimitationRadar, LimitationRadarViewModel) async -> Void) async {
    let service = FakeLimitationRadar()
    await body(service, LimitationRadarViewModel(service: service))
}
