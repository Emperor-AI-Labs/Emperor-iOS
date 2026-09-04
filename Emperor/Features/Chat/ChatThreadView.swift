import SwiftUI

struct ChatThreadView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    @State private var model: ChatViewModel?
    /// Owns the composer's text as well as the rewrite over it — see the type's own note on
    /// why that cannot live in a `@State` binding.
    @State private var composer: PromptEnhancerViewModel?
    @State private var isScanning = false
    @State private var isBrowsingFiles = false
    @State private var isFillingBlanks = false
    @State private var isReporting = false
    @State private var editing: ChatMessage?
    @State private var editText = ""

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
        .task {
            guard model == nil else { return }
            let created = ChatViewModel(
                chatID: chatID,
                service: session.chats,
                files: session.files,
                uploads: session.uploads,
                preferredModel: session.currentUser?.preferredModel)
            composer = PromptEnhancerViewModel(service: session.enhancer)
            model = created
            await created.load()

            // After `load()`, never before. `POST /chat` stores exactly the messages the
            // request carried and deletes the rest, so sending against a thread whose history
            // has not been read would erase it. `ChatViewModel` gates on `historyIsIntact` for
            // this reason — a new conversation has nothing to lose, but this path must not be
            // the one place that assumes so.
            if let seed, !seed.isEmpty {
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
                        // answer below is about to rest on.
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
                                tint: .orange)
                        }

                        if let busy = model.busyNotice {
                            Notice(icon: "clock", text: busy, tint: .secondary)
                        }

                        // A send that failed outright. Shown in the transcript rather than as
                        // an alert: the question is still in the composer's history above, and
                        // the useful next act is to send it again.
                        // Why the composer is disarmed. Shown next to the load failure that
                        // caused it, because the two are one situation and separating them
                        // would leave the user with a dead composer and no explanation.
                        if let blocked = model.sendBlockedReason {
                            Notice(
                                icon: "exclamationmark.triangle",
                                text: blocked,
                                tint: .orange)
                        }

                        if let error = model.errorMessage {
                            Notice(
                                icon: "exclamationmark.circle",
                                text: error,
                                tint: .red)
                        }
                    }
                    .padding()
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

            composerBar(model)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                settingsMenu(model)
            }
        }
        .sheet(isPresented: $isScanning) {
            DocumentScannerView { result in
                isScanning = false
                switch result {
                case .success(let document):
                    Task { await model.attach(document) }
                case .failure(let error):
                    model.reportScanFailure(error)
                }
            }
            .ignoresSafeArea()
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
                model.attachments = chosen
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
    }

    /// Presents an optional message as an alert, and clears it when the alert is dismissed by
    /// any route — not only the OK button.
    private func alertBinding(_ message: Binding<String?>) -> Binding<Bool> {
        Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } })
    }

    /// Mode and persona.
    ///
    /// Both are per-request and neither is plan-gated — a Lite account may select Thinking,
    /// which the platform is explicit about being a default rather than a restriction.
    private func settingsMenu(_ model: ChatViewModel) -> some View {
        Menu {
            Picker("Mode", selection: Binding(
                get: { model.model },
                set: { model.model = $0 }
            )) {
                ForEach(ChatModel.allCases) { choice in
                    Text("\(choice.label) — \(choice.detail)").tag(choice)
                }
            }

            Picker("Acting as", selection: Binding(
                get: { model.role },
                set: { model.role = $0 }
            )) {
                ForEach(ChatRole.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }

            Divider()

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
            Label(model.model.label, systemImage: "slider.horizontal.3")
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

        return VStack(spacing: 8) {
            if let notice = composer.failureNotice {
                // The server answers 200 with an empty body on every one of its own error
                // paths, so without saying so a failed rewrite is a button that did nothing.
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    Text(notice)
                    Spacer(minLength: 0)
                    Button("Dismiss") { composer.dismissFailure() }
                        .font(.brand(.caption, weight: .semibold))
                }
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal)
                .transition(.opacity)
            }

            if composer.canUndo {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                    Button(PromptEnhancerViewModel.Copy.undoButton) { composer.undo() }
                    Spacer(minLength: 0)
                    if composer.template != nil {
                        Button(PromptEnhancerViewModel.Copy.fillTitle) { isFillingBlanks = true }
                            .font(.brand(.caption, weight: .semibold))
                    }
                }
                .font(.brand(.caption))
                .foregroundStyle(theme.accentText)
                .padding(.horizontal)
            }

            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.attachments, id: \.name) { attachment in
                            Button {
                                model.attachments.removeAll { $0 == attachment }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "doc")
                                    Text(DisplayText.fileName(attachment.name))
                                        .lineLimit(1)
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(theme.textSecondary)
                                }
                                .font(.brand(.caption))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(theme.surfaceElevated, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "Remove \(DisplayText.fileName(attachment.name)) from this question")
                        }
                    }
                    .padding(.horizontal)
                }
            }

            HStack(spacing: 10) {
                Menu {
                    Button {
                        isBrowsingFiles = true
                    } label: {
                        Label("Attach from documents", systemImage: "folder")
                    }
                    Button {
                        isScanning = true
                    } label: {
                        Label("Scan a paperbook", systemImage: "doc.viewfinder")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.brand(.title3))
                }
                .accessibilityLabel("Attach a document")
                .disabled(model.isStreaming)

                TextField("Ask about this matter…", text: $composer.text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .disabled(composer.isEnhancing)

                // Dictation and a thumb keyboard both produce exactly the rough prompts this
                // rewrites, which is why it earns a place in a crowded bar on a phone.
                Button {
                    composer.attachments = model.attachments
                    composer.enhance()
                } label: {
                    if composer.isEnhancing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.sparkles").font(.brand(.title3))
                    }
                }
                .accessibilityLabel(
                    composer.isEnhancing
                        ? PromptEnhancerViewModel.Copy.running
                        : PromptEnhancerViewModel.Copy.button)
                .disabled(!composer.canEnhance || model.isStreaming)

                if model.isStreaming {
                    Button {
                        model.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.brand(.title2))
                    }
                    .accessibilityLabel("Stop this answer")
                } else {
                    Button {
                        model.send(composer.text)
                        composer.clear()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.brand(.title2))
                    }
                    .accessibilityLabel("Send")
                    .disabled(
                        composer.isEnhancing
                            || model.sendBlockedReason != nil
                            || composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(theme.surface)
        .animation(.easeOut(duration: 0.15), value: composer.canUndo)
        .animation(.easeOut(duration: 0.15), value: composer.failureNotice)
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
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}

