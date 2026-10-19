import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What became of an attempt to store an edited draft.
enum DraftEditSaveOutcome: Equatable, Sendable {
    /// The conversation on the server now carries the edit. `rowUpdated` says whether the Drafts
    /// row the draft was filed under was rewritten in place as well (`POST /save-document`).
    case saved(rowUpdated: Bool)
    /// The edit is in this conversation on the phone — every later question carries it, and
    /// `/chat` stores what it is sent — but it was not written to the server now.
    case kept(DraftEditKeptReason)
    /// A request went and did not come back as a success. Worth retrying.
    case failed
}

/// Why an edit was kept in the conversation rather than written straight away.
enum DraftEditKeptReason: Equatable, Sendable {
    /// This screen has nowhere to store it from.
    case unavailable
    case signedOut
    /// The conversation on screen is not known to be the whole conversation, or is a saved copy.
    case historyNotIntact
    /// A turn is being written on this conversation.
    case runStillActive
    /// The chat is not in `/chats`, so its title, role and model are unknown.
    case chatNotListed
    /// The stored messages could not be read back byte for byte.
    case unreadable
    /// The server holds more messages than this client knows about.
    case serverHasMore
    /// The server holds fewer.
    case serverHasFewer
    /// A stored message is not the one this client holds — changed elsewhere.
    case transcriptDiffers(at: Int)
    /// The conversation moved on here before the write could go.
    case conversationChanged
}

/// One edit, ready to store.
struct DraftEditSaveRequest: Equatable, Sendable {
    let chatID: String
    /// The conversation as the server is believed to hold it — the turn being edited still
    /// carrying the text it was stored with. What a fresh read must match, message for message.
    let storedTranscript: [ChatMessage]
    /// The assistant turn the edit was folded into.
    let index: Int
    /// That turn's content with the edit in place.
    let editedContent: String
}

protocol DraftEditSaving: Sendable {
    /// Stores one folded edit. Never throws; see `DraftEditService` for when it declines.
    ///
    /// - Parameter commit: asked immediately before anything is written; `false` abandons it.
    ///   The view model answers whether the conversation is still exactly as it was.
    func save(
        _ edit: DraftEditSaveRequest, commit: @escaping @Sendable () async -> Bool
    ) async -> DraftEditSaveOutcome
}

/// The two rules that make writing an edited conversation back safe — the same discipline as
/// `WorkLogSync`, whose account of `/sync` applies here word for word.
enum DraftEditSync {

    /// Whether the stored conversation is exactly `local`, message for message. Nil means it is.
    static func mismatch(server: [ChatMessage], local: [ChatMessage]) -> DraftEditKeptReason? {
        // The in-flight checkpoint is a row of its own; a rewrite would delete it from under a run.
        if server.contains(where: { $0.isTyping == true }) { return .runStillActive }
        if server.count > local.count { return .serverHasMore }
        if server.count < local.count { return .serverHasFewer }
        for index in server.indices
        where server[index].role != local[index].role || server[index].content != local[index].content {
            return .transcriptDiffers(at: index)
        }
        return nil
    }

    /// The `/sync` body: this one chat, its row echoed back as `/chats` listed it, and its
    /// messages as the stored bytes — every one untouched but the edited turn, whose `content`
    /// alone is replaced. Nothing is decoded and re-encoded, so attachments, citations, the work
    /// log and any field this build does not know go back as they were stored.
    static func body(
        userID: String, chat: ChatSummary, storedMessages: [Data], index: Int, content: String
    ) -> Data? {
        guard storedMessages.indices.contains(index) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let value = try? encoder.encode(content),
              let edited = RawJSON.replacingMember("content", with: value, inObject: storedMessages[index])
        else { return nil }

        struct Head: Encodable {
            let id: String
            let title: String?
            let role: String?
            let model: String?
            let updatedAt: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                // Explicit nulls, as `WorkLogSync` sends them: the server binds each straight
                // into its upsert, and null is the one value certain to bind.
                try c.encode(title, forKey: .title)
                try c.encode(role, forKey: .role)
                try c.encode(model, forKey: .model)
                try c.encode(updatedAt, forKey: .updatedAt)
            }
            enum CodingKeys: String, CodingKey { case id, title, role, model, updatedAt }
        }
        guard let head = try? encoder.encode(Head(
                  id: chat.id, title: chat.title, role: chat.role, model: chat.model,
                  updatedAt: chat.updatedAtRaw)),
              head.last == UInt8(ascii: "}"),
              let user = try? encoder.encode(userID)
        else { return nil }

        var messages = Data("[".utf8)
        for (position, stored) in storedMessages.enumerated() {
            if position > 0 { messages.append(UInt8(ascii: ",")) }
            messages.append(position == index ? edited : stored)
        }
        messages.append(UInt8(ascii: "]"))

