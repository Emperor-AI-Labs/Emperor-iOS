import Foundation

/// What became of an attempt to store a turn's work log.
///
/// Never shown to anyone. The answer is already stored by `/chat` whatever happens here; the
/// only thing at stake is the log, so a save that does not happen is silent by design. The
/// reasons exist so the conditions can be tested one by one.
enum WorkLogSaveOutcome: Equatable, Sendable {
    case saved
    case skipped(WorkLogSaveSkip)
    /// The request went and did not come back as a success.
    case failed
}

enum WorkLogSaveSkip: Equatable, Sendable {
    /// Nothing worth storing: no plan, no steps, no reasoning.
    case nothingToSave
    /// The conversation never loaded, so the transcript is not known to be whole.
    case historyNotIntact
    /// `/stream-status` could not be read, or answered with an error.
    case statusUnknown
    /// A run is generating on this chat right now — this one or another device's.
    case runStillActive
    /// The turn did not end with an answer this client appended.
    case noAnswer
    /// Another turn began, or the transcript changed, before the save could go.
    case newTurnStarted
    /// The question this answer belongs to has no id to find it by.
    case noQuestionID
    /// The chat is not in `/chats`, so its title, role and model are unknown.
    case chatNotListed
    case signedOut
    /// The stored messages could not be read back byte for byte.
    case unreadable
    /// The server holds more messages than this client knows about.
    case serverHasMore
    /// The server holds fewer — an edit or a regenerate elsewhere.
    case serverHasFewer
    /// A message before the answer is not the one this client holds.
    case transcriptDiffers(at: Int)
    /// The question before the stored answer is not the one this client asked.
    case questionNotFound
    /// The stored answer is not a finished server run.
    case answerNotFinished
    /// The stored answer already carries a log; it is not overwritten.
    case alreadyHasLog
}

/// Storing a turn's work log the way the web does — `POST /sync` the moment the turn finishes —
/// under the conditions that make that safe for a client that is not the web.
///
/// ## Why the web can, and when this client could not
///
/// `/sync` either ignores a chat (its `messages` array is shorter than the count stored) or
/// **deletes every stored message and re-inserts the array it was given** (`setMessages`). The web
/// calls it at the end of every turn with the conversation it just sent plus the new answer. That
/// is safe for the web because at that moment, and only then, its array *is* what the server
/// holds: `/chat` stored exactly that history, `finalizeChatRun` appended exactly that answer and
/// cleared the in-flight checkpoint before the response ended, and the web keeps every field of
/// every message it loaded because it never parses them into anything narrower.
///
/// Each of those can fail for this client, and each is a condition here:
///
/// - **A turn still streaming** — this one, or another device's on the same chat. Its checkpoint
///   is a row of its own, which a rewrite deletes, and the run's own final save then overwrites
///   whatever was written. `/stream-status` must say nothing is running, and the stored messages
///   must carry no in-flight row.
/// - **A load that failed** — the transcript on screen is not the conversation. Gated by the
///   view model's `historyIsIntact`.
/// - **A conversation changed elsewhere** — a turn asked or edited on the web while this answer
///   was being written. The count guard catches a longer server copy but not an edit, which can
///   leave the server with the same count or fewer. So the stored messages are read fresh, and
///   every one before the answer must match this transcript, the question must be the one this
///   client sent (by its id), and the answer after it must be the server run's own.
/// - **Fields this client does not model** — attachments in either wire form, `sources`, `usage`,
///   another client's log, anything added later. The array posted back is built from the bytes
///   `GET /messages` just returned, element for element, with the three log keys added to the last
///   one only. Nothing is decoded and re-encoded, so nothing can be lost or reworded.
///
/// What remains is the time between reading the messages and the server receiving the rewrite —
/// one round trip. The app never lets its own next turn into that window (see `ChatViewModel`).
enum WorkLogSync {

