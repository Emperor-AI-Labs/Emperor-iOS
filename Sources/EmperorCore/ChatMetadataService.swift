import Foundation

/// Renaming a conversation, and why there is no caller for it yet.
///
/// ## The route
///
/// `POST /sync` is the only way to change a chat's title. It takes a list of whole chats and
/// upserts them, so renaming means sending the chat back with a new `title`.
///
/// ## Why nothing calls this
///
/// Two properties of that route combine badly, and neither is visible from the outside:
///
/// 1. **A short message list makes the server skip the chat entirely.** It compares the incoming
///    `messages.length` against the count it holds and, if the incoming list is shorter, moves
///    on — the sensible guard against a half-loaded client wiping a conversation. So sending
///    `{id, title}` with no messages, which is what a rename *ought* to be, silently does
///    nothing to any chat that has ever been used. The response is still `200 {success:true}`,
///    so the client cannot tell.
///
/// 2. **Sending the full history rewrites it.** Passing the messages through makes the server
///    delete every stored message for that chat and re-insert the client's own serialisation.
///    `ChatMessage` is a typed struct, so anything the server stores that this build does not
///    model is dropped on the way through.
///
/// Together: renaming a real conversation means destroying and rebuilding every message in it,
/// through a lossy model, in order to change a title. That is the wrong trade for a cosmetic
/// operation, and the failure it risks — a turn quietly missing a field, or a conversation
/// truncated — is exactly the kind this product cannot afford.
///
/// **Renaming an empty conversation is safe** and is what `rename` supports: no messages, so
/// nothing is rewritten and the guard is satisfied. It is also nearly useless, since the chats
/// worth naming are the ones with content.
///
/// ## What would change this
///
/// One server change: let `/sync` take a metadata-only update — skip the message rewrite when
/// `messages` is absent, rather than skipping the whole chat when it is short. Then a rename is
/// `{id, title}` and this ships as-is. Kept under test for that day.
///
/// ## Deletion
///
/// There is none. No route deletes a chat, and no SQL anywhere removes one. The web client's
/// "delete" removes the chat from its own in-memory store and syncs, and since `/sync` only
/// ever upserts, the server keeps it — it returns on the next load and never left any other
/// device.
///
/// This client does not copy that. A delete that does not delete is worse than no delete at
/// all, and on a product holding privileged client material, telling someone their conversation
/// is gone when it is still on the server is not a UI infelicity.
struct ChatMetadataService: Sendable {
    let client: APIClient

    enum RenameError: LocalizedError, Equatable {
        /// The conversation has messages, so a rename would rewrite them. See the type's notes.
        case wouldRewriteHistory(messageCount: Int)

        var errorDescription: String? {
            switch self {
            case .wouldRewriteHistory:
                return "This conversation cannot be renamed yet."
            }
        }
    }

    private struct SyncChat: Encodable {
        let id: String
        let title: String
        let role: String?
        let model: String?
        /// Always sent, always empty. Present because the server reads `.length` off it without
        /// a guard; absent, that is a `TypeError` rather than a skipped chat.
        let messages: [String]
        let updatedAt: String
    }

    private struct SyncBody: Encodable {
        let userId: String
        let chats: [SyncChat]
    }

    /// Renames a conversation that has no messages.
    ///
    /// - Throws: `RenameError.wouldRewriteHistory` when `messageCount` is greater than zero.
    ///   Refusing locally rather than sending is deliberate: the server would answer
    ///   `200 {success:true}` and change nothing, and a rename that reports success without
    ///   happening is worse than one that declines.
    func rename(
        chatID: String,
        to title: String,
        role: String?,
        model: String?,
        messageCount: Int,
        now: Date = Date()
    ) async throws {
        guard messageCount == 0 else {
            throw RenameError.wouldRewriteHistory(messageCount: messageCount)
        }

        let body = SyncBody(
            userId: try await requireUserID(),
            chats: [
                SyncChat(
                    id: chatID,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    role: role,
                    model: model,
                    messages: [],
                    updatedAt: Self.isoFormatter.string(from: now)),
            ])
        let request = try await client.makeRequest("POST", "/sync", body: body)
        let response = try await client.send(request, as: WriteResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }

    private func requireUserID() async throws -> String {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        return credentials.userIDString
    }

    /// `updated_at` orders the chat list, so it has to be a form the server's own ordering
    /// understands. Fractional seconds are included because two renames in the same second
    /// would otherwise tie.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
