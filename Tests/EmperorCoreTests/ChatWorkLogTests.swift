import XCTest
@testable import EmperorCore

/// A server whose turn and whose work-log save can each be held mid-flight, so the ordering
/// between a save and the next question can be observed rather than assumed.
private final class LogFake: ChatProviding, @unchecked Sendable {
    private let lock = NSLock()

    var history: [ChatMessage] = []
    var messagesError: Error?
    var status = StreamStatus(active: false)
    var statusError: Error?
    var events: [ChatTurnEvent] = []
    /// Thrown after `events`, as a connection lost mid-answer would be.
    var sendError: Error?
    /// When set, a turn's stream stays open after its events until `releaseStream()`.
    var holdStream = false
    var saveOutcome: WorkLogSaveOutcome = .saved
    /// Where a save waits for `releaseSave()`: before asking to commit (cancellable, as the real
    /// one's requests are) or after committing (not, as the real one's rewrite is not).
    enum Hold { case none, beforeCommit, afterCommit }
    var holdSave = Hold.none

    private var _journal: [String] = []
    private var _saves: [(fields: [String: JSONValue], transcript: [ChatMessage])] = []
    private var _sent: [[ChatMessage]] = []
    private var saveRelease: CheckedContinuation<Void, Never>?
    private let (saveGate, saveOpener) = AsyncStream<Void>.makeStream()
    private let (streamGate, streamOpener) = AsyncStream<Void>.makeStream()

    var journal: [String] { lock.withLock { _journal } }
    var saves: [(fields: [String: JSONValue], transcript: [ChatMessage])] { lock.withLock { _saves } }
    var sent: [[ChatMessage]] { lock.withLock { _sent } }
    private func note(_ entry: String) { lock.withLock { _journal.append(entry) } }

    func releaseSave() {
        saveOpener.yield()
        lock.withLock {
            saveRelease?.resume()
            saveRelease = nil
        }
    }

    func releaseStream() { streamOpener.yield() }

    func messages(chatID: String) async throws -> [ChatMessage] {
        if let messagesError { throw messagesError }
        return history
    }

    func streamStatus(chatID: String) async throws -> StreamStatus {
        note("status")
        if let statusError { throw statusError }
        return status
    }

