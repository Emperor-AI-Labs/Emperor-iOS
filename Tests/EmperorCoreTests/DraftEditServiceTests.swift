import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

private let draftBody = "<h1>PLAINT</h1>\n<p>The Defendant has not paid <@Ledger.pdf:P-2:4-9>.</p>"
private let original = "Here is the plaint.\n[CANVAS_TRIGGER: Commercial Plaint]\n<canvas_content>\n\(draftBody)\n</canvas_content>"
private let edited = DraftEdit.replaceCanvasBody(
    original, html: "<h1>PLAINT</h1>\n<p>The Defendant has not paid a rupee.</p>")

/// The stored conversation, as `GET /messages` serialises it: every field a turn can carry.
private func messagesBody(answer: String = original, extra: String = "") -> String {
    let encoded = String(decoding: try! JSONEncoder().encode(answer), as: UTF8.self)
    return """
        {"success":true,"messages":[\
        {"role":"user","content":"Draft a plaint.","id":"q1","attachments":[{"name":"सेल_डीड.pdf","folderName":"Matters/Kaveri"}],"timestamp":"2026-10-03T06:30:00Z"},\
        {"role":"assistant","content":\(encoded),"usage":{"prompt_tokens":10},"isTyping":false,"done":true,"serverRun":true,"incomplete":false,"workLog":[{"kind":"note","text":"Reading."}],"timestamp":"2026-10-03T06:30:21.300Z"}\(extra)]}
        """
}

private func transcript(answer: String = original) -> [ChatMessage] {
    try! JSONDecoder().decode(MessagesResponse.self, from: Data(messagesBody(answer: answer).utf8)).messages
}

private let chatsBody = """
    {"success":true,"chats":[{"id":"chat-1","title":"Plaint","role":"Litigator","model":"fast","updatedAt":"2026-10-03 06:30:00"}]}
    """

