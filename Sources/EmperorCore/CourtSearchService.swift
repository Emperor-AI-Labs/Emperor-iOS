import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What happened when a case was saved.
enum SaveCaseOutcome: Equatable, Sendable {
    case saved(id: String)
    /// The matter is already on the dashboard. Not a failure worth an error colour: the user's
    /// goal — "this case should be on my dashboard" — is already met.
    case alreadySaved(message: String)
    /// **The save failed and the case is not on the dashboard.**
    ///
    /// The same 409 as `alreadySaved`, meaning the opposite thing. The server files matters
    /// under `ext_id = cnr || courtCode|caseType|caseNumber|caseYear` behind a unique index on
    /// `(team_id, ext_id)`, and the diary routes hand back cards with all four of those empty —
    /// NCLAT always, NCLT and a CNR-less Supreme Court matter often. Every such card computes
    /// the *same* key, so the second one collides with an unrelated matter already filed there.
    ///
    /// Reporting this as `alreadySaved` was the original bug: a green tick and "already on your
    /// dashboard" for a case that was never stored, and that the user has no way to discover is
    /// missing.
    case refusedAsIndistinguishable(message: String)
}

/// Looking a case up at the court and putting it on the dashboard.
///
/// Separate from `CaseProviding` because it is the only part of the case story that talks to
/// the courts rather than to our own database, and it is the part a screen most needs to fake:
/// a High Court lookup drives a captcha solver and can genuinely take ten seconds.
protocol CourtSearching: Sendable {
    func search(_ query: CourtSearchQuery) async throws -> [CourtSearchResult]
    func save(_ result: CourtSearchResult) async throws -> SaveCaseOutcome
}

struct CourtSearchService: CourtSearching {
    let client: APIClient

    /// A High Court lookup solves a captcha inline — up to eight attempts with a 700ms sleep
    /// between them — and `save-case` re-scrapes the court before it answers. Both routinely
    /// outlast a normal request timeout, and both are doing real work rather than hanging.
    static let timeout: TimeInterval = 60

    // MARK: - Lookup

    /// - Important: this route answers **HTTP 200 for everything**, so the status code is not
    ///   consulted at all — `success` is. And the server masks its own validation errors as
    ///   connectivity ones: a missing `year` is caught and reported as "could not reach the
    ///   court". `CourtSearchQuery.isComplete` exists so the app never gets that far.
    func search(_ query: CourtSearchQuery) async throws -> [CourtSearchResult] {
        var request = try await client.makeRequest(
            "POST", query.forum.path, body: query.body)
        request.timeoutInterval = Self.timeout

        // Never retried. A lookup can take ten seconds of the court's time and a second
        // attempt would double that while a lawyer waits — and a genuine court outage does not
        // clear inside a backoff.
        let (data, _) = try await client.perform(request)
        let response: CourtSearchResponse
        do {
            response = try JSONDecoder().decode(CourtSearchResponse.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
        guard response.success == true else {
            throw APIError.server(
                status: 200, message: response.error ?? "The lookup could not be completed.")
        }
        // `success: true` with nothing in it means the court had no such case. That is an
        // answer, not a failure, and the caller distinguishes them by the array being empty.
        return response.results ?? []
    }

    // MARK: - Saving

    private struct SavePayload: Encodable {
        let body: [String: JSONValue]
        func encode(to encoder: Encoder) throws { try body.encode(to: encoder) }
    }

    /// Pins a looked-up case to the dashboard.
    ///
    /// The card's presentation-only extras — `registrationNo`, `source`, `preview`,
    /// `caseNumberText` — are dropped, because the route ignores them and sending fields a
    /// server discards invites the belief that it kept them.
    ///
    /// - Important: `scrapeRef` travels **verbatim**. It is what lets the server re-scrape this
    ///   matter for hearing dates later; re-deriving it from the visible fields would produce
    ///   something that looks right and refreshes nothing.
    func save(_ result: CourtSearchResult) async throws -> SaveCaseOutcome {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }

        var body: [String: JSONValue] = ["userId": .string(credentials.userIDString)]
        func put(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            body[key] = .string(value)
        }
        put("cnr", result.cnr)
        put("diaryNumber", result.diaryNumber)
        put("courtType", result.courtType)
        put("courtCode", result.courtCode)
        put("courtName", result.courtName)
        put("caseType", result.caseType)
        put("caseNumber", result.caseNumber)
        put("caseYear", result.caseYear)
        put("title", result.title)
        put("parties", result.parties)
        put("status", result.status)
        if let scrapeRef = result.scrapeRef { body["scrapeRef"] = scrapeRef }

        var request = try await client.makeRequest(
            "POST", "/save-case", body: SavePayload(body: body))
        // The route `await`s a live court re-scrape before answering.
        request.timeoutInterval = Self.timeout

        let (data, response) = try await client.perform(request)
        let decoded = try? JSONDecoder().decode(SaveCaseResponse.self, from: data)

        // A 409 is a unique-index violation on `(team_id, ext_id)`, and the server sends the
        // same sentence either way. Which of the two it *means* depends entirely on whether
        // this card carries a number that could tell it apart — so that, and not the response,
        // is what decides. See `refusedAsIndistinguishable`.
        if response.statusCode == 409 {
            guard result.hasDistinguishingNumber else {
                return .refusedAsIndistinguishable(message: Self.collisionMessage(for: result))
            }
            return .alreadySaved(
                message: decoded?.error ?? "That case is already on your dashboard.")
        }
        guard (200..<300).contains(response.statusCode), decoded?.success == true,
              let id = decoded?.id, !id.isEmpty
        else {
            throw APIError.server(
                status: response.statusCode,
                message: decoded?.error ?? "The case could not be saved.")
        }
        return .saved(id: id)
    }

    /// Why a numberless card could not be filed, in terms of what can be done about it.
    ///
    /// Deliberately does not repeat the server's own "This case is already on the team
    /// dashboard", which is the one sentence guaranteed to be false here.
    static func collisionMessage(for result: CourtSearchResult) -> String {
        let named = result.courtName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let forum = named.isEmpty ? "This court" : named
        return "\(result.displayTitle) could not be added. \(forum) did not give it a case "
            + "number, and your dashboard already holds another matter filed without one. Only "
            + "one of those can be kept at a time — remove the other first, or add this case "
            + "once the court issues its number."
    }
}
