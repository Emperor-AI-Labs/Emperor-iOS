import XCTest
@testable import EmperorCore

// MARK: - Stand-ins

/// A conversation that folds nothing and answers what it is told to.
@MainActor
private final class FakeConversation: DraftEditCommitting {
    var result: DraftEditCommitResult = .folded(.saved(rowUpdated: true))
    private(set) var commits: [(html: String, target: DraftEditTarget)] = []

    func commitDraftEdit(_ html: String, target: DraftEditTarget) async -> DraftEditCommitResult {
        commits.append((html, target))
        return result
    }
}

/// A server for `ChatViewModel`: a stored conversation and a turn that answers at once.
private final class EditChat: ChatProviding, @unchecked Sendable {
    private let lock = NSLock()
    var history: [ChatMessage] = []
    private var _sent: [[ChatMessage]] = []
    var sent: [[ChatMessage]] { lock.withLock { _sent } }

    func messages(chatID: String) async throws -> [ChatMessage] { history }
    func streamStatus(chatID: String) async throws -> StreamStatus { StreamStatus(active: false) }
    func send(
        history: [ChatMessage], chatID: String, model: ChatModel, role: ChatRole?,
        attachments: [ChatAttachment]?, webSearch: Bool
    ) async throws -> AsyncThrowingStream<ChatTurnEvent, Error> {
        lock.withLock { _sent.append(history) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.content(StreamContent.parse("Noted.")))
            continuation.finish()
        }
    }
}

/// Where a `ChatViewModel` stores an edit: records each request, can hold it mid-flight, and
/// asks the view model's commit question as the real one does.
private final class FakeDraftEdits: DraftEditSaving, @unchecked Sendable {
    private let lock = NSLock()
    var outcome: DraftEditSaveOutcome = .saved(rowUpdated: true)
    var hold = false
    private var _requests: [DraftEditSaveRequest] = []
    private var _commits: [Bool] = []
    private var _journal: [String] = []
    private let (gate, opener) = AsyncStream<Void>.makeStream()

    var requests: [DraftEditSaveRequest] { lock.withLock { _requests } }
    var commits: [Bool] { lock.withLock { _commits } }
    var journal: [String] { lock.withLock { _journal } }
    func note(_ entry: String) { lock.withLock { _journal.append(entry) } }
    func release() { opener.yield() }

    func save(
        _ edit: DraftEditSaveRequest, commit: @escaping @Sendable () async -> Bool
    ) async -> DraftEditSaveOutcome {
        lock.withLock { _requests.append(edit) }
        note("save-start")
        if hold { for await _ in gate { break } }
        let ok = await commit()
        lock.withLock { _commits.append(ok) }
        note("save-end")
        return ok ? outcome : .kept(.conversationChanged)
    }
}

private let draftBody = "<h1>PLAINT</h1><p><strong>SYNOPSIS</strong></p><p>The Defendant has not paid.</p><h2>PRAYER</h2><p>Decree the suit.</p>"
private let draftMessage = "Here is the plaint.\n[CANVAS_TRIGGER: Commercial Plaint]\n<canvas_content>\n\(draftBody)\n</canvas_content>\n\n## References\n[1] Commercial Courts Act, 2015."

private func artifact(_ body: String = draftBody, format: StreamArtifact.Format = .html) -> StreamArtifact {
    StreamArtifact(kind: format == .html ? .canvas : .table, format: format, title: "Commercial Plaint", body: body)
}

@MainActor
private func editor(
    target: DraftEditTarget? = DraftEditTarget(index: 1, messageCount: 2),
    _ body: @MainActor (DraftEditViewModel, FakeConversation) async -> Void
) async {
    let conversation = FakeConversation()
    let model = DraftEditViewModel(artifact: artifact(), target: target, conversation: conversation)
    await body(model, conversation)
}

/// Opens the editor as the view does: begin, then the page reports what it opened over.
@MainActor
private func open(_ model: DraftEditViewModel) {
    model.begin()
    model.editorOpened(baseline: model.page)
}

// MARK: - The editor's state

final class DraftEditViewModelTests: XCTestCase {

