import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The case operations a view model needs.
protocol CaseProviding: Sendable {
    func cases() async throws -> [LegalCase]
    func caseDetail(id: String) async throws -> CaseDetail
    func causeList() async throws -> [CauseListing]
    func addNote(caseID: String, title: String?, body: String) async throws
    func addTask(caseID: String, title: String, dueDate: Date?) async throws
    func orderDocument(for item: CaseItem, in legalCase: LegalCase) async throws -> Data
}

/// One case with its timeline and structured rows.
struct CaseDetail: Equatable, Sendable {
    var legalCase: LegalCase
    var events: [CaseEvent]
    var items: [CaseItem]

    /// Items in a section, newest first.
    func items(in section: CaseSection) -> [CaseItem] {
        items.filter { $0.section == section.rawValue }
    }

    /// Every section that actually has rows, in the order a practitioner reads them.
    var populatedSections: [CaseSection] {
        CaseSection.allCases.filter { section in
            items.contains { $0.section == section.rawValue }
        }
    }

    /// Sections the server returned that this build does not know about. Surfaced rather than
    /// dropped: `section` is an open string server-side, so a new one can appear at any time
    /// and silently swallowing its rows would hide real case data.
    var unknownSections: [String] {
        let known = Set(CaseSection.allCases.map(\.rawValue))
        return Array(Set(items.map(\.section)).subtracting(known)).sorted()
    }
}

struct CaseService: CaseProviding {
    let client: APIClient

    // MARK: - Reads

    /// Every case across every team the user belongs to.
    ///
    /// Server-sorted by `updated_at DESC` (`sync-server.js:9682`), which means adding a note
    /// re-orders the list — the app re-sorts for display rather than relying on this.
    func cases() async throws -> [LegalCase] {
        let response = try await withRetry {
            let request = try await client.makeRequest("GET", "/cases")
            return try await client.send(request, as: CaseListResponse.self)
        }
        try Self.throwIfUnsuccessful(success: response.success, error: response.error)
        return response.cases ?? []
    }

    func caseDetail(id: String) async throws -> CaseDetail {
        let response = try await withRetry {
            let request = try await client.makeRequest("GET", "/case", query: ["id": id])
            return try await client.send(request, as: CaseDetailResponse.self)
        }
        try Self.throwIfUnsuccessful(success: response.success, error: response.error)
        guard let legalCase = response.case else {
            throw APIError.server(status: 404, message: "That matter could not be found.")
        }
        return CaseDetail(
            legalCase: legalCase,
            events: response.events ?? [],
            items: response.items ?? [])
    }

    /// The whole cause list, for every date.
    ///
    /// - Important: this route takes **no date range** and applies no date filter
    ///   (`sync-server.js:9697-9782`). It returns every listing for every date — the entire
    ///   past hearing history plus everything scheduled. The -45/+120 day window in the web
    ///   client is purely client-side. So this is fetched once and windowed locally; asking
    ///   per-day would re-fetch the whole history each time.
    ///
    ///   It also has an undocumented ceiling: the query builds one bound parameter per case, so
    ///   a large enough docket throws `too many SQL variables` and 500s.
    func causeList() async throws -> [CauseListing] {
        let response = try await withRetry {
            let request = try await client.makeRequest("GET", "/cause-list")
            return try await client.send(request, as: CauseListResponse.self)
        }
        try Self.throwIfUnsuccessful(success: response.success, error: response.error)
        return response.listings ?? []
    }

    // MARK: - Writes

    private struct NotePayload: Encodable {
        let userId: String
        let caseId: String
        let type: String
        let title: String?
        let body: String
        /// **Always a full ISO8601 string.** The server stores whatever it is sent, verbatim
        /// (`sync-server.js:9826`), and `GET /case` orders events by
        /// `COALESCE(event_date, created_at) DESC` compared as text. A bare `YYYY-MM-DD` is a
        /// strict prefix of an ISO datetime, so it sorts below every same-day server-defaulted
        /// event and the timeline silently reads out of order.
        let eventDate: String
    }

    func addNote(caseID: String, title: String?, body: String) async throws {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        let payload = NotePayload(
            userId: credentials.userIDString,
            caseId: caseID,
            type: "note",
            title: title,
            body: body,
            eventDate: Self.isoFormatter.string(from: Date()))
        let request = try await client.makeRequest("POST", "/case-event", body: payload)
        let response = try await client.send(request, as: WriteResponse.self)
        try Self.throwIfUnsuccessful(success: response.success, error: response.error)
    }

    private struct TaskPayload: Encodable {
        let userId: String
        let caseId: String
        let section: String
        let title: String
        let itemDate: String?
    }