    /// Whether the stored conversation is exactly this client's transcript, ending with the
    /// server's own copy of this client's latest answer. Nil means it is.
    ///
    /// - Parameter local: the transcript as this client holds it, ending with the question it
    ///   asked and the answer it was shown.
    static func mismatch(server: [ChatMessage], local: [ChatMessage]) -> WorkLogSaveSkip? {
        guard local.count >= 2, let answer = local.last, answer.role == .assistant,
              local[local.count - 2].role == .user
        else { return .noAnswer }
        guard let questionID = local[local.count - 2].id, !questionID.isEmpty
        else { return .noQuestionID }

        // The in-flight checkpoint is a row of its own; a rewrite would delete it from under a
        // run. `ChatService.messages` filters it for display, which is exactly why this checks
        // the unfiltered list.
        if server.contains(where: { $0.isTyping == true }) { return .runStillActive }
        if server.count > local.count { return .serverHasMore }
        if server.count < local.count { return .serverHasFewer }

        let last = local.count - 1
        for index in 0..<last
        where server[index].role != local[index].role || server[index].content != local[index].content {
            return .transcriptDiffers(at: index)
        }
        guard server[last - 1].id == questionID else { return .questionNotFound }

        let stored = server[last]
        let fromServerRun = stored.done == true || stored.extra["serverRun"] == .bool(true)
        guard stored.role == .assistant, fromServerRun else { return .answerNotFinished }
        guard !stored.hasWorkLog else { return .alreadyHasLog }
        return nil
    }

