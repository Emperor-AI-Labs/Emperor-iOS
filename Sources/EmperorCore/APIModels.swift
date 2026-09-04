import Foundation

// MARK: - Dates

/// Decodes the two timestamp formats this API emits for the same field.
///
/// `chats.updated_at` is a SQLite `DATETIME DEFAULT CURRENT_TIMESTAMP`, so anything the
/// server writes comes back as `"2026-08-25 09:12:44"` — space separator, no zone, UTC.
/// But `POST /sync` stores the client's string verbatim, and the web client sends full
/// ISO-8601 with milliseconds. Both are therefore reachable on the same field, and a
/// single-format decoder silently drops half the history.
enum WireDate {
    // Formatters are expensive to build and are only ever read after configuration here.
    // Foundation's date formatters are documented as safe for concurrent *use* — the hazard
    // is concurrent mutation, which never happens because these are `let` and never touched
    // again after the initialiser closure returns.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// SQLite's `CURRENT_TIMESTAMP` form. Always UTC despite carrying no zone marker.
    nonisolated(unsafe) private static let sqlite: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return iso.date(from: raw)
            ?? isoNoFraction.date(from: raw)
            ?? sqlite.date(from: raw)
    }

    /// Epoch **milliseconds**, used only by the ingest `progress` object — a different
    /// encoding from every other date on this API.
    static func fromEpochMillis(_ millis: Double?) -> Date? {
        guard let millis else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    // MARK: - Court days

    /// The timezone every date in this product means.
    ///
    /// Hearing dates, filing dates and the cause list are days in an Indian court. The web
    /// client filters the cause list on `Asia/Kolkata` deliberately rather than on the viewer's
    /// zone (`src/lib/datetime.js:51-57`), because "today" means India's today even when the
    /// advocate is not. Bucketing these against `Calendar.current` shows the wrong day's
    /// hearings to anyone travelling, with no error anywhere.
    nonisolated(unsafe) static let india = TimeZone(identifier: "Asia/Kolkata")
        ?? TimeZone(secondsFromGMT: 19800) ?? .gmt

    nonisolated(unsafe) private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = india
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Parses a bare `YYYY-MM-DD` as that day in India.
    ///
    /// Deliberately separate from `parse`: this returns midnight IST, which is the only
    /// reading of a court date that does not drift by a day.
    static func parseDay(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return day.date(from: String(raw.prefix(10)))
    }

    /// The `YYYY-MM-DD` key for an instant, in India — the same bucketing the server uses.
    static func dayKey(_ date: Date) -> String { day.string(from: date) }

    /// Today's key, in India.
    static func todayKey(now: Date = Date()) -> String { dayKey(now) }

    /// Any encoding this API emits, tried widest-first.
    ///
    /// A single `JSONDecoder.dateDecodingStrategy` cannot cover this: one `GET /case` response
    /// carries ISO8601-with-milliseconds (`cases`, `case_items`), zoneless SQLite
    /// `CURRENT_TIMESTAMP` (`case_events`, whose INSERT omits the column so the DDL default
    /// fires) **and** bare `YYYY-MM-DD` date columns, all in the same payload.
    static func parseAny(_ raw: String?) -> Date? {
        parse(raw) ?? parseDay(raw)
    }
}

// MARK: - Auth

struct User: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    var email: String?
    var name: String?
    var avatar: String?
    var title: String?
    var organization: String?
    var preferredModel: String?
    var plan: String?
    var planLabel: String?

    enum CodingKeys: String, CodingKey {
        case id, email, name, avatar, title, organization, plan
        case preferredModel = "preferred_model"
        case planLabel
    }
}

/// `/login` and `/register` share this envelope but not their `user` shape: register builds
/// its object by hand and returns only `id`, `name`, `email`. Every other field on `User` is
/// therefore optional.
struct AuthResponse: Codable {
    let success: Bool
    let user: User
    let token: String
}

/// Every failure on this API is `{"error": "..."}`. There is no `message`, no field list,
/// and no consistent status code — `/messages` answers 500 for a missing parameter and
/// `/stream-status` answers 200 for everything including errors.
struct APIErrorBody: Codable {
    let error: String?
    let success: Bool?
}

// MARK: - Chats

struct ChatSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String?
    var role: String?
    var model: String?
    var messageCount: Int?
    var lastPreview: String?
    var updatedAtRaw: String?

    var updatedAt: Date? { WireDate.parse(updatedAtRaw) }
    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "New Chat" : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case id, title, role, model, messageCount, lastPreview
        case updatedAtRaw = "updatedAt"
    }
}

struct ChatListResponse: Codable {
    let success: Bool?
    let chats: [ChatSummary]
}

enum MessageRole: String, Codable {
    case user, assistant, system
}

/// A stored message.
///
/// `messages.data` is an opaque TEXT column and `getMessages` returns `JSON.parse` output
/// unmodified, so there is no server-enforced schema — this is the union of what the
/// codebase actually produces. `extra` preserves unknown keys so a message can round-trip
/// back through `POST /sync` without losing fields.
struct ChatMessage: Codable, Equatable, Identifiable {
    var id: String?
    var role: MessageRole
    var content: String
    var timestampRaw: String?
    var usage: JSONValue?
    var isTyping: Bool?
    var done: Bool?
    var incomplete: Bool?
    var incompleteReason: String?
    var attachments: [JSONValue]?
    var sources: [JSONValue]?

    var timestamp: Date? { WireDate.parse(timestampRaw) }

    /// Server-authored assistant messages carry no `id` at all — the row id is generated but
    /// never written back into the blob — so a stable identity has to be synthesised.
    var stableID: String { id ?? "\(role.rawValue)-\(timestampRaw ?? "")-\(content.count)" }

