import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

/// What the system says about the connection, changed by the test.
final class ManualConnectivity: ConnectivityReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var _isOffline: Bool

    init(isOffline: Bool) { _isOffline = isOffline }

    var isOffline: Bool {
        get { lock.withLock { _isOffline } }
        set { lock.withLock { _isOffline = newValue } }
    }
}

/// The error a request made with no signal ends in.
private var noConnection: Error {
    APIError.transport("The Internet connection appears to be offline.")
}

/// A chat server whose answers the test sets, which records every write — and which can hold a
/// load open until released, to look at the screen while the request is still out.
private final class OfflineChatServer: ChatProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _history: [ChatMessage] = []
    private var _messagesError: Error?
    private var _sentHistories: [[ChatMessage]] = []
    private var _saveCalls = 0
    private var _sendError: Error?
    private var _events: [ChatTurnEvent] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var _holdsLoads = false
    private var _loadsWaiting = 0

    var history: [ChatMessage] {
        get { lock.withLock { _history } }
        set { lock.withLock { _history = newValue } }
    }
    var messagesError: Error? {
        get { lock.withLock { _messagesError } }
        set { lock.withLock { _messagesError = newValue } }
    }
    var sendError: Error? {
        get { lock.withLock { _sendError } }
        set { lock.withLock { _sendError = newValue } }
    }
    var events: [ChatTurnEvent] {
        get { lock.withLock { _events } }
        set { lock.withLock { _events = newValue } }
    }
    var holdsLoads: Bool {
        get { lock.withLock { _holdsLoads } }
        set { lock.withLock { _holdsLoads = newValue } }
    }
    var loadsWaiting: Int { lock.withLock { _loadsWaiting } }
    var sentHistories: [[ChatMessage]] { lock.withLock { _sentHistories } }
    var saveCalls: Int { lock.withLock { _saveCalls } }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    func messages(chatID: String) async throws -> [ChatMessage] {
        if holdsLoads {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    gate = continuation
                    _loadsWaiting += 1
                }
            }
        }
        if let messagesError { throw messagesError }
        return history
    }

    func streamStatus(chatID: String) async throws -> StreamStatus { StreamStatus(active: false) }

    func send(
        history: [ChatMessage], chatID: String, model: ChatModel, role: ChatRole?,
        attachments: [ChatAttachment]?, webSearch: Bool
    ) async throws -> AsyncThrowingStream<ChatTurnEvent, Error> {
        lock.withLock { _sentHistories.append(history) }
        if let sendError { throw sendError }
        let queued = events
        return AsyncThrowingStream { continuation in
            for event in queued { continuation.yield(event) }
            continuation.finish()
        }
    }

    func saveWorkLog(
        _ fields: [String: JSONValue], transcript: [ChatMessage], chatID: String,
        commit: @escaping @Sendable () async -> Bool
    ) async -> WorkLogSaveOutcome {
        lock.withLock { _saveCalls += 1 }
        return .skipped(.nothingToSave)
    }
}

private func turn(_ role: MessageRole, _ text: String, id: String) -> ChatMessage {
    ChatMessage(role: role, content: text, id: id)
}

private let stored = [
    turn(.user, "Is the suit barred?", id: "q1"),
    turn(.assistant, "Yes, under Article 58.", id: "a1"),
]

