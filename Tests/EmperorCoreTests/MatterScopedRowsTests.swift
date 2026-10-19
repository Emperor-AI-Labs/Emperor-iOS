import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Since the web's Matters feature, a conversation or a draft can belong to a matter
// (`project_id`). The web keeps those out of History, the home rail and the Library; this client
// does the same, for the reason given on `ChatListViewModel.ownConversations`.

private func chat(_ id: String, project: String? = nil) -> ChatSummary {
    var summary = ChatSummary(id: id, title: "Chat \(id)")
    summary.projectID = project
    return summary
}

@MainActor
private func withChatList(_ body: @MainActor (FakeChatList, ChatListViewModel) async -> Void) async {
    let fake = FakeChatList()
    await body(fake, ChatListViewModel(service: fake))
}

final class MatterScopedChatsTests: XCTestCase {

    func testProjectIdIsReadFromItsSnakeCaseKey() throws {
        let response = try JSONDecoder().decode(
            ChatListResponse.self,
            from: Data(#"{"success":true,"chats":[{"id":"c1","title":"Bail","updatedAt":"2026-10-18T09:00:00.000Z","messageCount":4,"project_id":"prj_9"},{"id":"c2","title":"Plain","project_id":null}]}"#.utf8))
        XCTAssertEqual(response.chats[0].projectID, "prj_9")
        XCTAssertTrue(response.chats[0].belongsToMatter)
        XCTAssertNil(response.chats[1].projectID)
        XCTAssertFalse(response.chats[1].belongsToMatter)
    }

    /// A matter's conversation opened here would be continued without its matter, and the server
    /// would drop that matter's documents from the turn. So it is not offered.
    func testAMattersConversationIsNotListed() async {
        await withChatList { fake, model in
            fake.chats = [chat("c1"), chat("c2", project: "prj_9"), chat("c3", project: "  ")]
            await model.load()
            XCTAssertEqual(model.chats.map(\.id), ["c1", "c3"])
            XCTAssertEqual(model.presentation.showsEmptyState, false)
        }
    }

    func testAListOfOnlyMatterConversationsReadsAsEmpty() async {
        await withChatList { fake, model in
            fake.chats = [chat("c2", project: "prj_9")]
            await model.load()
            XCTAssertTrue(model.chats.isEmpty)
            XCTAssertTrue(model.presentation.showsEmptyState)
        }
    }

    /// `nil` must omit the key. An empty string would reach the server as a matter id it then
    /// tries to own, and the turn would be refused.
    func testTheChatBodyCarriesTheMatterOnlyWhenOneIsNamed() throws {
        let encoder = JSONEncoder()
        var request = ChatRequest(messages: [], userId: "42", chatId: "c1", source: "chat")
        var json = String(decoding: try encoder.encode(request), as: UTF8.self)
        XCTAssertFalse(json.contains("projectId"), json)

        request.projectId = "prj_9"
        json = String(decoding: try encoder.encode(request), as: UTF8.self)
        XCTAssertTrue(json.contains(#""projectId":"prj_9""#), json)
    }
}

private final class FakeDrafts: DraftHistoryProviding, @unchecked Sendable {
    var items: [DraftedItem] = []
    func drafts(_ kind: DraftKind) async throws -> [DraftedItem] { items }
    func content(id: String) async throws -> String { "" }
}

final class MatterScopedDraftsTests: XCTestCase {

    func testAMattersDraftIsNotListed() async throws {
        let decoded = try JSONDecoder().decode(
            DraftListResponse.self,
            from: Data(#"{"success":true,"documents":[{"id":"d1","chat_id":"c1","title":"Plaint","type":"doc","created_at":"2026-10-18 09:00:00","chat_title":"Bail","project_id":"prj_9"},{"id":"d2","chat_id":"c2","title":"Reply","type":"doc","created_at":"2026-10-18 09:00:00","chat_title":"Reply matter"}]}"#.utf8))
        let fake = FakeDrafts()
        fake.items = decoded.documents ?? []
        let ids = await listedDraftIDs(fake)
        XCTAssertEqual(ids, ["d2"])
    }
}

@MainActor
private func listedDraftIDs(_ fake: FakeDrafts) async -> [String] {
    let model = DraftHistoryViewModel(service: fake)
    await model.load()
    return model.items.map(\.id)
}

final class GatewayDownTests: XCTestCase {

    /// An HTML page from the front door with a 502 is the platform being restarted — the state
    /// the web's "backend down" page covers — and must read as such, with a retry offered.
    func testAnHTML502ReadsAsThePlatformBeingUnreachable() {
        let error = APIError.classify(status: 502, body: Data("<html><body>502 Bad Gateway</body></html>".utf8))
        XCTAssertEqual(error, .maintenance(message: APIError.unreachableMessage))
        XCTAssertEqual(LoadFailure(error).kind, .maintenance)
        XCTAssertTrue(LoadFailure(error).isRetryable)
    }

    func testAnHTML504AndAnEmpty503ReadTheSameWay() {
        XCTAssertEqual(
            APIError.classify(status: 504, body: Data("Gateway Time-out".utf8)),
            .maintenance(message: APIError.unreachableMessage))
        XCTAssertEqual(
            APIError.classify(status: 503, body: Data()),
            .maintenance(message: APIError.unreachableMessage))
    }

    /// The platform's own JSON 502 — a court proxy that could not reach the court — is a server
    /// answer with its own sentence, not an outage.
    func testAJSON502FromThePlatformKeepsItsOwnMessage() {
        let error = APIError.classify(status: 502, body: Data(#"{"success":false,"error":"The court did not answer."}"#.utf8))
        XCTAssertEqual(error, .server(status: 502, message: "The court did not answer."))
    }

    func testAnHTML500IsStillAServerError() {
        XCTAssertEqual(
            APIError.classify(status: 500, body: Data("Internal Server Error".utf8)),
            .server(status: 500, message: "The server returned status 500."))
    }
}