    enum CodingKeys: String, CodingKey {
        case id, role, content, usage, isTyping, done, incomplete, incompleteReason
        case attachments, sources
        case timestampRaw = "timestamp"
    }

    init(role: MessageRole, content: String, id: String? = nil) {
        self.role = role
        self.content = content
        self.id = id
        self.timestampRaw = ISO8601DateFormatter().string(from: Date())
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Role is occasionally absent on hand-written rows; assume assistant rather than throw,
        // because one malformed row should not fail the whole history load.
        role = (try? c.decode(MessageRole.self, forKey: .role)) ?? .assistant
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        timestampRaw = try? c.decodeIfPresent(String.self, forKey: .timestampRaw)
        usage = try? c.decodeIfPresent(JSONValue.self, forKey: .usage)
        isTyping = try? c.decodeIfPresent(Bool.self, forKey: .isTyping)
        done = try? c.decodeIfPresent(Bool.self, forKey: .done)
        incomplete = try? c.decodeIfPresent(Bool.self, forKey: .incomplete)
        incompleteReason = try? c.decodeIfPresent(String.self, forKey: .incompleteReason)
        attachments = try? c.decodeIfPresent([JSONValue].self, forKey: .attachments)
        sources = try? c.decodeIfPresent([JSONValue].self, forKey: .sources)
    }
}

struct MessagesResponse: Codable {
    let success: Bool?
    let messages: [ChatMessage]
}

// MARK: - Stream rejoin

/// `GET /stream-status`. Always HTTP 200, including for errors — branch on `error`, never on
/// the status code.
///
/// This is the only authoritative completeness signal: a run that is aborted mid-stream ends
/// the response cleanly with no error bytes, so at the transport layer a truncated answer is
/// indistinguishable from a finished one.
struct StreamStatus: Codable {
    var active: Bool
    var done: Bool?
    var incomplete: Bool?
    var incompleteReason: String?
    /// Present but unreliable: the key is dropped entirely when the stored message never had it.
    var isTyping: Bool?
    var step: String?
    var contentLength: Int?
    /// The **full** accumulated draft, not a delta. On rejoin, replace the buffer wholesale.
    var content: String?
    var error: String?
    /// Epoch milliseconds, unlike every other date on this API.
    var startedAt: Double?
    var updatedAt: Double?

    var startedDate: Date? { WireDate.fromEpochMillis(startedAt) }
}

// MARK: - Files

/// `GET /user-files` returns a recursive tree whose nodes are discriminated by `type`, with
/// files and folders mixed at every level — including the top.
indirect enum FileNode: Codable, Equatable, Identifiable, Sendable {
    case folder(Folder)
    case file(StoredFile)

    struct Folder: Codable, Equatable, Sendable {
        var name: String
        var path: String
        var created: String?
        /// Holds sub-folders as well as files, despite the name.
        var files: [FileNode]?
    }

    struct StoredFile: Codable, Equatable, Sendable {
        var name: String
        var path: String
        var size: Int?
        var modified: String?
        var status: String?
        var progress: IngestProgress?
        var favorite: Bool?
    }

    var id: String {
        switch self {
        case .folder(let f): return "folder:" + f.path
        case .file(let f): return "file:" + f.path
        }
    }

    var name: String {
        switch self {
        case .folder(let f): return f.name
        case .file(let f): return f.name
        }
    }

    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TypeKey.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "folder": self = .folder(try Folder(from: decoder))
        default: self = .file(try StoredFile(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TypeKey.self)
        switch self {
        case .folder(let f):
            try c.encode("folder", forKey: .type)
            try f.encode(to: encoder)
        case .file(let f):
            try c.encode("file", forKey: .type)
            try f.encode(to: encoder)
        }
    }
}

struct IngestProgress: Codable, Equatable, Sendable {
    var stage: String?
    var pagesDone: Int?
    var pagesTotal: Int?
    var percent: Int?
    var etaSeconds: Int?
    /// Epoch milliseconds, or null.
    var startedAt: Double?
    var updatedAt: Double?
    var queuePosition: Int?
    var queueTotal: Int?
    var message: String?
}

struct UserFilesResponse: Codable {
    let success: Bool?
    let folders: [FileNode]
}

// MARK: - Ingest state

/// `GET /upload-status` returns a single free-text `status` string with no structure.
///
/// Only the terminal values are safe to match on. The progress sentences are explicitly
/// documented in the server as changeable prose, so substring-matching them would be a
/// silent breakage waiting to happen.
enum IngestState: Equatable {
    case ready
    /// An image-only PDF that is deliberately never OCR'd — still usable, since the model
    /// reads it visually. Only `/user-files` reports this; `/upload-status` never does.
    case scanned
    case failed(String)
    case inProgress(String)

    var isTerminal: Bool {
        switch self {
        case .ready, .scanned, .failed: return true
        case .inProgress: return false
        }
    }

    var isUsable: Bool {
        switch self {
        case .ready, .scanned: return true
        default: return false
        }
    }

    static func classify(_ raw: String?) -> IngestState {
        guard let raw else { return .inProgress("Preparing…") }
        // Lowercase "ready" is the initialiser that survives to mean done. The capitalised
        // "Ready" is a transient render of stage == 'done' and is not the terminal signal.
        if raw == "ready" { return .ready }
        if raw == "scanned" { return .scanned }
        if raw.hasPrefix("ERROR") { return .failed(raw) }
        return .inProgress(raw)
    }
}

struct UploadStatusResponse: Codable {
    let status: String?
}

struct UploadChunkResponse: Codable {
    let success: Bool?
    let message: String?
}
