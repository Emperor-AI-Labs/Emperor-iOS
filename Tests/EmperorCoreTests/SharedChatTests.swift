import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A shared conversation: the links that lead to one, reading it without an account, and what
/// the read-only screen shows — the web's `/share/:shareId` page.
final class SharedChatLinkTests: XCTestCase {

    private static let production = SharedChatLink.webHosts(for: .production)

    private func id(_ text: String, hosts: Set<String> = production) throws -> String? {
        SharedChatLink.shareID(in: try XCTUnwrap(URL(string: text)), webHosts: hosts)
    }

    func testTheAppsOwnLinkIsReadWhicheverWayItIsWritten() throws {
        for text in [
            "emperor://share/k3j9x2abq81mz", "EMPEROR://Share/k3j9x2abq81mz",
            "emperor:share/k3j9x2abq81mz", "emperor://share/k3j9x2abq81mz/",
        ] {
            XCTAssertEqual(try id(text), "k3j9x2abq81mz", text)
        }
    }

    /// The link the web hands out, on the host this build talks to.
    func testTheWebLinkIsReadOnThisBuildsHost() throws {
        XCTAssertEqual(try id("https://app.emperorailabs.com/share/k3j9x2abq81mz"), "k3j9x2abq81mz")
        XCTAssertEqual(try id("https://APP.emperorailabs.com/share/k3j9x2abq81mz?ref=mail"),
                       "k3j9x2abq81mz")
        let development = SharedChatLink.webHosts(for: .development)
        XCTAssertEqual(
            try id("https://dev.emperorailabs.com/share/abc", hosts: development), "abc")
    }

    /// A share id belongs to one deployment, so another deployment's link names nothing here.
    func testAnotherDeploymentsLinkIsNotOurs() throws {
        XCTAssertNil(try id("https://dev.emperorailabs.com/share/abc"))
        XCTAssertNil(try id(
            "https://app.emperorailabs.com/share/abc",
            hosts: SharedChatLink.webHosts(for: .development)))
    }

    func testOtherURLsAreLeftAlone() throws {
        for text in [
            "emperor://calendar", "emperor://share", "emperor://share/", "emperor://share/a/b",
            "emperor://shares/abc", "http://app.emperorailabs.com/share/abc",
            "https://example.com/share/abc", "https://app.emperorailabs.com/abc",
            "https://app.emperorailabs.com/api/shared-chat/abc",
            "file:///private/var/mobile/Order.pdf",
        ] {
            XCTAssertNil(try id(text), text)
        }
    }

    /// Anything but letters, digits, `-` and `_` would address something other than a shared
    /// conversation once it is put into a path.
    func testAnIdThatIsNotOneIsRefused() throws {
        XCTAssertNil(try id("emperor://share/..%2Fchats"))
        XCTAssertNil(try id("emperor://share/a%3Fb"))
        XCTAssertNil(try id("emperor://share/\(String(repeating: "a", count: 65))"))
        XCTAssertFalse(SharedChatLink.isValidID(""))
        XCTAssertFalse(SharedChatLink.isValidID("abc def"))
        XCTAssertFalse(SharedChatLink.isValidID("खोज"))
        XCTAssertTrue(SharedChatLink.isValidID("Ab-9_z"))
    }

    func testTheLinkIsBuiltTheWayItIsRead() throws {
        let url = try XCTUnwrap(SharedChatLink.url(for: "k3j9x2abq81mz"))
        XCTAssertEqual(url.absoluteString, "emperor://share/k3j9x2abq81mz")
        XCTAssertEqual(SharedChatLink.shareID(in: url, webHosts: []), "k3j9x2abq81mz")
        XCTAssertNil(SharedChatLink.url(for: "a/b"))
    }

    /// Not a destination the Today widget's links know — it stays out of `EmperorLink`, which the
    /// widget compiles on its own.
    func testTheWidgetsLinksDoNotClaimIt() throws {
        XCTAssertNil(EmperorLink(url: try XCTUnwrap(URL(string: "emperor://share/abc"))))
    }

    // MARK: - Waiting to be shown

    func testARequestIsTakenOnce() async {
        await MainActor.run {
            let requests = SharedChatRequests()
            requests.open("abc")
            XCTAssertEqual(requests.requestCount, 1)
            XCTAssertEqual(requests.take(), "abc")
            XCTAssertNil(requests.take())
        }
    }

    func testTheLatestRequestWinsAndANonIdIsIgnored() async {
        await MainActor.run {
            let requests = SharedChatRequests()
            requests.open("first")
            requests.open("second")
            requests.open("not/an/id")
            XCTAssertEqual(requests.requestCount, 2)
            XCTAssertEqual(requests.pending, "second")
        }
    }

