import Foundation

/// Why an answer is being reported.
///
/// A fixed list rather than free text alone, because a reviewer triaging a queue needs to sort
/// it, and because naming the categories tells a user what this channel is for. `wire` is what
/// goes into the route's `categories` array — lowercase and stable, so a label can be reworded
/// without orphaning every report already in the table.
enum ReportReason: String, CaseIterable, Identifiable, Sendable {
    case wrongLaw = "wrong-law"
    case fabricatedCitation = "fabricated-citation"
    case harmful
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wrongLaw: return "The law is wrong"
        case .fabricatedCitation: return "A citation does not exist"
        case .harmful: return "Harmful or offensive"
        case .other: return "Something else"
        }
    }
}

/// The seam the report sheet is built against.
protocol FeedbackProviding: Sendable {
    func reportAnswer(chatID: String?, reason: ReportReason, comment: String) async throws
}

/// `POST /draft-feedback`, used as the in-app report channel.
///
/// ## Why this route rather than a new one
///
/// Both stores require a way to report AI-generated content, and this app had none. The route
/// already exists, already writes to a table an admin screen already reads, and — unusually for
/// this server — already resolves identity properly, preferring the verified token over the
/// client-supplied id. A parallel endpoint would mean a second queue nobody reads.
///
/// ## The answer's text is deliberately not sent
///
/// The route accepts `docHtml` up to 500 KB and it is left empty. The reported answer is already
/// stored server-side against `chatID`; sending it again would copy client material — which on
/// this platform means privileged legal content — into a second table for no reviewer benefit.
/// The chat id is what lets a reviewer find it.
struct FeedbackService: FeedbackProviding {
    /// The server truncates rather than rejects, so an uncapped field loses its tail silently.
    /// Capped here, where the sheet can say so before the tap.
    static let commentLimit = 5_000

    let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    private struct Payload: Encodable {
        let userId: String?
        let chatId: String?
        let documentTitle: String
        /// `up` or `down` only — anything else is coerced to null server-side, and a null
        /// rating with an empty comment is a 400.
        let rating: String
        let categories: [String]
        let comment: String
    }

    private struct Body: Decodable {
        var ok: Bool?
        var id: Int?
        var error: String?
    }

    func reportAnswer(chatID: String?, reason: ReportReason, comment: String) async throws {
        let trimmed = String(
            comment.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Self.commentLimit))
        // Sent alongside the bearer token, not instead of it. This route already prefers the
        // verified identity; the id is here so the client keeps working unchanged once the rest
        // of the server is hardened the same way.
        let request = try await client.makeRequest(
            "POST", "/draft-feedback",
            body: Payload(
                userId: await client.currentCredentials()?.userIDString,
                chatId: chatID,
                documentTitle: "Reported from iOS",
                rating: "down",
                categories: [reason.rawValue],
                comment: trimmed))

        // - Important: this route answers **200 with `ok: false`** when it rejects, rather than
        //   a 4xx. Trusting the status code would report every rejection as a success and the
        //   user would believe a report had been filed that was not.
        let (data, response) = try await client.perform(request)
        let body = try? JSONDecoder().decode(Body.self, from: data)
        guard (200..<300).contains(response.statusCode), body?.ok == true else {
            throw APIError.server(
                status: response.statusCode,
                message: body?.error ?? "The report could not be sent.")
        }
    }
}