    func testItOpensReadingWithAnOutline() async {
        await editor { model, _ in
            XCTAssertEqual(model.phase, .reading)
            XCTAssertTrue(model.isEditable)
            XCTAssertTrue(model.canBeginEditing)
            XCTAssertTrue(model.showsPage)
            XCTAssertEqual(model.outline.map(\.text), ["PLAINT", "SYNOPSIS", "PRAYER"])
            XCTAssertTrue(model.showsOutline)
            XCTAssertTrue(model.page.contains(#"<h2 id="doc-h-2">PRAYER</h2>"#), "every heading can be jumped to")
            XCTAssertNil(model.statusText)
        }
    }

    func testWithoutATargetItIsReadOnly() async {
        await editor(target: nil) { model, _ in
            XCTAssertFalse(model.isEditable)
            model.begin()
            XCTAssertEqual(model.phase, .reading)
        }
    }

    func testDoneWithAnEditFoldsAndSaves() async {
        await editor { model, conversation in
            open(model)
            XCTAssertEqual(model.phase, .editing)
            let edited = model.page.replacingOccurrences(of: "has not paid", with: "has not paid a rupee")
            XCTAssertTrue(model.hasChanges(edited))
            XCTAssertTrue(model.closeNeedsConfirmation(current: edited))
            await model.finish(editedHTML: edited)

            XCTAssertEqual(conversation.commits.count, 1)
            XCTAssertEqual(conversation.commits.first?.target, DraftEditTarget(index: 1, messageCount: 2))
            XCTAssertTrue(conversation.commits.first?.html.contains("a rupee") ?? false)
            XCTAssertEqual(model.phase, .saved)
            XCTAssertTrue(model.isEdited)
            XCTAssertTrue(model.body.contains("a rupee"), "the viewer now shows the edit")
            XCTAssertEqual(model.statusText, "Edited · saved")
            XCTAssertFalse(model.canRetry)
            XCTAssertTrue(model.canBeginEditing, "and it can be edited again")
        }
    }

    /// What is folded is scrubbed: no edit-mode attribute, no `<font>`, no script.
    func testTheEditIsScrubbedBeforeItIsFolded() async {
        await editor { model, conversation in
            open(model)
            await model.finish(editedHTML: model.page + #"<p align="center"><font>New</font></p><script>x()</script>"#)
            let html = conversation.commits.first?.html ?? ""
            XCTAssertTrue(html.hasSuffix(#"<p style="text-align: center;">New</p>"#), html)
        }
    }

    func testDoneWithNoChangeSavesNothing() async {
        await editor { model, conversation in
            open(model)
            XCTAssertFalse(model.closeNeedsConfirmation(current: model.page + "\n  "))
            await model.finish(editedHTML: model.page + "  ")
            XCTAssertTrue(conversation.commits.isEmpty)
            XCTAssertEqual(model.phase, .reading)
        }
    }

    func testAFailedSaveKeepsTheEditForRetry() async {
        await editor { model, conversation in
            conversation.result = .folded(.failed)
            open(model)
            await model.finish(editedHTML: model.page + "<p>Added.</p>")
            XCTAssertEqual(model.phase, .failed)
            XCTAssertTrue(model.statusIsProblem)
            XCTAssertTrue(model.canRetry)
            XCTAssertTrue(model.body.contains("Added."), "folded, so the page shows it")

            conversation.result = .folded(.saved(rowUpdated: false))
            await model.retry()
            XCTAssertEqual(conversation.commits.count, 2)
            XCTAssertEqual(conversation.commits[0].html, conversation.commits[1].html, "the same edit again")
            XCTAssertEqual(model.phase, .saved)
            XCTAssertFalse(model.canRetry)
        }
    }

    func testAnEditKeptInTheConversationSaysSo() async {
        await editor { model, conversation in
            conversation.result = .folded(.kept(.serverHasMore))
            open(model)
            await model.finish(editedHTML: model.page + "<p>Added.</p>")
            XCTAssertEqual(model.phase, .kept)
            XCTAssertFalse(model.statusIsProblem, "the edit is not lost")
            XCTAssertEqual(model.statusText, "Kept in this conversation. It is stored with your next question.")
            XCTAssertTrue(model.canRetry)
        }
    }

    func testAnEditThatCannotBePlacedSaysWhy() async {
        await editor { model, conversation in
            conversation.result = .notPlaced
            open(model)
            await model.finish(editedHTML: model.page + "<p>Added.</p>")
            XCTAssertEqual(model.phase, .notPlaced)
            XCTAssertFalse(model.isEdited)
            XCTAssertFalse(model.body.contains("Added."))
            XCTAssertFalse(model.canBeginEditing)
            XCTAssertTrue(model.statusText?.contains("newer answer") ?? false)
        }
    }

    func testDiscardingReloadsTheDraftAsItStood() async {
        await editor { model, conversation in
            open(model)
            let revision = model.pageRevision
            model.discard()
            XCTAssertEqual(model.phase, .reading)
            XCTAssertEqual(model.pageRevision, revision + 1)
            XCTAssertTrue(conversation.commits.isEmpty)
        }
    }

    func testAPageThatCannotBeEditedReturnsToReading() async {
        await editor { model, _ in
            model.begin()
            model.editorOpened(baseline: nil)
            XCTAssertEqual(model.phase, .reading)
            XCTAssertNotNil(model.notice)
        }
    }

    func testAnUnreadablePageStaysInEditMode() async {
        await editor { model, conversation in
            open(model)
            await model.finish(editedHTML: nil)
            XCTAssertEqual(model.phase, .editing)
            XCTAssertNotNil(model.notice)
            XCTAssertTrue(conversation.commits.isEmpty)
        }
    }

    /// A Markdown table is drawn natively until it is edited, then as the HTML table it became.
    func testAMarkdownTableIsEditedAsHTML() async {
        await markdownTable()
    }
}

@MainActor
private func markdownTable() async {
        let conversation = FakeConversation()
        let model = DraftEditViewModel(
            artifact: artifact("| Date | Event |\n| --- | --- |\n| 04.03.2024 | Agreement |", format: .markdown),
            target: DraftEditTarget(index: 1, messageCount: 2), conversation: conversation)
        XCTAssertFalse(model.showsPage)
        XCTAssertFalse(model.showsOutline)
        model.begin()
        XCTAssertTrue(model.showsPage)
        XCTAssertTrue(model.page.contains("<table"))
        model.editorOpened(baseline: model.page)
        await model.finish(editedHTML: model.page.replacingOccurrences(of: "Agreement", with: "Agreement signed"))
        XCTAssertEqual(model.format, .html)
        XCTAssertTrue(model.showsPage)
        XCTAssertTrue(conversation.commits.first?.html.contains("<table") ?? false)
}

// MARK: - Folding into the conversation

@MainActor
private func conversation(
    _ body: @MainActor (EditChat, FakeDraftEdits, ChatViewModel) async -> Void
) async {
    let chat = EditChat()
    chat.history = [
        ChatMessage(role: .user, content: "Draft a plaint.", id: "q1"),
        ChatMessage(role: .assistant, content: draftMessage),
    ]
    let edits = FakeDraftEdits()
    let model = ChatViewModel(chatID: "chat-1", service: chat, draftEdits: edits)
    await model.load()
    await body(chat, edits, model)
}

@MainActor
private func settle(_ model: ChatViewModel) async {
    for _ in 0..<400 {
        if !model.isStreaming { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("stream did not settle")
}

@MainActor
private func withoutStore(_ body: @MainActor (ChatViewModel) async -> Void) async {
    let chat = EditChat()
    chat.history = [
        ChatMessage(role: .user, content: "Draft a plaint.", id: "q1"),
        ChatMessage(role: .assistant, content: draftMessage),
    ]
    let model = ChatViewModel(chatID: "chat-1", service: chat)
    await model.load()
    await body(model)
}

private let editedBody = draftBody.replacingOccurrences(of: "has not paid", with: "has not paid a rupee")

final class ChatDraftEditTests: XCTestCase {

    func testOnlyTheLastAnswerWithOneDraftCanBeEdited() async {
        await conversation { _, _, model in
            XCTAssertNil(model.draftEditTarget(for: model.messages[0]), "a question is not a draft")
            XCTAssertEqual(model.draftEditTarget(for: model.messages[1]), DraftEditTarget(index: 1, messageCount: 2))
        }
    }

    func testAnEditIsFoldedIntoItsTurnAndStoredFromTheBytesTheServerHolds() async {
        await conversation { _, edits, model in
            let target = model.draftEditTarget(for: model.messages[1])!
            let result = await model.commitDraftEdit(editedBody, target: target)
            XCTAssertEqual(result, .folded(.saved(rowUpdated: true)))
            XCTAssertTrue(model.messages[1].content.contains("a rupee"))
            XCTAssertTrue(model.messages[1].content.hasPrefix("Here is the plaint.\n[CANVAS_TRIGGER: Commercial Plaint]\n<canvas_content>\n"))
            XCTAssertTrue(model.messages[1].content.hasSuffix("</canvas_content>\n\n## References\n[1] Commercial Courts Act, 2015."))

            let request = edits.requests.first
            XCTAssertEqual(request?.chatID, "chat-1")
            XCTAssertEqual(request?.index, 1)
            XCTAssertEqual(request?.storedTranscript[1].content, draftMessage, "what the server holds")
            XCTAssertEqual(request?.editedContent, model.messages[1].content)
            XCTAssertEqual(edits.commits, [true])
            XCTAssertEqual(model.draftEditSave, .saved(rowUpdated: true))
        }
    }

    /// The fold is what the next question carries, saved or not.
    func testTheNextQuestionCarriesTheEdit() async {
        await conversation { chat, edits, model in
            edits.outcome = .failed
            let target = model.draftEditTarget(for: model.messages[1])!
            _ = await model.commitDraftEdit(editedBody, target: target)
            model.send("Shorten the synopsis.")
            await settle(model)
            XCTAssertTrue(chat.sent.last?[1].content.contains("a rupee") ?? false)
        }
    }

    /// A second edit is measured against what the server still holds, not against the first edit.
    func testAFailedWriteIsRetriedAgainstWhatTheServerHolds() async {
        await conversation { _, edits, model in
            edits.outcome = .failed
            let target = model.draftEditTarget(for: model.messages[1])!
            _ = await model.commitDraftEdit(editedBody, target: target)
            edits.outcome = .saved(rowUpdated: false)
            let retry = await model.commitDraftEdit(editedBody, target: target)
            XCTAssertEqual(retry, .folded(.saved(rowUpdated: false)), "the same edit, already folded, still stores")
            XCTAssertEqual(edits.requests.count, 2)
            XCTAssertEqual(edits.requests[1].storedTranscript[1].content, draftMessage)

            // Stored now: the next edit is measured from the edited text.
            let second = editedBody.replacingOccurrences(of: "Decree", with: "Kindly decree")
            _ = await model.commitDraftEdit(second, target: target)
            XCTAssertTrue(edits.requests[2].storedTranscript[1].content.contains("a rupee"))
        }
    }

    func testAQuestionAskedSinceStopsTheEdit() async {
        await conversation { _, edits, model in
            let target = model.draftEditTarget(for: model.messages[1])!
            model.send("Shorten the synopsis.")
            await settle(model)
            let result = await model.commitDraftEdit(editedBody, target: target)
            XCTAssertEqual(result, .notPlaced)
            XCTAssertFalse(model.messages[1].content.contains("a rupee"))
            XCTAssertTrue(edits.requests.isEmpty)
        }
    }

    /// The next question waits for an edit's write already on its way, so the two can never
    /// reach the server out of order.
    func testTheNextQuestionWaitsForTheWrite() async {
        await conversation { chat, edits, model in
            edits.hold = true
            let target = model.draftEditTarget(for: model.messages[1])!
            let saving = Task { await model.commitDraftEdit(editedBody, target: target) }
            for _ in 0..<200 where edits.requests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
            model.send("Shorten the synopsis.")
            try? await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(chat.sent.isEmpty, "the question has not gone yet")
            edits.release()
            _ = await saving.value
            await settle(model)
            XCTAssertEqual(chat.sent.count, 1)
            XCTAssertEqual(edits.commits, [false], "the question was asked before the write committed")
        }
    }

    func testWithNowhereToStoreItTheEditIsKept() async {
        await withoutStore { model in
            let target = model.draftEditTarget(for: model.messages[1])!
            let result = await model.commitDraftEdit(editedBody, target: target)
            XCTAssertEqual(result, .folded(.kept(.unavailable)))
            XCTAssertTrue(model.messages[1].content.contains("a rupee"))
        }
    }
}