    /// Adds a task row.
    ///
    /// - Important: **no `id` is sent.** `POST /case-item` upserts on `id`, and its update
    ///   branch is a full replace — every omitted field is set to NULL
    ///   (`sync-server.js:9857-9861`). Sending no id guarantees an insert, and an insert is the
    ///   only safe shape here. Editing an existing row would require sending every field back.
    ///
    ///   Omitting the `source` column is also deliberate: that makes the `DEFAULT 'user'` fire,
    ///   which is what keeps the row out of the scraper's `DELETE ... WHERE source = 'scrape'`
    ///   on the next refresh.
    func addTask(caseID: String, title: String, dueDate: Date?) async throws {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        let payload = TaskPayload(
            userId: credentials.userIDString,
            caseId: caseID,
            section: CaseSection.tasks.rawValue,
            title: title,
            itemDate: dueDate.map { WireDate.dayKey($0) })
        let request = try await client.makeRequest("POST", "/case-item", body: payload)
        let response = try await client.send(request, as: WriteResponse.self)
        try Self.throwIfUnsuccessful(success: response.success, error: response.error)
    }

    // MARK: - Order documents

    /// Fetches the PDF behind an order row.
    ///
    /// - Important: all three court proxies answer **HTTP 200 with an HTML error page** on
    ///   every failure — case not found, no access, no order on the portal, upstream network
    ///   error (`sync-server.js:9233`, `:9271`, `:9403`). There is no non-200 status on any of
    ///   them. So a 200 proves nothing, and the bytes must be sniffed. `/court/forum/order`
    ///   goes further and passes the upstream content type straight through even on success.
    func orderDocument(for item: CaseItem, in legalCase: LegalCase) async throws -> Data {
        guard let courtType = legalCase.courtType,
              let path = Self.orderPath(forCourtType: courtType)
        else {
            throw APIError.server(
                status: 400,
                message: """
                    Order documents cannot be fetched for this court yet. Open the matter on \
                    the web to reach the court's own copy.
                    """)
        }

        var query = ["caseId": legalCase.id]
        // Best-effort on all three routes. HC and tribunal fall back to the *first* order when
        // nothing matches, so a mismatched date silently hands back a different order.
        if let date = item.itemDateRaw, !date.isEmpty { query["date"] = date }

        let request = try await client.makeRequest("GET", path, query: query)
        let (data, response) = try await client.perform(request)

        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard Self.looksLikePDF(data) || contentType.contains("pdf") else {
            throw APIError.server(
                status: 200,
                message: Self.messageFromErrorPage(data))
        }
        return data
    }

    /// `%PDF-` — the magic bytes. Checked because the content type cannot be trusted either.
    static func looksLikePDF(_ data: Data) -> Bool {
        data.prefix(5).elementsEqual(Data("%PDF-".utf8))
    }

    /// Which proxy, if any, can serve an order for this court.
    ///
    /// - Important: `nclt` and `nclat` are **not** mapped to the tribunal proxy, even though
    ///   they are tribunals. That route rejects anything whose `court_type` is not literally
    ///   `'tribunal'` (`sync-server.js:9282`), and NCLT/NCLAT cases are stored with
    ///   `court_type` of `'nclt'`/`'nclat'` (`sync-server.js:8876, 8919-8924`) — so the fetch
    ///   could never succeed, and every attempt returned an HTML page reading "available for
    ///   tribunal cases only" to a user who was plainly looking at a tribunal case.
    ///
    ///   Returning `nil` produces an honest "not available yet" instead. The scraper does store
    ///   the portal URL on the order row's `data.url`, which is the obvious way to support this
    ///   properly once someone decides whether opening a government portal in Safari is
    ///   acceptable.
    static func orderPath(forCourtType courtType: String) -> String? {
        switch courtType.lowercased() {
        case "hc": return "/court/hc/order"
        case "tribunal": return "/court/tribunal/order"
        case "forum": return "/court/forum/order"
        default: return nil
        }
    }

    /// Pulls the sentence out of the server's HTML error page.
    ///
    /// The page is a single `<div style=...>message</div>`, so stripping tags recovers the
    /// message the server actually wrote — which is more use than "something went wrong".
    static func messageFromErrorPage(_ data: Data) -> String {
        let html = String(decoding: data.prefix(4096), as: UTF8.self)
        let stripped = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = stripped
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.isEmpty
            ? "The court portal did not return the order document."
            : collapsed
    }

    // MARK: - Envelope

    /// This API's envelope is not uniform: a 500 body carries no `success` key at all, so
    /// absence has to be read as failure rather than decoded as a missing field.
    static func throwIfUnsuccessful(success: Bool?, error: String?) throws {
        guard success != true else { return }
        throw APIError.server(
            status: 500, message: error ?? "The server could not complete that request.")
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
