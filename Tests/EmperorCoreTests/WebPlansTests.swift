import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

/// The way to a plan: the web app's plans page, in the browser, offered only where a plan is the
/// answer — and gone entirely from a build that switches it off.
@MainActor
final class WebPlansTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    /// The plans page is on the host the account lives on — a development build buys on the
    /// development server, never on production with a development account.
    func testThePlansPageIsOnTheSameHostAsTheAccount() {
        XCTAssertEqual(
            WebPlans(isOffered: true, apiBaseURL: APIEnvironment.production.baseURL).url.absoluteString,
            "https://app.emperorailabs.com/buy")
        XCTAssertEqual(
            WebPlans(isOffered: true, apiBaseURL: APIEnvironment.development.baseURL).url.absoluteString,
            "https://dev.emperorailabs.com/buy")
        XCTAssertEqual(
            WebPlans.plansURL(apiBaseURL: URL(string: "https://example.test")!).absoluteString,
            "https://example.test/buy")
    }

    func testTheBuildSwitch() {
        let api = APIEnvironment.production.baseURL
        XCTAssertTrue(WebPlans(info: [:], apiBaseURL: api).isOffered, "on by default")
        XCTAssertTrue(WebPlans(info: ["EmperorWebPlans": "YES"], apiBaseURL: api).isOffered)
        XCTAssertTrue(WebPlans(info: ["EmperorWebPlans": "$(EMPEROR_WEB_PLANS)"], apiBaseURL: api).isOffered)
        XCTAssertFalse(WebPlans(info: ["EmperorWebPlans": "NO"], apiBaseURL: api).isOffered)
        XCTAssertFalse(WebPlans(info: ["EmperorWebPlans": " false "], apiBaseURL: api).isOffered)
        XCTAssertFalse(WebPlans(info: ["EmperorWebPlans": false], apiBaseURL: api).isOffered)
    }

    /// Only where a plan changes the answer. A paused account is the administrator's to restore,
    /// and the hourly ceiling clears by itself; offering plans there would be selling something
    /// that does not help.
    func testOfferedOnlyWhereAPlanIsTheAnswer() {
        let plans = WebPlans(isOffered: true, apiBaseURL: APIEnvironment.production.baseURL)
        let offered: Set<Refusal.Code> = [
            .planRequired, .queryLimit, .featureNotInPlan, .documentLimit, .storageLimit,
            .matterLimit, .scanLimit,
        ]
        for code in Refusal.Code.allCases {
            let refusal = Refusal(code: code, status: 402, serverMessage: "")
            XCTAssertEqual(plans.isOffered(for: refusal), offered.contains(code), "\(code)")
        }
        XCTAssertTrue(plans.isOffered(for: .noPlan))
        XCTAssertFalse(plans.isOffered(for: .suspended))

        let off = WebPlans(isOffered: false, apiBaseURL: APIEnvironment.production.baseURL)
        XCTAssertFalse(off.isOffered(for: Refusal(code: .queryLimit, status: 402, serverMessage: "")))
        XCTAssertFalse(off.isOffered(for: .noPlan))
    }

    /// A session's plans page follows the host the session talks to.
    func testASessionSendsBuyersToItsOwnHost() {
        let session = Session(
            config: .development, store: InMemoryCredentialStore([:]),
            cache: ResponseCache(store: InMemoryCacheStore()), urlSession: HTTPStub.session())
        XCTAssertEqual(session.webPlans.url.host, "dev.emperorailabs.com")
        XCTAssertTrue(session.webPlans.isOffered)
    }

    /// Coming back from the plans page reads the account at once, not half an hour later, so a
    /// plan bought there is in force the moment the person returns.
    func testReturningFromThePlansPageReadsTheAccountAtOnce() async {
        let user = User(id: 42, email: "adv@example.test", needsPlan: true)
        let encoded = String(decoding: try! JSONEncoder().encode(user), as: UTF8.self)
        let session = Session(
            store: InMemoryCredentialStore(["auth.token": "tok", "auth.user": encoded]),
            cache: ResponseCache(store: InMemoryCacheStore()), urlSession: HTTPStub.session())
        await session.restore()
        HTTPStub.always(.json(#"""
        {"success":true,"token":"tok2","user":{"id":42,"email":"adv@example.test","plan":"pro","planLabel":"Pro","needsPlan":false}}
        """#))
        await session.refreshAccount()
        XCTAssertNil(session.standing)
        let reads = HTTPStub.seen.count

        // Within the half hour, coming back does nothing...
        await session.refreshAccountIfDue()
        XCTAssertEqual(HTTPStub.seen.count, reads)

        // ...unless the plans page was opened in the meantime.
        session.noteOpenedPlans()
        await session.refreshAccountIfDue()
        XCTAssertEqual(HTTPStub.seen.count, reads + 1)
        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/auth/session")
        XCTAssertFalse(session.isAwaitingPlanPurchase)

        // And only once.
        await session.refreshAccountIfDue()
        XCTAssertEqual(HTTPStub.seen.count, reads + 1)
    }

    /// The button's words are not the refusal's: the refusal says what happened, and never tells
    /// anyone to buy (`RefusalTests`). The button names where it goes.
    func testTheButtonSaysWhereItGoes() {
        XCTAssertEqual(WebPlans.buttonTitle, "View plans")
        XCTAssertTrue(WebPlans.settingsNote.contains("browser"))
    }
}
