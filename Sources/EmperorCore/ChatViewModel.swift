import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Turn state for one conversation.
///
/// `@Observable` is applied on Apple platforms only. The Linux toolchain ships a
/// `libswiftObservation.so` with an undefined symbol (`swift::threading::fatal`), so applying
/// the macro there compiles but fails to *link* — which would take the whole test suite with
/// it. SwiftUI observation is an Apple concern anyway; on Linux this is a plain class, which
/// is exactly what the tests need.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class ChatViewModel {
    /// Finished turns, oldest first.
    private(set) var messages: [ChatMessage] = []
    /// The answer currently streaming, if any.
    private(set) var live: StreamContent?
    /// Transient progress ("Reading: sale_deed.pdf"). Not part of the transcript.
    private(set) var status: String?
    /// Shown when the server refuses a concurrent run — deliberately outside the transcript.
    private(set) var busyNotice: String?
    /// Plan and work log for the turn currently streaming.
    private(set) var progress = ReasoningSnapshot()
    private(set) var isStreaming = false
    private(set) var isLoading = false
    var errorMessage: String?

    /// Set when a run finished but the server says the answer was cut short.
    private(set) var wasInterrupted = false

    /// Whether `messages` is the whole conversation, so it is safe to post back.
    ///
    /// **This gates sending, and it is not a nicety.** `POST /chat` replaces the chat's stored
    /// messages with exactly the array it receives (`setMessages` deletes and re-inserts). So
    /// if `load()` failed and left `messages` empty, a single send would post a one-message
    /// history and the server would delete every earlier turn — silently, with no error, and
    /// the user would only find out on the next load.
    ///
    /// A brand-new chat is intact by definition: there is nothing on the server to lose. That
    /// is why `load()` marks the "Chat not found" case as intact rather than failed.
    private(set) var historyIsIntact = true

    /// Why the composer is disarmed, when it is. `nil` means it is armed.
    var sendBlockedReason: String? {
        historyIsIntact
            ? nil
            : "This conversation could not be loaded, so a reply now would replace what is stored. Pull to retry first."
    }

    /// The cited document to present, once a citation tap has been resolved to a real file.
    var openSource: SourceSelection?
    /// A citation that could not be resolved. Kept apart from `errorMessage` because it is a
    /// different failure with different wording, not a failed turn.
    var citationError: String?
    /// A scan that could not be captured, assembled or ingested.
    var scanError: String?

    /// A question the server refused to start, handed back so the composer can restore it.
    ///
    /// The refusal happens *before* anything is stored (`sync-server.js:7256-7276`), so leaving
    /// the optimistic bubble in the transcript showed a turn that does not exist anywhere —
    /// and it vanished on the next load with the user's typing gone.
    var restoredDraft: String?

    let chatID: String
    var attachments: [ChatAttachment] = []
    var model: ChatModel = .default
    var role: ChatRole = .default

    /// Ask the model to search the web for this turn.
    ///
    /// - Important: this is "search on purpose", **not** a switch. The server auto-triggers a
    ///   web search on keywords in the message regardless of what is sent here, so turning it
    ///   off does not guarantee no search happens — only that we did not ask. Any wording that
    ///   promises otherwise would be a lie the server can contradict.
    var webSearch = false

    private let service: any ChatProviding
    private let files: (any FileProviding)?
    private let uploads: (any UploadProviding)?
    private var streamTask: Task<Void, Never>?

    /// The document tree, fetched on the first citation tap that needs it.
    ///
    /// `tree()` runs a full storage walk server-side, so it is not fetched until something
    /// actually needs it — and then kept, because a transcript tends to cite repeatedly.
    private var libraryCache: [FileNode.StoredFile] = []

    /// - Parameters:
    ///   - preferredModel: the account's `preferred_model`, which **seeds the picker only**.
    ///     The per-request model is what the server honours, so it is sent explicitly on every
    ///     turn regardless of this.
    ///   - files: needed only to resolve a citation against the wider library.
    ///   - uploads: needed only to attach a scan.
    init(
        chatID: String,
        service: any ChatProviding,
        files: (any FileProviding)? = nil,
        uploads: (any UploadProviding)? = nil,
        preferredModel: String? = nil
    ) {
        self.chatID = chatID
        self.service = service
        self.files = files
        self.uploads = uploads
        self.model = ChatModel.fromPreference(preferredModel)
    }

    nonisolated static func newChatID() -> String { UUID().uuidString }

    // MARK: - Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            messages = try await service.messages(chatID: chatID)
            historyIsIntact = true
            // A run may have continued server-side while the app was closed — generation is
            // not tied to the socket.
            await recoverInFlightRun()
        } catch let error as APIError {
            // A brand-new chat has no row yet, which this API reports as an error rather than
            // an empty list. That is not a failure worth showing — and there is nothing stored
            // to overwrite, so sending stays safe.
            if case .server(_, let message) = error, message.contains("Chat not found") {
                historyIsIntact = true
                return
            }
            // Everything else means we do not know what the server holds. Sending now would
            // post a partial history and delete the rest.
            historyIsIntact = false
            errorMessage = error.errorDescription
        } catch {
            historyIsIntact = false
            errorMessage = error.localizedDescription
        }
    }

    /// Rejoins a generation still running on the server.
    private func recoverInFlightRun() async {
        guard let status = try? await service.streamStatus(chatID: chatID), status.error == nil
        else { return }

        if status.active, let content = status.content, !content.isEmpty {
            live = StreamContent.parse(content)
            isStreaming = true
            pollUntilFinished()
        } else if status.incomplete == true {
            wasInterrupted = true
        }
    }

    /// Polls a rejoined run to completion.
    ///
    /// There is no way to re-attach to the byte stream of a run started by another
    /// connection, so recovery is polling `/stream-status`, whose `content` is always the
    /// full draft rather than a delta.
    private func pollUntilFinished() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let status = try? await self.service.streamStatus(chatID: self.chatID)
                else { continue }

                // Re-checked after the await: a poll already in flight when `stop()` ran would
                // otherwise resurrect `live` and append the answer a second time — and, since
                // history is posted back verbatim, persist the duplicate.
                if Task.isCancelled { return }

                if let content = status.content, !content.isEmpty {
                    self.live = StreamContent.parse(content)
                }
                if !status.active {
                    self.wasInterrupted = status.incomplete == true
                    await self.finishStreaming()
                    return
                }
            }
        }
    }

    // MARK: - Sending

    // MARK: - Editing a question

    /// How many turns editing `message` would throw away — the question itself and everything
    /// after it.
    ///
    /// Returns 0 when the message is not editable, so a caller can use this as the test.
    ///
    /// The count is the whole point of asking. Re-answering the third of eight turns discards
    /// six, and because `POST /chat` stores exactly what it is sent, they go from the server
    /// too. A confirmation that says "this cannot be undone" without saying *how much* is not
    /// a confirmation, it is a formality.
    func discardCount(editing message: ChatMessage) -> Int {
        guard canEdit(message), let index = indexOf(message) else { return 0 }
        return messages.count - index
    }

    /// Whether this turn can be edited and re-answered.
    ///
    /// User turns only: an assistant answer is not ours to rewrite, and offering it would
    /// suggest the model could be made to have said something it did not.
    func canEdit(_ message: ChatMessage) -> Bool {
        message.role == .user && !isStreaming && historyIsIntact && indexOf(message) != nil
    }

    /// Replaces a question and answers again from that point.
    ///
    /// Everything from the edited turn onward is dropped before sending, which is what makes
    /// this an *edit* rather than a second question — the model must not see the original
    /// wording or the answer it produced, or it will reconcile the two instead of starting
    /// again.
    ///
    /// The truncation is local first and the send does the rest: the server replaces its stored
    /// messages with the array it receives, so the discarded turns are gone at both ends. That
    /// is the intended behaviour and the reason `discardCount` exists to be shown first.
    func edit(_ message: ChatMessage, to newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit(message), !trimmed.isEmpty, let index = indexOf(message) else { return }

        // Attachments travel on the message, so an edited turn keeps the documents its original
        // asked about. Dropping them would silently change the question by more than its words.
        attachments = ChatAttachment.list(from: messages[index].attachments)

        messages.removeSubrange(index...)
        live = nil
        progress = ReasoningSnapshot()
        wasInterrupted = false
        send(trimmed)
    }

    private func indexOf(_ message: ChatMessage) -> Int? {
        messages.firstIndex { $0.stableID == message.stableID }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `historyIsIntact` last, because it is the one that costs data rather than a no-op.
        guard !trimmed.isEmpty, !isStreaming, historyIsIntact else { return }

        busyNotice = nil
        wasInterrupted = false
        errorMessage = nil
        progress = ReasoningSnapshot()
        var turn = ChatMessage(role: .user, content: trimmed, id: UUID().uuidString)
        // Also on the message, not just the top-level array — the scanned-document check
        // reads it from here, and later turns rely on it to keep files in scope.
        if !attachments.isEmpty {
            turn.attachments = attachments.map(\.jsonValue)
        }
        messages.append(turn)
        isStreaming = true
        live = StreamContent()
        status = "Preparing…"

        let outbound = attachments.isEmpty ? nil : attachments
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                // The full conversation must go every time: the server replaces the chat's
                // stored messages with exactly what it receives, so omitting history deletes it.
                let stream = try await self.service.send(
                    history: self.messages,
                    chatID: self.chatID,
                    model: self.model,
                    role: self.role,
                    attachments: outbound,
                    webSearch: self.webSearch)

                for try await event in stream {
                    switch event {
                    case .status(let text):
                        self.status = text
                    case .busy(let notice):
                        self.busyNotice = notice
                        // Nothing was started and nothing was stored. Drop the optimistic
                        // bubble *and* give the text back, so the question is not lost.
                        self.live = nil
                        if let last = self.messages.last, last.role == .user {
                            self.restoredDraft = last.content
                            self.messages.removeLast()
                        }
                    case .content(let content):
                        self.live = content
                    case .progress(let snapshot):
                        self.progress = snapshot
                    case .usage:
                        break
                    }
                }
                await self.confirmCompletion()
            } catch is CancellationError {
                await self.finishStreaming()
            } catch {
                self.errorMessage = (error as? APIError)?.errorDescription
                    ?? error.localizedDescription
                await self.finishStreaming()
            }
        }
    }

    /// Confirms the answer actually finished.
    ///
    /// An aborted run ends its response cleanly with no error bytes, so end-of-stream alone
    /// proves nothing. `/stream-status` is the only authoritative signal.
    private func confirmCompletion() async {
        if let status = try? await service.streamStatus(chatID: chatID), status.error == nil {
            wasInterrupted = status.incomplete == true
        }
        // The server's verdict is necessary but not sufficient: `/chat` discards the provider's
        // `status:'length'` finding (`sync-server.js:7797`), so a draft stranded mid-document is
        // reported complete. Trust the shape of the answer as well as the server's word.
        if live?.hasUnclosedDocumentBlock == true { wasInterrupted = true }
        await finishStreaming()
    }

    private func finishStreaming() async {
        // Reentrancy guard. `stop()` and a late-arriving poll can both reach here, and without
        // this the turn is appended twice.
        guard isStreaming else {
            live = nil
            status = nil
            return
        }
        if let live, !live.prose.isEmpty || !live.artifacts.isEmpty {
            // `persistableContent`, NOT `prose`. The next `send` posts this whole array back,
            // and the server replaces its stored messages with exactly what it receives
            // (`sync-server.js:4250`) — so posting the stripped prose would permanently delete
            // this turn's drafted document and every citation token from the server's copy.
            messages.append(ChatMessage(role: .assistant, content: live.persistableContent))
        }
        live = nil
        status = nil
        isStreaming = false
        streamTask = nil
    }

    /// Stops rendering locally. It does **not** stop the run: generation continues on the
    /// server and will be there on the next load.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        Task { await finishStreaming() }
    }

    // MARK: - Citations

    /// A cited document, ready to present.
    struct SourceSelection: Identifiable {
        let id = UUID()
        let attachment: ChatAttachment
        let mention: AnnexureMention
    }

    /// Opens the document a citation points at, at the page it names.
    ///
    /// Resolution is two-stage: the turn's own attachments first, which needs no network, and
    /// only then the whole library — because a citation from an earlier turn may name a file
    /// that is no longer attached to the composer.
    func showSource(_ mention: AnnexureMention) async {
        if resolveFromCache(mention) { return }

        if libraryCache.isEmpty, let files, let tree = try? await files.tree() {
            libraryCache = FileService.allFiles(in: tree)
            if resolveFromCache(mention) { return }
        }

        // Name the file that is missing. A citation pointing at a document no longer in the
        // library is exactly the case the user needs told plainly rather than as a dead tap.
        citationError = """
            \(DisplayText.fileName(mention.fileName)) is not in your document library any \
            more, so its cited page cannot be opened.
            """
    }

    private func resolveFromCache(_ mention: AnnexureMention) -> Bool {
        guard let attachment = CitationResolver.resolve(
            mention, attachments: attachments, files: libraryCache)
        else { return false }
        openSource = SourceSelection(attachment: attachment, mention: mention)
        return true
    }

    // MARK: - Scanning

    /// Uploads a freshly captured scan and attaches it to the turn.
    ///
    /// The attachment is added only once ingestion reports the file usable: attaching earlier
    /// would put a name on the turn that the server cannot yet read, and the refusal that
    /// follows is far harder to understand than a short wait.
    func attach(_ document: ScannedDocument) async {
        guard let uploads else { return }
        do {
            for try await event in uploads.upload(
                data: document.pdfData,
                fileName: document.suggestedName,
                folderName: ScannedDocument.folderName
            ) {
                guard case .finished(let state) = event else { continue }
                if state.isUsable {
                    attachments.append(
                        ChatAttachment(
                            // The sanitised name, because that is what the server wrote to
                            // disk — and annexure citations match on the exact on-disk name.
                            name: UploadService.sanitize(fileName: document.suggestedName),
                            folderName: ScannedDocument.folderName))
                } else if case .failed(let reason) = state {
                    // Ingestion failures arrive with no HTTP error at all, so this is the only
                    // place they can surface.
                    scanError = reason
                }
            }
        } catch {
            scanError = DisplayText.message(for: error)
        }
    }

    /// Reports a capture that never produced a document — a cancelled or failed scan.
    func reportScanFailure(_ error: Error) {
        scanError = DisplayText.message(for: error)
    }
}
