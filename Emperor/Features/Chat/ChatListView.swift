import SwiftUI

/// The conversations, newest first, and the way into each.
///
/// On a phone a conversation is pushed over the list. At a regular width — an iPad — the list is
/// a column of its own and the conversation opens beside it (`ListBesideDetail`), the open one's
/// row tinted; choosing another, or starting a new one, replaces the conversation in that column.
/// Both read the one `path` (see `ListDetailPath`), so what was open survives the screen changing
/// width. A phone never draws the split.
struct ChatListView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var model: ChatListViewModel?
    /// One navigation path rather than a `for:` destination plus an `item:` destination.
    /// Registering two destinations for the same type — which `String` was — makes SwiftUI warn
    /// about a duplicate and lets one shadow the other.
    @State private var path: [String] = []
    @State private var isShowingSettings = false
    @State private var isShowingDrafts = false

    var body: some View {
        if isBesideDetail {
            ListBesideDetail(detailID: path.last) {
                conversationsScreen
            } detail: {
                if let chatID = path.last {
                    // No "New chat" of its own: the list's is beside it, and two of the same
                    // button on one screen is one too many. Each finished answer refreshes the
                    // list, so a conversation started here appears in it, at the top.
                    ChatThreadView(chatID: chatID, onTurnFinished: {
                        Task { await model?.load() }
                    })
                } else {
                    DetailPlaceholder(placeholder: ListDetailPath.placeholder(
                        ListDetailPath.chooseConversation, beside: model?.presentation))
                }
            }
        } else {
            NavigationStack(path: $path) {
                conversationsScreen
                    .navigationDestination(for: String.self) { chatID in
                        ChatThreadView(chatID: chatID, onStartNewChat: { startNewChat() })
                    }
            }
        }
    }

    /// The list in a column of its own, with the conversation beside it — a regular-width screen.
    private var isBesideDetail: Bool { sizeClass == .regular }

    /// Opens a new conversation.
    ///
    /// Replaces the path rather than pushing onto it. A new conversation is a move sideways, not
    /// a step deeper: pushed, Back would walk the user out through every chat they had opened
    /// this session instead of returning them to the list they came from — and beside the list,
    /// it would pile conversations up behind the one on screen.
    private func startNewChat() {
        path = [ChatListViewModel.newChatID()]
    }

    /// The conversation open beside the list, as the list's selection. A new conversation is in
    /// no row until its first turn is stored, so nothing is tinted while one is open.
    private var selectedChatID: Binding<String?> {
        Binding(
            get: { ListDetailPath.selection(in: path) },
            set: { path = ListDetailPath.selecting($0, in: path) })
    }

    /// The list itself, the same in both layouts: its title, toolbar, sheets and model.
    private var conversationsScreen: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Emperor")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startNewChat()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isShowingSettings = true
                } label: {
                    Label("Settings", systemImage: "person.crop.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // A draft is the product of a chat, so this is where someone comes looking
                // for one — without having to remember which conversation produced it.
                Button {
                    isShowingDrafts = true
                } label: {
                    Label("Your drafts", systemImage: "doc.text")
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
                .pageSizedSheet()
        }
        .sheet(isPresented: $isShowingDrafts) {
            DraftHistoryView()
                .pageSizedSheet()
        }
        .task {
            guard model == nil else { return }
            let created = ChatListViewModel(
                service: session.chats, cache: session.cache)
            model = created
            await created.load()
        }
    }

    private func content(_ model: ChatListViewModel) -> some View {
        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            Group {
                if isBesideDetail {
                    List(selection: selectedChatID) {
                        recent(model)
                    }
                } else {
                    List {
                        recent(model)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .refreshable { await model.load() }
        } empty: {
            EmptyStateView(
                "No conversations yet",
                systemImage: "bubble.left.and.bubble.right",
                message: "Start one, or bring in a paperbook to ask about.") {
                Button {
                    startNewChat()
                } label: {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                .buttonStyle(.primaryAction)
            }
        }
    }

    /// The conversations. Each link carries the conversation's id, which a phone pushes and the
    /// list beside the detail takes as its selection.
    private func recent(_ model: ChatListViewModel) -> some View {
        Section {
            ForEach(model.chats) { chat in
                let isOpen = isBesideDetail && path.last == chat.id
                NavigationLink(value: chat.id) {
                    row(for: chat)
                }
                .accessibilityIdentifier("chat-row-\(chat.id)")
                .accessibilityAddTraits(isOpen ? .isSelected : [])
                // On the row rather than the section, so the open conversation's can differ.
                .listRowBackground(ListRowCard(isSelected: isOpen))
            }
        } header: {
            SectionHeader(title: "Recent", detail: "\(model.chats.count)")
        }
    }

    /// The title, when it was last touched, and a line of what was said — the order a mail list
    /// reads in, so the eye finds the matter first and the date beside it.
    private func row(for chat: ChatSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // The date under the title at the accessibility sizes, where beside it the title
            // would be cut to a word. Not combined into one element: the tests find a
            // conversation by its title's text.
            AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(chat.displayTitle)
                    .font(.brand(.headline))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(1)
                Spacer(minLength: Spacing.sm)
                if let updated = chat.updatedAt {
                    Text(updated, format: .relative(presentation: .named))
                        .font(.brand(.caption))
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            if let preview = chat.lastPreview, !preview.isEmpty {
                Text(preview)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
                    .dynamicLineLimit(2)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}