    func send(
        history: [ChatMessage], chatID: String, model: ChatModel, role: ChatRole?,
        attachments: [ChatAttachment]?, webSearch: Bool
    ) async throws -> AsyncThrowingStream<ChatTurnEvent, Error> {
        let count = lock.withLock { () -> Int in
            _sent.append(history)
            return _sent.count
        }
        note("send-\(count)")
        let queued = events
        let failure = sendError
        let hold = holdStream
        let gate = streamGate
        return AsyncThrowingStream { continuation in
            Task {
                for event in queued { continuation.yield(event) }
                if hold { for await _ in gate { break } }
                if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    func saveWorkLog(
        _ fields: [String: JSONValue], transcript: [ChatMessage], chatID: String,
        commit: @escaping @Sendable () async -> Bool
    ) async -> WorkLogSaveOutcome {
        lock.withLock { _saves.append((fields, transcript)) }
        note("save-start")
        if holdSave == .beforeCommit {
            for await _ in saveGate { break }
        }
        guard await commit() else {
            note("save-abandoned")
            return .skipped(.newTurnStarted)
        }
        note("save-commit")
        if holdSave == .afterCommit {
            await withCheckedContinuation { continuation in
                lock.withLock { saveRelease = continuation }
            }
        }
        note("save-end")
        return saveOutcome
    }
}

@MainActor
private func withModel(_ body: @MainActor (LogFake, ChatViewModel) async -> Void) async {
    let fake = LogFake()
    await body(fake, ChatViewModel(chatID: "chat-1", service: fake))
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
private func waitUntil(_ condition: () -> Bool, _ what: String) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("timed out waiting for \(what)")
}

/// A turn that did real work: a plan, one round of two calls, a sentence of reasoning.
private func workingTurn() -> [ChatTurnEvent] {
    let snapshot = ReasoningSnapshot(
        plan: [PlanRow(title: "Read the record", status: .inProgress, subtasks: [
            PlanRow(title: "Open the deed", status: .inProgress, subtasks: []),
        ])],
        workLog: [
            .note(text: "Let me read the deed.", at: 10),
            .group(WorkGroup(status: .inProgress, steps: [
                WorkStep(label: "Reading pages 1–4 of Sale Deed", status: .inProgress, at: 30),
                WorkStep(label: "Searching the record for: possession", status: .inProgress, at: 30),
            ])),
        ],
        reasoning: ["The deed is the root of title."])
    return [.progress(snapshot), .content(StreamContent.parse("Possession passed in 2019."))]
}

/// The work log on the conversation: carried by each answer, stored the web's way, and saved
/// only when the conversation on the server is exactly the one on screen.
final class ChatWorkLogTests: XCTestCase {

    // MARK: - The answer carries its panel

    func testAFinishedTurnCarriesItsSettledPanel() async {
        await withModel { fake, model in
            fake.events = workingTurn()
            model.send("Who has possession?")
            await settle(model)

            let log = model.messages.last?.storedWorkLog
            XCTAssertEqual(log?.stepCount, 2)
            XCTAssertEqual(log.map { PanelShape($0).log }, [
                "note: Let me read the deed.",
                "round [completed]",
                "  Reading pages 1–4 of Sale Deed [completed]",
                "  Searching the record for: possession [completed]",
            ], "a clean finish means every call in flight came back")
            XCTAssertEqual(log?.plan.first?.subtasks.first?.status, .completed)
            XCTAssertEqual(log?.reasoning, ["The deed is the root of title."])
            XCTAssertEqual(model.messages.last?.extra["reasoning"]?["seconds"], .number(0))
        }
    }

    /// A turn that failed mid-answer keeps what it showed, and says honestly that the calls in
    /// flight never confirmed — but nothing is saved.
    func testAFailedTurnKeepsAnUnfinishedPanelAndIsNotSaved() async {
        await withModel { fake, model in
            fake.events = workingTurn()
            fake.sendError = APIError.transport("The network connection was lost.")
            model.send("Who has possession?")
            await settle(model)
            await model.settleWorkLogSave()

            let log = model.messages.last?.storedWorkLog
            guard case .group(let round)? = log?.workLog.last else { return XCTFail("no round") }
            XCTAssertEqual(round.status, .stopped)
            XCTAssertEqual(round.steps.map(\.status), [.stopped, .stopped])
            XCTAssertEqual(log?.plan.first?.status, .stopped, "no spinner under a finished answer")
            XCTAssertTrue(fake.saves.isEmpty)
            XCTAssertNil(model.workLogSave)
        }
    }

    /// `/chat` stores the history it is sent, so the log must be in it — or the next question
    /// deletes it.
    func testTheNextQuestionCarriesTheLog() async {
        await withModel { fake, model in
            fake.events = workingTurn()
            model.send("Who has possession?")
            await settle(model)
            await model.settleWorkLogSave()

            fake.events = [.content(StreamContent.parse("No."))]
            model.send("Was it ever disputed?")
            await settle(model)

            let earlier = fake.sent.last?[1]
            XCTAssertEqual(earlier?.role, .assistant)
            for key in WorkLogWire.keys {
                XCTAssertNotNil(earlier?.extra[key], "\(key) must travel with the history")
            }
        }
    }

    // MARK: - Reopening

    /// A conversation reopened from History draws the log stored with each answer — the web's
    /// own, here, exactly as this client would have drawn it live.
    func testReopeningDrawsEachAnswersStoredLog() async {
        await withModel { fake, model in
            let body = Data(WorkLogFixture.shared.messagesBody.utf8)
            fake.history = try! JSONDecoder().decode(MessagesResponse.self, from: body).messages
            await model.load()

            XCTAssertEqual(model.messages.count, 6)
            XCTAssertNil(model.messages[0].storedWorkLog, "a question carries no panel")
            XCTAssertNil(model.messages[1].storedWorkLog, "an answer stored without one shows none")
            let web = model.messages[3].storedWorkLog
            let live = WorkLogFixture.replay(WorkLogFixture.named("research"))
            XCTAssertEqual(web.map(PanelShape.init), PanelShape(live))
            XCTAssertNil(model.messages[5].storedWorkLog, "the server's answer has not been given one yet")
            XCTAssertTrue(model.progress.isEmpty, "a stored panel is not a live one")
        }
    }

    // MARK: - When a save is attempted

    func testACleanTurnSavesItsLog() async {
        await withModel { fake, model in
            fake.events = workingTurn()
            model.send("Who has possession?")
            await settle(model)
            await model.settleWorkLogSave()

            XCTAssertEqual(model.workLogSave, .saved)
            XCTAssertEqual(fake.saves.count, 1)
            let save = fake.saves.first
            XCTAssertEqual(save?.transcript, model.messages)
            XCTAssertEqual(Set(save.map { Array($0.fields.keys) } ?? []), Set(WorkLogWire.keys))
            XCTAssertEqual(save?.fields["workLog"], model.messages.last?.extra["workLog"])
        }
    }

    func testNothingToStoreIsNotSaved() async {
        await withModel { fake, model in
            fake.events = [.content(StreamContent.parse("Yes."))]
            model.send("Is it barred?")
            await settle(model)
            await model.settleWorkLogSave()

            XCTAssertEqual(model.workLogSave, .skipped(.nothingToSave))
            XCTAssertTrue(fake.saves.isEmpty)
            XCTAssertFalse(model.messages.last?.hasWorkLog ?? true,
                           "an empty panel is not stored either")
        }
    }

    /// No answer — refused as busy — nothing to attach a log to.
    func testABusyRefusalIsNotSaved() async {
        await withModel { fake, model in
            fake.events = [.busy("Still drafting your earlier request.")] + workingTurn().prefix(1)
            model.send("Who has possession?")
            await settle(model)
            await model.settleWorkLogSave()

            XCTAssertEqual(model.workLogSave, .skipped(.noAnswer))
            XCTAssertTrue(fake.saves.isEmpty)
        }
    }

    func testAnUnreadableStatusIsNotSaved() async {
        await withModel { fake, model in
            fake.events = workingTurn()
            fake.statusError = APIError.transport("offline")
            model.send("Who has possession?")
            await settle(model)
            await model.settleWorkLogSave()

            XCTAssertEqual(model.workLogSave, .skipped(.statusUnknown))
            XCTAssertTrue(fake.saves.isEmpty)
        }
    }

    /// `/stream-status` answers 200 for its errors; an error in the body is not "nothing running".
    func testAStatusErrorIsNotSaved() async {
        await withModel { fake, model in
            fake.events = workingTurn()
            fake.status = StreamStatus(active: false, error: "Forbidden")
            model.send("Who has possession?")
            await settle(model)
            await model.settleWorkLogSave()

            XCTAssertEqual(model.workLogSave, .skipped(.statusUnknown))
            XCTAssertTrue(fake.saves.isEmpty)
        }
    }

    /// Something is still generating on this chat — a rewrite would delete its checkpoint.
    func testARunStillActiveIsNotSaved() async {
        await withModel { fake, model in
            fake.events = workingTurn()
            fake.status = StreamStatus(active: true)
            model.send("Who has possession?")
            await settle(model)
            await model.settleWorkLogSave()

            XCTAssertEqual(model.workLogSave, .skipped(.runStillActive))
            XCTAssertTrue(fake.saves.isEmpty)
        }
    }

    /// The conversation stopped being known-whole while the answer was arriving.
    func testAHistoryNoLongerIntactIsNotSaved() async {
        await withModel { fake, model in
            fake.events = workingTurn()
            fake.holdStream = true
            model.send("Who has possession?")
            await waitUntil({ model.live?.prose.isEmpty == false }, "the answer")

            fake.messagesError = APIError.transport("offline")
            await model.load()
            XCTAssertFalse(model.historyIsIntact)

            fake.releaseStream()
            await settle(model)
            await model.settleWorkLogSave()

            XCTAssertEqual(model.workLogSave, .skipped(.historyNotIntact))
            XCTAssertTrue(fake.saves.isEmpty)
        }
    }

    /// A stop is not a completion, whatever order the two endings run in: the turn is not
    /// confirmed with the server, its calls in flight are not ticked, and nothing is saved.
    func testAStopIsNotSaved() async {
        await withModel { fake, model in
            fake.events = workingTurn()
            fake.holdStream = true
            model.send("Who has possession?")
            await waitUntil({ model.live?.prose.isEmpty == false }, "the answer")
            model.stop()
            await settle(model)
            try? await Task.sleep(for: .milliseconds(50))
            await model.settleWorkLogSave()

            XCTAssertFalse(fake.journal.contains("status"),
                           "a stopped turn was confirmed as though it had finished")
            XCTAssertTrue(fake.saves.isEmpty)
            guard case .group(let round)? = model.messages.last?.storedWorkLog?.workLog.last else {
                return XCTFail("the stopped answer lost its panel")
            }
            XCTAssertEqual(round.status, .stopped)
            fake.releaseStream()
        }
    }

    // MARK: - A save never crosses the next turn

    /// A save not yet committed is abandoned by a new question: it asks once more before
    /// sending, and finds the conversation streaming.
    func testANewQuestionAbandonsASaveNotYetSent() async {
        await withModel { fake, model in
            fake.events = workingTurn()
            fake.holdSave = .beforeCommit
            model.send("Who has possession?")
            await settle(model)
            await waitUntil({ fake.journal.contains("save-start") }, "the save to start")

            fake.events = [.content(StreamContent.parse("No."))]
            model.send("Was it ever disputed?")
            await settle(model)

            XCTAssertEqual(fake.journal.filter { $0 != "status" },
                           ["send-1", "save-start", "save-abandoned", "send-2"])
            // The second turn did no work, so it has nothing of its own to save.
            XCTAssertEqual(model.workLogSave, .skipped(.nothingToSave))
        }
    }

    /// A save already on its way is waited for: the next question's request — above all an edit,
    /// which stores a shorter history — must reach the server after the rewrite, never before.
    func testANewQuestionWaitsForASaveAlreadySent() async {
        await withModel { fake, model in
            fake.events = workingTurn()
            fake.holdSave = .afterCommit
            model.send("Who has possession?")
            await settle(model)
            await waitUntil({ fake.journal.contains("save-commit") }, "the save to commit")

            fake.events = [.content(StreamContent.parse("Re-answered."))]
            guard let question = model.messages.first else { return XCTFail("no question") }
            model.edit(question, to: "Who holds title?")
            try? await Task.sleep(for: .milliseconds(60))
            XCTAssertFalse(fake.journal.contains("send-2"),
                           "the edit went out while the rewrite was still on its way")

            fake.releaseSave()
            await settle(model)
            XCTAssertEqual(fake.journal.filter { $0 != "status" },
                           ["send-1", "save-start", "save-commit", "save-end", "send-2"])
        }
    }

    /// The conversation was reloaded underneath the save — not the transcript it was built from.
    func testAReloadDuringTheSaveAbandonsIt() async {
        await withModel { fake, model in
            fake.events = workingTurn()
            fake.holdSave = .beforeCommit
            model.send("Who has possession?")
            await settle(model)
            await waitUntil({ fake.journal.contains("save-start") }, "the save to start")

            fake.history = [ChatMessage(role: .user, content: "Asked elsewhere", id: "w1")]
            await model.load()
            fake.releaseSave()
            await model.settleWorkLogSave()

            XCTAssertEqual(model.workLogSave, .skipped(.newTurnStarted))
        }
    }

    /// The conversation stopped being known-whole while the save was being prepared.
    func testAFailedReloadDuringTheSaveAbandonsIt() async {
        await withModel { fake, model in
            fake.events = workingTurn()
            fake.holdSave = .beforeCommit
            model.send("Who has possession?")
            await settle(model)
            await waitUntil({ fake.journal.contains("save-start") }, "the save to start")

            fake.messagesError = APIError.transport("offline")
            await model.load()
            fake.releaseSave()
            await model.settleWorkLogSave()

            XCTAssertEqual(model.workLogSave, .skipped(.newTurnStarted))
        }
    }

    /// A failed save is an outcome, not an error: nothing on screen changes.
    func testAFailedSaveIsSilent() async {
        await withModel { fake, model in
            fake.events = workingTurn()
            fake.saveOutcome = .failed
            model.send("Who has possession?")
            await settle(model)
            await model.settleWorkLogSave()

            XCTAssertEqual(model.workLogSave, .failed)
            XCTAssertNil(model.errorMessage)
            XCTAssertNotNil(model.messages.last?.storedWorkLog, "the panel stays on the answer")
        }
    }
}