    /// The same link opened twice is still a change to observe.
    func testOpeningTheSameLinkAgainCounts() async {
        await MainActor.run {
            let requests = SharedChatRequests()
            requests.open("abc")
            _ = requests.take()
            requests.open("abc")
            XCTAssertEqual(requests.requestCount, 2)
            XCTAssertEqual(requests.pending, "abc")
        }
    }
}

// MARK: - The wire

final class SharedChatServiceTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService(signedIn: Bool = true) async -> SharedChatService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        if signedIn {
            await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        }
        return SharedChatService(client: client)
    }

    /// `sync-server.js` answers `{id, title, role, updated_at, messages}`, the messages as
    /// `getMessages` returns them — each stored message's own JSON.
    static let body = #"""
        {"id":"chat_1","title":"Bail in a commercial dispute","role":"Litigator",
         "updated_at":"2026-10-17 10:12:30",
         "messages":[
           {"role":"user","content":"Is bail available?","timestamp":"2026-10-17T10:11:00.000Z",
            "attachments":[{"name":"FIR_Copy.pdf","folderName":"Bakshi"},"Order.pdf",{"filename":"Notice.pdf"},{}]},
           {"role":"assistant","content":"<think>weighing</think>Yes, it is <@FIR_Copy.pdf:P-2:2>.\n\n## References\n1. FIR","timestamp":"2026-10-17T10:12:00.000Z","workLog":[]},
           {"role":"system","content":"You are Emperor."},
           {"role":"assistant","content":"   "},
           {"content":"[CANVAS_TRIGGER: Bail Application]\n<canvas_content><p>IN THE COURT</p></canvas_content>"},
           42
         ]}
        """#

    func testItReadsWithoutAnAccountEvenWhenSignedIn() async throws {
        let service = await makeService()
        HTTPStub.always(.json(Self.body))

        _ = try await service.sharedChat(id: "k3j9x2abq81mz")

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.url?.path, "/api/shared-chat/k3j9x2abq81mz")
        XCTAssertNil(sent.url?.query, "no userId")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sent.value(forHTTPHeaderField: "X-Auth-Token"))
    }

    func testItReadsSignedOut() async throws {
        let service = await makeService(signedIn: false)
        HTTPStub.always(.json(Self.body))

        let chat = try await service.sharedChat(id: "abc")
        XCTAssertEqual(chat.title, "Bail in a commercial dispute")
    }

    func testTheConversationIsDecodedIntoWhatTheScreenDraws() async throws {
        let service = await makeService()
        HTTPStub.always(.json(Self.body))

        let chat = try await service.sharedChat(id: "abc")

        XCTAssertEqual(chat.roleLabel, "Litigator")
        XCTAssertEqual(chat.updatedAtRaw, "2026-10-17 10:12:30")
        // Zoneless UTC, shown in India's time, as the web page says.
        XCTAssertEqual(chat.updatedLabel, "17 October 2026, 3:42 pm IST")

        // The system message and the empty answer are left out; the unreadable row costs only
        // itself; a message with no role is an answer.
        XCTAssertEqual(chat.entries.count, 3)
        XCTAssertEqual(chat.entries.map(\.id), [0, 1, 2])

        guard case .question(let text, let files) = chat.entries[0].kind else {
            return XCTFail("the first turn is the question")
        }
        XCTAssertEqual(text, "Is bail available?")
        XCTAssertEqual(files, ["FIR_Copy.pdf", "Order.pdf", "Notice.pdf", "Document"])

        guard case .answer(let answer) = chat.entries[1].kind else {
            return XCTFail("the second turn is the answer")
        }
        XCTAssertFalse(answer.prose.contains("weighing"), "control tags are stripped")
        XCTAssertFalse(answer.prose.contains("<@"))
        XCTAssertTrue(answer.prose.contains("## References"))
        XCTAssertEqual(answer.mentions, [], "the asker's documents cannot be opened here")

        guard case .answer(let draft) = chat.entries[2].kind else {
            return XCTFail("the third turn is the draft")
        }
        XCTAssertEqual(draft.artifacts.first?.title, "Bail Application")
    }

    /// The web page also accepts the messages as a JSON string.
    func testMessagesSentAsAStringAreRead() throws {
        let body = #"""
            {"title":"  ","role":"Judicial Officer","updated_at":null,
             "messages":"[{\"role\":\"user\",\"content\":\"Hello\"}]"}
            """#
        let chat = try JSONDecoder().decode(SharedConversation.self, from: Data(body.utf8))
        XCTAssertEqual(chat.title, SharedConversation.untitled)
        XCTAssertEqual(chat.roleLabel, "Arbitrator or Judge")
        XCTAssertNil(chat.updatedLabel)
        XCTAssertEqual(chat.entries.count, 1)
    }

    func testAnUnknownRoleIsShownAsSentAndNoRoleIsNone() throws {
        let unknown = try JSONDecoder().decode(
            SharedConversation.self, from: Data(#"{"role":"Mediator","messages":[]}"#.utf8))
        XCTAssertEqual(unknown.roleLabel, "Mediator")
        let none = try JSONDecoder().decode(
            SharedConversation.self, from: Data(#"{"role":"","messages":[]}"#.utf8))
        XCTAssertNil(none.roleLabel)
        XCTAssertEqual(none.entries, [])
    }

    func testANotFoundLinkIsA404() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"error":"Shared chat not found"}"#, status: 404))

        do {
            _ = try await service.sharedChat(id: "abc")
            XCTFail("expected a failure")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 404, message: "Shared chat not found"))
        }
        XCTAssertEqual(HTTPStub.seen.count, 1, "a 404 is not retried")
    }

    /// An id that is not one never reaches the server.
    func testAnIdThatIsNotOneIsNotSent() async throws {
        let service = await makeService()
        HTTPStub.always(.json(Self.body))

        do {
            _ = try await service.sharedChat(id: "../chats")
            XCTFail("expected a failure")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 404, message: "Shared chat not found"))
        }
        XCTAssertTrue(HTTPStub.seen.isEmpty)
    }
}

// MARK: - The screen

private final class FakeSharedChats: SharedChatProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: Result<SharedConversation, Error>
    private var _calls: [String] = []

    init(_ result: Result<SharedConversation, Error>) { _result = result }

    var calls: [String] { lock.withLock { _calls } }
    func set(_ result: Result<SharedConversation, Error>) { lock.withLock { _result = result } }

    func sharedChat(id: String) async throws -> SharedConversation {
        let result = lock.withLock { () -> Result<SharedConversation, Error> in
            _calls.append(id)
            return _result
        }
        return try result.get()
    }
}

private let sampleConversation = SharedConversation(
    title: "Bail", role: "Litigator", updatedAtRaw: "2026-10-17 10:12:30",
    entries: [SharedChatEntry(id: 0, kind: .question(text: "Is bail available?", attachments: []))])

/// A free function rather than a method: an `XCTestCase` is not `Sendable` — see
/// `ChatViewModelTests`.
@MainActor
private func withSharedChat(
    _ result: Result<SharedConversation, Error>,
    _ body: @MainActor (FakeSharedChats, SharedChatViewModel) async -> Void
) async {
    let service = FakeSharedChats(result)
    await body(service, SharedChatViewModel(shareID: "abc", service: service))
}

final class SharedChatViewModelTests: XCTestCase {

    func testItLoadsTheConversation() async {
        await withSharedChat(.success(sampleConversation)) { service, model in
            XCTAssertEqual(model.state, .idle)
            await model.load()
            XCTAssertEqual(model.state, .loaded)
            XCTAssertEqual(model.conversation, sampleConversation)
            XCTAssertFalse(model.isNotFound)
            XCTAssertFalse(model.isEmpty)
            XCTAssertEqual(service.calls, ["abc"])
        }
    }

    func testANotFoundLinkSaysSo() async {
        let missing = APIError.server(status: 404, message: "Shared chat not found")
        await withSharedChat(.failure(missing)) { _, model in
            await model.load()
            XCTAssertTrue(model.isNotFound)
            guard case .failed(let failure) = model.state else { return XCTFail("expected a failure") }
            XCTAssertEqual(failure.message, SharedChatViewModel.notFoundMessage)
            XCTAssertNil(model.conversation)
        }
    }

    func testAnOutageIsNotANotFoundAndCanBeRetried() async {
        await withSharedChat(.failure(APIError.transport(DisplayText.offlineMessage))) { service, model in
            await model.load()
            XCTAssertFalse(model.isNotFound)
            guard case .failed(let failure) = model.state else { return XCTFail("expected a failure") }
            XCTAssertEqual(failure.kind, .offline)
            XCTAssertTrue(failure.isRetryable)

            service.set(.success(sampleConversation))
            await model.load()
            XCTAssertEqual(model.state, .loaded)
            XCTAssertEqual(service.calls.count, 2)
        }
    }

    func testAConversationWithNothingToReadIsEmpty() async {
        let empty = SharedConversation(title: "Bail", role: nil, updatedAtRaw: nil, entries: [])
        await withSharedChat(.success(empty)) { _, model in
            await model.load()
            XCTAssertTrue(model.isEmpty)
        }
    }
}
