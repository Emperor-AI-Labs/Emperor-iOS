import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

// MARK: - Shared builders

private func message(
    _ role: MessageRole, _ content: String, id: String? = nil,
    done: Bool? = nil, isTyping: Bool? = nil, extra: [String: JSONValue] = [:]
) -> ChatMessage {
    var built = ChatMessage(role: role, content: content, id: id)
    built.done = done
    built.isTyping = isTyping
    built.extra = extra
    return built
}

private let logFields: [String: JSONValue] = [
    "reasoning": .object(["points": .array([]), "seconds": .number(4)]),
    "workflowTasks": .array([]),
    "workLog": .array([.object(["kind": .string("note"), "text": .string("Reading first.")])]),
]

/// The fixture's stored conversation, decoded as `ChatService` decodes it.
private func storedMessages() -> [ChatMessage] {
    let body = Data(WorkLogFixture.shared.messagesBody.utf8)
    return try! JSONDecoder().decode(MessagesResponse.self, from: body).messages
}

/// This client's transcript at the end of the fixture's last turn: what it loaded, the question
/// it asked, and the answer it was shown — its own copy, with its own log attached.
private func appTranscript() -> [ChatMessage] {
    var transcript = Array(storedMessages().dropLast())
    let fixture = WorkLogFixture.named(WorkLogFixture.shared.appTurnCase)
    let parser = ChatStreamParser()
    for chunk in fixture.chunks { _ = parser.consume(text: chunk) }
    _ = parser.finish()
    var answer = ChatMessage(
        role: .assistant, content: StreamContent.parse(parser.raw).persistableContent)
    answer.attachWorkLog(appFields())
    transcript.append(answer)
    return transcript
}

private func appFields() -> [String: JSONValue] {
    let fixture = WorkLogFixture.named(WorkLogFixture.shared.appTurnCase)
    return WorkLogWire.fields(
        for: WorkLogFixture.replay(fixture), seconds: fixture.seconds, ended: .completed)
}

private func json(_ data: Data) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: data)
}

// MARK: - The raw reader

final class RawJSONTests: XCTestCase {

    /// The slices put back together are the response, byte for byte — so nothing between them,
    /// and nothing inside them, was lost or reworded.
    func testTheStoredMessagesSplitIntoTheirExactBytes() throws {
        let body = Data(WorkLogFixture.shared.messagesBody.utf8)
        let slices = try XCTUnwrap(RawJSON.arrayElements(forKey: "messages", in: body))
        XCTAssertEqual(slices.count, storedMessages().count)

        var rebuilt = Data(#"{"success":true,"messages":["#.utf8)
        rebuilt.append(Data(slices.map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: ",").utf8))
        rebuilt.append(Data("]}".utf8))
        XCTAssertEqual(rebuilt, body)
    }

    func testEachSliceIsOneWholeMessage() throws {
        let body = Data(WorkLogFixture.shared.messagesBody.utf8)
        let slices = try XCTUnwrap(RawJSON.arrayElements(forKey: "messages", in: body))
        for (slice, decoded) in zip(slices, storedMessages()) {
            let reread = try JSONDecoder().decode(ChatMessage.self, from: slice)
            XCTAssertEqual(reread, decoded)
        }
    }

