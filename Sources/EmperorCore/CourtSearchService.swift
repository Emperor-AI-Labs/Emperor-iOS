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
    /// - Throws: `NeedsHumanCaptcha` when a Supreme Court search by case number could not be
    ///   solved server-side. That is not a failure — it is the point at which the flow moves to
    ///   `startCaptchaSession()`.
    func search(_ query: CourtSearchQuery) async throws -> [CourtSearchResult]
    func startCaptchaSession() async throws -> SupremeCourtCaptcha
    func submitCaptcha(
        _ answer: String, for query: CourtSearchQuery, session: String
    ) async throws -> CaptchaOutcome
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
            "POST", query.forum.path(for: query.mode), body: query.body)
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
            // A court that answered and had nothing is not a failure — it is the same answer as
            // an empty `results` on a success, and the caller already knows how to say
            // "check the case type and year". Reporting it as an error would put a red banner
            // in front of someone who simply mistyped a digit.
            if response.notFound == true { return [] }
            // Only the Supreme Court has somewhere to go from here. The High Court sets the same
            // flag to mean "this search is not wired up yet" and has no session/submit pair
            // behind it, so treating the two alike would offer a captcha sheet that can never
            // resolve.
            if response.fallback == true,
               query.forum == .supremeCourt, query.mode == .caseNumber {
                throw NeedsHumanCaptcha()
            }
            throw CourtSearchFailure(response: response).asError
        }
        // `success: true` with nothing in it means the court had no such case. That is an
        // answer, not a failure, and the caller distinguishes them by the array being empty.
        //
        // Fabricated rows are dropped rather than shown. `GET /court/search` answers for a court
        // whose adapter has not been built by echoing the request back as a case record; this
        // client never calls that route, so a `preview` row arriving here means the server
        // started routing one of these forums through it. Showing a lawyer their own typing as
        // a court record is not a thing to fail open on. See `CourtSearchResult.preview`.
        return (response.results ?? []).filter { $0.preview != true }
    }

    // MARK: - The Supreme Court captcha

    private struct CaptchaSessionResponse: Decodable {
        var success: Bool?
        var sessionId: String?
        var captcha: String?
        var error: String?
    }

    /// Opens a captcha session and returns the image to put in front of the user.
    ///
    /// - Important: this is the one route in the whole court set that signals failure with a
    ///   status code — a 502 when the court cannot be reached — rather than `200` with
    ///   `success: false`. `client.perform` does not throw on status, so the check here is
    ///   deliberate and not redundant with the `success` check below it.
    func startCaptchaSession() async throws -> SupremeCourtCaptcha {
        var request = try await client.makeRequest("POST", "/court/sc/session")
        request.timeoutInterval = Self.timeout

        let (data, http) = try await client.perform(request)
        let response = try? JSONDecoder().decode(CaptchaSessionResponse.self, from: data)

        if let status = (http as? HTTPURLResponse)?.statusCode, status >= 400 {
            throw APIError.server(
                status: status,
                message: response?.error ?? "Could not reach the Supreme Court website.")
        }
        guard response?.success == true,
              let sessionID = response?.sessionId, !sessionID.isEmpty,
              let uri = response?.captcha,
              let image = SupremeCourtCaptcha.decodeImage(fromDataURI: uri)
        else {
            throw APIError.server(
                status: 200,
                message: response?.error ?? "The CAPTCHA could not be loaded. Try again.")
        }
        return SupremeCourtCaptcha(sessionID: sessionID, image: image)
    }

    /// Answers the captcha and, if it was right, returns what the court had.
    ///
    /// - Parameter session: the `sessionID` from `startCaptchaSession()`. It is consumed by this
    ///   call whether or not the answer was correct, so a `.needsANewCaptcha` result must be
    ///   followed by a fresh `startCaptchaSession()` and never by a second call here.
    func submitCaptcha(
        _ answer: String, for query: CourtSearchQuery, session: String
    ) async throws -> CaptchaOutcome {
        var body = query.body
        body["sessionId"] = .string(session)
        body["captcha"] = .string(answer.trimmingCharacters(in: .whitespacesAndNewlines))

        var request = try await client.makeRequest(
            "POST", "/court/sc/submit", body: SavePayload(body: body))
        request.timeoutInterval = Self.timeout

        let (data, _) = try await client.perform(request)
        let response: CourtSearchResponse
        do {
            response = try JSONDecoder().decode(CourtSearchResponse.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }

        // Checked before `success`, because both of these arrive as failures and neither is one
        // the user can do anything about except try the next image.
        if response.captchaError == true || response.expired == true {
            return .needsANewCaptcha(
                message: response.error ?? "That CAPTCHA did not go through. Here is a new one.")
        }
        guard response.success == true else {
            throw CourtSearchFailure(response: response).asError
        }
        // An empty list here carries `message` rather than `error`, and means the captcha was
        // right and the court had no such case — which `CourtSearchViewModel.emptyMessage`
        // already knows how to say.
        return .results((response.results ?? []).filter { $0.preview != true })
    }

    /// Turns the flags a failed lookup carries into one sentence and one classification.
    ///
    /// The platform sends `notFound`, `portalDown` and `fallback` and the web client decodes
    /// none of them, so a mistyped case number and a court being down produce the same red line
    /// there. They mean opposite things to the person reading: one says check what you typed,
    /// the other says there is nothing to check and to come back later.
    struct CourtSearchFailure {
        let response: CourtSearchResponse

        /// The court's site is down. Retrying now will not help.
        var isCourtOutage: Bool { response.portalDown == true }

        /// The server's captcha solver gave up. A human can still get through — see
        /// `SupremeCourtCaptcha` — so this is not a dead end.
        var needsHumanCaptcha: Bool { response.fallback == true }

        var asError: APIError {
            // The server's own wording is used where it has any: it knows which court, and its
            // High Court outage message already says the fault is at the court's end.
            let message = response.error ?? response.message ?? fallbackMessage
            return .server(status: 200, message: message)
        }

        private var fallbackMessage: String {
            if isCourtOutage { return "The court's website is not responding. Try again later." }
            if needsHumanCaptcha { return "The court asked for a CAPTCHA we could not read." }
            return "The lookup could not be completed."
        }
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
