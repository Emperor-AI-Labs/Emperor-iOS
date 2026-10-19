import SwiftUI

/// Where a matter's conversation opens: an existing one by its id, or a new one, which starts
/// with the matter's ready documents attached.
struct MatterChatRoute: Hashable, Identifiable {
    let chatID: String
    let isNew: Bool
    var id: String { chatID }
}

/// Ask Emperor, inside a matter: the matter's own conversations, newest first, and a new one.
///
/// A conversation opened here names the matter on every turn and reads only its documents — the
/// web's isolation rule (docs/projects.md). That is also why these are not in History.
struct MatterAskSection: View {
    @Environment(\.theme) private var theme

    let model: ProjectDetailViewModel
    let onOpen: (MatterChatRoute) -> Void

    var body: some View {
        Section {
            Button {
                onOpen(MatterChatRoute(chatID: ProjectDetailViewModel.newConversationID(), isNew: true))
            } label: {
                Label("New conversation", systemImage: "plus.bubble")
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.accentText)
            }

            if model.chats.isEmpty {
                Text("No conversations yet. Ask about this matter, and the conversation is kept here.")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.chats) { chat in
                    row(chat)
                }
            }
        } header: {
            SectionHeader(title: "Conversations", detail: model.chats.isEmpty ? nil : "\(model.chats.count)")
        } footer: {
            Label(ProjectDetailViewModel.conversationsLockLine, systemImage: "lock")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)
    }

    private func row(_ chat: ProjectChatRow) -> some View {
        Button {
            onOpen(MatterChatRoute(chatID: chat.id, isNew: false))
        } label: {
            HStack(spacing: Spacing.md) {
                IconTile(systemImage: "bubble.left.and.text.bubble.right")
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.displayTitle)
                        .font(.brand(.subheadline, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .dynamicLineLimit(2)
                    if let when = chat.lastActivity {
                        Text(DisplayText.relative(when))
                            .font(.brand(.caption2))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
                RowChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
