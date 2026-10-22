import SwiftUI

/// The Ask tab: a question starts here.
///
/// The reader's name greets them in the design's serif, then the design's own composer at the
/// middle of the screen — the mark in the box, Send carrying the question into a fresh
/// conversation — with the role's suggestions as rows beneath it. No date, no next sitting and no
/// recents: those live on Home (cause list, recents) and under More (History). A suggestion only
/// ever *fills* the composer; nothing sends until the reader sends it.
///
/// A question sent from here opens a new conversation and goes as soon as its history is ready —
/// the same path a tool's prompt takes (`ChatThreadView.seed`). Offline, nothing is sent and the
/// words stay in the composer.
struct AskHomeView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.practice) private var practice
    @Environment(\.navigator) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var path: [ChatRoute] = []
    @State private var text = ""
    @State private var attachments: [ChatAttachment] = []
    /// The answer mode chosen for this question, or `nil` for the default.
    @State private var chosenMode: ChatModel?
    @State private var isPickingFiles = false
    @State private var isChoosingMode = false
    @State private var isOffline = AppConnectivity.current.isOffline
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            // Centered while there is room; scrolls when the keyboard, a banner or a large text
            // size leaves none — the composer holds the middle either way.
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        notices

                        greeting
                            .padding(.horizontal, Spacing.gutter)
                            .padding(.top, Spacing.lg)

                        Spacer(minLength: Spacing.xl)

                        composer

                        suggestions
                            .padding(.top, Spacing.lg)

                        Spacer(minLength: Spacing.xl)
                    }
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.xxxl)
                    .frame(maxWidth: ReadableWidth.cap(for: sizeClass))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(minHeight: max(geometry.size.height - 24, 0))
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(theme.canvas)
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ChatRoute.self) { route in
                ChatThreadView(
                    chatID: route.id,
                    seed: route.seed,
                    initialAttachments: route.attachments,
                    initialModel: route.model,
                    onStartNewChat: { path = [ChatRoute(id: ChatListViewModel.newChatID())] },
                    onTurnFinished: {})
            }
            .sheet(isPresented: $isPickingFiles) {
                FileLibraryView(alreadyAttached: attachments) { chosen in
                    attachments = chosen
                }
            }
            .sheet(isPresented: $isChoosingMode) {
                AnswerModeSheet(selection: mode) { chosenMode = $0 }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .emperorConnectivityChanged)) { _ in
            isOffline = AppConnectivity.current.isOffline
        }
        // "Ask about it" from Matters, "Ask about this folder" from Files, Home's composer
        // sending its words across.
        .onAppear { takeQuestion() }
        .onChange(of: navigator.pendingQuestion) { _, _ in takeQuestion() }
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        if isOffline {
            OfflineStrip()
                .padding(.horizontal, Spacing.gutter)
        }
        if let standing = session.standing {
            AccountStandingBanner(standing: standing)
                .padding(.horizontal, Spacing.gutter)
        }
    }

    // MARK: - Greeting

    /// The reader's name, big, in the voice the app speaks in — New York, the serif everything
    /// the app *says* is set in. The first word of a name that is a name: an honorific is
    /// skipped, an email address is not used (`AskHome.firstName`). Falls back to the greeting
    /// alone when the account has no usable name.
    private var greeting: some View {
        Text(AskHome.greetingLine(
            hour: Calendar.current.component(.hour, from: Date()),
            name: session.currentUser?.name))
            .font(.serif(.largeTitle, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .accessibilityIdentifier("ask-greeting")
    }

    // MARK: - Composer

    private var mode: ChatModel {
        chosenMode ?? AnswerModeDefault.starting(feeTier: session.currentUser?.feeTier)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isOffline
            && session.standing == nil
    }

    private var composer: some View {
        RecordComposer(
            text: $text,
            placeholder: "Ask",
            attachments: attachments.map { DisplayText.fileName($0.name) },
            onRemoveAttachment: { index in
                guard attachments.indices.contains(index) else { return }
                attachments.remove(at: index)
            },
            model: mode,
            onChooseMode: { isChoosingMode = true },
            canSend: canSend,
            showsMark: true,
            onAttach: { isPickingFiles = true },
            onSend: send,
            focus: $composerFocused) {
                // The design's own row: rewrite and dictation. The buttons are drawn; the
                // wiring — the enhancer and Speech — is a later step, so both are no-ops yet.
                composerAccessory("wand.and.stars", label: "Rewrite", tint: theme.warning) {}
                composerAccessory("mic", label: "Dictate", tint: theme.textSecondary) {}
            }
            .padding(.horizontal, Spacing.gutter)
    }

    /// One of the composer's trailing stub buttons — gold for the wand, plain for the mic.
    private func composerAccessory(
        _ systemImage: String, label: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(theme.surface2, in: Circle())
                .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func send() {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Offline or refused, the words stay where they were written.
        guard !question.isEmpty, canSend else { return }
        composerFocused = false
        path.append(ChatRoute(
            id: ChatListViewModel.newChatID(), seed: question, attachments: attachments, model: mode))
        text = ""
        attachments = []
        chosenMode = nil
    }

    /// Puts a question in the composer — a suggestion, one asked for from another tab, or Home's
    /// own composer sending its words across with the answer mode chosen beside them.
    private func fill(_ prompt: String, attachments chosen: [ChatAttachment], model: ChatModel? = nil) {
        text = prompt
        if !chosen.isEmpty { attachments = chosen }
        chosenMode = model
        path = []
        composerFocused = true
    }

    private func takeQuestion() {
        guard let question = navigator.takePendingQuestion() else { return }
        fill(question.prompt, attachments: question.attachments, model: question.model)
    }

    // MARK: - Suggestions

    /// The role's questions as rows under the composer — each fills the box and waits.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(AskHome.suggestions(for: practice.role)) { suggestion in
                Button {
                    fill(suggestion.prompt, attachments: [])
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: suggestion.systemImage)
                            .imageScale(.small)
                            .foregroundStyle(theme.accentText)
                            .accessibilityHidden(true)
                        Text(suggestion.title)
                            .font(.brand(.body, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: Spacing.xs)
                        Image(systemName: "arrow.up.right")
                            .imageScale(.small)
                            .foregroundStyle(theme.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: Layout.listRow, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.recordRow)
                .panel()
                .accessibilityHint("Puts this question in the box above")
            }
        }
        .padding(.horizontal, Spacing.gutter)
    }
}

/// A conversation pushed on the Ask tab: an existing one by its id, or a new one with the question
/// that starts it.
struct ChatRoute: Hashable {
    let id: String
    var seed: String?
    var attachments: [ChatAttachment] = []
    var model: ChatModel?
}
