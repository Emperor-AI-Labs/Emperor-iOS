import Foundation

/// Remembers which documents the user has taken off which conversation.
///
/// ## Why this has to exist at all
///
/// A conversation's documents are not a field on the chat. They live on the turns that carried
/// them, so every reopen reconstructs them from the transcript — see `attachedDocuments`. That
/// reconstruction has no way to tell "attached on turn one" from "attached on turn one and since
/// removed", so without a record of the removal the chip disappears and the document is back the
/// next time the conversation is opened.
///
/// There is nowhere else to write it. The server has no notion of a removal, and inventing one by
/// rewriting past turns would misstate what the model was actually given — those answers cite
/// those documents by page. So it is recorded on the device, per conversation, and the restore is
/// filtered through it.
///
/// ## The invariant
///
/// **A document is never both attached and detached.** Wrong in one direction and a document
/// cannot be got rid of; wrong in the other and it cannot be put back — remove a pleading, change
/// your mind, re-attach it, and the next reopen silently drops it again.
protocol DetachedDocuments: Sendable {
    func detached(inChat chatID: String) -> Set<ChatAttachment>
    func setDetached(_ attachments: Set<ChatAttachment>, inChat chatID: String)
}

/// The record, kept in a `PreferenceStore`.
struct StoredDetachedDocuments: DetachedDocuments {
    private let store: any PreferenceStore

    init(store: any PreferenceStore) {
        self.store = store
    }

    /// One key per conversation rather than one list for all of them.
    ///
    /// A read only ever concerns the conversation being opened, and a write only the one being
    /// edited, so a removal touches its own key instead of rewriting everybody else's. It also
    /// removes the question of what to do when a shared list grows — there is no shared list, and
    /// so no size at which somebody's removals would quietly start coming back.
    private func key(_ chatID: String) -> String { "chat.detached.v1.\(chatID)" }

    func detached(inChat chatID: String) -> Set<ChatAttachment> {
        guard let raw = store.string(for: key(chatID)),
              let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode([ChatAttachment].self, from: data)
        else { return [] }
        return Set(stored)
    }

    func setDetached(_ attachments: Set<ChatAttachment>, inChat chatID: String) {
        // Sorted before writing. A `Set` has no order, and an unordered encode would rewrite the
        // stored string on every save even when nothing changed.
        let ordered = attachments.sorted {
            ($0.name, $0.folderName ?? "") < ($1.name, $1.folderName ?? "")
        }
        guard let data = try? JSONEncoder().encode(ordered),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        store.setString(raw, for: key(chatID))
    }
}
