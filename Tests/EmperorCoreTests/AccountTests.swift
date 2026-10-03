import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

/// The account between sign-in and sign-out: what goes on the wire for the new sign-in routes,
/// renewing the session at launch, and learning the account's standing from refusals.
///
/// Response bodies are the platform's own (`sync-server.js` — `/register`, `/auth/otp/*`,
/// `/auth/session`, the paywall gate).
@MainActor
final class AccountTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private static let user = User(
        id: 42, email: "adv@example.test", name: "R. Iyer", preferredModel: "fast",
        plan: "lite", planLabel: "Lite")

    private func signedInSession() async -> (Session, InMemoryCredentialStore) {
        let encoded = String(decoding: try! JSONEncoder().encode(Self.user), as: UTF8.self)
        let store = InMemoryCredentialStore(["auth.token": "tok-old", "auth.user": encoded])
        let session = Session(
            store: store, cache: ResponseCache(store: InMemoryCacheStore()),
            urlSession: HTTPStub.session())
        await session.restore()
        return (session, store)
    }

    private func signedOutSession() -> Session {
        Session(
            store: InMemoryCredentialStore([:]), cache: ResponseCache(store: InMemoryCacheStore()),
            urlSession: HTTPStub.session())
    }

    // MARK: - The new sign-in routes, on the wire

    func testCreatingAnAccountUnderstandsTheConfirmationResponse() async throws {
        let session = signedOutSession()
        HTTPStub.always(.json(#"""
        {"success":true,"verificationRequired":true,"email":"new@example.test",
         "user":{"id":9,"name":"N","email":"new@example.test"}}
        """#))

        let outcome = try await session.auth.register(
            name: "N", email: "New@Example.test", password: "longenough")

        XCTAssertEqual(outcome, .confirmationSent(email: "new@example.test"))
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.url?.path, "/api/register")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
    }

    func testCodeRequestAndVerifyGoWhereTheServerListens() async throws {
        let session = signedOutSession()
        HTTPStub.always(.json(#"{"success":true,"sent":true,"expiresInMinutes":10}"#))
        let request = try await session.auth.requestCode(email: "adv@example.test")
        XCTAssertEqual(request.expiresInMinutes, 10)
        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/auth/otp/request")
        XCTAssertEqual(HTTPStub.lastRequest?.bodyJSON["email"] as? String, "adv@example.test")

        HTTPStub.always(.json(#"""
        {"success":true,"token":"tok-otp","user":{"id":42,"email":"adv@example.test","plan":"lite","planLabel":"Lite"}}
        """#))
        let response = try await session.auth.verifyCode(email: "adv@example.test", code: "012345")
        XCTAssertEqual(response.token, "tok-otp")
        let body = try XCTUnwrap(HTTPStub.lastRequest?.bodyJSON)
        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/auth/otp/verify")
        XCTAssertEqual(body["code"] as? String, "012345", "a leading zero is part of the code")
    }

    /// A wrong code is a 401. It must not sign out a session — on a phone that is already
    /// signed in, it would.
    func testAWrongCodeDoesNotEndASession() async {
        let (session, _) = await signedInSession()
        HTTPStub.always(.json(#"{"error":"That code is not correct.","code":"OTP_INVALID"}"#, status: 401))
        do {
            _ = try await session.auth.verifyCode(email: "adv@example.test", code: "000000")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? APIError)?.refusal?.code, .invalidCode)
        }
        await Task.yield()
        XCTAssertEqual(session.currentUser?.id, 42)
    }

    // MARK: - Renewing the session

    /// `/auth/session` returns the account as it stands and a freshly signed token. Taking both
    /// is what keeps an account in daily use signed in.
    func testOpeningTheAppRenewsTheTokenAndTheAccount() async throws {
        let (session, store) = await signedInSession()
        HTTPStub.always(.json(#"""
        {"success":true,"token":"tok-new","user":{"id":42,"email":"adv@example.test","name":"R. Iyer",
         "plan":"ultra","planLabel":"Ultra","preferred_model":"thinking","needsPlan":false,"suspended":false}}
        """#))

        await session.refreshAccount()

        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/auth/session")
        XCTAssertEqual(store.string(for: "auth.token"), "tok-new")
        XCTAssertEqual(session.currentUser?.planLabel, "Ultra")
        XCTAssertEqual(session.currentUser?.preferredModel, "thinking")
        XCTAssertNil(session.standing)

        // The next request carries the renewed token.
        HTTPStub.always(.json(#"{"success":true,"chats":[]}"#))
        _ = try? await session.chats.chats()
        XCTAssertEqual(HTTPStub.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-new")
    }

    func testAnAccountWithNoPlanSaysSoFromTheStart() async {
        let (session, _) = await signedInSession()
        HTTPStub.always(.json(#"""
        {"success":true,"token":"t","user":{"id":42,"email":"adv@example.test","needsPlan":true,"suspended":false}}
        """#))
        await session.refreshAccount()
        XCTAssertEqual(session.standing, .noPlan)
    }

    /// A different account behind the same token would put one person's work under another's
    /// name. It is not adopted.
    func testADifferentAccountIsNeverAdopted() async {
        let (session, store) = await signedInSession()
        HTTPStub.always(.json(#"{"success":true,"token":"t2","user":{"id":99,"email":"x@y.z"}}"#))
        await session.refreshAccount()
        XCTAssertEqual(session.currentUser?.id, 42)
        XCTAssertEqual(store.string(for: "auth.token"), "tok-old")
    }

    /// Against a server without `/auth/session`, the older refresh still runs.
    func testAServerWithoutTheRouteFallsBackToThePreferredModel() async {
        let (session, _) = await signedInSession()
        HTTPStub.respond { request in
            if request.url?.path == "/api/auth/session" {
                return .json(#"{"error":"Not found"}"#, status: 404)
            }
            return .json(#"{"success":true,"preferredModel":"thinking","plan":"pro","planLabel":"Pro"}"#)
        }
        await session.refreshAccount()
        XCTAssertEqual(session.currentUser?.preferredModel, "thinking")
        XCTAssertEqual(
            HTTPStub.seen.map { $0.url?.path ?? "" }, ["/api/auth/session", "/api/preferred-model"])
    }

    // MARK: - Standing, learned from refusals

    /// Whichever screen meets the paywall first teaches the whole app, so the banner appears
    /// everywhere rather than one failed question at a time.
    func testARefusalAnywhereUpdatesTheAccountsStanding() async throws {
        let (session, store) = await signedInSession()
        HTTPStub.always(.json(
            #"{"error":"This account is suspended. You can still open your history and documents, but new work is paused. Contact support to restore it.","code":"ACCOUNT_SUSPENDED"}"#,
            status: 403))

        _ = try? await session.cases.cases()
        // The observer hops to the main actor; let it land.
        for _ in 0..<20 where session.standing == nil { await Task.yield() }

        XCTAssertEqual(session.standing, .suspended)
        let stored = try XCTUnwrap(store.string(for: "auth.user"))
        XCTAssertTrue(stored.contains("\"suspended\":true"), "remembered across launches")
    }

    func testOtherRefusalsDoNotChangeTheStanding() async {
        let (session, _) = await signedInSession()
        session.note(Refusal(code: .queryLimit, status: 402, serverMessage: ""))
        XCTAssertNil(session.standing)
        session.note(Refusal(code: .planRequired, status: 402, serverMessage: ""))
        XCTAssertEqual(session.standing, .noPlan)
    }

    // MARK: - Signing in and out

    func testSigningInWithTheFlowStoresTheCredential() async {
        let session = signedOutSession()
        HTTPStub.always(.json(#"""
        {"success":true,"token":"tok-in","user":{"id":42,"email":"adv@example.test","needsPlan":false}}
        """#))
        session.signInFlow.email = "adv@example.test"
        session.signInFlow.password = "pw"
        await session.signInFlow.signIn()
        XCTAssertEqual(session.currentUser?.id, 42)
    }

    /// The server is told, while the request can still carry the token — and the sign-in screen
    /// forgets the address, so the next person to hold the phone starts clean.
    func testSigningOutTellsTheServerAndForgetsTheForm() async throws {
        let (session, store) = await signedInSession()
        session.signInFlow.email = "adv@example.test"
        HTTPStub.always(.json(#"{"success":true}"#))

        await session.signOut()

        let logout = try XCTUnwrap(HTTPStub.seen.first { $0.url?.path == "/api/logout" })
        XCTAssertEqual(logout.httpMethod, "POST")
        XCTAssertEqual(logout.value(forHTTPHeaderField: "Authorization"), "Bearer tok-old")
        XCTAssertNil(store.string(for: "auth.token"))
        XCTAssertEqual(session.state, .signedOut)
        XCTAssertEqual(session.signInFlow.email, "")
    }

    /// Signing out must work with no signal: the logout call is best-effort.
    func testSigningOutWorksOffline() async {
        let (session, store) = await signedInSession()
        HTTPStub.fail(URLError(.notConnectedToInternet))
        await session.signOut()
        XCTAssertEqual(session.state, .signedOut)
        XCTAssertNil(store.string(for: "auth.token"))
    }

    /// The bearer token is the only credential this client uses. A cookie jar would keep a
    /// second one on the phone that outlives signing out.
    func testTheClientKeepsNoCookies() {
        let configuration = URLSessionConfiguration.default
        APIClient.refuseCookies(configuration)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
    }
}
