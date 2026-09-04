import SwiftUI

struct ChatListView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    @State private var model: ChatListViewModel?
    /// One navigation path rather than a `for:` destination plus an `item:` destination.
    /// Registering two destinations for the same type — which `String` was — makes SwiftUI warn
    /// about a duplicate and lets one shadow the other.
    @State private var path: [String] = []
    @State private var isShowingSettings = false
    @State private var isShowingDrafts = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Emperor")
            .navigationDestination(for: String.self) { chatID in
                ChatThreadView(chatID: chatID)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        path.append(ChatListViewModel.newChatID())
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
            }
            .sheet(isPresented: $isShowingDrafts) {
                DraftHistoryView()
            }
            .task {
                guard model == nil else { return }
                let created = ChatListViewModel(
                    service: session.chats, cache: session.cache)
                model = created
                await created.load()
            }
        }
    }

    private func content(_ model: ChatListViewModel) -> some View {
        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List(model.chats) { chat in
                NavigationLink(value: chat.id) {
                    row(for: chat)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .refreshable { await model.load() }
        } empty: {
            ContentUnavailableView(
                "No conversations yet",
                systemImage: "doc.text",
                description: Text("Start one, or bring in a paperbook to ask about."))
        }
    }

    private func row(for chat: ChatSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chat.displayTitle)
                .font(.brand(.headline))
                .lineLimit(1)
            if let preview = chat.lastPreview, !preview.isEmpty {
                Text(preview)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }
            if let updated = chat.updatedAt {
                Text(updated, format: .relative(presentation: .named))
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