    /// The `/sync` body: this one chat, its row echoed back as `/chats` reported it, and its
    /// messages as the stored bytes with the log added to the last.
    ///
    /// The chat's `title`, `role` and `model` are written by `/sync` unconditionally, so they are
    /// sent back exactly as listed — the save must not rename the chat or change its mode. So is
    /// `updatedAt`, which orders History: storing a log is not activity, and must not move the
    /// conversation up the list. Should `/chats` not give one, the server stamps the time of the
    /// save — harmless straight after a turn, which has just put the chat at the top anyway.
    static func body(
        userID: String, chat: ChatSummary, storedMessages: [Data], adding fields: [String: JSONValue]
    ) -> Data? {
        guard var answer = storedMessages.last,
              let extended = RawJSON.appending(fields, keyOrder: WorkLogWire.keys, toObject: answer)
        else { return nil }
        answer = extended

        struct Head: Encodable {
            let id: String
            let title: String?
            let role: String?
            let model: String?
            let updatedAt: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                // Explicit nulls rather than omitted keys: the server binds each straight into
                // its upsert, and null is the one value certain to bind.
                try c.encode(title, forKey: .title)
                try c.encode(role, forKey: .role)
                try c.encode(model, forKey: .model)
                try c.encode(updatedAt, forKey: .updatedAt)
            }
            enum CodingKeys: String, CodingKey { case id, title, role, model, updatedAt }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let head = try? encoder.encode(Head(
                  id: chat.id, title: chat.title, role: chat.role, model: chat.model,
                  updatedAt: chat.updatedAtRaw)),
              head.last == UInt8(ascii: "}"),
              let user = try? encoder.encode(userID)
        else { return nil }

        var messages = Data("[".utf8)
        for (index, stored) in (storedMessages.dropLast() + [answer]).enumerated() {
            if index > 0 { messages.append(UInt8(ascii: ",")) }
            messages.append(stored)
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

/// Just enough of a JSON reader to find where things are, without changing a byte of them.
///
/// `JSONDecoder` answers what a document *means*; posting a conversation back needs the exact
/// bytes it arrived as, so a field this build has never heard of — or a number, an escape, a key
/// order — goes back as the server wrote it.
enum RawJSON {

    /// The bytes of each element of the top-level object's `key` array, in order.
    /// Nil if the document is not well formed, or has no such array.
    static func arrayElements(forKey key: String, in data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        var scanner = Scanner(bytes: bytes)
        scanner.skipWhitespace()
        guard scanner.peek == UInt8(ascii: "{") else { return nil }
        scanner.index += 1
        var found: [Data]?
        while true {
            scanner.skipWhitespace()
            if scanner.peek == UInt8(ascii: "}") { scanner.index += 1; break }
            guard let keyRange = scanner.string() else { return nil }
            scanner.skipWhitespace()
            guard scanner.peek == UInt8(ascii: ":") else { return nil }
            scanner.index += 1
            scanner.skipWhitespace()
            let name = try? JSONDecoder().decode(String.self, from: Data(bytes[keyRange]))
            if name == key, scanner.peek == UInt8(ascii: "[") {
                guard let elements = scanner.arrayElements() else { return nil }
                found = elements.map { Data(bytes[$0]) }
            } else {
                guard scanner.value() != nil else { return nil }
            }
            scanner.skipWhitespace()
            if scanner.peek == UInt8(ascii: ",") { scanner.index += 1; continue }
            if scanner.peek == UInt8(ascii: "}") { scanner.index += 1; break }
            return nil
        }
        scanner.skipWhitespace()
        guard scanner.index == bytes.count else { return nil }
        return found
    }

    /// `object` with `fields` written in before its closing brace, in `keyOrder`.
    ///
    /// The existing bytes are untouched; the new members are appended. Nil when `object` is not
    /// a JSON object, or already has one of the keys — a duplicate key is read differently by
    /// different parsers, so it is never written.
    static func appending(
        _ fields: [String: JSONValue], keyOrder: [String], toObject object: Data
    ) -> Data? {
        let bytes = [UInt8](object)
        var scanner = Scanner(bytes: bytes)
        scanner.skipWhitespace()
        guard scanner.peek == UInt8(ascii: "{"), let end = scanner.value(),
              end.upperBound == bytes.count || bytes[end.upperBound...].allSatisfy(Scanner.isWhitespace),
              let existing = try? JSONDecoder().decode([String: JSONValue].self, from: object)
        else { return nil }
        let names = keyOrder.filter { fields[$0] != nil }
        guard !names.isEmpty, !names.contains(where: { existing[$0] != nil }) else { return nil }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var members = Data()
        for (index, name) in names.enumerated() {
            guard let key = try? encoder.encode(name),
                  let value = try? encoder.encode(fields[name]!)
            else { return nil }
            if index > 0 || !existing.isEmpty { members.append(UInt8(ascii: ",")) }
            members.append(key)
            members.append(UInt8(ascii: ":"))
            members.append(value)
        }

        // The closing brace is the last byte of the object's own range.
        let close = end.upperBound - 1
        var result = Data(bytes[..<close])
        result.append(members)
        result.append(contentsOf: bytes[close...])
        return result
    }

    /// A forward-only cursor over JSON text. Validates as it goes; does not build values.
    struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
        }

        mutating func skipWhitespace() {
            while let byte = peek, Self.isWhitespace(byte) { index += 1 }
        }

        /// Skips one value and returns its range.
        mutating func value() -> Range<Int>? {
            guard let byte = peek else { return nil }
            let start = index
            switch byte {
            case UInt8(ascii: "{"):
                index += 1
                skipWhitespace()
                if peek == UInt8(ascii: "}") { index += 1; return start..<index }
                while true {
                    skipWhitespace()
                    guard string() != nil else { return nil }
                    skipWhitespace()
                    guard peek == UInt8(ascii: ":") else { return nil }
                    index += 1
                    skipWhitespace()
                    guard value() != nil else { return nil }
                    skipWhitespace()
                    if peek == UInt8(ascii: ",") { index += 1; continue }
                    guard peek == UInt8(ascii: "}") else { return nil }
                    index += 1
                    return start..<index
                }
            case UInt8(ascii: "["):
                guard arrayElements() != nil else { return nil }
                return start..<index
            case UInt8(ascii: "\""):
                return string()
            default:
                // Numbers and the three literals: a run of the characters they are made of.
                // Their exact grammar is not this reader's concern — the same bytes are decoded
                // by `JSONDecoder` before anything is sent, which rejects a malformed one.
                while let next = peek, !Self.isWhitespace(next),
                      next != UInt8(ascii: ","), next != UInt8(ascii: "}"),
                      next != UInt8(ascii: "]"), next != UInt8(ascii: ":") {
                    index += 1
                }
                return index > start ? start..<index : nil
            }
        }

        /// Skips one array and returns the range of each element.
        mutating func arrayElements() -> [Range<Int>]? {
            guard peek == UInt8(ascii: "[") else { return nil }
            index += 1
            var elements: [Range<Int>] = []
            skipWhitespace()
            if peek == UInt8(ascii: "]") { index += 1; return elements }
            while true {
                skipWhitespace()
                guard let element = value() else { return nil }
                elements.append(element)
                skipWhitespace()
                if peek == UInt8(ascii: ",") { index += 1; continue }
                guard peek == UInt8(ascii: "]") else { return nil }
                index += 1
                return elements
            }
        }

        /// Skips one string, escapes included, and returns its range with the quotes.
        mutating func string() -> Range<Int>? {
            guard peek == UInt8(ascii: "\"") else { return nil }
            let start = index
            index += 1
            while let byte = peek {
                index += 1
                if byte == UInt8(ascii: "\\") {
                    guard peek != nil else { return nil }
                    index += 1
                } else if byte == UInt8(ascii: "\"") {
                    return start..<index
                }
            }
            return nil
        }
    }
}
