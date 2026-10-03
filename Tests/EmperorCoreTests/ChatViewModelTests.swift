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

    /// A month's questions spent, or no plan at all: refused before anything is stored. The
    /// question goes back to the composer and the refusal gets its own card — not a red error
    /// inviting a retry that would only be refused again.
    func testAPlanRefusalGivesTheQuestionBackAndExplainsItself() async {
        await withModel { fake, model in
            fake.sendError = APIError.classify(status: 402, body: Data(#"""
                {"error":"You've used all 30 chat queries on your Free plan this month. Upgrade to keep going.","code":"QUERY_LIMIT","limit":30,"used":30,"resetsAt":"2026-10-31T18:30:00.000Z"}
                """#.utf8))
            model.send("What is the limitation for a s.34 petition?")
            await settle(model)

            XCTAssertEqual(model.refusal?.code, .queryLimit)
            XCTAssertNil(model.errorMessage, "a refusal is not shown twice")
            XCTAssertTrue(model.messages.isEmpty)
            XCTAssertEqual(model.restoredDraft, "What is the limitation for a s.34 petition?")
            XCTAssertFalse(model.isStreaming)

            // The next send starts clean.
            fake.sendError = nil
            model.send("Again")
            await settle(model)
            XCTAssertNil(model.refusal)
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

    /// The finished panel moves onto the answer it explains, as the web's does, so it is drawn
    /// from the answer from then on — the same way it is drawn when the conversation is reopened.
    func testProgressSnapshotTravelsWithTheAnswer() async {
        await withModel { fake, model in
            let snapshot = ReasoningSnapshot(
                plan: [PlanRow(title: "Read the record", status: .inProgress, subtasks: [])],
                workLog: [], reasoning: [])
            fake.events = [.progress(snapshot), .content(StreamContent.parse("Done."))]
            model.send("Question")
            await settle(model)

            XCTAssertEqual(model.messages.last?.storedWorkLog?.plan.first?.title, "Read the record")
            XCTAssertEqual(model.messages.last?.storedWorkLog?.plan.first?.status, .completed,
                           "a clean finish completes the plan")
            XCTAssertTrue(model.progress.isEmpty, "drawn once, on the answer, not twice")
        }
    }

    /// With no answer to carry it, the panel stays where it was — it is the only account of the
    /// work the turn did.
    func testProgressStaysWhenThereIsNoAnswer() async {
        await withModel { fake, model in
            let snapshot = ReasoningSnapshot(
                plan: [PlanRow(title: "Read the record", status: .inProgress, subtasks: [])],
                workLog: [], reasoning: [])
            fake.events = [.progress(snapshot)]
            model.send("Question")
            await settle(model)

            XCTAssertEqual(model.progress.plan.first?.title, "Read the record")
            XCTAssertEqual(model.messages.count, 1)
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

/// The two documents a matter is typically opened with.
///
/// A free function rather than a stored property: an `XCTestCase` is not `Sendable`, and these are
/// read inside `@MainActor` closures — the same reason `withModel` is a free function.
private func pickedDocuments() -> [ChatAttachment] {
    [
        ChatAttachment(name: "Charter_Party_2021.pdf", folderName: "Suvarnapatnam_Port_Terminals"),
        ChatAttachment(name: "Evidence_Vol_2.pdf", folderName: "Suvarnapatnam_Port_Terminals"),
    ]
}

/// The strip of documents above the composer, which is shown only before the first question.
///
/// The rule is one line — `messages.isEmpty` — and both halves of it carry weight, so both are
/// pinned here. Wrong in one direction it costs a line of every screen for the rest of the
/// conversation; wrong in the other the user cannot see the documents they just chose on a
/// different screen, and has only a number in the toolbar to go on.
final class ChatOpeningAttachmentsTests: XCTestCase {

    /// The library picker's Done button opens a new conversation already carrying documents. This
    /// is the only surface that names them before the question is asked.
    func testANewChatNamesWhatItIsAboutToAsk() async {
        await withModel { _, model in
            model.attachments = pickedDocuments()

            XCTAssertEqual(model.openingAttachments, pickedDocuments())
        }
    }

    func testAChatWithNothingAttachedHasNoStrip() async {
        await withModel { _, model in
            XCTAssertTrue(model.openingAttachments.isEmpty)
        }
    }

    /// The boundary is the send, not the answer: `send` appends the user's turn before the
    /// request leaves, so the strip goes on the tap.
    func testTheStripGoesOnceTheQuestionIsAsked() async {
        await withModel { fake, model in
            fake.events = [.content(StreamContent.parse("It runs from receipt."))]
            model.attachments = pickedDocuments()
            model.send("Does the cure period run from breach or from receipt?")
            await settle(model)

            XCTAssertTrue(model.openingAttachments.isEmpty)
            XCTAssertEqual(
                model.attachments, pickedDocuments(),
                "the documents are still attached — only the strip that named them has gone")
        }
    }

    /// "After the first question, no strip in that conversation" — including for a document
    /// attached to a conversation already under way.
    func testAttachingLaterDoesNotBringTheStripBack() async {
        await withModel { fake, model in
            fake.events = [.content(StreamContent.parse("Noted."))]
            model.send("A question with nothing attached")
            await settle(model)

            model.attachments = pickedDocuments()

            XCTAssertTrue(model.openingAttachments.isEmpty)
        }
    }

    /// Opening a conversation from History loads turns into `messages`, so the strip must not
    /// appear on turn nine. This is the case a flag remembered by the view would get wrong.
    func testAConversationOpenedFromHistoryHasNoStrip() async {
        await withModel { fake, model in
            fake.history = [
                ChatMessage(role: .user, content: "Is the suit barred?"),
                ChatMessage(role: .assistant, content: "Yes, under Article 58."),
            ]
            await model.load()
            model.attachments = pickedDocuments()

            XCTAssertTrue(model.openingAttachments.isEmpty)
        }
    }
}

// MARK: - Reopening a conversation with its documents

final class ChatAttachmentRestoreTests: XCTestCase {

    /// A conversation reopened from History has to come back holding its documents. They are not
    /// a field on the chat — the server keeps each turn's JSON verbatim and hands it back
    /// untouched — so they exist only on the turns that carried them, and a load that reads only
    /// `content` drops them.
    func testReopeningAConversationBringsItsDocumentsBack() async {
        await withModel { fake, model in
            fake.history = [
                turn("Is the suit barred?", attaching: [("Plaint.pdf", "Menon_vs_Union")]),
                ChatMessage(role: .assistant, content: "See page 4 of Plaint.pdf."),
            ]
            await model.load()

            XCTAssertEqual(model.attachments, [
                ChatAttachment(name: "Plaint.pdf", folderName: "Menon_vs_Union"),
            ])
        }
    }

    /// The union across every turn, not the most recent one. A document attached on turn one is
    /// still what turn seven is about, so reading only the last turn would drop the pleading the
    /// matter rests on the moment a follow-up is asked without re-attaching it.
    func testDocumentsFromEveryTurnAreKept() async {
        await withModel { fake, model in
            fake.history = [
                turn("First", attaching: [("Plaint.pdf", "Menon")]),
                ChatMessage(role: .assistant, content: "..."),
                turn("Second", attaching: [("Evidence.pdf", "Menon")]),
                ChatMessage(role: .assistant, content: "..."),
                turn("Third, asked without re-attaching anything", attaching: []),
            ]
            await model.load()

            XCTAssertEqual(model.attachments.map(\.name), ["Plaint.pdf", "Evidence.pdf"])
        }
    }

    /// Deduplicated on the whole value, in first-seen order. The same file carried on five
    /// consecutive turns is one document, and two matters may each hold an `Order.pdf`.
    func testTheSameDocumentOnEveryTurnAppearsOnce() async {
        await withModel { fake, model in
            fake.history = [
                turn("A", attaching: [("Order.pdf", "Menon"), ("Plaint.pdf", "Menon")]),
                turn("B", attaching: [("Order.pdf", "Menon")]),
                turn("C", attaching: [("Order.pdf", "Suvarnapatnam")]),
            ]
            await model.load()

            XCTAssertEqual(
                model.attachments,
                [
                    ChatAttachment(name: "Order.pdf", folderName: "Menon"),
                    ChatAttachment(name: "Plaint.pdf", folderName: "Menon"),
                    ChatAttachment(name: "Order.pdf", folderName: "Suvarnapatnam"),
                ],
                "same name, different matter — two documents, not one")
        }
    }

    /// Merged into whatever is already chosen, never assigned over it. A conversation can be
    /// opened with documents picked on the library screen, and that choice races this load —
    /// assigning would let whichever finished last erase the other with nothing on screen to
    /// say so.
    func testALoadDoesNotEraseDocumentsAlreadyChosen() async {
        await withModel { fake, model in
            fake.history = [turn("Earlier", attaching: [("Plaint.pdf", "Menon")])]
            model.attachments = [ChatAttachment(name: "Fresh.pdf", folderName: "Menon")]

            await model.load()

            XCTAssertEqual(model.attachments.map(\.name), ["Fresh.pdf", "Plaint.pdf"],
                           "the standing choice leads, the restored ones follow")
        }
    }

    /// An overlap between the two costs nothing.
    func testAChoiceAlreadyHeldIsNotDuplicatedByTheRestore() async {
        await withModel { fake, model in
            fake.history = [turn("Earlier", attaching: [("Plaint.pdf", "Menon")])]
            model.attachments = [ChatAttachment(name: "Plaint.pdf", folderName: "Menon")]

            await model.load()

            XCTAssertEqual(model.attachments.count, 1)
        }
    }

    /// The web client writes a bare string for a document at the storage root, and a
    /// conversation may hold turns written there.
    func testABareStringTurnRestoresToo() async {
        await withModel { fake, model in
            var bare = ChatMessage(role: .user, content: "Q")
            bare.attachments = [.string("Notice.pdf")]
            fake.history = [bare]
            await model.load()

            XCTAssertEqual(model.attachments, [ChatAttachment(name: "Notice.pdf")])
        }
    }

    /// A conversation that never had a document still has none.
    func testAConversationWithNoDocumentsRestoresNothing() async {
        await withModel { fake, model in
            fake.history = [
                ChatMessage(role: .user, content: "Q"),
                ChatMessage(role: .assistant, content: "A"),
            ]
            await model.load()

            XCTAssertTrue(model.attachments.isEmpty)
        }
    }

    /// Restoring documents must not bring the composer's strip back. The strip is for the moment
    /// before the first question, and a reopened conversation is long past it — which is why it
    /// is derived from the transcript rather than from whether anything is attached.
    func testRestoredDocumentsDoNotBringBackTheOpeningStrip() async {
        await withModel { fake, model in
            fake.history = [
                turn("Is the suit barred?", attaching: [("Plaint.pdf", "Menon")]),
                ChatMessage(role: .assistant, content: "Yes."),
            ]
            await model.load()

            XCTAssertFalse(model.attachments.isEmpty, "the documents are back")
            XCTAssertTrue(model.openingAttachments.isEmpty, "the strip is not")
        }
    }
}

// MARK: - Taking a document off a conversation, and having it stay off

/// Removing a document sticks across a reopen.
///
/// `ChatAttachmentRestoreTests` fixed the opposite bug — a reopened conversation arriving with
/// nothing attached — by rebuilding the documents from the turns that carried them. That rebuild
/// cannot tell "attached on turn one" from "attached on turn one and since removed", so removal
/// became impossible: the chip went, and the document was back on the next open.
///
/// The invariant underneath every test here is that **a document is never both attached and
/// detached**. Wrong one way and it cannot be got rid of; wrong the other and it cannot be put
/// back.
final class DetachedDocumentTests: XCTestCase {

    private static let plaint = ChatAttachment(name: "Plaint.pdf", folderName: "Menon")
    private static let evidence = ChatAttachment(name: "Evidence.pdf", folderName: "Menon")

    func testARemovedDocumentDoesNotComeBackOnTheNextOpen() async {
        let store = InMemoryPreferenceStore()
        let history = [turn("Q", attaching: [("Plaint.pdf", "Menon")])]

        await withDetaching(store, history) { model in
            await model.load()
            XCTAssertEqual(model.attachments, [Self.plaint])
            model.detach(Self.plaint)
            XCTAssertTrue(model.attachments.isEmpty)
        }
        // A second view model over the same store is the reopen.
        await withDetaching(store, history) { model in
            await model.load()
            XCTAssertTrue(model.attachments.isEmpty, "it stayed off")
        }
    }

    /// Removing one leaves the others alone.
    func testRemovingOneDocumentKeepsTheRest() async {
        let store = InMemoryPreferenceStore()
        let history = [
            turn("Q", attaching: [("Plaint.pdf", "Menon"), ("Evidence.pdf", "Menon")]),
        ]

        await withDetaching(store, history) { model in
            await model.load()
            model.detach(Self.plaint)
        }
        await withDetaching(store, history) { model in
            await model.load()
            XCTAssertEqual(model.attachments, [Self.evidence])
        }
    }

    /// The other half of the invariant. Remove a pleading, change your mind, put it back — and it
    /// has to still be there next time. A record that only ever grows would drop it again.
    func testADocumentPutBackStaysBack() async {
        let store = InMemoryPreferenceStore()
        let history = [turn("Q", attaching: [("Plaint.pdf", "Menon")])]

        await withDetaching(store, history) { model in
            await model.load()
            model.detach(Self.plaint)
            model.setAttachments([Self.plaint])
        }
        await withDetaching(store, history) { model in
            await model.load()
            XCTAssertEqual(model.attachments, [Self.plaint])
        }
    }

    /// The picker's Done is both directions at once: what it dropped is removed, what it added is
    /// no longer removed.
    func testThePickersSelectionRecordsBothDirections() async {
        let store = InMemoryPreferenceStore()
        let history = [
            turn("Q", attaching: [("Plaint.pdf", "Menon"), ("Evidence.pdf", "Menon")]),
        ]

        await withDetaching(store, history) { model in
            await model.load()
            model.setAttachments([Self.evidence])
        }
        await withDetaching(store, history) { model in
            await model.load()
            XCTAssertEqual(model.attachments, [Self.evidence])
            model.setAttachments([Self.plaint, Self.evidence])
        }
        await withDetaching(store, history) { model in
            await model.load()
            XCTAssertEqual(Set(model.attachments), [Self.plaint, Self.evidence])
        }
    }

    /// The record is per conversation. Removing a document from one matter must not remove it
    /// from another that happens to hold the same file.
    func testARemovalIsScopedToItsConversation() async {
        let store = InMemoryPreferenceStore()
        let history = [turn("Q", attaching: [("Plaint.pdf", "Menon")])]

        await withDetaching(store, history, chatID: "chat-1") { model in
            await model.load()
            model.detach(Self.plaint)
        }
        await withDetaching(store, history, chatID: "chat-2") { model in
            await model.load()
            XCTAssertEqual(model.attachments, [Self.plaint], "a different matter is untouched")
        }
    }

    /// The record can be emptied again, which is what the un-removing above relies on.
    ///
    /// Named for what it checks rather than for `edit()`, which routes through `setAttachments`
    /// for this reason but is covered here only by way of that shared path.
    func testTheRecordCanBeClearedAgain() async {
        let store = InMemoryPreferenceStore()
        let detached = StoredDetachedDocuments(store: store)
        detached.setDetached([Self.plaint], inChat: "chat-1")

        XCTAssertEqual(detached.detached(inChat: "chat-1"), [Self.plaint])
        detached.setDetached([], inChat: "chat-1")
        XCTAssertTrue(detached.detached(inChat: "chat-1").isEmpty, "and it can be cleared")
    }

    /// Without a store, a removal lasts the session — which is what this screen did before, and
    /// is the behaviour every other test in this file relies on.
    func testWithoutAStoreARemovalIsSessionOnly() async {
        await withModel { fake, model in
            fake.history = [turn("Q", attaching: [("Plaint.pdf", "Menon")])]
            await model.load()
            model.detach(Self.plaint)
            XCTAssertTrue(model.attachments.isEmpty)

            await model.load()
            XCTAssertEqual(model.attachments, [Self.plaint], "back, with nowhere to record it")
        }
    }
}

/// A fresh view model over a shared store, so a second call is a reopen of the same conversation.
@MainActor
private func withDetaching(
    _ store: InMemoryPreferenceStore,
    _ history: [ChatMessage],
    chatID: String = "chat-1",
    _ body: @MainActor (ChatViewModel) async -> Void
) async {
    let fake = FakeChat()
    fake.history = history
    await body(ChatViewModel(
        chatID: chatID,
        service: fake,
        detached: StoredDetachedDocuments(store: store)))
}

/// A user turn carrying documents in the object wire form.
///
/// Built in two steps because `ChatMessage` declares `init(role:content:id:)`, which suppresses
/// the memberwise initialiser — `attachments` is set after, as `send(_:)` does on the real path.
private func turn(_ content: String, attaching files: [(String, String?)]) -> ChatMessage {
    var message = ChatMessage(role: .user, content: content)
    message.attachments = files.map { name, folder in
        var object: [String: JSONValue] = ["name": .string(name)]
        if let folder { object["folderName"] = .string(folder) }
        return JSONValue.object(object)
    }
    return message
}
