import XCTest
@testable import EmperorCore

/// A stand-in server. Lets us drive the exact event sequences the real backend produces —
/// including the awkward ones that are hard to reproduce on demand against a live server.
private final class FakeChat: ChatProviding, @unchecked Sendable {
    var history: [ChatMessage] = []
    var status = StreamStatus(active: false)
    var events: [ChatTurnEvent] = []
    var sendError: Error?
    var messagesError: Error?
    /// What `send` was called with, so we can assert the request and not only the result.
    var sentHistory: [ChatMessage] = []
    var sentModel: ChatModel?
    var sentRole: ChatRole?
    var sentWebSearch: Bool?

    func messages(chatID: String) async throws -> [ChatMessage] {
        if let messagesError { throw messagesError }
        return history
    }

    func streamStatus(chatID: String) async throws -> StreamStatus { status }

    func send(
        history: [ChatMessage], chatID: String, model: ChatModel, role: ChatRole?,
        attachments: [ChatAttachment]?, webSearch: Bool
    ) async throws -> AsyncThrowingStream<ChatTurnEvent, Error> {
        sentHistory = history
        sentModel = model
        sentRole = role
        sentWebSearch = webSearch
        if let sendError { throw sendError }
        let queued = events
        return AsyncThrowingStream { continuation in
            for event in queued { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Free functions rather than methods: an `XCTestCase` is not `Sendable`, so calling an
/// instance helper from a `@MainActor` closure makes Swift 6 reject the capture of `self`.
@MainActor
private func withModel(_ body: @MainActor (FakeChat, ChatViewModel) async -> Void) async {
    let fake = FakeChat()
    await body(fake, ChatViewModel(chatID: "chat-1", service: fake))
}

/// Waits for the in-flight turn to settle. Sending is deliberately fire-and-forget so the UI
/// stays responsive, which means tests poll rather than await it.
@MainActor
private func settle(_ model: ChatViewModel) async {
    for _ in 0..<400 {
        if !model.isStreaming { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("stream did not settle")
}

/// The class is deliberately **not** `@MainActor`: Linux XCTest cannot cast a `@MainActor`
/// test method and aborts the entire run. Each test hops through `withModel`, which is
/// isolated, so the view model is still exercised on the main actor.
final class ChatWebSearchTests: XCTestCase {

    /// Off by default. The platform's own default is no explicit search mode, and asking for
    /// one on every turn would slow ordinary questions down for nothing.
    func testWebSearchIsOffByDefault() async {
        await withModel { fake, model in
            model.send("What is the limitation period?")
            await settle(model)
            XCTAssertEqual(fake.sentWebSearch, false)
        }
    }

    func testTurningItOnAsksForASearch() async {
        await withModel { fake, model in
            model.webSearch = true
            model.send("What did the Court hold last week?")
            await settle(model)
            XCTAssertEqual(fake.sentWebSearch, true)
        }
    }

    /// The preference is per-conversation and persists across turns — a matter that needs
    /// current law needs it for every question, not the first one.
    func testThePreferenceSurvivesTheTurn() async {
        await withModel { fake, model in
            model.webSearch = true
            model.send("First")
            await settle(model)
            model.send("Second")
            await settle(model)
            XCTAssertEqual(fake.sentWebSearch, true)
        }
    }
}

final class ChatViewModelTests: XCTestCase {

    // MARK: - Loading

    func testLoadPopulatesHistory() async {
        await withModel { fake, model in
            fake.history = [
                ChatMessage(role: .user, content: "Is the suit barred?"),
                ChatMessage(role: .assistant, content: "Yes, under Article 58."),
            ]
            await model.load()

            XCTAssertEqual(model.messages.count, 2)
            XCTAssertNil(model.errorMessage)
        }
    }

    /// A brand-new chat has no row yet, and this API reports that as an error rather than an
    /// empty list. Surfacing it would make every new conversation look broken.
    func testChatNotFoundIsNotSurfacedAsAnError() async {
        await withModel { fake, model in
            fake.messagesError = APIError.server(status: 500, message: "Chat not found")
            await model.load()

            XCTAssertNil(model.errorMessage)
            XCTAssertTrue(model.messages.isEmpty)
        }
    }

    /// A genuine failure still has to reach the user.
    func testRealLoadFailureIsSurfaced() async {
        await withModel { fake, model in
            fake.messagesError = APIError.transport("The network connection was lost.")
            await model.load()

            XCTAssertEqual(model.errorMessage, "The network connection was lost.")
        }
    }

    /// Generation is not tied to the socket — a run continues on the server while the app is
    /// closed. Reopening the chat must rejoin it rather than show an empty screen.
    func testReopeningRejoinsARunStillInFlight() async {
        await withModel { fake, model in
            fake.status = StreamStatus(
                active: true, done: false, incomplete: false, isTyping: true,
                step: "unknown", contentLength: 16, content: "The draft so far")
            await model.load()

            XCTAssertTrue(model.isStreaming)
            XCTAssertEqual(model.live?.prose, "The draft so far")
            model.stop()
            await settle(model)
        }
    }

    /// An aborted run ends its response cleanly with no error bytes, so `/stream-status` is
    /// the only thing that can tell us the answer was cut short.
    func testInterruptedRunIsFlaggedOnLoad() async {
        await withModel { fake, model in
            fake.status = StreamStatus(active: false, done: true, incomplete: true)
            await model.load()

            XCTAssertTrue(model.wasInterrupted)
            XCTAssertFalse(model.isStreaming)
        }
    }

    // MARK: - Sending

    func testSendAppendsTurnAndStreamsAnswer() async {
        await withModel { fake, model in
            fake.events = [
                .status("Preparing…"),
                .content(StreamContent.parse("The suit is barred.")),
            ]
            model.send("Is the suit barred?")
            await settle(model)

            XCTAssertEqual(model.messages.count, 2)
            XCTAssertEqual(model.messages.first?.role, .user)
            XCTAssertEqual(model.messages.last?.role, .assistant)
            XCTAssertEqual(model.messages.last?.content, "The suit is barred.")
        }
    }

    /// `/chat` replaces the chat's stored messages with exactly what it received, so anything
    /// omitted is deleted server-side. The whole conversation must go every time.
    func testSendTransmitsTheWholeConversation() async {
        await withModel { fake, model in
            fake.history = [
                ChatMessage(role: .user, content: "First question"),
                ChatMessage(role: .assistant, content: "First answer"),
            ]
            fake.events = [.content(StreamContent.parse("Second answer"))]
            await model.load()
            model.send("Second question")
            await settle(model)

            XCTAssertEqual(fake.sentHistory.count, 3, "prior turns must be re-sent, not dropped")
            XCTAssertEqual(fake.sentHistory.map(\.content),
                           ["First question", "First answer", "Second question"])
        }
    }

    func testSendTransmitsModelAndRole() async {
        await withModel { fake, model in
            fake.events = [.content(StreamContent.parse("ok"))]
            model.model = .thinking
            model.role = .judicialOfficer
            model.send("Question")
            await settle(model)

            XCTAssertEqual(fake.sentModel, .thinking)
            XCTAssertEqual(fake.sentRole, .judicialOfficer)
        }
    }

    func testEmptyMessageIsIgnored() async {
        await withModel { _, model in
            model.send("   \n  ")
            XCTAssertTrue(model.messages.isEmpty)
            XCTAssertFalse(model.isStreaming)
        }
    }

    /// The server refuses a second run on a chat already generating and answers 200 with an
    /// explanation. That explanation is not an answer and must stay out of the transcript.
    ///
    /// The refusal happens **before** anything is stored (`sync-server.js:7256-7276`), so the
    /// optimistic user bubble is a turn that exists nowhere. Leaving it made the typed question
    /// disappear on the next load with no trace; it is handed back to the composer instead.
    func testBusyRefusalGivesTheQuestionBackRatherThanLosingIt() async {
        await withModel { fake, model in
            fake.events = [.busy("Your draft for this chat is still being generated.")]
            model.send("Another question")
            await settle(model)

            XCTAssertNotNil(model.busyNotice)
            XCTAssertNil(model.live)
            XCTAssertTrue(
                model.messages.isEmpty,
                "nothing was stored server-side, so nothing belongs in the transcript")
            XCTAssertEqual(
                model.restoredDraft, "Another question",
                "and the user's typing is not thrown away")
        }
    }

    /// Stopping mid-poll must not append the answer twice. A poll already in flight when
    /// `stop()` ran used to resurrect `live` and finish a second time — and since history is
    /// posted back verbatim, the duplicate was then persisted server-side.
    func testStoppingDuringAnInFlightPollDoesNotDoubleAppend() async {
        await withModel { fake, model in
            fake.status = StreamStatus(
                active: true, done: false, incomplete: false, isTyping: true,
                step: "unknown", contentLength: 8, content: "The draft")
            await model.load()
            XCTAssertTrue(model.isStreaming)

            model.stop()
            await settle(model)
            let afterStop = model.messages.count

            // Give any late poll a chance to land.
            try? await Task.sleep(for: .milliseconds(60))

            XCTAssertEqual(model.messages.count, afterStop, "the turn is appended once")
        }
    }

    /// Attachments must ride on the user message too — the scanned-document check reads them
    /// from there, not from the top-level array.
    func testAttachmentsAreEmbeddedOnTheUserTurn() async {
        await withModel { fake, model in
            fake.events = [.content(StreamContent.parse("ok"))]
            model.attachments = [
                ChatAttachment(name: "sale_deed.pdf", folderName: "Partition_Suit"),
            ]
            model.send("What does this say?")
            await settle(model)

            let userTurn = fake.sentHistory.first { $0.role == .user }
            XCTAssertEqual(userTurn?.attachments?.count, 1)
            XCTAssertEqual(userTurn?.attachments?.first?["name"]?.stringValue, "sale_deed.pdf")
        }
    }

    func testProgressSnapshotIsRecorded() async {
        await withModel { fake, model in
            let snapshot = ReasoningSnapshot(
                plan: [PlanRow(title: "Read the record", status: .inProgress, subtasks: [])],
                workLog: [], reasoning: [])
            fake.events = [.progress(snapshot), .content(StreamContent.parse("Done."))]
            model.send("Question")
            await settle(model)

            XCTAssertEqual(model.progress.plan.first?.title, "Read the record")
        }
    }

    func testTransportFailureSurfacesAsAnError() async {
        await withModel { fake, model in
            fake.sendError = APIError.transport("The network connection was lost.")
            model.send("Question")
            await settle(model)

            XCTAssertEqual(model.errorMessage, "The network connection was lost.")
            XCTAssertFalse(model.isStreaming)
        }
    }

    /// Sending clears the previous turn's notices, so a stale warning cannot linger over a
    /// fresh answer.
    func testSendClearsPreviousNotices() async {
        await withModel { fake, model in
            fake.status = StreamStatus(active: false, done: true, incomplete: true)
            await model.load()
            XCTAssertTrue(model.wasInterrupted)

            fake.status = StreamStatus(active: false, done: true, incomplete: false)
            fake.events = [.content(StreamContent.parse("A complete answer."))]
            model.send("Try again")
            await settle(model)

            XCTAssertFalse(model.wasInterrupted)
            XCTAssertNil(model.busyNotice)
        }
    }

    /// The server reports a token-truncated draft as complete, because `/chat`'s `onDone`
    /// (sync-server.js:7797) discards the provider's `status:'length'` verdict. The shape of
    /// the answer is the only remaining evidence, so the view model must act on it.
    func testADraftStrandedMidDocumentIsFlaggedDespiteACleanServerVerdict() async {
        await withModel { fake, model in
            fake.status = StreamStatus(active: false, done: true, incomplete: false)
            fake.events = [.content(StreamContent.parse(
                "[CANVAS_TRIGGER: Written Submissions]\n<canvas_content><p>IN THE HIGH COURT"))]
            model.send("Draft written submissions")
            await settle(model)

            XCTAssertTrue(
                model.wasInterrupted,
                "an unclosed document block means truncated, whatever /stream-status says")
        }
    }

    /// The converse: a complete artifact with a clean verdict must not be flagged.
    func testACompleteDraftIsNotFlagged() async {
        await withModel { fake, model in
            fake.status = StreamStatus(active: false, done: true, incomplete: false)
            fake.events = [.content(StreamContent.parse(
                "[CANVAS_TRIGGER: Draft]\n<canvas_content><p>Complete.</p></canvas_content>"))]
            model.send("Draft it")
            await settle(model)

            XCTAssertFalse(model.wasInterrupted)
        }
    }
}
