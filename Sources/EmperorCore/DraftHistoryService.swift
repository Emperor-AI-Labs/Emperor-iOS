import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What kind of thing the assistant produced.
enum DraftKind: String, CaseIterable, Identifiable, Sendable {
    case document = "doc"
    case table

    var id: String { rawValue }

    /// The route. The server derives `type` from the **path**, not from a parameter, so these
    /// are two endpoints rather than one with a filter.
    var path: String { self == .document ? "/documents" : "/tables" }

    var title: String { self == .document ? "Drafts" : "Tables" }
    var emptyMessage: String {
        self == .document
            ? "Anything the assistant drafts for you is kept here."
            : "Tables the assistant builds are kept here."
    }
    var systemImage: String { self == .document ? "doc.text" : "tablecells" }
}

/// One thing the assistant produced, as it appears in the list.
///
/// The list carries no content — that is a second request — so this is deliberately cheap.
struct DraftedItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var chatID: String?
    var title: String?
    var type: String?
    var createdAtRaw: String?
    /// The conversation it came out of. `""` rather than null when the chat is gone, because
    /// the server COALESCEs it — so emptiness is the signal, not nil.
    var chatTitle: String?

    enum CodingKeys: String, CodingKey {
        case id
        case chatID = "chat_id"
        case title
        case type
        case createdAtRaw = "created_at"
        case chatTitle = "chat_title"
    }

    /// - Note: **two encodings on one field.** Ordinary writes are JavaScript ISO 8601 with
    ///   milliseconds; rows from the one-time migration and the column default are SQLite's
    ///   zoneless `YYYY-MM-DD HH:MM:SS`. A single `dateDecodingStrategy` cannot read both,
    ///   which is what `WireDate.parseAny` exists for.
    var createdAt: Date? { WireDate.parseAny(createdAtRaw) }

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// Which conversation to send someone back to, or nil when it no longer exists.
    var openableChatID: String? {
        guard let chatID, !chatID.isEmpty,
              let chatTitle, !chatTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return chatID
    }

    var sourceLabel: String {
        let trimmed = chatTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The chat was deleted; the draft outlived it. Saying "From " and then nothing would
        // read as a rendering fault.
        return trimmed.isEmpty ? "From a conversation you have since deleted" : "From \(trimmed)"
    }
}

struct DraftListResponse: Codable, Sendable {
    var success: Bool?
    var error: String?
    /// - Warning: the server returns **the same array under both keys**, so on `/tables` the
    ///   `documents` key contains tables. Never key off the name; key off the path you called.
    var documents: [DraftedItem]?
    var tables: [DraftedItem]?
}

struct DraftContentResponse: Codable, Sendable {
    var success: Bool?
    var error: String?
    var content: String?
}

protocol DraftHistoryProviding: Sendable {
    func drafts(_ kind: DraftKind) async throws -> [DraftedItem]
    func content(id: String) async throws -> String
}

struct DraftHistoryService: DraftHistoryProviding {
    let client: APIClient

    /// - Important: there is **no pagination** — no limit, no offset, no cursor. Every row this
    ///   user has ever produced comes back in one response, newest first. Fetch on appear and
    ///   on pull-to-refresh; never poll it.
    func drafts(_ kind: DraftKind) async throws -> [DraftedItem] {
        let response = try await withRetry {
            // `userId` is added by `makeRequest` for GETs. Omitting it is a **500**, not a 400,
            // because the route throws rather than validating.
            let request = try await client.makeRequest("GET", kind.path)
            return try await client.send(request, as: DraftListResponse.self)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        // Both keys mirror each other; taking whichever is present is the only reading that
        // works for both routes.
        return response.documents ?? response.tables ?? []
    }

    /// Fetches a draft's full text.
    ///
    /// - Important: an unknown or deleted id answers `{"success":true,"content":""}` — the
    ///   route ternaries a missing row straight to an empty string. So "no content" cannot be
    ///   distinguished from "no such document", and the caller must not render a blank page as
    ///   though the draft were genuinely empty.
    ///
    /// - Note: the app only ever passes ids drawn from the signed-in user's own list. Nothing
    ///   on this path is an authorisation boundary — never accept an id from any other source.
    func content(id: String) async throws -> String {
        let response = try await withRetry {
            let request = try await client.makeRequest(
                "GET", "/documents/content", query: ["id": id])
            return try await client.send(request, as: DraftContentResponse.self)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        let content = response.content ?? ""
        guard !content.isEmpty else {
            throw APIError.server(
                status: 404,
                message: """
                    That draft could not be opened. It may have been deleted along with its \
                    conversation.
                    """)
        }
        return content
    }
}
