import SwiftUI

/// A conversation someone has shared, read-only — the web's `/share/:shareId` page.
///
/// The title, the role it was asked in and when it was last updated, then every question and
/// answer. Answers are drawn by `AnswerView`, the same view the conversation screen uses, each in
/// a framed card as the web frames them; a draft opens full screen as it does anywhere else.
/// Nothing here can be changed, continued or saved to the reader's account.
///
/// Opened from a link (`AppLinks`, `SharedChatPresenting`) and readable before anyone has signed
/// in, as the web page is.
struct SharedChatView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var model: SharedChatViewModel

    init(shareID: String, service: any SharedChatProviding) {
        _model = State(initialValue: SharedChatViewModel(shareID: shareID, service: service))
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.canvas.ignoresSafeArea())
                .navigationTitle("Shared conversation")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task {
            if model.state == .idle { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel("Loading the shared conversation")
        case .failed(let failure):
            if model.isNotFound {
                EmptyStateView(
                    SharedChatViewModel.notFoundTitle, systemImage: "link",
                    message: failure.message, tone: .neutral)
            } else {
                LoadFailureView(failure: failure, retry: { await model.load() })
            }
        case .loaded:
            if let conversation = model.conversation {
                SharedChatTranscript(conversation: conversation)
            }
        }
    }
}

/// The conversation itself, under its header.
private struct SharedChatTranscript: View {
    @Environment(\.theme) private var theme
    let conversation: SharedConversation

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                SharedChatHeader(conversation: conversation)
                if conversation.entries.isEmpty {
                    Text("This conversation has no messages.")
                        .font(.brand(.subheadline))
                        .foregroundStyle(theme.textTertiary)
                }
                ForEach(conversation.entries) { entry in
                    SharedChatTurn(entry: entry)
                }
                Text("Shared from Emperor. Read only — nothing here is saved to your account.")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Spacing.lg)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.lg)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The mark, the title, the role and the date.
private struct SharedChatHeader: View {
    @Environment(\.theme) private var theme
    let conversation: SharedConversation

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                RecordMarkView(height: 18)
                Text("Shared conversation")
                    .font(.brand(.footnote, weight: .semibold))
                    .foregroundStyle(theme.accentText)
            }
            Text(conversation.title)
                .font(.display(size: 28, relativeTo: .title))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            meta
        }
        .padding(.bottom, Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var meta: some View {
        if conversation.roleLabel != nil || conversation.updatedLabel != nil {
            AdaptiveStack(spacing: Spacing.md) {
                if let role = conversation.roleLabel {
                    Label(role, systemImage: "person")
                }
                if let updated = conversation.updatedLabel {
                    Label(updated, systemImage: "calendar")
                }
            }
            .font(.brand(.footnote))
            .foregroundStyle(theme.textSecondary)
        }
    }
}

/// One question or one answer.
private struct SharedChatTurn: View {
    @Environment(\.theme) private var theme
    let entry: SharedChatEntry

    var body: some View {
        switch entry.kind {
        case .question(let text, let attachments):
            SharedChatQuestion(text: text, attachments: attachments)
        case .answer(let content):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(title: "Emperor's answer")
                AnswerView(content: content, isStreaming: false)
                    .textSelection(.enabled)
                    .padding(Spacing.lg)
                    .panel(radius: Radius.card)
            }
        }
    }
}

/// The question as it was asked, on the right, with the documents it carried.
private struct SharedChatQuestion: View {
    @Environment(\.theme) private var theme
    let text: String
    let attachments: [String]

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.sm) {
            SectionHeader(title: "Question")
            if !text.isEmpty {
                Text(text)
                    .font(.brand(.body))
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .accessibilityValue("The question")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        theme.bubble,
                        in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, name in
                AttachmentChip(name: DisplayText.fileName(name))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }
}

// MARK: - Presenting a link

/// Shows the shared conversation a link asked for (`AppLinks.sharedChats`), over whatever the app
/// is showing — signed in or not, as the web page needs no account.
///
/// Applied by `RootView` around everything it draws. It waits for two things only: the
/// first-launch disclaimer (`isReady`), and for any sheet already up to close — iOS presents one
/// at a time and would drop this one, so it checks every third of a second, as Updates does
/// (`NotificationTapRouting`). The person's own sheet is never taken from them. A second link
/// while a shared conversation is open replaces it.
struct SharedChatPresenting: ViewModifier {
    let isReady: Bool

    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme
    @State private var shown: SharedChatSheet?

    /// What the sheet shows. Identified by the request, so the same link opened again after its
    /// sheet closed is a new sheet.
    struct SharedChatSheet: Identifiable {
        let id: Int
        let shareID: String
    }

    private struct Trigger: Hashable {
        let request: Int
        let isReady: Bool
    }

    func body(content: Content) -> some View {
        content
            .task(id: Trigger(request: AppLinks.sharedChats.requestCount, isReady: isReady)) {
                await presentWhenFree()
            }
            .sheet(item: $shown) { sheet in
                SharedChatView(shareID: sheet.shareID, service: session.sharedChats)
                    .environment(\.theme, theme)
            }
    }

    private func presentWhenFree() async {
        let requests = AppLinks.sharedChats
        guard isReady, requests.pending != nil else { return }
        if shown == nil {
            while requests.pending != nil, ModalPresentation.isShowingAnything {
                try? await Task.sleep(nanoseconds: 330_000_000)
                if Task.isCancelled { return }
            }
        }
        guard let shareID = requests.take() else { return }
        shown = SharedChatSheet(id: requests.requestCount, shareID: shareID)
    }
}

extension View {
    /// See `SharedChatPresenting`.
    func presentsSharedChats(isReady: Bool) -> some View {
        modifier(SharedChatPresenting(isReady: isReady))
    }
}