@MainActor
private func settle(_ model: ChatViewModel) async {
    for _ in 0..<400 {
        if !model.isStreaming { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("stream did not settle")
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("condition never held")
}

// MARK: - Conversations

@MainActor
final class ChatOfflineTests: XCTestCase {

    // Built per test — XCTest makes a new instance for each — rather than in a `setUp`, which is
    // not isolated to the main actor this class is.
    private let clock = TestClock()
    private let server = OfflineChatServer()
    private lazy var store = OfflineStore(
        namespace: "a1.conversations", budget: 1_000_000, store: InMemoryCacheStore(),
        now: clock.reader)

    private func makeModel(connectivity: ManualConnectivity? = nil, files: FakeFiles? = nil)
        -> ChatViewModel {
        ChatViewModel(
            chatID: "chat-1", service: server, files: files, offline: store,
            connectivity: connectivity)
    }

    /// Opened once with a connection, which keeps it.
    private func openOnceOnline() async {
        server.history = stored
        await makeModel().load()
        server.messagesError = noConnection
        clock.advance(2 * 3_600)
    }

    // MARK: Keeping

    func testAConversationOpenedOnlineIsKept() async {
        server.history = stored
        await makeModel().load()

        XCTAssertEqual(store.value([ChatMessage].self, for: "chat-1")?.value, stored)
    }

    /// "As the app received them": every key of every message, including the ones this build does
    /// not model, so the copy reads exactly as the conversation did.
    func testTheCopyKeepsEveryKeyTheServerSent() async throws {
        let raw = #"[{"id":"a9","role":"assistant","content":"Done.","workLog":[{"kind":"note","text":"Read it."}],"futureField":7}]"#
        server.history = try JSONDecoder().decode([ChatMessage].self, from: Data(raw.utf8))
        await makeModel().load()

        let kept = try XCTUnwrap(store.value([ChatMessage].self, for: "chat-1")?.value.first)
        XCTAssertEqual(kept.extra["futureField"], .number(7))
        XCTAssertNotNil(kept.storedWorkLog)
    }

    func testAnEmptyConversationIsNotKept() async {
        server.history = []
        await makeModel().load()
        XCTAssertFalse(store.contains("chat-1"))
    }

    // MARK: Opening offline

    func testOpenedOfflineItShowsTheSavedCopyWithANotice() async {
        await openOnceOnline()
        let model = makeModel()

        await model.load()

        XCTAssertEqual(model.messages, stored)
        XCTAssertTrue(model.isShowingSavedCopy)
        XCTAssertEqual(
            model.offlineNotice(now: clock.now), "Offline — showing the copy saved 2 hours ago.")
        XCTAssertNil(model.errorMessage, "the notice explains it; a red error would not be calm")
    }

    /// Asking is disabled, with the reason, rather than allowed to fail.
    func testAskingIsPausedWithTheReason() async {
        await openOnceOnline()
        let model = makeModel()
        await model.load()

        XCTAssertEqual(model.sendBlockedReason, OfflineReading.askingPaused)
        model.send("And the limitation for a counter-claim?")
        await settle(model)

        XCTAssertTrue(server.sentHistories.isEmpty, "nothing was sent")
        XCTAssertEqual(model.messages, stored, "and nothing was added")
    }

    /// The read-only guarantee, at every way of writing: no send, no edit, no work-log save.
    func testASavedCopyIsNeverWrittenBack() async {
        await openOnceOnline()
        let model = makeModel()
        await model.load()

        XCTAssertFalse(model.historyIsIntact)
        XCTAssertFalse(model.canEdit(stored[0]))
        XCTAssertEqual(model.discardCount(editing: stored[0]), 0)
        model.edit(stored[0], to: "Is the suit within time?")
        model.send("Anything")
        await settle(model)

        XCTAssertTrue(server.sentHistories.isEmpty)
        XCTAssertEqual(server.saveCalls, 0)
    }

    /// The copy stands in only for a network that could not be reached. A server that answered
    /// has said something about the conversation.
    func testAServerErrorIsNotCoveredByTheSavedCopy() async {
        await openOnceOnline()
        server.messagesError = APIError.server(status: 500, message: "Internal error")
        let model = makeModel()

        await model.load()

        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertFalse(model.isShowingSavedCopy)
        XCTAssertEqual(model.errorMessage, "Internal error")
    }

    /// "Chat not found" means the server holds nothing — so whatever this device kept goes, and
    /// above all is not what the first question carries.
    func testAChatTheServerDoesNotHoldDropsTheCopyBeforeAnythingIsSent() async {
        await openOnceOnline()
        let connectivity = ManualConnectivity(isOffline: true)
        server.messagesError = APIError.server(status: 500, message: "Chat not found")
        let model = makeModel(connectivity: connectivity)

        await model.load()

        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertFalse(model.isShowingSavedCopy)
        XCTAssertFalse(store.contains("chat-1"), "a copy of nothing the server holds")
        XCTAssertTrue(model.historyIsIntact)

        server.events = [.content(StreamContent.parse("New answer."))]
        model.send("A new question")
        await settle(model)
        XCTAssertEqual(server.sentHistories.first?.map(\.content), ["A new question"],
                       "the saved transcript did not travel with it")
    }

    /// Opening with no connection shows the copy at once, while the request is still out — not
    /// minutes later when it gives up.
    func testWithNoConnectionTheCopyShowsWhileTheRequestWaits() async {
        await openOnceOnline()
        server.messagesError = nil
        server.history = stored + [
            turn(.user, "Asked on the web", id: "q2"),
            turn(.assistant, "Answered there.", id: "a2"),
        ]
        server.holdsLoads = true
        let model = makeModel(connectivity: ManualConnectivity(isOffline: true))

        let loading = Task { await model.load() }
        await waitUntil { self.server.loadsWaiting == 1 }

        XCTAssertTrue(model.isShowingSavedCopy, "shown before the request answered")
        XCTAssertEqual(model.messages, stored)
        XCTAssertNotNil(model.sendBlockedReason)

        server.release()
        await loading.value

        XCTAssertFalse(model.isShowingSavedCopy, "the server's transcript replaced it")
        XCTAssertNil(model.offlineNotice())
        XCTAssertEqual(model.messages.count, 4)
        XCTAssertNil(model.sendBlockedReason)
    }

    /// The window that matters most: the copy is on screen and the request has not answered. A
    /// question sent now would carry the saved transcript to a server that may hold more.
    func testNothingIsSentWhileTheCopyIsShownAndTheRequestIsStillOut() async {
        await openOnceOnline()
        server.messagesError = nil
        server.holdsLoads = true
        let model = makeModel(connectivity: ManualConnectivity(isOffline: true))

        let loading = Task { await model.load() }
        await waitUntil { self.server.loadsWaiting == 1 }
        model.send("Sent too early")
        await settle(model)

        XCTAssertTrue(server.sentHistories.isEmpty)
        server.release()
        await loading.value
    }

    /// When the connection returns, the conversation reloads, the notice goes — and the next
    /// question carries the server's history, not the saved one.
    func testWhenTheConnectionReturnsTheNextQuestionGoesFromTheFreshHistory() async {
        await openOnceOnline()
        let connectivity = ManualConnectivity(isOffline: true)
        let model = makeModel(connectivity: connectivity)
        await model.load()
        XCTAssertTrue(model.isShowingSavedCopy)

        let fresh = stored + [
            turn(.user, "Asked on the web", id: "q2"),
            turn(.assistant, "Answered there.", id: "a2"),
        ]
        server.messagesError = nil
        server.history = fresh
        connectivity.isOffline = false
        await model.connectivityChanged()

        XCTAssertFalse(model.isShowingSavedCopy)
        XCTAssertNil(model.offlineNotice())
        XCTAssertTrue(model.historyIsIntact)

        server.events = [.content(StreamContent.parse("Answer."))]
        model.send("Follow-up")
        await settle(model)
        XCTAssertEqual(
            server.sentHistories.first?.compactMap(\.id).prefix(4), ["q1", "a1", "q2", "a2"],
            "posted from what the server holds, so the web's turn is not deleted")
    }

    /// Losing the connection while the first load waits shows the copy then and there.
    func testLosingTheConnectionMidLoadShowsTheCopy() async {
        await openOnceOnline()
        server.messagesError = nil
        server.holdsLoads = true
        let connectivity = ManualConnectivity(isOffline: false)
        let model = makeModel(connectivity: connectivity)

        let loading = Task { await model.load() }
        await waitUntil { self.server.loadsWaiting == 1 }
        XCTAssertFalse(model.isShowingSavedCopy, "the network first, while it is believed up")

        connectivity.isOffline = true
        await model.connectivityChanged()
        XCTAssertTrue(model.isShowingSavedCopy)

        server.release()
        await loading.value
        XCTAssertFalse(model.isShowingSavedCopy)
    }

    /// Without a saved copy, a failed load is what it always was.
    func testWithNoCopyAnOfflineLoadFailsAsBefore() async {
        server.messagesError = noConnection
        let model = makeModel()
        await model.load()

        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertFalse(model.isShowingSavedCopy)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.historyIsIntact)
    }

    // MARK: What is kept after a turn

    /// A finished answer is kept with its question, so a conversation continued in chambers
    /// reopens in court with the last answer in it.
    func testAFinishedTurnIsKept() async {
        server.history = stored
        let model = makeModel()
        await model.load()
        server.events = [.content(StreamContent.parse("Within three years."))]

        model.send("And for a counter-claim?")
        await settle(model)

        XCTAssertEqual(
            store.value([ChatMessage].self, for: "chat-1")?.value.map(\.content),
            stored.map(\.content) + ["And for a counter-claim?", "Within three years."])
    }

    /// Nothing the server refused or failed on is kept: the refused question exists nowhere but
    /// on this screen.
    func testARefusedOrFailedTurnIsNotKept() async {
        server.history = stored
        let model = makeModel()
        await model.load()

        server.sendError = APIError.refused(
            Refusal(code: .queryLimit, status: 402, serverMessage: "Upgrade"))
        model.send("Refused question")
        await settle(model)
        server.sendError = APIError.server(status: 500, message: "boom")
        model.send("Failed question")
        await settle(model)

        XCTAssertEqual(store.value([ChatMessage].self, for: "chat-1")?.value, stored)
    }

    // MARK: Citations offline

    /// A citation in a saved copy opens its document from the transcript's own attachments — the
    /// library cannot be fetched with no connection, and must not be needed.
    func testACitationInASavedCopyResolvesWithoutTheLibrary() async {
        var question = turn(.user, "Summarise the plaint", id: "q1")
        question.attachments = [ChatAttachment(name: "Plaint.pdf", folderName: "Bakshi").jsonValue]
        server.history = [question, turn(.assistant, "It pleads … <@Plaint.pdf:P-1:3>", id: "a1")]
        await makeModel().load()
        server.messagesError = noConnection

        let files = FakeFiles()
        files.treeError = noConnection
        let model = makeModel(files: files)
        await model.load()
        XCTAssertTrue(model.isShowingSavedCopy)
        XCTAssertTrue(model.attachments.isEmpty, "the saved copy does not arm the composer")

        await model.showSource(
            AnnexureMention(fileName: "Plaint.pdf", mark: "P-1", startPage: 3, endPage: nil))

        XCTAssertEqual(model.openSource?.attachment, ChatAttachment(name: "Plaint.pdf", folderName: "Bakshi"))
        XCTAssertEqual(files.treeCallCount, 0)
    }
}

// MARK: - Documents

@MainActor
final class DocumentOfflineTests: XCTestCase {

    private final class Previews: OfficePreviewProviding, @unchecked Sendable {
        var success = true
        var pdf = Data("%PDF converted".utf8)
        var error: Error?
        func preview(fileName: String, folderName: String?) async throws -> OfficePreview.Response {
            if let error { throw error }
            return OfficePreview.Response(
                success: success, fileName: fileName, pages: 1, cached: true,
                reason: success ? nil : "unsupported", error: nil)
        }
        func previewPDF(fileName: String, folderName: String?) async throws -> Data { pdf }
    }

    private let clock = TestClock()
    private let files = FakeFiles()
    private lazy var documents = OfflineDocuments(store: OfflineStore(
        namespace: "a1.documents", budget: 1_000, store: InMemoryCacheStore(), now: clock.reader))

    private static var plaint: ChatAttachment { ChatAttachment(name: "Plaint.pdf", folderName: "Bakshi") }

    private func viewer(
        _ attachment: ChatAttachment = DocumentOfflineTests.plaint,
        previews: Previews? = nil,
        connectivity: ManualConnectivity? = nil
    ) -> SourceDocumentViewModel {
        SourceDocumentViewModel(
            attachment: attachment,
            mention: AnnexureMention(fileName: attachment.name, mark: "", startPage: nil, endPage: nil),
            service: files, officePreview: previews, offline: documents,
            connectivity: connectivity)
    }

    func testAnOpenedDocumentIsKept() async {
        files.data = ["Plaint.pdf": Data("%PDF plaint".utf8)]
        await viewer().load()

        XCTAssertTrue(documents.isAvailable(Self.plaint))
        XCTAssertFalse(documents.isSaved(Self.plaint), "kept because opened, not saved on purpose")
    }

    func testOfflineItOpensFromTheDeviceWithItsAge() async {
        files.data = ["Plaint.pdf": Data("%PDF plaint".utf8)]
        await viewer().load()
        clock.advance(30 * 60)
        files.dataError = noConnection

        let model = viewer()
        await model.load()

        XCTAssertEqual(model.data, Data("%PDF plaint".utf8))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(
            model.offlineNotice(now: clock.now), "Offline — showing the copy saved 30 minutes ago.")
    }

    /// "That document is no longer in your library" is the server's answer, and a copy must not
    /// contradict it.
    func testAServerAnswerIsNotCoveredByTheCopy() async {
        files.data = ["Plaint.pdf": Data("%PDF plaint".utf8)]
        await viewer().load()
        files.dataError = APIError.server(
            status: 404, message: "That document is no longer in your library.")

        let model = viewer()
        await model.load()

        XCTAssertNil(model.data)
        XCTAssertNil(model.offlineNotice())
        XCTAssertEqual(model.unavailableMessage, "That document is no longer in your library.")
    }

    /// Known offline: the copy opens without asking the network to wait for a connection.
    func testKnownOfflineOpensTheCopyWithoutFetching() async {
        documents.keep(ViewableDocument(data: Data("%PDF".utf8), isConvertedPreview: false),
                       of: Self.plaint, pin: true)

        let model = viewer(connectivity: ManualConnectivity(isOffline: true))
        await model.load()

        XCTAssertEqual(model.data, Data("%PDF".utf8))
        XCTAssertNil(files.lastRequestedName, "no request was made")
    }

    /// A Word document is kept as the server's PDF of it, and reopens as that — labelled as a
    /// conversion, as it was online.
    func testAWordDocumentIsKeptAsItsConversion() async {
        let brief = ChatAttachment(name: "Brief.docx", folderName: "Bakshi")
        let previews = Previews()
        await viewer(brief, previews: previews).load()
        previews.error = noConnection

        let model = viewer(brief, previews: previews)
        await model.load()

        XCTAssertEqual(model.data, previews.pdf)
        XCTAssertTrue(model.isConvertedPreview)
        XCTAssertTrue(model.isPDF)
    }

    /// A conversion the server refused is not a document, and nothing is kept of it.
    func testARefusedConversionIsNotKept() async {
        let brief = ChatAttachment(name: "Brief.docx", folderName: "Bakshi")
        let previews = Previews()
        previews.success = false
        let model = viewer(brief, previews: previews)
        await model.load()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(documents.isAvailable(brief))
    }

    func testAnEmptyBodyIsNotKept() async {
        files.data = [:]
        await viewer().load()
        XCTAssertFalse(documents.isAvailable(Self.plaint))
    }

    /// Opening a document saved for offline refreshes it and leaves it saved.
    func testOpeningASavedDocumentKeepsItSaved() async {
        documents.keep(ViewableDocument(data: Data("old".utf8), isConvertedPreview: false),
                       of: Self.plaint, pin: true)
        files.data = ["Plaint.pdf": Data("%PDF new".utf8)]
        await viewer().load()

        XCTAssertTrue(documents.isSaved(Self.plaint))
        XCTAssertEqual(documents.copy(of: Self.plaint, converted: false)?.data, Data("%PDF new".utf8))
    }

    /// Room taken by documents saved on purpose: the document opens, and the screen says it was
    /// not kept.
    func testWhenSavedDocumentsFillTheSpaceTheViewerSaysSo() async {
        documents.keep(ViewableDocument(data: Data(repeating: 1, count: 900), isConvertedPreview: false),
                       of: ChatAttachment(name: "Paperbook.pdf", folderName: "Bakshi"), pin: true)
        files.data = ["Plaint.pdf": Data(repeating: 2, count: 200)]

        let model = viewer()
        await model.load()

        XCTAssertNotNil(model.data)
        XCTAssertEqual(model.offlineNote?.contains("space for offline copies"), true)
        XCTAssertFalse(documents.isAvailable(Self.plaint))
    }
}

// MARK: - My Files

@MainActor
final class MyFilesOfflineTests: XCTestCase {

    private final class Manager: FileManaging, @unchecked Sendable {
        func rename(name: String, in folderName: String?, to newName: String) async throws
            -> FileOperationResult {
            FileOperationResult(fileName: newName, folderName: folderName ?? "")
        }
        func move(name: String, from folderName: String?, to destination: String?) async throws {}
        func setFavorite(_ favorite: Bool, name: String, folderName: String?) async throws -> Bool {
            favorite
        }
        func createFolder(named path: String) async throws {}
        func renameFolder(at path: String, to newName: String) async throws -> String { newName }
        func delete(name: String, folderName: String?) async throws {}
        func deleteFolder(named path: String) async throws {}
    }

    private let clock = TestClock()
    private lazy var documents = OfflineDocuments(store: OfflineStore(
        namespace: "a1.documents", budget: 1_000, store: InMemoryCacheStore(), now: clock.reader))
    private let files: FakeFiles = {
        let files = FakeFiles()
        files.tree = [
            folder("Bakshi", [.file(readyFile("Bakshi/Plaint.pdf")), .file(readyFile("Bakshi/Reply.pdf"))]),
        ]
        return files
    }()

    private func makeModel(cache: ResponseCache? = nil) -> MyFilesViewModel {
        MyFilesViewModel(
            service: files, manager: Manager(), now: clock.reader, cache: cache, offline: documents)
    }

    private var plaint: FileNode.StoredFile { readyFile("Bakshi/Plaint.pdf") }
    private var reply: FileNode.StoredFile { readyFile("Bakshi/Reply.pdf") }

    func testSavingForOfflineFetchesAndMarksIt() async {
        files.data = ["Plaint.pdf": Data("%PDF".utf8)]
        let model = makeModel()

        await model.saveForOffline(plaint)

        XCTAssertEqual(model.offlineStatus(of: plaint), .saved)
        XCTAssertEqual(model.actionNotice, "Plaint.pdf is saved for offline reading.")
        XCTAssertNil(model.actionError)
    }

    /// A document already kept because it was opened is simply marked — with no connection and
    /// no download.
    func testSavingADocumentAlreadyKeptNeedsNoConnection() async {
        documents.keep(ViewableDocument(data: Data("%PDF".utf8), isConvertedPreview: false),
                       of: plaint.attachment, pin: nil)
        files.dataError = noConnection
        let model = makeModel()
        XCTAssertEqual(model.offlineStatus(of: plaint), .available)

        await model.saveForOffline(plaint)

        XCTAssertEqual(model.offlineStatus(of: plaint), .saved)
        XCTAssertNil(files.lastRequestedName)
    }

    /// Space ran out: the documents saved earlier that had to go are named.
    func testWhenSpaceRunsOutTheScreenSaysWhatWasRemoved() async {
        documents.keep(ViewableDocument(data: Data(repeating: 1, count: 700), isConvertedPreview: false),
                       of: reply.attachment, pin: true)
        clock.advance()
        files.data = ["Plaint.pdf": Data(repeating: 2, count: 600)]
        let model = makeModel()

        await model.saveForOffline(plaint)

        XCTAssertEqual(
            model.actionNotice,
            "Plaint.pdf is saved for offline reading. Offline space ran out, so Reply.pdf was removed to make room.")
        XCTAssertEqual(model.offlineStatus(of: reply), MyFilesViewModel.OfflineStatus.none)
    }

    func testADocumentLargerThanTheSpaceSaysSo() async {
        files.data = ["Plaint.pdf": Data(repeating: 2, count: 1_001)]
        let model = makeModel()

        await model.saveForOffline(plaint)

        XCTAssertEqual(model.actionError?.contains("is larger than the"), true)
        XCTAssertEqual(model.offlineStatus(of: plaint), MyFilesViewModel.OfflineStatus.none)
    }

    func testRemovingTheOfflineCopy() async {
        files.data = ["Plaint.pdf": Data("%PDF".utf8)]
        let model = makeModel()
        await model.saveForOffline(plaint)

        model.removeOfflineCopy(plaint)

        XCTAssertEqual(model.offlineStatus(of: plaint), MyFilesViewModel.OfflineStatus.none)
        XCTAssertFalse(documents.isAvailable(plaint.attachment))
    }

    /// My Files opens offline on the library last fetched — the only way to reach a document
    /// saved for offline — stamped with its age.
    func testTheLibraryOpensOfflineFromTheLastFetch() async {
        let cache = ResponseCache(store: InMemoryCacheStore(), now: clock.reader)
        await makeModel(cache: cache).load()

        files.treeError = noConnection
        let offline = makeModel(cache: cache)
        await offline.load()

        XCTAssertNotNil(offline.listing(at: "Bakshi"))
        let presentation = offline.presentation(for: .folders)
        XCTAssertTrue(presentation.showsStaleBanner)
        XCTAssertEqual(presentation.cachedAt, clock.now)
    }

    /// Automatic copies of documents no longer in the library go — but only on a library the
    /// server has just sent, never on a failed load.
    func testCopiesOfDocumentsNoLongerInTheLibraryGoOnAFreshLoadOnly() async {
        let gone = readyFile("Bakshi/Withdrawn.pdf")
        documents.keep(ViewableDocument(data: Data("x".utf8), isConvertedPreview: false),
                       of: gone.attachment, pin: nil)
        files.treeError = noConnection
        let model = makeModel()
        await model.load()
        XCTAssertTrue(documents.isAvailable(gone.attachment), "a failed load prunes nothing")

        files.treeError = nil
        await model.load()
        XCTAssertFalse(documents.isAvailable(gone.attachment))
    }

    /// A rename made here takes the copy, and its saved standing, to the new name.
    func testARenameCarriesTheCopy() async {
        documents.keep(ViewableDocument(data: Data("x".utf8), isConvertedPreview: false),
                       of: plaint.attachment, pin: true)
        files.tree = [folder("Bakshi", [.file(readyFile("Bakshi/Amended_Plaint.pdf"))])]
        let model = makeModel()

        await model.rename(plaint, to: "Amended_Plaint.pdf")

        XCTAssertEqual(model.offlineStatus(of: readyFile("Bakshi/Amended_Plaint.pdf")), .saved)
        XCTAssertFalse(documents.isAvailable(plaint.attachment))
    }

    func testDeletingADocumentRemovesItsCopy() async {
        documents.keep(ViewableDocument(data: Data("x".utf8), isConvertedPreview: false),
                       of: plaint.attachment, pin: true)
        let model = makeModel()

        await model.confirm(FileDeletion(file: plaint))

        XCTAssertFalse(documents.isAvailable(plaint.attachment))
    }
}

// MARK: - Matters

@MainActor
final class CaseDetailOfflineTests: XCTestCase {

    private let store = OfflineStore(
        namespace: "a1.matters", budget: 100_000, store: InMemoryCacheStore())
    private let cases: FakeCases = {
        let cases = FakeCases()
        let legalCase = try! JSONDecoder().decode(LegalCase.self, from: Data(#"""
            {"id":"case1","title":"Bakshi v. State","court_name":"Bombay High Court",
             "next_hearing_date":"2026-10-06","last_synced_at":"2026-10-05T22:00:00.000Z"}
            """#.utf8))
        let item = try! JSONDecoder().decode(CaseItem.self, from: Data(#"""
            {"id":"i1","section":"orders","title":"Interim order","item_date":"2026-09-20",
             "data":"{\"url\":\"x\"}","source":"scrape"}
            """#.utf8))
        let event = try! JSONDecoder().decode(CaseEvent.self, from: Data(#"""
            {"id":"e1","type":"note","body":"Client called","created_at":"2026-10-01 09:00:00"}
            """#.utf8))
        cases.detail = CaseDetail(legalCase: legalCase, events: [event], items: [item])
        return cases
    }()

    private func makeModel(connectivity: ManualConnectivity? = nil) -> CaseDetailViewModel {
        CaseDetailViewModel(caseID: "case1", service: cases, offline: store, connectivity: connectivity)
    }

    func testAMatterOpensOfflineFromItsCopyWithItsAge() async {
        await makeModel().load()
        let fetched = cases.detail
        cases.error = noConnection

        let model = makeModel()
        await model.load()

        XCTAssertEqual(model.detail, fetched, "every field survives the round trip")
        XCTAssertNotNil(model.cachedAt)
        XCTAssertTrue(model.presentation.showsStaleBanner)
        XCTAssertEqual(model.presentation.failure?.kind, .offline)
        XCTAssertFalse(model.canWrite, "a note added to a copy would vanish on the next load")
    }

    func testKnownOfflineShowsTheCopyWhileLoading() async {
        await makeModel().load()
        let model = makeModel(connectivity: ManualConnectivity(isOffline: true))
        cases.error = noConnection
        await model.load()
        XCTAssertNotNil(model.detail)
    }

    func testAServerAnswerIsNotCoveredByTheCopy() async {
        await makeModel().load()
        cases.error = APIError.server(status: 404, message: "That matter could not be found.")

        let model = makeModel()
        await model.load()

        XCTAssertNil(model.detail)
        XCTAssertTrue(model.presentation.showsFailureState)
    }

    func testAFreshLoadReplacesTheCopyAndCanWriteAgain() async {
        await makeModel().load()
        cases.error = noConnection
        let model = makeModel()
        await model.load()
        XCTAssertNotNil(model.cachedAt)

        cases.error = nil
        await model.load()
        XCTAssertNil(model.cachedAt)
        XCTAssertTrue(model.canWrite)
    }
}

// MARK: - Settings → Storage

/// `async` throughout, like every main-actor test class here: Linux XCTest cannot call a
/// *synchronous* `@MainActor` test method, and aborts the whole run trying.
@MainActor
final class OfflineStorageViewModelTests: XCTestCase {

    func testItCountsTheSignedInAccountsCopiesAndClearsThem() async {
        let library = OfflineLibrary(store: InMemoryCacheStore())
        library.copies(for: 1).conversations.save(Data(repeating: 1, count: 1_500_000), for: "c1")
        library.copies(for: 1).documents.save(Data(repeating: 1, count: 1_000_000), for: "file:A.pdf")
        library.copies(for: 2).documents.save(Data(repeating: 1, count: 9_000_000), for: "file:B.pdf")

        let model = OfflineStorageViewModel(library: library, account: 1)
        XCTAssertEqual(model.summary.sizeText, "2.5 MB", "another account's copies are not counted")
        XCTAssertEqual(model.summary.contentsText, "1 conversation and 1 document")

        model.clear()
        XCTAssertEqual(model.summary.sizeText, "None")
        XCTAssertEqual(library.copies(for: 1).totalBytes, 0)
    }

    func testNobodySignedInCountsNothing() async {
        let model = OfflineStorageViewModel(library: OfflineLibrary(store: InMemoryCacheStore()), account: nil)
        XCTAssertTrue(model.summary.isEmpty)
    }
}