        var body = Data(#"{"userId":"#.utf8)
        body.append(user)
        body.append(Data(#","chats":["#.utf8))
        body.append(head.dropLast())
        body.append(Data(#","messages":"#.utf8))
        body.append(messages)
        body.append(Data("}]}".utf8))
        return body
    }
}

extension RawJSON {
    /// `object` with the value of its one member `key` replaced by `value`, every other byte as
    /// it was. Nil when `object` is not a JSON object, or holds `key` other than exactly once.
    static func replacingMember(_ key: String, with value: Data, inObject object: Data) -> Data? {
        let bytes = [UInt8](object)
        var scanner = Scanner(bytes: bytes)
        scanner.skipWhitespace()
        guard scanner.peek == UInt8(ascii: "{") else { return nil }
        scanner.index += 1
        var found: [Range<Int>] = []
        while true {
            scanner.skipWhitespace()
            if scanner.peek == UInt8(ascii: "}") { scanner.index += 1; break }
            guard let keyRange = scanner.string() else { return nil }
            scanner.skipWhitespace()
            guard scanner.peek == UInt8(ascii: ":") else { return nil }
            scanner.index += 1
            scanner.skipWhitespace()
            guard let valueRange = scanner.value() else { return nil }
            if (try? JSONDecoder().decode(String.self, from: Data(bytes[keyRange]))) == key {
                found.append(valueRange)
            }
            scanner.skipWhitespace()
            if scanner.peek == UInt8(ascii: ",") { scanner.index += 1; continue }
            if scanner.peek == UInt8(ascii: "}") { scanner.index += 1; break }
            return nil
        }
        scanner.skipWhitespace()
        guard scanner.index == bytes.count, found.count == 1, let range = found.first,
              (try? JSONDecoder().decode(JSONValue.self, from: value)) != nil
        else { return nil }
        var result = Data(bytes[..<range.lowerBound])
        result.append(value)
        result.append(contentsOf: bytes[range.upperBound...])
        return result
    }
}

/// Stores an edited draft: the conversation through a guarded `POST /sync`, and the draft's own
/// row in the Drafts list through `POST /save-document` with that row's id.
///
/// ## Why both, and in this order
///
/// The web's chat surface writes an edit into the assistant message and syncs the conversation
/// (`saveDocEdit` → `persistAssistantSession`). The server re-derives the Drafts row from every
/// assistant message on every write (`setMessages`), recognising a draft it already holds by a
/// hash of its body — so an edited body, on its own, is filed as a new row beside the original.
/// The web's tool workspace avoids that by saving the edit over its own row by id
/// (`onDocEditCommit`). This does the same for a chat draft: the row the original body was filed
/// under is found by reading it back (`GET /documents?chatId=`, then each candidate's content),
/// rewritten with the edited body exactly as the server would derive it
/// (`DraftEdit.storedDraft`) — and only then is the conversation synced, at which point the server
/// recognises the edited body as that same row instead of filing a second one.
///
/// ## When it declines
///
/// `/sync` deletes every stored message and re-inserts what it is sent, so this writes nothing
/// unless a fresh read of the conversation matches, message for message, what this client
/// believes the server holds — and the body sent is the stored bytes, with one turn's `content`
/// replaced (`DraftEditSync`). Declining is not a loss: the edit is in the conversation on the
/// phone, and the next question stores it with everything else.
struct DraftEditService: DraftEditSaving {
    let client: APIClient

    /// Short: the next question waits for a save that is on its way (see `ChatViewModel`).
    static let timeout: TimeInterval = 20
    /// How many of a chat's drafts are read back to find the one being edited.
    static let candidateLimit = 6

    func save(
        _ edit: DraftEditSaveRequest, commit: @escaping @Sendable () async -> Bool
    ) async -> DraftEditSaveOutcome {
        guard let credentials = await client.currentCredentials() else { return .kept(.signedOut) }
        do {
            var listing = try await client.makeRequest("GET", "/chats")
            listing.timeoutInterval = Self.timeout
            let (listData, listResponse) = try await client.perform(listing)
            guard (200..<300).contains(listResponse.statusCode),
                  let chats = try? JSONDecoder().decode(ChatListResponse.self, from: listData).chats,
                  let chat = chats.first(where: { $0.id == edit.chatID })
            else { return .kept(.chatNotListed) }

            var read = try await client.makeRequest("GET", "/messages", query: ["chatId": edit.chatID])
            read.timeoutInterval = Self.timeout
            let (data, response) = try await client.perform(read)
            guard (200..<300).contains(response.statusCode),
                  let stored = try? JSONDecoder().decode(MessagesResponse.self, from: data).messages,
                  let bytes = RawJSON.arrayElements(forKey: "messages", in: data),
                  bytes.count == stored.count
            else { return .kept(.unreadable) }

            // Already there: a write that landed but whose answer never came back.
            var withEdit = edit.storedTranscript
            if withEdit.indices.contains(edit.index) {
                withEdit[edit.index].content = edit.editedContent
                if DraftEditSync.mismatch(server: stored, local: withEdit) == nil {
                    return .saved(rowUpdated: false)
                }
            }
            if let mismatch = DraftEditSync.mismatch(server: stored, local: edit.storedTranscript) {
                return .kept(mismatch)
            }
            guard edit.storedTranscript.indices.contains(edit.index),
                  let body = DraftEditSync.body(
                      userID: credentials.userIDString, chat: chat, storedMessages: bytes,
                      index: edit.index, content: edit.editedContent)
            else { return .kept(.unreadable) }

            guard !Task.isCancelled, await commit() else { return .kept(.conversationChanged) }

            let rowUpdated = await updateDraftRow(
                chatID: edit.chatID, userID: credentials.userIDString,
                original: edit.storedTranscript[edit.index].content, edited: edit.editedContent)

            var write = try await client.makeRequest("POST", "/sync")
            write.setValue("application/json", forHTTPHeaderField: "Content-Type")
            write.httpBody = body
            write.timeoutInterval = Self.timeout
            // Not cancellable once committed: the next question waits for this, and that wait is
            // an ordering guarantee only if the request it waits for is the one that arrived.
            let client = self.client
            let sent = Task { try await client.perform(write) }
            let (reply, status) = try await sent.value
            guard (200..<300).contains(status.statusCode),
                  (try? JSONDecoder().decode(WriteResponse.self, from: reply))?.success == true
            else { return .failed }
            return .saved(rowUpdated: rowUpdated)
        } catch {
            return .failed
        }
    }

    // MARK: - The Drafts row

    private struct SaveDocumentBody: Encodable {
        let userId: String
        let id: String
        let title: String
        let content: String
        let type: String
        let source: String
        let chatId: String
    }

    private struct SaveDocumentReply: Decodable {
        let success: Bool?
        let id: String?
    }

    /// Rewrites the row the original body was filed under. Best effort: whatever happens, the
    /// conversation is synced afterwards, and the worst a miss costs is the second row the web's
    /// own chat path files.
    private func updateDraftRow(
        chatID: String, userID: String, original: String, edited: String
    ) async -> Bool {
        guard let before = DraftEdit.storedDraft(fromMessage: original),
              let after = DraftEdit.storedDraft(fromMessage: edited),
              DraftEdit.normalisedForMatch(before.content) != DraftEdit.normalisedForMatch(after.content),
              let rowID = await findRow(chatID: chatID, holding: before)
        else { return false }
        do {
            var request = try await client.makeRequest(
                "POST", "/save-document",
                body: SaveDocumentBody(
                    userId: userID, id: rowID, title: before.title, content: after.content,
                    type: after.declaredType,
                    // What `setMessages` filed it as. The web's tool workspace says "draft" for
                    // its own drafts; this row came from a conversation and stays one.
                    source: "chat", chatId: chatID))
            request.timeoutInterval = Self.timeout
            let (data, response) = try await client.perform(request)
            guard (200..<300).contains(response.statusCode),
                  let reply = try? JSONDecoder().decode(SaveDocumentReply.self, from: data)
            else { return false }
            return reply.success == true && reply.id == rowID
        } catch {
            return false
        }
    }

    /// The id of this chat's row whose body is `draft`'s, or nil. Read from the list the row is
    /// filed on (`/tables` for a table, `/documents` otherwise), titles matching first.
    private func findRow(chatID: String, holding draft: DraftEdit.StoredDraft) async -> String? {
        let path = DraftKind(rawValue: draft.resolvedType)?.path ?? DraftKind.document.path
        do {
            var request = try await client.makeRequest("GET", path, query: ["chatId": chatID])
            request.timeoutInterval = Self.timeout
            let (data, response) = try await client.perform(request)
            guard (200..<300).contains(response.statusCode),
                  let list = try? JSONDecoder().decode(DraftListResponse.self, from: data)
            else { return nil }
            let rows = (list.documents ?? list.tables ?? []).filter { ($0.chatID ?? chatID) == chatID }
            let titled = rows.filter { $0.title == draft.title }
            // Oldest first: the server keeps the oldest of identical rows, and the list is newest first.
            let candidates = (titled.isEmpty ? rows : titled).reversed().prefix(Self.candidateLimit)
            let wanted = DraftEdit.normalisedForMatch(draft.content)
            for row in candidates {
                var read = try await client.makeRequest("GET", "/documents/content", query: ["id": row.id])
                read.timeoutInterval = Self.timeout
                let (body, status) = try await client.perform(read)
                guard (200..<300).contains(status.statusCode),
                      let content = try? JSONDecoder().decode(DraftContentResponse.self, from: body).content
                else { continue }
                if DraftEdit.normalisedForMatch(content) == wanted { return row.id }
            }
            return nil
        } catch {
            return nil
        }
    }
}
