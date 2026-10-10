import SwiftUI

struct ChatThreadView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.practice) private var practice
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model: ChatViewModel?
    /// Owns the composer's text as well as the rewrite over it — see the type's own note on
    /// why that cannot live in a `@State` binding.
    @State private var composer: PromptEnhancerViewModel?
    @State private var isBrowsingFiles = false
    @State private var isFillingBlanks = false
    @State private var isReporting = false
    @State private var editing: ChatMessage?
    @State private var editText = ""
    /// The composer's keyboard. Lowered when a question is sent, so the answer has the screen.
    /// Nothing raises it again: tapping the field does that on its own, which is the behaviour
    /// the platform already gives a focusable field and the one a reader expects.
    @FocusState private var isComposerFocused: Bool
    /// The composer's round controls and the height of its field, scaled with Dynamic Type so
    /// the bar keeps its proportions at every text size.
    @ScaledMetric(relativeTo: .body) private var composerControl: CGFloat = 36
    /// How far a round control's 44-point target reaches past the circle drawn for it — given
    /// back with negative padding, so the target grows and the bar does not. Nothing once the
    /// circle itself is 44 points or more.
    private var composerSlack: CGFloat { max(0, (44 - composerControl) / 2) }

    let chatID: String
    /// An opening message to send as soon as the thread is ready.
    ///
    /// This is how a tool becomes a conversation: the form builds a prompt and hands it over.
    /// Sent rather than pre-filled, because the user has already pressed Run and these prompts
    /// run to tens of thousands of characters — dropping one into the composer would give them
    /// a wall of text to scroll past rather than an answer.
    ///
    /// Passed directly rather than through the navigation path. Android needed a file handoff
    /// for the same job because a 29,000-character route argument risks
    /// `TransactionTooLargeException`; a Swift `String` held in a view is just memory.
    var seed: String?

    /// The documents a new conversation's first question is about — chosen in Ask's composer, or
    /// a folder from Files. Attached before the seed is sent.
    var initialAttachments: [ChatAttachment] = []

    /// The answer mode the first question was asked in, chosen in Ask's composer.
    var initialModel: ChatModel?

    /// Leaves this conversation and opens a fresh one.
    ///
    /// The caller does it rather than this view, because only the caller knows what the new
    /// conversation should replace — this screen has no idea what it was pushed onto.
    ///
    /// Absent where there is nothing sensible to replace: a tool form pushes a thread of its
    /// own with no conversation list behind it, and the button is simply not offered there.
    var onStartNewChat: (() -> Void)?

    /// Told when an answer has finished arriving.
    ///
    /// For the list beside this conversation on an iPad. A new conversation exists server-side
    /// only once its first turn is stored, so without this the list next to it never showed it,
    /// and a conversation already listed kept its old preview and place. On a phone the list is
    /// not on screen, and nothing is passed.
    var onTurnFinished: (() -> Void)?

    var body: some View {
        Group {
            if let model {
                thread(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        // A pushed screen: the tab bar goes, as the design asks.
        .toolbar(.hidden, for: .tabBar)
        // The connection came or went: show the saved copy, or reload over it.
        .onReceive(NotificationCenter.default.publisher(for: .emperorConnectivityChanged)) { _ in
            guard let model else { return }
            Task { await model.connectivityChanged() }
        }
        .task {
            guard model == nil else { return }
            let created = ChatViewModel(
                chatID: chatID,
                service: session.chats,
                files: session.files,
                uploads: session.uploads,
                detached: StoredDetachedDocuments(store: Preferences.detachedDocuments),
                // This device's default answer mode, chosen under You, else the account's.
                preferredModel: AnswerModeDefault.stored(in: Preferences())?.rawValue
                    ?? session.currentUser?.preferredModel,
                // Kept for reading offline, and read back only when the server cannot be
                // reached — never sent. See `ChatViewModel.savedCopyAt`.
                offline: session.offlineCopies?.conversations,
                connectivity: AppConnectivity.current)
            // Asked for in the role the user practises in, and only that: the conversation
            // offers no role of its own to pick, so the one chosen in Settings governs every
            // answer. Without this every conversation would open as a litigator regardless of
            // who is asking.
            created.role = practice.role.wireRole
            composer = PromptEnhancerViewModel(service: session.enhancer)
            model = created
            await created.load()

            // After `load()`, never before. `POST /chat` stores exactly the messages the
            // request carried and deletes the rest, so sending against a thread whose history
            // has not been read would erase it. `ChatViewModel` gates on `historyIsIntact` for
            // this reason — a new conversation has nothing to lose, but this path must not be
            // the one place that assumes so.
            //
            // And only while the screen is still there. The history is read to the end even if
            // this task is cancelled (`uncancelledRead`), so a tool's prompt would otherwise go
            // out — and count against the plan — after the person had already backed out.
            if !initialAttachments.isEmpty, created.messages.isEmpty {
                created.setAttachments(initialAttachments)
            }
            if let initialModel { created.model = initialModel }
            if let seed, !seed.isEmpty, !Task.isCancelled {
                created.send(seed)
            }
        }
    }

    /// Says how much a re-answer throws away.
    ///
    /// Singular and plural are spelled out rather than "(s)" — this is the sentence standing
    /// between someone and losing six turns of work, and it should read like a person wrote it.
    static func discardWarning(count: Int) -> String {
        switch count {
        case 0, 1:
            return "This question will be answered again. Nothing else is affected."
        case 2:
            return "This question and the answer below it are replaced. That cannot be undone."
        default:
            return "This question and the \(count - 1) turns after it are replaced. That cannot be undone."
        }
    }

    private func thread(_ model: ChatViewModel) -> some View {
        @Bindable var model = model

        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.messages, id: \.stableID) { message in
                            // Explicit labels rather than trailing closures: both of these
                            // structs carry a private @State property, so the synthesised
                            // memberwise initialiser has a parameter after this one and
                            // trailing-closure matching gets subtle. Naming it is unambiguous.
                            MessageBubble(
                                message: message,
                                chatID: chatID,
                                canEdit: model.canEdit(message),
                                onEdit: {
                                    editing = message
                                    editText = message.content
                                },
                                onSelectCitation: { select($0, in: model) })
                                .id(message.stableID)
                        }

                        // Above the answer, as in the web client: it explains the work the
                        // answer below is about to rest on. Only while the turn runs — once the
                        // answer is in, the panel moves onto it and `MessageBubble` draws it, as
                        // it will when the conversation is reopened. It stays here only for a
                        // turn that produced no answer to carry it.
                        if model.isStreaming || !model.progress.isEmpty {
                            ReasoningPanel(
                                snapshot: model.progress,
                                isStreaming: model.isStreaming,
                                liveStatus: model.status)
                        }

                        if let live = model.live {
                            AnswerView(
                                content: live,
                                isStreaming: true,
                                onSelectCitation: { select($0, in: model) })
                                .id("live")
                        }

                        if model.wasInterrupted {
                            Notice(
                                icon: "exclamationmark.triangle",
                                text: "This answer was interrupted before it finished. Nothing above has been lost — send again to have it completed.",
                                tint: theme.warning)
                        }

                        if let busy = model.busyNotice {
                            Notice(icon: "clock", text: busy, tint: theme.textSecondary)
                        }

                        // A send that failed outright. Shown in the transcript rather than as
                        // an alert: the question is still in the composer's history above, and
                        // the useful next act is to send it again.
                        // Why the composer is disarmed. Shown next to the load failure that
                        // caused it, because the two are one situation and separating them
                        // would leave the user with a dead composer and no explanation.
                        // Not while the saved copy is on screen: the offline bar above the composer
                        // says why, calmly, and stays in sight.
                        if let blocked = model.sendBlockedReason, !model.isShowingSavedCopy {
                            Notice(
                                icon: "exclamationmark.triangle",
                                text: blocked,
                                tint: theme.warning)
                        }

                        if let error = model.errorMessage {
                            Notice(
                                icon: "exclamationmark.circle",
                                text: error,
                                tint: theme.danger)
                        }

                        // Declined on purpose — no plan, this month's questions used. Its own
                        // card rather than the red error above: nothing failed, and the question
                        // has been handed back to the composer.
                        if let refusal = model.refusal {
                            RefusalCard(refusal: refusal)
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.lg)
                    // A readable measure on an iPad or a phone held sideways: an answer set the
                    // full width of a 13-inch screen is a line nobody can follow back. On an
                    // iPad the composer below keeps the same measure, so the two line up.
                    .frame(maxWidth: ReadableWidth.measure)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.live?.prose) { scrollToBottom(proxy, model) }
                .onChange(of: model.messages.count) { scrollToBottom(proxy, model) }
                // The server refused before storing anything, so the question is handed back
                // rather than left as a bubble for a turn that exists nowhere.
                .onChange(of: model.restoredDraft) { _, restored in
                    guard let restored, let composer else { return }
                    if composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        composer.text = restored
                    }
                    model.restoredDraft = nil
                }
            }

            // Above the composer it explains, and outside the transcript so it cannot scroll away.
            if let notice = model.offlineNotice() {
                OfflineCopyBanner(
                    notice: notice, detail: model.sendBlockedReason,
                    isReloading: model.isLoading, retry: { await model.load() })
            }

            composerBar(model)
        }
        .toolbar {
            // Leading of the three, so the two that describe *this* conversation keep the
            // positions and the reasoning they already had.
            //
            // Conditional on a parameter rather than on state: it is fixed for the life of the
            // view, so this is not the toolbar item that appears and disappears — that is the
            // pattern SwiftUI handles badly, and this never toggles.
            if let onStartNewChat {
                ToolbarItem(placement: .primaryAction) {
                    // Not disabled while streaming, and it does not stop the answer. This is a
                    // shortcut for Back-then-New, so it must do neither more nor less than
                    // leaving the screen already does — an answer still arriving is stored by
                    // the server either way, and is there when the conversation is reopened.
                    Button(action: onStartNewChat) {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                optionsMenu(model)
            }
            // Trailing-most, as on the Android client.
            ToolbarItem(placement: .primaryAction) {
                documentsMenu(model)
            }
        }
        .alert("Ask this again?", isPresented: Binding(
            get: { editing != nil },
            set: { if !$0 { editing = nil } }
        )) {
            TextField("Your question", text: $editText, axis: .vertical)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Re-answer", role: .destructive) {
                if let message = editing {
                    model.edit(message, to: editText)
                }
                editing = nil
            }
        } message: {
            // The count, not a vague "this cannot be undone". Re-answering the third of eight
            // turns discards six, and because `POST /chat` stores exactly what it is sent they
            // go from the server too — so the number is the whole reason to ask.
            if let message = editing {
                Text(Self.discardWarning(count: model.discardCount(editing: message)))
            }
        }
        .sheet(isPresented: $isBrowsingFiles) {
            FileLibraryView(alreadyAttached: model.attachments) { chosen in
                model.setAttachments(chosen)
            }
        }
        .sheet(item: $model.openSource) { source in
            SourceDocumentView(attachment: source.attachment, mention: source.mention)
        }
        .alert("Scan failed", isPresented: alertBinding($model.scanError)) {
            Button("OK") { model.scanError = nil }
        } message: {
            Text(model.scanError ?? "")
        }
        .alert("Cannot open that source", isPresented: alertBinding($model.citationError)) {
            Button("OK") { model.citationError = nil }
        } message: {
            Text(model.citationError ?? "")
        }
        .onChange(of: model.isStreaming) { _, isStreaming in
            if !isStreaming { onTurnFinished?() }
            // The answer streams in above the composer VoiceOver was left on, so its end is
            // said. A failure or a refusal says itself, below.
            if !isStreaming, model.errorMessage == nil, model.refusal == nil {
                VoiceOver.announce("Answer finished")
            }
        }
        .onChange(of: model.errorMessage) { _, error in
            if let error { VoiceOver.announce(error) }
        }
        .onChange(of: model.refusal) { _, refusal in
            if let refusal { VoiceOver.announce(DisplayText.title(for: refusal)) }
        }
    }

    /// Presents an optional message as an alert, and clears it when the alert is dismissed by
    /// any route — not only the OK button.
    private func alertBinding(_ message: Binding<String?>) -> Binding<Bool> {
        Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } })
    }

    /// The documents this conversation is reading, behind the toolbar's document button.
    ///
    /// The full list, each row naming the matter as well as the file — which is what actually
    /// tells two documents apart. The strip above the composer shows names only, and only until
    /// the first question; this is the account that stays for the rest of the conversation.
    ///
    /// Removing lives here as well as on the chips, and here is the part that is not optional: the
    /// chips are gone once a question has been asked, so without this a conversation could gain
    /// documents and never lose one.
    private func documentsMenu(_ model: ChatViewModel) -> some View {
        Menu {
            if model.attachments.isEmpty {
                Text("No documents attached")
            } else {
                Section("In this conversation") {
                    ForEach(model.attachments, id: \.self) { attachment in
                        Button(role: .destructive) {
                            model.detach(attachment)
                        } label: {
                            Label(
                                DisplayText.attachmentTitle(attachment),
                                systemImage: "doc.text")
                        }
                    }
                }
            }

            Divider()

            Button {
                isBrowsingFiles = true
            } label: {
                Label("Attach from documents", systemImage: "folder")
            }
        } label: {
            // The count, not a bare icon. Before the first question the strip below carries it;
            // afterwards the strip is gone, and without a number here a question can be sent
            // against documents the user has forgotten are attached.
            //
            // An HStack rather than a `Label`, deliberately: a toolbar is free to render a Label
            // icon-only, and this number is the whole reason the control is here.
            HStack(spacing: 3) {
                Image(systemName: "paperclip")
                if !model.attachments.isEmpty {
                    Text("\(model.attachments.count)")
                        .monospacedDigit()
                }
            }
        }
        .accessibilityLabel(
            model.attachments.isEmpty
                ? "Documents in this conversation"
                : "Documents in this conversation, \(model.attachments.count) attached")
    }

    /// The conversation's less-used settings: searching the web, and reporting an answer.
    ///
    /// Quick and Thinking are not here — they sit in the composer, where they are always in
    /// sight (`AnswerModeSwitch`). Nor is a role: a conversation is asked for in the role the
    /// user practises in, set as it opens, and Settings is the one place that role is chosen.
    private func optionsMenu(_ model: ChatViewModel) -> some View {
        Menu {
            // "Search the web" rather than a switch labelled "web search": the server searches
            // on its own when the question looks like it needs it, so this can turn searching
            // ON but cannot turn it off. Wording that implied otherwise would be contradicted.
            Toggle(isOn: Binding(
                get: { model.webSearch },
                set: { model.webSearch = $0 }
            )) {
                Label("Always search the web", systemImage: "globe")
            }

            Divider()

            // Also offered here, not only on the bubble. The prose has
            // `.textSelection(.enabled)`, so a long press inside it starts a *selection* and
            // raises the system text menu rather than the bubble's context menu — which would
            // leave Report unreachable across most of the answer. It also belongs here on the
            // merits: the report carries a conversation id, not a message id, so it was never
            // really a per-message action.
            Button(role: .destructive) {
                isReporting = true
            } label: {
                Label("Report an answer", systemImage: "flag")
            }
        } label: {
            // A Label, so the bar may draw it as the bare icon and VoiceOver still names it.
            Label("More options", systemImage: "ellipsis.circle")
        }
        .sheet(isPresented: $isReporting) {
            ReportAnswerSheet(chatID: chatID)
        }
        .disabled(model.isStreaming)
    }

    @ViewBuilder
    private func composerBar(_ model: ChatViewModel) -> some View {
        if let composer {
            composerBar(model, composer)
        }
    }

    private func composerBar(
        _ model: ChatViewModel, _ composer: PromptEnhancerViewModel
    ) -> some View {
        @Bindable var composer = composer

        return VStack(spacing: Spacing.sm) {
            // Said before the question is typed, not after it is refused.
            if let standing = session.standing, model.refusal == nil {
                AccountStandingBanner(standing: standing)
                    .padding(.horizontal)
            }

            if let notice = composer.failureNotice {
                // The server answers 200 with an empty body on every one of its own error
                // paths, so without saying so a failed rewrite is a button that did nothing.
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .accessibilityHidden(true)
                    Text(notice)
                    Spacer(minLength: 0)
                    Button {
                        composer.dismissFailure()
                    } label: {
                        Text("Dismiss")
                            .font(.brand(.caption, weight: .semibold))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal)
                .transition(.opacity)
            }

            if composer.canUndo {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                        .accessibilityHidden(true)
                    // Each a line of text to the eye and a 44-point target to the thumb.
                    Button {
                        composer.undo()
                    } label: {
                        Text(PromptEnhancerViewModel.Copy.undoButton)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    Spacer(minLength: 0)
                    if composer.template != nil {
                        Button {
                            isFillingBlanks = true
                        } label: {
                            Text(PromptEnhancerViewModel.Copy.fillTitle)
                                .font(.brand(.caption, weight: .semibold))
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                    }
                }
                .font(.brand(.caption))
                .foregroundStyle(theme.accentText)
                .padding(.horizontal)
            }

            // The documents this question is about to carry, named until it has been asked.
            //
            // Gated on `openingAttachments`, which empties on the first send — see its note for
            // why the strip earns its line here and stops earning it immediately afterwards.
            // From then on the toolbar's document button is where they live.
            if !model.openingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.openingAttachments, id: \.self) { attachment in
                            Button {
                                model.detach(attachment)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(theme.accentText)
                                    Text(DisplayText.fileName(attachment.name))
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(theme.textTertiary)
                                }
                                .font(.brand(.caption, weight: .medium))
                                .padding(.horizontal, Spacing.sm + 2)
                                .padding(.vertical, 6)
                                .background(theme.surfaceElevated, in: Capsule())
                                .overlay(Capsule().strokeBorder(theme.separator, lineWidth: 1))
                                // Drawn as a small capsule, answering a touch across 44 points.
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "Remove \(DisplayText.fileName(attachment.name)) from this question")
                        }
                    }
                    .padding(.horizontal)
                }
            }

            // Next to the field, so the choice is in sight as the question is written and the
            // send button is pressed. Per conversation, seeded from the account's preferred
            // model, and never plan-gated: a Lite account may select Thinking, which the
            // platform is explicit about being a default rather than a restriction.
            //
            // Aligned with the attach button below it, so the switch and the bar read as one
            // composer rather than a control floating above it.
            AnswerModeSwitch(selection: model.model, onSelect: { model.model = $0 })
                .disabled(model.isStreaming)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.md)

            HStack(alignment: .bottom, spacing: Spacing.sm) {
                // Straight to the picker rather than a menu. Attaching from the library is what
                // the button is for in nearly every case, and the menu charged a tap for that to
                // offer scanning beside it — which the library already offers, under "Digitise
                // or translate".
                //
                // The one thing that changes: a scan used to land on the turn directly, and now
                // lands in the library to be picked from. A round trip, but through the screen
                // that was going to be opened anyway.
                Button {
                    isBrowsingFiles = true
                } label: {
                    Image(systemName: "plus")
                        .font(.brand(.body, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: composerControl, height: composerControl)
                        .background(theme.surfaceElevated, in: Circle())
                        .overlay(Circle().strokeBorder(theme.separator, lineWidth: 1))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-composerSlack)
                .accessibilityLabel("Attach a document")
                .disabled(model.isStreaming)
                .opacity(model.isStreaming ? 0.5 : 1)

                // The field and the rewrite button share one rounded well, as a message field
                // does — the wand acts on what is typed, so it sits with it.
                HStack(alignment: .bottom, spacing: Spacing.xs) {
                    TextField("Ask about this matter…", text: $composer.text, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .font(.brand(.body))
                        .foregroundStyle(theme.textPrimary)
                        .focused($isComposerFocused)
                        .disabled(composer.isEnhancing)
                        .padding(.vertical, Spacing.sm)
                        .padding(.leading, Spacing.md + 2)

                    // Dictation and a thumb keyboard both produce exactly the rough prompts this
                    // rewrites, which is why it earns a place in a crowded bar on a phone.
                    Button {
                        composer.attachments = model.attachments
                        composer.enhance()
                    } label: {
                        Group {
                            if composer.isEnhancing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "wand.and.sparkles")
                                    .font(.brand(.body, weight: .medium))
                            }
                        }
                        .foregroundStyle(theme.accentText)
                        .frame(width: composerControl, height: composerControl)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-composerSlack)
                    .accessibilityLabel(
                        composer.isEnhancing
                            ? PromptEnhancerViewModel.Copy.running
                            : PromptEnhancerViewModel.Copy.button)
                    .disabled(!composer.canEnhance || model.isStreaming)
                    .opacity(!composer.canEnhance || model.isStreaming ? 0.4 : 1)
                    .padding(.trailing, Spacing.xxs)
                }
                .frame(minHeight: composerControl)
                .background(
                    theme.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: composerControl / 2, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: composerControl / 2, style: .continuous)
                        .strokeBorder(
                            isComposerFocused ? theme.accentMuted : theme.separator,
                            lineWidth: 1))

                if model.isStreaming {
                    Button {
                        model.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.brand(.footnote, weight: .bold))
                            .foregroundStyle(theme.onAccent)
                            .frame(width: composerControl, height: composerControl)
                            .background(theme.accent, in: Circle())
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-composerSlack)
                    .accessibilityLabel("Stop this answer")
                } else {
                    let canSend = !(composer.isEnhancing
                        || model.sendBlockedReason != nil
                        || composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        // Lowered as the question goes, not when the answer finishes. The answer
                        // starts arriving at once and streams for seconds; on a phone the
                        // keyboard covers about half of where it lands, so waiting for the end
                        // would hide exactly the part the reader is waiting to read.
                        isComposerFocused = false
                        model.send(composer.text)
                        composer.clear()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.brand(.body, weight: .bold))
                            .foregroundStyle(canSend ? theme.onAccent : theme.textTertiary)
                            .frame(width: composerControl, height: composerControl)
                            .background(canSend ? theme.accent : theme.surfaceElevated, in: Circle())
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-composerSlack)
                    .accessibilityLabel("Send")
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.xs)
            .padding(.bottom, Spacing.sm)
        }
        // The conversation's measure, centred, so on an iPad the switch, the documents and the
        // field sit under the answer they belong to rather than running the width of the screen
        // — the send button a hand's span from the last line read. The bar behind them, and its
        // hairline, still span the screen. At a regular width only: a phone's composer is as it
        // was, held sideways too.
        .frame(maxWidth: ReadableWidth.cap(for: sizeClass))
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.sm)
        .background(theme.canvas)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separator).frame(height: 0.5)
        }
        // The lines above the field slide in and out; under Reduce Motion they are simply there.
        .animation(reduceMotion ? nil : Animation.easeOut(duration: 0.15), value: composer.canUndo)
        .animation(
            reduceMotion ? nil : Animation.easeOut(duration: 0.15), value: composer.failureNotice)
        // A failed rewrite lands above the field, away from the button that asked for it.
        .onChange(of: composer.failureNotice) { _, notice in
            if let notice { VoiceOver.announce(notice) }
        }
        // Offered rather than forced: a rewrite full of blanks is still sendable as it stands,
        // and the assistant is told by the {{LABEL}} itself what was left unspecified.
        .onChange(of: composer.template) { _, template in
            isFillingBlanks = template != nil
        }
        .sheet(isPresented: $isFillingBlanks) {
            if let template = composer.template {
                EnhancedPromptSheet(template: template) { answers in
                    composer.applyFilled(answers)
                }
            }
        }
    }

    private func select(_ mention: AnnexureMention, in model: ChatViewModel) {
        Task { await model.showSource(mention) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, _ model: ChatViewModel) {
        let target = model.live != nil ? "live" : model.messages.last?.stableID
        guard let target else { return }
        // Every streamed chunk scrolls; under Reduce Motion it jumps rather than glides.
        withAnimation(reduceMotion ? nil : Animation.easeOut(duration: 0.15)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}

// MARK: - Pieces

/// Quick or Thinking, just above the composer's field.
///
/// It used to be the first thing in the toolbar's menu, behind an icon — a reader had to know it
/// was there to find it, and it is the one setting that changes every answer. The web keeps its
/// own switch just above its composer as well (`ToolWorkspace.jsx:2131-2145`).
///
/// Two segments in one capsule rather than the system's segmented control: this sits among the
/// bar's round controls and rounded field, and a full-width segmented strip would outweigh the
/// question beneath it. The chosen segment is filled with the accent and the fill slides to the
/// other on a tap; the unchosen one is plain.
///
/// One control to VoiceOver, "Answer mode", whose options are buttons with the chosen one marked
/// selected — so the choice is heard rather than inferred from a colour.
private struct AnswerModeSwitch: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionSpace
    /// A segment's drawn height, scaled with its words — enough to know how far a 44-point target
    /// reaches past it at each text size. On the generous side, so the target never spills far
    /// past the track.
    @ScaledMetric(relativeTo: .footnote) private var segmentHeight: CGFloat = 30

    let selection: ChatModel
    let onSelect: (ChatModel) -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            track
                // Measured first, so the caption gets only what is left.
                .layoutPriority(1)

            // What the chosen mode does, while there is room for it. On a narrow phone at a
            // large text size the caption goes — never the switch. The fallback is a real
            // zero-size view rather than `EmptyView`, which a builder may drop altogether and
            // so leave the caption as the only, and therefore chosen, candidate.
            ViewThatFits(in: .horizontal) {
                Text(selection.detail)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                Color.clear.frame(width: 0, height: 0)
            }
            .accessibilityHidden(true)
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var track: some View {
        HStack(spacing: 0) {
            ForEach(ChatModel.allCases) { choice in
                segment(choice)
            }
        }
        .padding(3)
        .background(theme.surfaceElevated, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answer mode")
        .accessibilityIdentifier("answer-mode")
    }

    private func segment(_ choice: ChatModel) -> some View {
        let isSelected = choice == selection
        return Button {
            guard !isSelected else { return }
            withAnimation(reduceMotion ? nil : Animation.easeOut(duration: 0.18)) {
                onSelect(choice)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: Self.symbol(for: choice))
                    .imageScale(.small)
                Text(choice.label)
                    .lineLimit(1)
            }
            .font(.brand(.footnote, weight: .semibold))
            .foregroundStyle(isSelected ? theme.onAccent : theme.textSecondary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(theme.accent)
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                }
            }
            // Drawn as a slim pill; a 44-point target. The negative padding hands the extra back,
            // so the track keeps its height and the composer does not grow.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -max(0, (44 - segmentHeight) / 2))
        .accessibilityLabel(choice.label)
        .accessibilityHint(choice == .fast ? "Faster answers" : "Deeper reasoning; takes longer")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A bolt for speed; a brain for Thinking, which is the web's own icon for it.
    private static func symbol(for choice: ChatModel) -> String {
        switch choice {
        case .fast: return "bolt.fill"
        case .thinking: return "brain"
        }
    }
}

private struct MessageBubble: View {
    @Environment(\.theme) private var theme
    let message: ChatMessage
    var chatID: String?
    var canEdit = false
    var onEdit: () -> Void = {}
    var onSelectCitation: (AnnexureMention) -> Void = { _ in }

    @State private var isReporting = false

    /// The answer as a PDF on disk, ready to share.
    ///
    /// Built on demand rather than up front: laying out a page per bubble on every scroll would
    /// cost more than the feature is worth, and most answers are never exported.
    ///
    /// Bridged as markdown, which the answer is. Handed to the HTML engine raw, its line breaks
    /// collapsed — a References list came out as one run-on line, and every `##` and `**` as
    /// the characters themselves.
    private func exportedPDF() -> URL? {
        let prose = StreamContent.parse(message.content).prose
        let data = AnswerPDF.render(html: MarkdownHTML.answerFragment(prose))
        return ShareableFile.url(for: data, named: AnswerPDF.fileName())
    }

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                // The question in the accent's own wash with a hairline of it, so it reads as
                // the reader's side of the exchange without a slab of colour in a working
                // document. Corners like a message's, the one at the speaker's side tucked in.
                Text(message.content)
                    .font(.brand(.body))
                    .foregroundStyle(theme.textPrimary)
                    // Which side of the exchange this is shows only by position and colour; to
                    // VoiceOver it is said, as the value after the words. Not as a prefix to the
                    // label: a label longer than the text drawn reads to the audit as text cut off.
                    .accessibilityValue("Your question")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 18, bottomLeadingRadius: 18,
                            bottomTrailingRadius: 6, topTrailingRadius: 18,
                            style: .continuous)
                            .fill(theme.surfaceAccent))
                    .overlay(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 18, bottomLeadingRadius: 18,
                            bottomTrailingRadius: 6, topTrailingRadius: 18,
                            style: .continuous)
                            .stroke(theme.accentMuted, lineWidth: 0.5))
                    .contextMenu {
                        if canEdit {
                            Button {
                                onEdit()
                            } label: {
                                Label("Edit and ask again", systemImage: "pencil")
                            }
                        }
                        Button {
                            UIPasteboard.general.string = message.content
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
            }
        } else {
            // The same spacing the live panel has above a streaming answer, so the panel does not
            // shift when the finished turn moves onto its answer.
            VStack(alignment: .leading, spacing: 16) {
                // The work log stored with this answer — by this app or the web — collapsed, as
                // the live panel is once a run has finished. Nothing when none was stored.
                if let log = message.storedWorkLog {
                    ReasoningPanel(snapshot: log, isStreaming: false, liveStatus: nil)
                }
                answer
            }
        }
    }

    private var answer: some View {
        AnswerView(
            content: StreamContent.parse(message.content),
            isStreaming: false,
            onSelectCitation: onSelectCitation)
            // On the answer only. Reporting your own question would file a complaint about
            // something the model did not write.
            .contextMenu {
                Button {
                    // The parsed prose, not the raw content: the stored message still
                    // carries `<think>` and `<usage>` tags, and pasting those into an email
                    // to a client would be its own kind of bad day.
                    UIPasteboard.general.string = StreamContent.parse(message.content).prose
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if let url = exportedPDF() {
                    ShareLink(item: url) {
                        Label("Export as PDF", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    isReporting = true
                } label: {
                    Label("Report this answer", systemImage: "flag")
                }
            }
            .sheet(isPresented: $isReporting) {
                ReportAnswerSheet(chatID: chatID)
            }
    }
}

private struct AnswerView: View {
    @Environment(\.theme) private var theme
    let content: StreamContent
    let isStreaming: Bool
    var onSelectCitation: (AnnexureMention) -> Void = { _ in }
    @State private var openArtifact: StreamArtifact?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !content.prose.isEmpty {
                // Markdown, not plain text. The platform renders the reply through its own
                // Markdown component and says so (`ToolWorkspace.jsx:503`); drawn with a bare
                // `Text`, every heading, list and table in an answer arrived as the characters
                // that were meant to produce them.
                MarkdownContentView(markdown: content.prose, isStreaming: isStreaming)
            }

            if !content.mentions.isEmpty {
                CitationStrip(mentions: content.mentions, onSelect: onSelectCitation)
            }

            ForEach(content.artifacts) { artifact in
                Button {
                    openArtifact = artifact
                } label: {
                    ArtifactCard(artifact: artifact)
                }
                .buttonStyle(.plain)
            }

            ForEach(content.errors, id: \.self) { error in
                Notice(icon: "exclamationmark.circle", text: error, tint: theme.danger)
            }

            if content.wasInterrupted {
                Notice(
                    icon: "exclamationmark.triangle",
                    text: "This answer was interrupted before it finished.",
                    tint: theme.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Full screen, not a sheet. On an iPad a sheet is a centred form sheet a
        // fraction of the display, which is the wrong shape for reading a pleading —
        // and the one device where there is most room to give it.
        .fullScreenCover(item: $openArtifact) { artifact in
            ArtifactDetailView(artifact: artifact)
        }
    }
}

/// Drafts and chronologies are delivered as separate documents rather than inline prose,
/// so they get their own surface instead of being flattened into the transcript.
private struct ArtifactCard: View {
    @Environment(\.theme) private var theme
    let artifact: StreamArtifact

    var body: some View {
        HStack(spacing: Spacing.md) {
            // The same tile a document wears in Your drafts, so a draft looks like itself in
            // both places.
            IconTile(
                systemImage: artifact.kind == .canvas ? "doc.text" : "tablecells",
                hue: artifact.kind == .canvas ? .indigo : .teal,
                size: .large)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.title)
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(2)
                Text(artifact.kind == .canvas ? "Document" : "Table")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 0)
            RowChevron()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: Radius.control)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(artifact.kind == .canvas ? "Document" : "Table"): \(artifact.title)")
        .accessibilityHint("Opens full screen")
    }
}

private struct Notice: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: icon)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.brand(.footnote))
        .foregroundStyle(tint)
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tint.opacity(0.08),
            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
