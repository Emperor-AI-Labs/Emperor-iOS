import XCTest
@testable import EmperorCore

/// A stand-in server, counting calls as well as recording them — several tests here assert that
/// a send did **not** happen, which a "last request" field alone cannot show.
private final class FakeChat: ChatProviding, @unchecked Sendable {
    var history: [ChatMessage] = []
    var messagesError: Error?
    var sentHistory: [ChatMessage] = []
    var sendCount = 0

    func messages(chatID: String) async throws -> [ChatMessage] {
        if let messagesError { throw messagesError }
        return history
    }

    func streamStatus(chatID: String) async throws -> StreamStatus { StreamStatus(active: false) }

    func send(
        history: [ChatMessage], chatID: String, model: ChatModel, role: ChatRole?,
        attachments: [ChatAttachment]?, webSearch: Bool
    ) async throws -> AsyncThrowingStream<ChatTurnEvent, Error> {
        sentHistory = history
        sendCount += 1
        return AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private func withChat(
    _ stored: [ChatMessage] = [],
    _ body: @MainActor (FakeChat, ChatViewModel) async -> Void
) async {
    let fake = FakeChat()
    fake.history = stored
    let model = ChatViewModel(chatID: "chat-1", service: fake)
    if !stored.isEmpty { await model.load() }
    await body(fake, model)
}

@MainActor
private func settle(_ model: ChatViewModel) async {
    for _ in 0..<400 {
        if !model.isStreaming { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func userTurn(_ text: String, id: String) -> ChatMessage {
    ChatMessage(role: .user, content: text, id: id)
}

private func assistantTurn(_ text: String, id: String) -> ChatMessage {
    ChatMessage(role: .assistant, content: text, id: id)
}

/// Editing a question, and the guard that makes it safe.
///
/// `POST /chat` replaces the chat's stored messages with exactly the array it receives. Two
/// things follow and both are pinned here: an edit genuinely deletes the turns after it at
/// *both* ends, which is the intent; and a send against a history we failed to read would
/// delete all of it, which is not.
final class ChatEditTests: XCTestCase {

    // MARK: - The guard

    /// **The one that matters.** Before this existed, a failed load left `messages` empty and
    /// nothing stopped a send — which would have posted a one-message history and deleted every
    /// earlier turn on the server, with no error and no way to tell until the next load.
    func testAFailedLoadDisarmsSending() async {
        await withChat { fake, model in
            fake.messagesError = APIError.transport("the network dropped")
            await model.load()

            XCTAssertFalse(model.historyIsIntact)
            XCTAssertNotNil(model.sendBlockedReason)

            model.send("this must not go anywhere")
            await settle(model)
            XCTAssertEqual(
                fake.sendCount, 0,
                "a send after a failed load would replace the stored conversation")
        }
    }

    /// A brand-new chat reports "Chat not found" rather than an empty list. There is nothing
    /// stored to overwrite, so it must stay armed — otherwise the first message of every new
    /// conversation would be silently refused.
    func testANewChatIsStillSendable() async {
        await withChat { fake, model in
            fake.messagesError = APIError.server(status: 500, message: "Chat not found")
            await model.load()

            XCTAssertTrue(model.historyIsIntact)
            XCTAssertNil(model.sendBlockedReason)

            model.send("first question")
            await settle(model)
            XCTAssertEqual(fake.sendCount, 1)
        }
    }

    func testARecoveredLoadRearmsSending() async {
        await withChat { fake, model in
            fake.messagesError = APIError.transport("the network dropped")
            await model.load()
            XCTAssertFalse(model.historyIsIntact)

            fake.messagesError = nil
            fake.history = [userTurn("q", id: "m1")]
            await model.load()

            XCTAssertTrue(model.historyIsIntact, "a successful retry must re-arm the composer")
        }
    }

    // MARK: - The count

    /// Re-answering the first of five turns discards all five. A confirmation that says "this
    /// cannot be undone" without saying how much is a formality, not a confirmation.
    func testTheDiscardCountIsTheTurnAndEverythingAfterIt() async {
        await withChat([
            userTurn("one", id: "m1"), assistantTurn("a1", id: "m2"),
            userTurn("two", id: "m3"), assistantTurn("a2", id: "m4"),
            userTurn("three", id: "m5"),
        ]) { _, model in
            XCTAssertEqual(model.discardCount(editing: model.messages[0]), 5)
            XCTAssertEqual(model.discardCount(editing: model.messages[2]), 3)
            XCTAssertEqual(model.discardCount(editing: model.messages[4]), 1)
        }
    }

    /// An assistant answer is not ours to rewrite, and offering it would suggest the model could
    /// be made to have said something it did not.
    func testAnAssistantTurnCannotBeEdited() async {
        await withChat([userTurn("q", id: "m1"), assistantTurn("a", id: "m2")]) { fake, model in
            let answer = model.messages[1]
            XCTAssertFalse(model.canEdit(answer))
            XCTAssertEqual(model.discardCount(editing: answer), 0)

            model.edit(answer, to: "rewritten")
            await settle(model)
            XCTAssertEqual(fake.sendCount, 0)
            XCTAssertEqual(model.messages.count, 2, "nothing may be discarded either")
        }
    }

    func testEditingIsRefusedWhenHistoryIsNotIntact() async {
        await withChat { fake, model in
            fake.messagesError = APIError.transport("the network dropped")
            await model.load()

            let stale = userTurn("q", id: "m1")
            XCTAssertFalse(model.canEdit(stale))
            model.edit(stale, to: "new")
            await settle(model)
            XCTAssertEqual(fake.sendCount, 0)
        }
    }

    // MARK: - The edit

    /// The model must not see the original wording or the answer it produced, or it reconciles
    /// the two instead of starting again.
    func testEditingTruncatesFromThatTurnAndResends() async throws {
        try await withChatThrowing([
            userTurn("first", id: "m1"), assistantTurn("a1", id: "m2"),
            userTurn("second", id: "m3"), assistantTurn("a2", id: "m4"),
        ]) { fake, model in
            model.edit(model.messages[2], to: "second, rephrased")
            await settle(model)

            XCTAssertEqual(fake.sentHistory.map(\.content), ["first", "a1", "second, rephrased"])
            XCTAssertFalse(
                fake.sentHistory.contains { $0.content == "second" },
                "the original wording still went")
            XCTAssertFalse(
                fake.sentHistory.contains { $0.content == "a2" },
                "the answer being replaced still went")
        }
    }

    /// Attachments live on the message. Dropping them would change the question by more than its
    /// words — the edited turn would ask about nothing.
    func testAnEditKeepsTheDocumentsTheQuestionAskedAbout() async {
        var turn = userTurn("what does it say", id: "m1")
        turn.attachments = [ChatAttachment(name: "award.pdf", folderName: "Bakshi").jsonValue]

        await withChat([turn, assistantTurn("a", id: "m2")]) { _, model in
            model.edit(model.messages[0], to: "what does clause 9 say")
            await settle(model)

            XCTAssertEqual(
                model.attachments,
                [ChatAttachment(name: "award.pdf", folderName: "Bakshi")])
        }
    }

    func testAnEmptyEditIsANoOp() async {
        await withChat([userTurn("q", id: "m1")]) { fake, model in
            model.edit(model.messages[0], to: "   ")
            await settle(model)
            XCTAssertEqual(fake.sendCount, 0)
            XCTAssertEqual(model.messages.count, 1, "the turn must not be discarded for nothing")
        }
    }

    // MARK: - Reading attachments back off a turn

    /// The server accepts a bare filename or an object, and a conversation may hold turns
    /// written by the web client — so both have to decode.
    func testAttachmentsDecodeFromBothWireShapes() {
        let values: [JSONValue] = [
            .string("root.pdf"),
            .object(["name": .string("nested.pdf"), "folderName": .string("Bakshi")]),
            .object(["name": .string("bare.pdf")]),
            .string("   "),                          // blank
            .object(["folderName": .string("x")]),   // no name
        ]
        XCTAssertEqual(
            ChatAttachment.list(from: values),
            [
                ChatAttachment(name: "root.pdf"),
                ChatAttachment(name: "nested.pdf", folderName: "Bakshi"),
                ChatAttachment(name: "bare.pdf"),
            ])
        XCTAssertEqual(ChatAttachment.list(from: nil), [])
    }
}

@MainActor
private func withChatThrowing(
    _ stored: [ChatMessage],
    _ body: @MainActor (FakeChat, ChatViewModel) async throws -> Void
) async throws {
    let fake = FakeChat()
    fake.history = stored
    let model = ChatViewModel(chatID: "chat-1", service: fake)
    await model.load()
    try await body(fake, model)
}