    /// Brackets, braces, commas and escaped quotes inside strings are text, not structure.
    func testStructureInsideStringsIsNotStructure() throws {
        let body = Data(#"""
            { "messages" : [ {"content":"a \"quoted\" ], { , } [ \\"} , "twoé" ,
            [1, {"x": [true, null]}], -1.5e+3 ] , "after": {"messages": []} }
            """#.utf8)
        let slices = try XCTUnwrap(RawJSON.arrayElements(forKey: "messages", in: body))
        XCTAssertEqual(slices.map { String(decoding: $0, as: UTF8.self) }, [
            #"{"content":"a \"quoted\" ], { , } [ \\"}"#,
            #""twoé""#,
            #"[1, {"x": [true, null]}]"#,
            "-1.5e+3",
        ])
    }

    func testMalformedDocumentsAreRefused() {
        for broken in [
            #"{"messages":[{"a":"unterminated}]}"#,
            #"{"messages":[1,2]"#,
            #"{"messages":[1,2]} trailing"#,
            #"{"messages":[1,,2]}"#,
            #"["messages"]"#,
            #"{"other":[1]}"#,
        ] {
            XCTAssertNil(RawJSON.arrayElements(forKey: "messages", in: Data(broken.utf8)), broken)
        }
    }

    /// The new members go in before the closing brace; every existing byte stays where it was.
    func testAppendingKeepsTheOriginalBytes() throws {
        let original = Data(#"{"b":1,"a":"x\/y","n":null}"#.utf8)
        let extended = try XCTUnwrap(RawJSON.appending(
            ["workLog": .array([]), "reasoning": .number(2)],
            keyOrder: WorkLogWire.keys, toObject: original))
        XCTAssertEqual(String(decoding: extended, as: UTF8.self),
                       #"{"b":1,"a":"x\/y","n":null,"reasoning":2,"workLog":[]}"#)
    }

    func testAppendingToAnEmptyObjectNeedsNoComma() throws {
        let extended = try XCTUnwrap(RawJSON.appending(
            ["workLog": .array([])], keyOrder: WorkLogWire.keys, toObject: Data("{ }".utf8)))
        XCTAssertEqual(String(decoding: extended, as: UTF8.self), #"{ "workLog":[]}"#)
    }

    /// A key written twice is read differently by different parsers. Never written.
    func testAppendingAnExistingKeyIsRefused() {
        XCTAssertNil(RawJSON.appending(
            ["workLog": .array([])], keyOrder: WorkLogWire.keys,
            toObject: Data(#"{"workLog":[1]}"#.utf8)))
        XCTAssertNil(RawJSON.appending(
            ["workLog": .array([])], keyOrder: WorkLogWire.keys, toObject: Data("[1]".utf8)))
    }
}

// MARK: - When a save is safe

/// Each condition under which a `/sync` rewrite would cost something other than the log.
final class WorkLogSyncTests: XCTestCase {

    private func transcript() -> [ChatMessage] {
        [
            message(.user, "Is the suit barred?", id: "q1"),
            message(.assistant, "Yes, under Article 58."),
            message(.user, "And the counter-claim?", id: "q2"),
            message(.assistant, "It is within time.", extra: logFields),
        ]
    }

    private func server() -> [ChatMessage] {
        [
            message(.user, "Is the suit barred?", id: "q1"),
            message(.assistant, "Yes, under Article 58."),
            message(.user, "And the counter-claim?", id: "q2"),
            message(.assistant, "It is within time.", done: true),
        ]
    }

    func testTheStoredConversationMatchingIsSafe() {
        XCTAssertNil(WorkLogSync.mismatch(server: server(), local: transcript()))
    }

    /// The fixture's own conversation: a web turn with its log and attachments, then this
    /// client's question and the server's answer.
    func testTheFixturesConversationIsSafe() {
        XCTAssertNil(WorkLogSync.mismatch(server: storedMessages(), local: appTranscript()))
    }

    /// The stored answer is the server run's own copy and may not match this client's character
    /// for character; it is identified by the question before it, not by its text.
    func testTheAnswerItselfIsMatchedByItsQuestion() {
        var server = server()
        server[3].content = "It is within time.\n\n[Error: quotation check skipped]"
        XCTAssertNil(WorkLogSync.mismatch(server: server, local: transcript()))
    }

    func testARunInFlightIsNeverRewritten() {
        var server = server()
        server.append(message(.assistant, "partial", isTyping: true))
        XCTAssertEqual(WorkLogSync.mismatch(server: server, local: transcript()), .runStillActive)
        // Even when the counts happen to agree.
        var replaced = self.server()
        replaced[3].isTyping = true
        XCTAssertEqual(WorkLogSync.mismatch(server: replaced, local: transcript()), .runStillActive)
    }

    func testATurnAskedElsewhereIsNotOverwritten() {
        var server = server()
        server.append(message(.user, "Asked on the web", id: "w1"))
        XCTAssertEqual(WorkLogSync.mismatch(server: server, local: transcript()), .serverHasMore)
    }

    /// The count guard on the server would let this through: an edit leaves fewer messages.
    func testAnEditElsewhereIsNotUndone() {
        let server = Array(server().prefix(2)) + [message(.user, "Edited on the web", id: "w2")]
        XCTAssertEqual(WorkLogSync.mismatch(server: server, local: transcript()), .serverHasFewer)
    }

    /// Same count, different conversation — the case only a full comparison catches.
    func testAnEarlierTurnChangedElsewhereIsNotOverwritten() {
        var server = server()
        server[1].content = "Yes, under Article 58 — see the edited draft."
        XCTAssertEqual(WorkLogSync.mismatch(server: server, local: transcript()),
                       .transcriptDiffers(at: 1))
        var roles = self.server()
        roles[0].role = .assistant
        XCTAssertEqual(WorkLogSync.mismatch(server: roles, local: transcript()),
                       .transcriptDiffers(at: 0))
    }

    /// The same words asked again on the web are a different question.
    func testTheQuestionMustBeTheOneThisClientAsked() {
        var server = server()
        server[2].id = nil
        XCTAssertEqual(WorkLogSync.mismatch(server: server, local: transcript()), .questionNotFound)
    }

    func testTheAnswerMustBeAFinishedServerRun() {
        var server = server()
        server[3].done = nil
        XCTAssertEqual(WorkLogSync.mismatch(server: server, local: transcript()), .answerNotFinished)
        server[3].extra["serverRun"] = .bool(true)
        XCTAssertNil(WorkLogSync.mismatch(server: server, local: transcript()),
                     "`serverRun` alone marks the server's own answer")
    }

    /// Another client stored its log first. Not overwritten.
    func testALogAlreadyStoredIsKept() {
        var server = server()
        server[3].extra["workLog"] = .array([])
        XCTAssertEqual(WorkLogSync.mismatch(server: server, local: transcript()), .alreadyHasLog)
    }

    func testThereMustBeAnAnswerAndAQuestionWithAnID() {
        XCTAssertEqual(WorkLogSync.mismatch(server: server(), local: Array(transcript().prefix(3))),
                       .noAnswer)
        var local = transcript()
        local[2].id = nil
        XCTAssertEqual(WorkLogSync.mismatch(server: server(), local: local), .noQuestionID)
    }

    // MARK: - The body

    func testTheBodyEchoesTheChatRowAndAddsTheLogToTheLastMessageOnly() throws {
        let slices = [Data(#"{"role":"user","content":"Q","id":"q2"}"#.utf8),
                      Data(#"{"role":"assistant","content":"A","done":true}"#.utf8)]
        let chat = ChatSummary(
            id: "c-1", title: "Sharma v Gupta", role: nil, model: "fast",
            updatedAtRaw: "2026-10-03 06:30:00")
        let body = try XCTUnwrap(WorkLogSync.body(
            userID: "42", chat: chat, storedMessages: slices, adding: logFields))

        let parsed = try XCTUnwrap(json(body))
        XCTAssertEqual(parsed["userId"], .string("42"))
        guard case .array(let chats)? = parsed["chats"], let only = chats.first, chats.count == 1 else {
            return XCTFail("exactly one chat")
        }
        XCTAssertEqual(only["id"], .string("c-1"))
        XCTAssertEqual(only["title"], .string("Sharma v Gupta"))
        XCTAssertEqual(only["role"], .null, "a null role goes back null, not missing")
        XCTAssertEqual(only["model"], .string("fast"))
        XCTAssertEqual(only["updatedAt"], .string("2026-10-03 06:30:00"),
                       "storing a log must not move the chat up History")

        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains(#"[{"role":"user","content":"Q","id":"q2"},"#))
        XCTAssertTrue(text.contains(#"{"role":"assistant","content":"A","done":true,"reasoning":"#))
        guard case .array(let messages)? = only["messages"] else { return XCTFail("no messages") }
        XCTAssertEqual(messages.last?["workLog"], logFields["workLog"])
        XCTAssertNil(messages.first?["workLog"])
    }
}

// MARK: - The save, over the wire

final class WorkLogServiceTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)
    private static let chatsBody = """
        {"success":true,"chats":[\
        {"id":"other","title":"Another matter","role":"Litigator","model":"fast","updatedAt":"2026-10-01 09:00:00","messageCount":2},\
        {"id":"chat-1","title":"Is the eviction notice valid?","role":"Corporate","model":"pro","updatedAt":"2026-10-03 06:30:00","messageCount":6}]}
        """

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    private func makeService(signedIn: Bool = true) async -> (ChatService, APIClient) {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        if signedIn { await client.setCredentials(Credentials(token: "tok", userID: 42)) }
        return (ChatService(client: client), client)
    }

    /// A server holding the fixture's conversation. `messages` overrides the stored body.
    private func serve(messages: String = WorkLogFixture.shared.messagesBody,
                       chats: String = chatsBody,
                       sync: HTTPStub.Reply = .json(#"{"success":true}"#)) {
        HTTPStub.respond { request in
            switch request.path {
            case "/api/chats": return .json(chats)
            case "/api/messages": return .json(messages)
            case "/api/sync": return sync
            default: return .json("{}", status: 404)
            }
        }
    }

    private var syncRequests: [URLRequest] { HTTPStub.seen.filter { $0.path == "/api/sync" } }

    private func save(
        _ service: ChatService, transcript: [ChatMessage] = appTranscript(),
        commit: Bool = true
    ) async -> WorkLogSaveOutcome {
        await service.saveWorkLog(
            appFields(), transcript: transcript, chatID: "chat-1", commit: { commit })
    }

    func testTheLogIsStoredThroughSync() async throws {
        let (service, _) = await makeService()
        serve()
        let outcome = await save(service)
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(HTTPStub.seen.map(\.path), ["/api/chats", "/api/messages", "/api/sync"],
                       "the chat row first and the messages last, so the window is one round trip")
        let request = try XCTUnwrap(syncRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.header("Authorization"), "Bearer tok")
        XCTAssertEqual(request.header("Content-Type"), "application/json")
    }

    /// **The guarantee.** Every message goes back as the exact bytes `GET /messages` returned —
    /// attachments in both wire forms, `sources`, `usage`, a null, an unknown `feedback`, the web's
    /// own work log on its own answer, Devanagari, escapes — and the last one gains the log and
    /// nothing else.
    func testEveryStoredMessageGoesBackByteForByte() async throws {
        let (service, _) = await makeService()
        serve()
        _ = await save(service)
        let body = try XCTUnwrap(syncRequests.first?.httpBody)

        let stored = try XCTUnwrap(RawJSON.arrayElements(
            forKey: "messages", in: Data(WorkLogFixture.shared.messagesBody.utf8)))
        let sent = try XCTUnwrap(postedMessages(in: body))
        XCTAssertEqual(sent.count, stored.count)
        for index in 0..<(stored.count - 1) {
            XCTAssertEqual(sent[index], stored[index], "message \(index) changed on the way back")
        }

        // The answer: its stored bytes, then the three keys, then its closing brace.
        let answer = try XCTUnwrap(sent.last)
        let original = try XCTUnwrap(stored.last)
        XCTAssertEqual(answer.prefix(original.count - 1), original.dropLast())
        let added = String(decoding: answer.dropFirst(original.count - 1), as: UTF8.self)
        XCTAssertTrue(added.hasPrefix(#","reasoning":"#), added)
        XCTAssertTrue(added.hasSuffix("}"))

        let reread = try XCTUnwrap(json(answer))
        let before = try XCTUnwrap(json(original))
        guard case .object(let after) = reread, case .object(let was) = before else {
            return XCTFail("the answer is not an object")
        }
        XCTAssertEqual(after.filter { !WorkLogWire.keys.contains($0.key) }, was)
        for key in WorkLogWire.keys {
            XCTAssertEqual(after[key], appFields()[key], key)
        }
    }

    func testTheChatRowGoesBackAsListed() async throws {
        let (service, _) = await makeService()
        serve()
        _ = await save(service)
        let body = try XCTUnwrap(syncRequests.first?.httpBody)
        let parsed = try XCTUnwrap(json(body))
        XCTAssertEqual(parsed["userId"], .string("42"))
        guard case .array(let chats)? = parsed["chats"] else { return XCTFail("no chats") }
        XCTAssertEqual(chats.count, 1, "only this conversation is sent")
        XCTAssertEqual(chats.first?["id"], .string("chat-1"))
        XCTAssertEqual(chats.first?["title"], .string("Is the eviction notice valid?"))
        XCTAssertEqual(chats.first?["role"], .string("Corporate"))
        XCTAssertEqual(chats.first?["model"], .string("pro"))
        XCTAssertEqual(chats.first?["updatedAt"], .string("2026-10-03 06:30:00"))
    }

    // MARK: Declining

    func testAChatNotListedIsNotWritten() async {
        let (service, _) = await makeService()
        serve(chats: #"{"success":true,"chats":[]}"#)
        let outcome = await save(service)
        XCTAssertEqual(outcome, .skipped(.chatNotListed))
        XCTAssertTrue(syncRequests.isEmpty)
    }

    func testAStoredConversationThatDiffersIsNotWritten() async throws {
        let (service, _) = await makeService()
        // A turn asked on the web since: one more message than this client knows about.
        var stored = try XCTUnwrap(json(Data(WorkLogFixture.shared.messagesBody.utf8)))
        if case .array(var messages)? = stored["messages"], case .object(var object) = stored {
            messages.append(.object(["role": .string("user"), "content": .string("Asked on the web")]))
            object["messages"] = .array(messages)
            stored = .object(object)
        }
        serve(messages: String(decoding: try JSONEncoder().encode(stored), as: UTF8.self))
        let outcome = await save(service)
        XCTAssertEqual(outcome, .skipped(.serverHasMore))
        XCTAssertTrue(syncRequests.isEmpty)
    }

    func testARunStillCheckpointingIsNotWritten() async throws {
        let (service, _) = await makeService()
        let body = WorkLogFixture.shared.messagesBody
            .replacingOccurrences(of: #""isTyping":false"#, with: #""isTyping":true"#)
        serve(messages: body)
        let outcome = await save(service)
        XCTAssertEqual(outcome, .skipped(.runStillActive))
        XCTAssertTrue(syncRequests.isEmpty)
    }

    /// The view model's last word: a new turn began while the save was being prepared.
    func testACommitRefusedIsNotWritten() async {
        let (service, _) = await makeService()
        serve()
        let outcome = await save(service, commit: false)
        XCTAssertEqual(outcome, .skipped(.newTurnStarted))
        XCTAssertTrue(syncRequests.isEmpty)
    }

    func testSignedOutSendsNothing() async {
        let (service, _) = await makeService(signedIn: false)
        serve()
        let outcome = await save(service)
        XCTAssertEqual(outcome, .skipped(.signedOut))
        XCTAssertTrue(HTTPStub.seen.isEmpty)
    }

    /// A failure is an outcome, never an error the user sees — and never a sign-out.
    func testAFailedWriteIsSilent() async {
        let (service, client) = await makeService()
        let signedOut = SignOutFlag()
        await client.setAuthenticationLostHandler { signedOut.set() }

        serve(sync: .json(#"{"error":"database is locked"}"#, status: 500))
        let failed = await save(service)
        XCTAssertEqual(failed, .failed)

        HTTPStub.reset()
        serve(sync: .json(#"{"success":false,"error":"Unauthorized"}"#, status: 401))
        let refused = await save(service)
        XCTAssertEqual(refused, .failed)
        XCTAssertFalse(signedOut.value, "storing a log must never sign anyone out")
    }

    func testAnUnreachableServerIsSilent() async {
        let (service, _) = await makeService()
        HTTPStub.fail(URLError(.notConnectedToInternet))
        let outcome = await save(service)
        XCTAssertEqual(outcome, .failed)
    }

    /// The messages array of the chat in a posted `/sync` body, element by element.
    private func postedMessages(in body: Data) -> [Data]? {
        let bytes = [UInt8](body)
        let marker = Array(#""messages":"#.utf8)
        guard let start = (0...(bytes.count - marker.count)).first(where: {
            Array(bytes[$0..<($0 + marker.count)]) == marker
        }) else { return nil }
        var scanner = RawJSON.Scanner(bytes: bytes)
        scanner.index = start + marker.count
        return scanner.arrayElements()?.map { Data(bytes[$0]) }
    }
}

private final class SignOutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

// MARK: - Every key goes back through /chat too

/// `POST /chat` stores the history it is sent as the conversation. A key this client drops on
/// the way through is deleted — including another client's work log on an earlier answer.
final class ChatMessageRoundTripTests: XCTestCase {

    func testEveryStoredMessageEncodesBackToItsOwnValue() throws {
        let slices = try XCTUnwrap(RawJSON.arrayElements(
            forKey: "messages", in: Data(WorkLogFixture.shared.messagesBody.utf8)))
        for (index, slice) in slices.enumerated() {
            let decoded = try JSONDecoder().decode(ChatMessage.self, from: slice)
            let encoded = try JSONEncoder().encode(decoded)
            XCTAssertEqual(json(encoded), json(slice), "message \(index)")
        }
    }

    /// The history a follow-up question posts carries the web's log on the web's answer.
    func testTheNextQuestionCarriesEveryKeyOfTheHistory() throws {
        let history = storedMessages()
        let request = ChatRequest(
            messages: history, userId: "42", chatId: "chat-1", model: "fast", role: nil,
            searchMode: nil, attachments: nil, source: "chat")
        let posted = try XCTUnwrap(json(try JSONEncoder().encode(request)))
        guard case .array(let messages)? = posted["messages"] else { return XCTFail("no messages") }

        let slices = try XCTUnwrap(RawJSON.arrayElements(
            forKey: "messages", in: Data(WorkLogFixture.shared.messagesBody.utf8)))
        XCTAssertEqual(messages, slices.compactMap(json))
        XCTAssertNotNil(messages[3]["workLog"], "the web's log survives the phone's next question")
    }

    /// A malformed or missing modelled key goes back exactly as it came — a default this client
    /// filled in is not written as though the server had sent it.
    func testMalformedAndMissingKeysGoBackAsTheyCame() throws {
        for raw in [
            #"{"role":"tool","content":5,"id":42,"done":"yes","timestamp":1696000000000,"usage":null,"attachments":"x.pdf","sources":null,"isTyping":null,"incomplete":0}"#,
            #"{"x":1}"#,
            #"{"role":"assistant","content":"A","attachments":[],"sources":[],"usage":null,"serverRun":true,"incompleteReason":null}"#,
        ] {
            let data = Data(raw.utf8)
            let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
            XCTAssertEqual(json(try JSONEncoder().encode(decoded)), json(data), raw)
        }
    }

    /// A default is a default only while it is untouched.
    func testADeliberateChangeIsWritten() throws {
        var decoded = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"x":1}"#.utf8))
        decoded.content = "Now with words."
        let encoded = try XCTUnwrap(json(try JSONEncoder().encode(decoded)))
        XCTAssertEqual(encoded["content"], .string("Now with words."))
        XCTAssertNil(encoded["role"], "the role was never set, so it is still not written")
    }

    func testAStoredLogIsReadOnlyFromAnAnswer() {
        var question = message(.user, "Q", extra: WorkLogFixture.named("research").stored)
        XCTAssertNil(question.storedWorkLog)
        question.role = .assistant
        XCTAssertNotNil(question.storedWorkLog)
    }

    /// A malformed field costs that field, never the message or the rest of the panel.
    func testAMalformedLogCostsOnlyItself() throws {
        let raw = #"""
            {"role":"assistant","content":"The answer.","reasoning":"not an object",
             "workflowTasks":[7,{"title":"Read","subtasks":[{"label":"Open the deed","status":"in-progress"},{"nolabel":true}]}],
             "workLog":[{"kind":"group","steps":[{"label":"Reading page 2 of Deed"},{"label":4}]},{"kind":"mystery"},{"kind":"note","text":"  "}]}
            """#
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.content, "The answer.")
        let log = try XCTUnwrap(decoded.storedWorkLog)
        XCTAssertTrue(log.reasoning.isEmpty)
        XCTAssertEqual(log.plan.map(\.title), ["Read"])
        XCTAssertEqual(log.plan.first?.subtasks.map(\.title), ["Open the deed"])
        XCTAssertEqual(log.plan.first?.subtasks.first?.status, .stopped,
                       "nothing in a stored log is still running")
        XCTAssertEqual(log.plan.first?.status, .pending)
        XCTAssertEqual(log.workLog.count, 1)
        guard case .group(let group)? = log.workLog.first else { return XCTFail("no round") }
        XCTAssertEqual(group.steps.map(\.label), ["Reading page 2 of Deed"])
        XCTAssertEqual(group.steps.first?.status, .stopped,
                       "a step with no status never wears the tick")
    }
}
