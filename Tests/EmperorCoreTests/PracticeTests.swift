import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

/// The role, kept in step between this device and the account — so the role switched on the
/// phone is the role the web opens in, and the other way round.
@MainActor
final class PracticeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    /// Records what reached the account, and can be told to fail.
    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [String] = []
        private var _failing = false
        var sent: [String] { lock.withLock { _sent } }
        var failing: Bool {
            get { lock.withLock { _failing } }
            set { lock.withLock { _failing = newValue } }
        }
        func write(_ id: String) throws {
            try lock.withLock {
                if _failing { throw APIError.transport("offline") }
                _sent.append(id)
            }
        }
    }

    private func practice(
        _ store: InMemoryPreferenceStore = InMemoryPreferenceStore()
    ) -> (Practice, Writes) {
        let writes = Writes()
        let practice = Practice(store: store)
        practice.accountWriter = { id in try writes.write(id) }
        return (practice, writes)
    }

    // MARK: - Choosing here

    func testAChoiceIsTakenAtOnceAndSentToTheAccount() async {
        let store = InMemoryPreferenceStore()
        let (practice, writes) = practice(store)
        var told: [String] = []
        practice.onAccountWritten = { told.append($0) }

        await practice.select(.corporateCounsel)?.value

        XCTAssertEqual(practice.role, .corporateCounsel)
        XCTAssertEqual(writes.sent, ["corporate"], "sent under the web's id, not this app's")
        XCTAssertEqual(told, ["corporate"])
        XCTAssertFalse(practice.isUnsent)
        XCTAssertEqual(PractitionerRole.stored(in: store), .corporateCounsel)
    }

    /// Offline, the choice still takes effect here — and is not forgotten: it goes up the next
    /// time the account is read, rather than being overwritten by the account's older role.
    func testAChoiceThatCouldNotBeSentIsSentLaterNotOverwritten() async {
        let (practice, writes) = practice()
        writes.failing = true
        await practice.select(.student)?.value
        XCTAssertTrue(practice.isUnsent)
        XCTAssertEqual(practice.role, .student)

        writes.failing = false
        await practice.reconcile(withAccountRole: "litigator")?.value

        XCTAssertEqual(practice.role, .student, "the account's older role must not win")
        XCTAssertEqual(writes.sent, ["student"])
        XCTAssertFalse(practice.isUnsent)
    }

    /// Two quick switches reach the account in the order they were made.
    func testQuickSwitchesArriveInOrder() async {
        let (practice, writes) = practice()
        let first = practice.select(.paralegal)
        let second = practice.select(.legalAid)
        await first?.value
        await second?.value
        XCTAssertEqual(writes.sent, ["paralegal", "ngo"])
        XCTAssertEqual(practice.role, .legalAid)
        XCTAssertFalse(practice.isUnsent)
    }

    /// With nowhere to send it — not connected to a session — a choice is still a choice here.
    func testWithNoAccountTheChoiceStaysOnTheDevice() async {
        let practice = Practice(store: InMemoryPreferenceStore())
        XCTAssertNil(practice.select(.adjudicator))
        XCTAssertEqual(practice.role, .adjudicator)
    }

    // MARK: - Reading the account

    /// A role switched on the web arrives with the next reading of the account.
    func testTheAccountsRoleIsAdopted() async {
        let store = InMemoryPreferenceStore()
        let (practice, writes) = practice(store)
        XCTAssertNil(practice.reconcile(withAccountRole: "judge"))
        XCTAssertEqual(practice.role, .adjudicator)
        XCTAssertEqual(PractitionerRole.stored(in: store), .adjudicator)
        XCTAssertTrue(writes.sent.isEmpty, "adopting is not a write")
    }

    /// An account with no role is given the one chosen here — but never the default, which
    /// nobody chose.
    func testAnAccountWithNoRoleIsGivenTheDevicesChoiceButNotTheDefault() async {
        let (fresh, freshWrites) = practice()
        XCTAssertNil(fresh.reconcile(withAccountRole: nil))
        XCTAssertTrue(freshWrites.sent.isEmpty)

        let store = InMemoryPreferenceStore()
        PractitionerRole.seniorCounsel.save(to: store)
        let (chosen, writes) = practice(store)
        await chosen.reconcile(withAccountRole: "")?.value
        XCTAssertEqual(writes.sent, ["counsel"])
    }

    /// The web's Devil's Advocate is not a role here. The device keeps its own, and nothing is
    /// written back over the account's.
    func testARoleThisAppDoesNotCarryIsLeftAlone() async {
        let store = InMemoryPreferenceStore()
        PractitionerRole.paralegal.save(to: store)
        let (practice, writes) = practice(store)
        XCTAssertNil(practice.reconcile(withAccountRole: "devil"))
        XCTAssertEqual(practice.role, .paralegal)
        XCTAssertTrue(writes.sent.isEmpty)
    }

    // MARK: - On the wire, through a session

    private static let user = User(id: 42, email: "adv@example.test", name: "R. Iyer")

    private func signedInSession(role: String? = nil) async -> Session {
        var user = Self.user
        user.practiceRole = role
        let encoded = String(decoding: try! JSONEncoder().encode(user), as: UTF8.self)
        let session = Session(
            store: InMemoryCredentialStore(["auth.token": "tok", "auth.user": encoded]),
            cache: ResponseCache(store: InMemoryCacheStore()),
            urlSession: HTTPStub.session())
        await session.restore()
        return session
    }

    func testTheRoleIsWrittenToTheAccountAndTheSessionLearnsIt() async throws {
        let session = await signedInSession(role: "litigator")
        let practice = Practice(store: InMemoryPreferenceStore())
        practice.link(to: session)
        HTTPStub.always(.json(#"{"success":true}"#))

        await practice.select(.corporateCounsel)?.value

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/api/set-practice-role")
        XCTAssertEqual(sent.bodyJSON["role"] as? String, "corporate")
        XCTAssertEqual(sent.bodyJSON["userId"] as? String, "42")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(session.currentUser?.practiceRole, "corporate")
        XCTAssertFalse(practice.isUnsent)
    }

    /// A server that does not keep the role yet — or says it did not save — leaves the choice
    /// unsent, to go up again later.
    func testARefusedWriteLeavesTheChoiceUnsent() async {
        let session = await signedInSession()
        let practice = Practice(store: InMemoryPreferenceStore())
        practice.link(to: session)

        HTTPStub.always(.json(#"{"error":"Not found"}"#, status: 404))
        await practice.select(.student)?.value
        XCTAssertTrue(practice.isUnsent)

        HTTPStub.always(.json(#"{"success":false}"#))
        await practice.reconcile(withAccountRole: nil)?.value
        XCTAssertTrue(practice.isUnsent)
        XCTAssertNil(session.currentUser?.practiceRole)
    }

    /// The account's role arrives with the account itself, from `/login` and `/auth/session`.
    func testTheAccountCarriesItsRole() throws {
        let user = try JSONDecoder().decode(User.self, from: Data(#"""
        {"id":7,"email":"a@b.c","practice_role":"ngo"}
        """#.utf8))
        XCTAssertEqual(user.practiceRole, "ngo")
        XCTAssertEqual(PractitionerRole(webID: user.practiceRole), .legalAid)
    }

    // MARK: - The first-sign-in question

    /// An account that already has a role — chosen on the web or another phone — has answered
    /// the welcome's question, even with a role this app does not carry.
    func testTheWelcomeIsNotAskedOfAnAccountWithARole() {
        let store = InMemoryPreferenceStore()
        RoleWelcome.noteSignInShown(store)
        XCTAssertTrue(RoleWelcome.shouldShow(store, isSignedIn: true, accountRole: nil))
        XCTAssertTrue(RoleWelcome.shouldShow(store, isSignedIn: true, accountRole: ""))
        XCTAssertFalse(RoleWelcome.shouldShow(store, isSignedIn: true, accountRole: "counsel"))
        XCTAssertFalse(RoleWelcome.shouldShow(store, isSignedIn: true, accountRole: "devil"))
    }
}