final class DraftEditServiceTests: XCTestCase {
    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService(signedIn: Bool = true) async -> DraftEditService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        if signedIn { await client.setCredentials(Credentials(token: "tok", userID: 42)) }
        return DraftEditService(client: client)
    }

    /// The server holds the original draft, filed as `canvas_row` among the chat's drafts.
    private func serve(
        messages: String = messagesBody(),
        rowContent: String = DraftEdit.storedDraft(fromMessage: original)!.content,
        sync: HTTPStub.Reply = .json(#"{"success":true}"#)
    ) {
        HTTPStub.respond { request in
            switch request.path {
            case "/api/chats": return .json(chatsBody)
            case "/api/messages": return .json(messages)
            case "/api/documents":
                return .json("""
                    {"success":true,"documents":[\
                    {"id":"canvas_newer","chat_id":"chat-1","title":"Reply","type":"doc","created_at":"2026-10-03T07:00:00Z","chat_title":"Plaint"},\
                    {"id":"canvas_row","chat_id":"chat-1","title":"Commercial Plaint","type":"doc","created_at":"2026-10-03T06:30:21Z","chat_title":"Plaint"}],"tables":[]}
                    """)
            case "/api/documents/content":
                let id = request.queryItems["id"]
                let content = id == "canvas_row" ? rowContent : "<p>Another draft</p>"
                let encoded = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
                return .json(#"{"success":true,"content":\#(encoded)}"#)
            case "/api/save-document":
                return .json(#"{"success":true,"id":"canvas_row","type":"doc","deduped":false,"reclassified":false}"#)
            case "/api/sync": return sync
            default: return .json("{}", status: 404)
            }
        }
    }

    private func save(_ service: DraftEditService, local: [ChatMessage] = transcript(), commit: Bool = true) async -> DraftEditSaveOutcome {
        await service.save(
            DraftEditSaveRequest(chatID: "chat-1", storedTranscript: local, index: 1, editedContent: edited),
            commit: { commit })
    }

    private func requests(_ path: String) -> [URLRequest] { HTTPStub.seen.filter { $0.path == path } }

    func testTheRowIsRewrittenThenTheConversationIsSynced() async throws {
        let service = await makeService()
        serve()
        let outcome = await save(service)
        XCTAssertEqual(outcome, .saved(rowUpdated: true))
        XCTAssertEqual(HTTPStub.seen.map(\.path), [
            "/api/chats", "/api/messages", "/api/documents", "/api/documents/content",
            "/api/save-document", "/api/sync",
        ], "the titled row is read back first, and the row is written before the conversation")

        let list = try XCTUnwrap(requests("/api/documents").first)
        XCTAssertEqual(list.queryItems["chatId"], "chat-1")
        XCTAssertEqual(requests("/api/documents/content").first?.queryItems["id"], "canvas_row")

        let saveDocument = try XCTUnwrap(requests("/api/save-document").first)
        XCTAssertEqual(saveDocument.httpMethod, "POST")
        XCTAssertEqual(saveDocument.header("Authorization"), "Bearer tok")
        let fields = saveDocument.bodyJSON
        XCTAssertEqual(fields["userId"] as? String, "42")
        XCTAssertEqual(fields["id"] as? String, "canvas_row")
        XCTAssertEqual(fields["title"] as? String, "Commercial Plaint")
        XCTAssertEqual(fields["type"] as? String, "doc")
        XCTAssertEqual(fields["source"] as? String, "chat")
        XCTAssertEqual(fields["chatId"] as? String, "chat-1")
        XCTAssertEqual(fields["content"] as? String, DraftEdit.storedDraft(fromMessage: edited)?.content,
                       "the body the server will derive from the synced message, so it recognises the row")
        XCTAssertFalse((fields["content"] as? String ?? "").contains("<@"), "a document's row holds no tokens")
    }

    /// Every stored message goes back as its exact bytes, the edited turn's `content` alone replaced.
    func testTheSyncSendsTheStoredBytesWithOneContentReplaced() async throws {
        let service = await makeService()
        serve()
        _ = await save(service)
        let body = try XCTUnwrap(requests("/api/sync").first?.httpBody)
        let stored = try XCTUnwrap(RawJSON.arrayElements(forKey: "messages", in: Data(messagesBody().utf8)))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["userId"] as? String, "42")
        let chats = try XCTUnwrap(object["chats"] as? [[String: Any]])
        XCTAssertEqual(chats.first?["title"] as? String, "Plaint")
        XCTAssertEqual(chats.first?["updatedAt"] as? String, "2026-10-03 06:30:00", "editing is not activity")

        let text = String(decoding: body, as: UTF8.self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let answer = try XCTUnwrap(RawJSON.replacingMember(
            "content", with: try encoder.encode(edited), inObject: stored[1]))
        let expected = "[" + String(decoding: stored[0], as: UTF8.self) + ","
            + String(decoding: answer, as: UTF8.self) + "]"
        XCTAssertTrue(text.hasSuffix(#""messages":"# + expected + "}]}"),
                      "the question byte for byte, the answer with its content alone replaced")

        let sent = try XCTUnwrap(chats.first?["messages"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1]["content"] as? String, edited)
        XCTAssertEqual(sent[1]["done"] as? Bool, true)
        XCTAssertNotNil(sent[1]["workLog"], "the work log goes back with it")
    }

    func testARowThatNoLongerHoldsTheOriginalIsLeftAlone() async {
        let service = await makeService()
        serve(rowContent: "<p>Something else</p>")
        let outcome = await save(service)
        XCTAssertEqual(outcome, .saved(rowUpdated: false))
        XCTAssertTrue(requests("/api/save-document").isEmpty)
        XCTAssertEqual(requests("/api/sync").count, 1)
    }

    func testAConversationChangedElsewhereIsNotRewritten() async {
        let service = await makeService()
        serve(messages: messagesBody(extra: #",{"role":"user","content":"Asked on the web."}"#))
        let outcome = await save(service)
        XCTAssertEqual(outcome, .kept(.serverHasMore))
        XCTAssertTrue(requests("/api/sync").isEmpty)
        XCTAssertTrue(requests("/api/save-document").isEmpty)
    }

    func testAnEditMadeElsewhereIsNotOverwritten() async {
        let service = await makeService()
        serve(messages: messagesBody(answer: original + " "))
        let outcome = await save(service)
        XCTAssertEqual(outcome, .kept(.transcriptDiffers(at: 1)))
        XCTAssertTrue(requests("/api/sync").isEmpty)
    }

    func testAWriteThatAlreadyLandedIsNotSentAgain() async {
        let service = await makeService()
        serve(messages: messagesBody(answer: edited))
        let outcome = await save(service)
        XCTAssertEqual(outcome, .saved(rowUpdated: false))
        XCTAssertEqual(HTTPStub.seen.map(\.path), ["/api/chats", "/api/messages"])
    }

    func testTheConversationMovingOnAbandonsTheWrite() async {
        let service = await makeService()
        serve()
        let outcome = await save(service, commit: false)
        XCTAssertEqual(outcome, .kept(.conversationChanged))
        XCTAssertTrue(requests("/api/save-document").isEmpty)
        XCTAssertTrue(requests("/api/sync").isEmpty)
    }

    func testAFailedSyncIsAFailure() async {
        let service = await makeService()
        serve(sync: .json(#"{"error":"database is locked"}"#, status: 500))
        let outcome = await save(service)
        XCTAssertEqual(outcome, .failed)
    }

    func testAnUnlistedChatIsNotWritten() async {
        let service = await makeService()
        HTTPStub.respond { request in
            request.path == "/api/chats" ? .json(#"{"success":true,"chats":[]}"#) : .json("{}", status: 404)
        }
        let outcome = await save(service)
        XCTAssertEqual(outcome, .kept(.chatNotListed))
    }

    func testSignedOutWritesNothing() async {
        let service = await makeService(signedIn: false)
        serve()
        let outcome = await save(service)
        XCTAssertEqual(outcome, .kept(.signedOut))
        XCTAssertTrue(HTTPStub.seen.isEmpty)
    }

    func testNoConnectionIsAFailure() async {
        let service = await makeService()
        HTTPStub.fail(URLError(.notConnectedToInternet))
        let outcome = await save(service)
        XCTAssertEqual(outcome, .failed)
    }
}
