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
    /// Set when the server declined the question on purpose — no plan, this month's questions
    /// used, a paused account. Kept apart from `errorMessage` because it is not a failure to
    /// retry: it gets its own card, worded by `DisplayText`, and sending the same question again
    /// would only be refused again.
    private(set) var refusal: Refusal?

    /// Set when a run finished but the server says the answer was cut short.
    private(set) var wasInterrupted = false

    /// What became of the last attempt to store a turn's work log. Never shown — the answer is
    /// stored whatever happens to the log — and kept so the conditions can be tested.
    private(set) var workLogSave: WorkLogSaveOutcome?
    /// A work-log save still on its way. The next turn waits for it: see `send(_:)`.
    private var saveTask: Task<Void, Never>?
    /// When the turn now streaming was sent, for the "Worked · 00:47" the web shows.
    private var turnStartedAt: Date?

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

    /// When the transcript on screen is the copy saved on this device, the moment that copy was
    /// fetched. `nil` means what is on screen came from the server in this session.
    ///
    /// ## A saved copy is for reading, and never for sending
    ///
    /// `POST /chat` stores exactly the history it is sent and deletes the rest, and the work-log
    /// save rewrites the whole conversation through `/sync`. A transcript read off the disk may be
    /// hours behind what the server holds — a question asked on the web since, an answer that
    /// finished after the app was closed — and posting it back would delete those turns without
    /// a word. So while this is set, `historyIsIntact` is false, and every path that writes is
    /// shut on this as well, in case that ever changes: `send`, `edit`, the work-log save and its
    /// final check before committing. The next question goes only from a history the server has
    /// just sent, whole — `load()` clears this on exactly that.
    private(set) var savedCopyAt: Date?

    var isShowingSavedCopy: Bool { savedCopyAt != nil }

    /// Why the composer is disarmed, when it is. `nil` means it is armed.
    var sendBlockedReason: String? {
        if isShowingSavedCopy { return OfflineReading.askingPaused }
        return historyIsIntact
            ? nil
            : "This conversation could not be loaded, so a reply now would replace what is stored. Pull to retry first."
    }

    /// "Offline — showing the copy saved 2 hours ago", while the saved copy is on screen.
    ///
    /// Takes the clock so the age is worked out when it is drawn rather than when the copy was
    /// opened, and so a test can fix it.
    func offlineNotice(now: Date = Date()) -> String? {
        savedCopyAt.map { OfflineReading.notice(savedAt: $0, now: now) }
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

    /// The documents to name above the composer, which is none once the conversation has started.
    ///
    /// Attaching happens on a *different* screen — the library picker, whose Done button opens a
    /// new conversation carrying the selection — so the user arrives at the composer holding
    /// documents they have not yet seen listed anywhere. Naming them here is the confirmation for
    /// that moment, and it is the moment a mis-picked file is most likely to be spotted.
    ///
    /// Once a question has been asked they belong to the conversation's record and the toolbar's
    /// document button owns them. A strip above the composer would by then cost a line of the
    /// transcript on every screen for the rest of the conversation, and still truncate to whatever
    /// fitted the width — while saying less than the button's list, which has room for the folder
    /// name. `{name, folderName}` is the platform's identity for a document, and the name alone
    /// collides across matters.
    ///
    /// The boundary is the **send**, not a finished answer: `send(_:)` appends the user's turn
    /// before the request leaves, so this empties on the tap rather than when the answer lands. A
    /// send that then fails leaves that turn in place, which is the intended reading — the user
    /// has committed this selection to a question, whatever happened to it afterwards.
    ///
    /// Derived from the transcript rather than remembered by the view, so reopening a conversation
    /// from History cannot bring the strip back on turn nine, and there is one source of truth
    /// rather than two that can disagree.
    var openingAttachments: [ChatAttachment] {
        messages.isEmpty ? attachments : []
    }

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
    /// Where removals are remembered. Absent means they are not — the documents come back on the
    /// next load, which is what this screen did before there was anywhere to write them.
    private let detached: (any DetachedDocuments)?
    /// This account's saved conversations. Absent means nothing is kept and nothing is shown
    /// offline — which is how this screen behaved before there was anywhere to keep them.
    private let offline: OfflineStore?
    /// Whether the system says there is no connection, so the saved copy can be shown at once
    /// rather than after a request has waited out its timeout.
    private let connectivity: (any ConnectivityReporting)?
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
    ///   - detached: where removals are remembered. Without it a removal lasts the session only.
    ///   - offline: where this account keeps conversations for reading offline.
    ///   - connectivity: whether the device is known to have no connection.
    init(
        chatID: String,
        service: any ChatProviding,
        files: (any FileProviding)? = nil,
        uploads: (any UploadProviding)? = nil,
        detached: (any DetachedDocuments)? = nil,
        preferredModel: String? = nil,
        offline: OfflineStore? = nil,
        connectivity: (any ConnectivityReporting)? = nil
    ) {
        self.chatID = chatID
        self.service = service
        self.files = files
        self.uploads = uploads
        self.detached = detached
        self.model = ChatModel.fromPreference(preferredModel)
        self.offline = offline
        self.connectivity = connectivity
    }

    // MARK: - Documents on this conversation

    /// Takes a document off this conversation and remembers that it was taken off.
    ///
    /// The remembering is the whole point: `load()` rebuilds the list from the turns, and a
    /// removal it knows nothing about is undone the next time the conversation is opened.
    func detach(_ attachment: ChatAttachment) {
        attachments.removeAll { $0 == attachment }
        guard let detached else { return }
        var removed = detached.detached(inChat: chatID)
        removed.insert(attachment)
        detached.setDetached(removed, inChat: chatID)
    }

    /// Replaces the whole selection, as the library picker's Done does.
    ///
    /// Both directions at once, which is why it cannot be a plain assignment: what the picker
    /// dropped is a removal to be remembered, and what it added is a document that must be struck
    /// off the removed list. Leave that second half out and a document put back is dropped again
    /// on the next load — the invariant is that nothing is ever both attached and detached.
    func setAttachments(_ chosen: [ChatAttachment]) {
        let dropped = Set(attachments).subtracting(chosen)
        attachments = chosen
        guard let detached else { return }
        var removed = detached.detached(inChat: chatID)
        removed.formUnion(dropped)
        removed.subtract(chosen)
        detached.setDetached(removed, inChat: chatID)
    }

    nonisolated static func newChatID() -> String { UUID().uuidString }

    // MARK: - Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        // With no connection at all, the request below would wait for one — for minutes. The
        // saved copy is shown meanwhile, read-only, and replaced if the request comes back.
        if messages.isEmpty, OfflineReading.opensSavedCopyFirst(connectivity) {
            showSavedCopy()
        }
        do {
            messages = try await service.messages(chatID: chatID)
            // The server's transcript replaces any saved copy on screen, and the notice goes.
            savedCopyAt = nil
            // Reopening a matter has to reopen its documents. They are not a field on the chat —
            // they live on the turns that carried them — so they are reconstructed here; see
            // `attachedDocuments`. Without this, a conversation opened from History listed no
            // documents while its own answers cited them by page, and the next question went to
            // the model with nothing attached at all.
            //
            // Merged rather than assigned. A conversation can be opened with documents already
            // chosen, and that choice races this load; assigning would let whichever finished
            // last erase the other, with nothing on screen to say so. The standing choice leads
            // and the restored ones follow it, so an overlap costs nothing either way.
            //
            // Filtered through what the user has taken off this conversation. The transcript
            // cannot record a removal — see `DetachedDocuments` — so without this the restore
            // would undo every removal the moment the conversation was reopened.
            let removed = detached?.detached(inChat: chatID) ?? []
            for restored in messages.attachedDocuments
            where !removed.contains(restored) && !attachments.contains(restored) {
                attachments.append(restored)
            }
            historyIsIntact = true
            // The server's own transcript, whole: the one state a question may be sent from,
            // and the copy worth keeping for reading offline.
            keepCopy()
            // A run may have continued server-side while the app was closed — generation is
            // not tied to the socket.
            await recoverInFlightRun()
        } catch let error as APIError {
            // A brand-new chat has no row yet, which this API reports as an error rather than
            // an empty list. That is not a failure worth showing — and there is nothing stored
            // to overwrite, so sending stays safe.
            if case .server(_, let message) = error, message.contains("Chat not found") {
                // Whatever this device kept is a copy of nothing the server holds. It goes, from
                // the screen *before* the history is declared intact — or the first question
                // would carry it to the server as though it were the conversation.
                discardSavedCopy()
                offline?.remove(chatID)
                historyIsIntact = true
                return
            }
            // Everything else means we do not know what the server holds. Sending now would
            // post a partial history and delete the rest.
            historyIsIntact = false
            if OfflineReading.mayStandIn(after: error), showSavedCopy() { return }
            discardSavedCopy()
            errorMessage = error.errorDescription
        } catch {
            historyIsIntact = false
            if OfflineReading.mayStandIn(after: error), showSavedCopy() { return }
            discardSavedCopy()
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - The saved copy

    /// Puts the saved copy on screen, read-only. Returns whether there was one.
    ///
    /// Shut before it is shown: `historyIsIntact` goes false first, so there is no moment in which
    /// the copy is on screen and a send would be let through.
    @discardableResult
    private func showSavedCopy() -> Bool {
        guard let saved = offline?.value([ChatMessage].self, for: chatID),
              !saved.value.isEmpty
        else { return false }
        historyIsIntact = false
        messages = saved.value
        savedCopyAt = saved.storedAt
        errorMessage = nil
        return true
    }

    /// Takes the saved copy off the screen — the server has answered, and not with the
    /// conversation, so the copy must not stand in for what it said.
    private func discardSavedCopy() {
        guard isShowingSavedCopy else { return }
        messages = []
        savedCopyAt = nil
    }

    /// Keeps the transcript for reading offline: only one the server has just sent whole, or one
    /// it has just finished answering — never a refused or failed turn, which exists nowhere but
    /// here.
    private func keepCopy() {
        guard historyIsIntact, !isShowingSavedCopy, !messages.isEmpty else { return }
        offline?.save(messages, for: chatID)
    }

    /// The device's connection came or went while this conversation is open.
    ///
    /// Lost, while the first load is still waiting: show the saved copy now rather than when the
    /// request gives up. Back, with the saved copy on screen and nothing in flight: load the
    /// conversation again, which replaces the copy and takes the notice away.
    func connectivityChanged() async {
        if connectivity?.isOffline == true {
            if isLoading, messages.isEmpty { showSavedCopy() }
        } else if isShowingSavedCopy, !isLoading {
            await load()
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
                    // The run finished on the server, which stored the answer itself.
                    if await self.finishStreaming() { self.keepCopy() }
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
        message.role == .user && !isStreaming && historyIsIntact && !isShowingSavedCopy
            && indexOf(message) != nil
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
        //
        // Through `setAttachments` rather than assigned, so re-asking a turn also un-removes the
        // documents it carried: they are attached again by definition, and leaving them on the
        // removed list would drop them from the very question being re-asked on the next load.
        setAttachments(ChatAttachment.list(from: messages[index].attachments))

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
        // `historyIsIntact` last, because it is the one that costs data rather than a no-op —
        // and the saved copy with it, which is never sent anywhere (see `savedCopyAt`).
        guard !trimmed.isEmpty, !isStreaming, historyIsIntact, !isShowingSavedCopy else { return }

        busyNotice = nil
        wasInterrupted = false
        errorMessage = nil
        refusal = nil
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
        turnStartedAt = Date()

        // A work-log save from the turn before may still be on its way. It rewrites the whole
        // conversation, so it must never reach the server *after* this turn's request does —
        // above all when this turn is an edit, which stores a shorter history that the rewrite
        // would put back. Cancelling stops a save that has not committed (it checks again
        // before sending, and finds this turn streaming); one already sent is waited for. The
        // save's requests have a short timeout of their own, so the wait is bounded.
        let pendingSave = saveTask
        pendingSave?.cancel()
        saveTask = nil

        let outbound = attachments.isEmpty ? nil : attachments
        streamTask = Task { [weak self] in
            await pendingSave?.value
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
                // A stop ends the loop the same way the end of the body does. It is not a
                // completion: what was in flight never confirmed, and nothing is saved for it.
                if Task.isCancelled {
                    await self.finishStreaming()
                    return
                }
                await self.confirmCompletion()
            } catch is CancellationError {
                await self.finishStreaming()
            } catch let apiError as APIError where apiError.refusal != nil {
                // Refused before a byte was written — the allowance is checked first, so
                // nothing was stored. As with the busy refusal, the optimistic bubble is a turn
                // that exists nowhere, and the typing is handed back rather than lost.
                self.refusal = apiError.refusal
                self.live = nil
                if let last = self.messages.last, last.role == .user {
                    self.restoredDraft = last.content
                    self.messages.removeLast()
                }
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
        let status = try? await service.streamStatus(chatID: chatID)
        if let status, status.error == nil {
            wasInterrupted = status.incomplete == true
        }
        // The server's verdict is necessary but not sufficient: `/chat` discards the provider's
        // `status:'length'` finding (`sync-server.js:7797`), so a draft stranded mid-document is
        // reported complete. Trust the shape of the answer as well as the server's word.
        if live?.hasUnclosedDocumentBlock == true { wasInterrupted = true }
        let answered = await finishStreaming(ended: .completed)
        if answered { keepCopy() }
        saveWorkLog(answered: answered, status: status)
    }

    /// Ends the turn on screen. Returns whether it appended an answer.
    ///
    /// - Parameter ended: how the stream ended — `.completed` only from a clean end of body.
    ///   Anything else may have left work in flight that never came back.
    @discardableResult
    private func finishStreaming(ended: WorkStatus = .stopped) async -> Bool {
        // Reentrancy guard. `stop()` and a late-arriving poll can both reach here, and without
        // this the turn is appended twice.
        guard isStreaming else {
            live = nil
            status = nil
            return false
        }
        var answered = false
        if let live, !live.prose.isEmpty || !live.artifacts.isEmpty {
            // `persistableContent`, NOT `prose`. The next `send` posts this whole array back,
            // and the server replaces its stored messages with exactly what it receives
            // (`sync-server.js:4250`) — so posting the stripped prose would permanently delete
            // this turn's drafted document and every citation token from the server's copy.
            var answer = ChatMessage(role: .assistant, content: live.persistableContent)
            // The panel moves onto the answer, as the web's does (`streamManager.js` builds the
            // finished message with it). From here it is drawn from the answer — exactly as it
            // will be when the conversation is reopened — and it travels with the history the
            // next question posts, which `/chat` stores as sent.
            let finished = progress.settled(ended: ended)
            if !finished.isEmpty {
                answer.attachWorkLog(WorkLogWire.fields(
                    for: finished,
                    seconds: Int(Date().timeIntervalSince(turnStartedAt ?? Date())),
                    ended: ended))
                progress = ReasoningSnapshot()
            }
            messages.append(answer)
            answered = true
        }
        live = nil
        status = nil
        isStreaming = false
        streamTask = nil
        return answered
    }

    // MARK: - Storing the work log

    /// Stores the work log of the turn that just finished, if — and only if — that is safe.
    ///
    /// The web stores its log by posting the whole conversation to `/sync` when a turn ends.
    /// `/sync` deletes every stored message and re-inserts what it is sent, so the conditions are
    /// the point; `WorkLogSync` has the full account. Checked here, in order:
    ///
    /// - this turn ended cleanly and appended an answer carrying a log;
    /// - the conversation was loaded whole (`historyIsIntact`) — otherwise what is on screen is
    ///   not what is stored;
    /// - `/stream-status` answered, without error, that nothing is running — a run's checkpoint
    ///   would be deleted by the rewrite, and its own final save would overwrite the log anyway.
    ///
    /// The service then checks the stored conversation against this one, and asks
    /// `isUnchanged(count:lastID:)` once more immediately before sending. Every way out is
    /// silent: the answer is stored by `/chat` regardless, and the log still travels with the
    /// next question's history.
    private func saveWorkLog(answered: Bool, status: StreamStatus?) {
        guard answered, let answer = messages.last, answer.role == .assistant else {
            workLogSave = .skipped(.noAnswer)
            return
        }
        guard answer.hasWorkLog else {
            workLogSave = .skipped(.nothingToSave)
            return
        }
        guard historyIsIntact, !isShowingSavedCopy else {
            workLogSave = .skipped(.historyNotIntact)
            return
        }
        guard let status, status.error == nil else {
            workLogSave = .skipped(.statusUnknown)
            return
        }
        guard !status.active else {
            workLogSave = .skipped(.runStillActive)
            return
        }

        let fields = answer.extra.filter { WorkLogWire.keys.contains($0.key) }
        let transcript = messages
        let count = messages.count
        let lastID = answer.stableID
        let service = self.service
        let chatID = self.chatID
        saveTask = Task {
            let outcome = await service.saveWorkLog(
                fields, transcript: transcript, chatID: chatID,
                commit: { [weak self] in
                    await self?.isUnchanged(count: count, lastID: lastID) ?? false
                })
            self.workLogSave = outcome
        }
    }

    /// Whether the conversation is still exactly the one the save was prepared from: no turn
    /// streaming, nothing appended, removed or edited, and still known to be whole.
    ///
    /// Every new turn also appends its question, so the count alone would catch one; streaming is
    /// checked as well so that this does not rest on how `send` happens to be written.
    private func isUnchanged(count: Int, lastID: String) -> Bool {
        !isStreaming && historyIsIntact && !isShowingSavedCopy
            && messages.count == count && messages.last?.stableID == lastID
    }

    /// Waits for a work-log save still on its way. For tests, which otherwise cannot tell a save
    /// that has not happened yet from one that never will.
    func settleWorkLogSave() async {
        await saveTask?.value
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
        // The transcript's own documents after the composer's: a citation names a file some turn
        // carried, and the transcript knows its folder exactly. This is also what lets a citation
        // open from a saved copy with no connection, when the library cannot be fetched.
        let transcript = messages.attachedDocuments.filter { !attachments.contains($0) }
        guard let attachment = CitationResolver.resolve(
            mention, attachments: attachments + transcript, files: libraryCache)
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
