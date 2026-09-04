import XCTest
@testable import EmperorCore

/// Renaming a conversation — built, tested, and with no caller in the app.
///
/// These pin the refusal as much as the behaviour. The reason nothing calls this is a property
/// of the server that is invisible from outside: a rename carrying no messages is silently
/// dropped for any chat that has ever been used, and one carrying messages destroys and
/// rebuilds every one of them. A future maintainer who wires this up without knowing that would
/// ship a feature that either does nothing or loses turns, and in both cases reports success.
final class ChatMetadataTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    private func makeService() async -> ChatMetadataService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok", userID: 42))
        return ChatMetadataService(client: client)
    }

    // MARK: - The refusal

    /// The whole reason this has no caller. Renaming a used conversation would make the server
    /// delete every stored message and re-insert this client's re-serialisation of them.
    func testRenamingAConversationWithMessagesIsRefusedLocally() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true}"#))

        do {
            try await service.rename(
                chatID: "c1", to: "Kumar v State", role: nil, model: nil, messageCount: 3)
            XCTFail("a conversation with history must not be renamed through /sync")
        } catch {
            XCTAssertEqual(
                error as? ChatMetadataService.RenameError, .wouldRewriteHistory(messageCount: 3))
        }
    }

    /// Refused *before* the request, not after. The server would answer `200 {success:true}`
    /// and change nothing, so sending it and believing the response would report a rename that
    /// did not happen.
    func testTheRefusalHappensWithoutTouchingTheNetwork() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true}"#))

        _ = try? await service.rename(
            chatID: "c1", to: "New name", role: nil, model: nil, messageCount: 1)

        XCTAssertTrue(
            HTTPStub.seen.isEmpty,
            "a request that would silently do nothing must not be sent at all")
    }

    // MARK: - The one safe case

    func testAnEmptyConversationCanBeRenamed() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true}"#))

        try await service.rename(
            chatID: "c1", to: "  Kumar v State  ", role: "advocate", model: "thinking",
            messageCount: 0)

        let request = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/sync")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testTheTitleIsTrimmedBeforeItIsSent() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true}"#))

        try await service.rename(
            chatID: "c1", to: "  Kumar v State  ", role: nil, model: nil, messageCount: 0)

        let body = try XCTUnwrap(HTTPStub.lastRequest?.bodyJSON)
        let chats = try XCTUnwrap(body["chats"] as? [[String: Any]])
        XCTAssertEqual(chats.first?["title"] as? String, "Kumar v State")
    }

    /// The server reads `.length` off `messages` with no guard, so omitting the key is a
    /// `TypeError` rather than a skipped chat. It is always sent, and always empty.
    func testAnEmptyMessagesArrayIsAlwaysPresent() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true}"#))

        try await service.rename(
            chatID: "c1", to: "Title", role: nil, model: nil, messageCount: 0)

        let body = try XCTUnwrap(HTTPStub.lastRequest?.bodyJSON)
        let chats = try XCTUnwrap(body["chats"] as? [[String: Any]])
        let messages = try XCTUnwrap(chats.first?["messages"] as? [Any])
        XCTAssertTrue(messages.isEmpty, "sending any message would trigger a full rewrite")
    }

    func testTheCallerIdentityIsSentInTheBody() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true}"#))

        try await service.rename(
            chatID: "c1", to: "Title", role: nil, model: nil, messageCount: 0)

        let body = try XCTUnwrap(HTTPStub.lastRequest?.bodyJSON)
        XCTAssertEqual(body["userId"] as? String, "42")
    }

    /// `updated_at` orders the chat list, so a rename that omitted it would reorder the list
    /// unpredictably or land the chat at the bottom.
    func testAnUpdatedTimestampIsSent() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true}"#))

        try await service.rename(
            chatID: "c1", to: "Title", role: nil, model: nil, messageCount: 0,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let body = try XCTUnwrap(HTTPStub.lastRequest?.bodyJSON)
        let chats = try XCTUnwrap(body["chats"] as? [[String: Any]])
        let stamp = try XCTUnwrap(chats.first?["updatedAt"] as? String)
        XCTAssertTrue(stamp.hasPrefix("2023-11-14"), stamp)
    }

    // MARK: - Failures

    func testAServerFailureIsReported() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":"database is locked"}"#))

        do {
            try await service.rename(
                chatID: "c1", to: "Title", role: nil, model: nil, messageCount: 0)
            XCTFail("a success:false answer must not read as a rename")
        } catch {
            XCTAssertTrue(DisplayText.message(for: error).contains("database is locked"))
        }
    }

    func testRenamingWhileSignedOutFails() async {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        let service = ChatMetadataService(client: client)
        HTTPStub.always(.json(#"{"success":true}"#))

        do {
            try await service.rename(
                chatID: "c1", to: "Title", role: nil, model: nil, messageCount: 0)
            XCTFail("expected notAuthenticated")
        } catch {
            XCTAssertTrue(HTTPStub.seen.isEmpty)
        }
    }
}
