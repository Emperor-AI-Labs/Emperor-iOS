import XCTest
@testable import EmperorCore

/// Re-reading the account's plan on launch.
///
/// The model already arrives with the login response and is already applied, so this is not
/// about making the feature work — it is about the *stored user going stale*. `restore()`
/// trusts what is on disk because the platform has no endpoint that validates a token, and a
/// token lasts long enough that someone who signed in weeks ago is running on whatever their
/// plan was then. Moving an account to a better plan would change the web immediately and the
/// phone not at all.
@MainActor
final class PreferredModelRefreshTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    private static let user = User(
        id: 42, email: "adv@example.test", name: "R. Iyer", avatar: nil, title: nil,
        organization: nil, preferredModel: "fast", plan: "starter", planLabel: "Starter")

    private func signedInSession(
        _ user: User = PreferredModelRefreshTests.user
    ) async -> (Session, InMemoryCredentialStore) {
        let encoded = String(decoding: try! JSONEncoder().encode(user), as: UTF8.self)
        let store = InMemoryCredentialStore([
            "auth.token": "tok-abc",
            "auth.user": encoded,
        ])
        let session = Session(
            store: store,
            cache: ResponseCache(store: InMemoryCacheStore()),
            urlSession: HTTPStub.session())
        await session.restore()
        return (session, store)
    }

    // MARK: - The refresh

    func testANewerPlanReachesAPhoneThatNeverSignedOut() async {
        let (session, _) = await signedInSession()
        XCTAssertEqual(session.currentUser?.preferredModel, "fast")

        HTTPStub.always(.json(#"""
        {"success":true,"preferredModel":"thinking","plan":"pro","planLabel":"Pro",
         "planDefaultModel":"thinking","isOverride":false}
        """#))
        await session.refreshPreferredModel()

        XCTAssertEqual(session.currentUser?.preferredModel, "thinking")
        XCTAssertEqual(session.currentUser?.plan, "pro")
        XCTAssertEqual(session.currentUser?.planLabel, "Pro")
    }

    /// The refresh has to reach disk, or the next launch reads the stale value again and the
    /// change appears to revert every time the app is reopened.
    func testTheRefreshedValueIsPersisted() async throws {
        let (session, store) = await signedInSession()

        HTTPStub.always(.json(#"{"success":true,"preferredModel":"thinking","plan":"pro"}"#))
        await session.refreshPreferredModel()

        let stored = try XCTUnwrap(store.string(for: "auth.user")?.data(using: .utf8))
        let decoded = try JSONDecoder().decode(User.self, from: stored)
        XCTAssertEqual(decoded.preferredModel, "thinking")
        XCTAssertEqual(decoded.plan, "pro")
    }

    // MARK: - Failing quietly

    /// This runs at launch and nobody asked for it. An error here would put a failure in front
    /// of someone who was simply opening the app, and the stored value is a perfectly good
    /// answer.
    func testAFailedRefreshChangesNothingAndReportsNothing() async {
        let (session, _) = await signedInSession()

        HTTPStub.always(.json(#"{"error":"upstream unavailable"}"#, status: 503))
        await session.refreshPreferredModel()

        XCTAssertEqual(session.currentUser?.preferredModel, "fast")
        XCTAssertNil(session.signInError)
        XCTAssertEqual(session.state, .signedIn(Self.user))
    }

    func testATransportFailureIsAlsoSilent() async {
        let (session, _) = await signedInSession()

        HTTPStub.fail(URLError(.notConnectedToInternet))
        await session.refreshPreferredModel()

        XCTAssertEqual(session.currentUser?.preferredModel, "fast")
        XCTAssertNil(session.signInError)
    }

    /// A future plan introducing a third mode must leave the phone on something it can render
    /// rather than being blanked or guessed at.
    func testAnUnknownModelLeavesTheStoredValueAlone() async {
        let (session, _) = await signedInSession()

        HTTPStub.always(.json(#"{"success":true,"preferredModel":"reasoning-max","plan":"ultra"}"#))
        await session.refreshPreferredModel()

        XCTAssertEqual(session.currentUser?.preferredModel, "fast")
        XCTAssertEqual(
            session.currentUser?.plan, "starter",
            "a plan must not be adopted alongside a model this build cannot use")
    }

    func testRefreshingWhileSignedOutDoesNothing() async {
        let session = Session(
            store: InMemoryCredentialStore(),
            cache: ResponseCache(store: InMemoryCacheStore()),
            urlSession: HTTPStub.session())
        await session.restore()

        HTTPStub.always(.json(#"{"success":true,"preferredModel":"thinking"}"#))
        await session.refreshPreferredModel()

        XCTAssertEqual(session.state, .signedOut)
        XCTAssertTrue(HTTPStub.seen.isEmpty, "a signed-out app must not call the route at all")
    }

    // MARK: - The request itself

    func testTheRequestCarriesTheCallerIdentity() async {
        let (session, _) = await signedInSession()

        HTTPStub.always(.json(#"{"success":true,"preferredModel":"thinking"}"#))
        await session.refreshPreferredModel()

        let request = HTTPStub.lastRequest
        XCTAssertEqual(request?.url?.path, "/api/preferred-model")
        XCTAssertTrue(
            request?.url?.query?.contains("userId=42") == true,
            "this route reads the caller from the query string")
        XCTAssertNotNil(request?.value(forHTTPHeaderField: "Authorization"))
    }
}