// MARK: - Pieces

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
    private func exportedPDF() -> URL? {
        let data = AnswerPDF.render(html: StreamContent.parse(message.content).prose)
        return ShareableFile.url(for: data, named: AnswerPDF.fileName())
    }

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.content)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
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
}

private struct AnswerView: View {
    let content: StreamContent
    let isStreaming: Bool
    var onSelectCitation: (AnnexureMention) -> Void = { _ in }
    @State private var openArtifact: StreamArtifact?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !content.prose.isEmpty {
                Text(content.prose)
                    .textSelection(.enabled)
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
                Notice(icon: "exclamationmark.circle", text: error, tint: .red)
            }

            if content.wasInterrupted {
                Notice(
                    icon: "exclamationmark.triangle",
                    text: "This answer was interrupted before it finished.",
                    tint: .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $openArtifact) { artifact in
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
        HStack(spacing: 12) {
            Image(systemName: artifact.kind == .canvas ? "doc.text" : "tablecells")
                .font(.brand(.title3))
                .foregroundStyle(theme.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.title)
                    .font(.brand(.subheadline, weight: .semibold))
                    .lineLimit(2)
                Text(artifact.kind == .canvas ? "Document" : "Table")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.brand(.caption))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.brand(.footnote))
        .foregroundStyle(tint)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
