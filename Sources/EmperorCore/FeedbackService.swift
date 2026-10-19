import Foundation

/// What the feedback is about — the web's six chips (`CATEGORIES` in
/// `src/components/feedback/DraftFeedbackButton.jsx`). The label is the wire value: the web sends
/// the words themselves in `categories`, so a reviewer's queue reads the same from either client.
enum DraftFeedbackCategory: String, CaseIterable, Identifiable, Sendable {
    case formatting = "Formatting"
    case accuracy = "Accuracy"
    case structure = "Structure"
    case citations = "Citations"
    case annexures = "Annexures"
    case other = "Other"

    var id: String { rawValue }
    var label: String { rawValue }
}

/// Thumbs up or down. The only two values the route keeps; anything else is stored as no rating.
enum DraftFeedbackRating: String, CaseIterable, Identifiable, Sendable {
    case up, down

    var id: String { rawValue }

    /// The web's button words.
    var label: String {
        switch self {
        case .up: return "Good"
        case .down: return "Needs work"
        }
    }

    var systemImage: String {
        switch self {
        case .up: return "hand.thumbsup"
        case .down: return "hand.thumbsdown"
        }
    }
}

/// One piece of feedback, as `POST /draft-feedback` takes it.
struct DraftFeedback: Equatable, Sendable {
    var chatID: String?
    /// The saved draft's id where this client knows it. It does not, today: a chat's drafts are
    /// saved server-side under ids this client never receives, so it is sent as null and the
    /// reviewer finds the draft by the conversation and the text sent with it.
    var documentID: String?
    var documentTitle: String
    var rating: DraftFeedbackRating?
    var categories: [DraftFeedbackCategory]
    var comment: String
    /// The drafted document's HTML, exactly as rated — or nil when there is no draft.
    var docHTML: String?

    /// The route's own rule: a rating or a comment. Categories alone are not enough.
    var canSubmit: Bool {
        rating != nil || !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The seam the feedback sheet is built against.
protocol FeedbackProviding: Sendable {
    /// Sends it. Returns the stored row's id when the server gives one.
    @discardableResult
    func send(_ feedback: DraftFeedback) async throws -> Int?
}

/// `POST /draft-feedback` — feedback on a drafted document, table or answer, as the web's
/// `DraftFeedbackButton` sends it.
///
/// ## The draft's text is sent
///
/// The web sends the draft's HTML with every piece of feedback — "a complaint always arrives with
/// the exact output it is about" — and this client now does the same whenever the feedback is
/// about a draft. A plain answer with no draft sends only the conversation id, as before. The
/// sheet says which, before the tap (`DraftFeedbackViewModel.privacyNote`).
///
/// The server keeps up to 5,000 characters of comment and 500 KB of HTML and trims the rest
/// rather than refusing it; both are capped here first, so nothing is uploaded only to be cut.
///
/// ## Contract (`sync-server.js`, the `/draft-feedback` POST)
///
/// Body `{userId, chatId, documentId, documentTitle, rating: 'up'|'down'|null, categories,
/// comment, docHtml}`. 200 `{ok: true, id}`; 400 `{ok: false, error: 'Pick a rating or write a
/// comment'}` when there is neither; 500 `{ok: false, error}`.
struct FeedbackService: FeedbackProviding {
    static let commentLimit = 5_000
    /// 500 KB, counted as the server counts it — in UTF-16 units of a JavaScript string.
    static let htmlLimit = 500 * 1024

    let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    /// Every key is always sent, null where there is nothing: the web's body has the same shape.
    private struct Payload: Encodable {
        let userId: String?
        let chatId: String?
        let documentId: String?
        let documentTitle: String
        let rating: String?
        let categories: [String]
        let comment: String
        let docHtml: String

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(userId, forKey: .userId)
            try c.encode(chatId, forKey: .chatId)
            try c.encode(documentId, forKey: .documentId)
            try c.encode(documentTitle, forKey: .documentTitle)
            try c.encode(rating, forKey: .rating)
            try c.encode(categories, forKey: .categories)
            try c.encode(comment, forKey: .comment)
            try c.encode(docHtml, forKey: .docHtml)
        }

        enum CodingKeys: String, CodingKey {
            case userId, chatId, documentId, documentTitle, rating, categories, comment, docHtml
        }
    }

    private struct Body: Decodable {
        var ok: Bool?
        var id: Int?
        var error: String?
    }

    /// The comment as sent: trimmed, then cut to the server's limit.
    static func cappedComment(_ comment: String) -> String {
        String(comment.trimmingCharacters(in: .whitespacesAndNewlines).prefix(commentLimit))
    }

    /// The HTML as sent: at most `htmlLimit` UTF-16 units, on a character boundary.
    static func cappedHTML(_ html: String?) -> String {
        guard let html, html.utf16.count > htmlLimit else { return html ?? "" }
        var end = html.utf16.index(html.utf16.startIndex, offsetBy: htmlLimit)
        while end > html.startIndex, String.Index(end, within: html) == nil {
            end = html.utf16.index(before: end)
        }
        return String(html[..<end])
    }

    @discardableResult
    func send(_ feedback: DraftFeedback) async throws -> Int? {
        // Sent alongside the bearer token, not instead of it; the route prefers the verified
        // identity.
        let request = try await client.makeRequest(
            "POST", "/draft-feedback",
            body: Payload(
                userId: await client.currentCredentials()?.userIDString,
                chatId: feedback.chatID,
                documentId: feedback.documentID,
                documentTitle: feedback.documentTitle,
                rating: feedback.rating?.rawValue,
                categories: feedback.categories.map(\.rawValue),
                comment: Self.cappedComment(feedback.comment),
                docHtml: Self.cappedHTML(feedback.docHTML)))

        // A refusal is a 400 carrying `ok: false` and the reason, which `send` surfaces. A 2xx
        // is still read for `ok`: "sent" is only ever what the server said it stored.
        let body = try await client.send(request, as: Body.self)
        guard body.ok == true else {
            throw APIError.server(status: 200, message: body.error ?? "Your feedback could not be sent.")
        }
        return body.id
    }
}
