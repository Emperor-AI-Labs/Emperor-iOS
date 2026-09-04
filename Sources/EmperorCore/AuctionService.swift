import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The auction operations a view model needs.
protocol AuctionProviding: Sendable {
    func notices(filter: AuctionFilter, limit: Int, offset: Int) async throws -> AuctionPage
    func facets() async throws -> AuctionFacets
    func notice(id: String) async throws -> AuctionNoticeDetail
    func watchlists() async throws -> [AuctionWatchlist]
    func watch(cin: String?, keyword: String?) async throws -> String
    func unwatch(id: String) async throws
}

/// One page of notices, with the size of the whole result behind it.
///
/// `total` is the count matching the filter, not the page. It is the only paging signal this
/// route offers — there is no cursor and no `hasMore` — so `loaded < total` is how the client
/// knows to ask again.
struct AuctionPage: Equatable, Sendable {
    var notices: [AuctionNotice] = []
    var total = 0
}

/// One notice and everything that amends it.
struct AuctionNoticeDetail: Equatable, Sendable {
    var notice: AuctionNotice
    /// Notices whose `supersedes_unique_number` is this one's `unique_number`, oldest first
    /// (`sync-server.js:10360`). A corrigendum can itself be corrected, so this can be more
    /// than one, and the last is the operative version.
    var amendments: [AuctionNotice] = []

    /// The amendment a reader must see before acting on the figures below it.
    var latestAmendment: AuctionNotice? { amendments.last }
    var isSuperseded: Bool { !amendments.isEmpty }
}

/// The IBBI liquidation e-auction feed.
///
/// Public market data rather than the user's own matters — the routes are global with no team
/// scoping (`sync-server.js:10292`) — but credentials are sent anyway, as everywhere else.
struct AuctionService: AuctionProviding {
    let client: APIClient

    /// Injected so the India day boundary the `upcomingOnly` filter turns into can be asserted
    /// rather than sampled. See `AuctionFilter.upcomingOnly` for why that boundary is computed
    /// here at all instead of being left to the server.
    var now: @Sendable () -> Date = { Date() }

    /// What one page asks for. The server's own default.
    static let pageSize = 50

    /// The ceiling `limit` is clamped to, silently: `Math.min(200, …)` with no indication in the
    /// response that truncation happened (`sync-server.js:10305`). Asking for 500 yields 200 and
    /// a `total` that says there is more, so a client that trusted its own page size would
    /// compute the wrong offset for every subsequent page.
    static let maximumLimit = 200

    // MARK: - Reads

    func notices(
        filter: AuctionFilter = AuctionFilter(),
        limit: Int = pageSize,
        offset: Int = 0
    ) async throws -> AuctionPage {
        var query = filter.queryItems(todayInIndia: WireDate.dayKey(now()))
        query["limit"] = String(min(max(limit, 1), Self.maximumLimit))
        query["offset"] = String(max(0, offset))

        let response = try await withRetry {
            let request = try await client.makeRequest("GET", "/auction-notices", query: query)
            return try await client.send(request, as: AuctionListResponse.self)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return AuctionPage(notices: response.notices ?? [], total: response.total ?? 0)
    }

    /// The values the filters can actually offer.
    ///
    /// Empty facets are a normal answer for an empty table and are not treated as a failure —
    /// unlike the reference library, this feed has no mounted-volume trap where success with
    /// zero rows means the data source is gone.
    func facets() async throws -> AuctionFacets {
        let response = try await withRetry {
            let request = try await client.makeRequest("GET", "/auction-notices/facets")
            return try await client.send(request, as: AuctionFacetsResponse.self)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        // A facet with no value cannot be sent as a filter — `type_of_an = ''` matches nothing —
        // so it is dropped rather than offered as a dead menu entry.
        return AuctionFacets(
            types: (response.types ?? []).filter { !$0.id.isEmpty },
            platforms: (response.platforms ?? []).filter { !$0.id.isEmpty })
    }

    /// One notice, with its corrigenda and addenda.
    ///
    /// - Important: the route advertises a match on `id` **or** `unique_number`
    ///   (`sync-server.js:10358`), but the second half is unreachable. Every `unique_number`
    ///   contains slashes — IBBI's own `Liq.AN/<CIN>/<process>/…` form, or the ingest's
    ///   `fallback:<pdf url>` key — while the route's path pattern is `[^/]+`. Percent-encoding
    ///   does not rescue it either: Node leaves `%2F` encoded in `pathname`, so the lookup would
    ///   run against a string no row holds. So only an id is accepted, and one carrying a slash
    ///   is refused here rather than being turned into a request for some other path.
    func notice(id: String) async throws -> AuctionNoticeDetail {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw APIError.server(status: 404, message: Self.noticeGoneMessage)
        }

        do {
            let response = try await withRetry {
                let request = try await client.makeRequest(
                    "GET", "/auction-notices/\(trimmed)")
                return try await client.send(request, as: AuctionDetailResponse.self)
            }
            try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
            guard let notice = response.notice else {
                throw APIError.server(status: 404, message: Self.noticeGoneMessage)
            }
            return AuctionNoticeDetail(notice: notice, amendments: response.amendments ?? [])
        } catch let error as APIError {
            // The server's own word for this is the bare string "Not found", which read on its
            // own says nothing about what was not found or what to do next.
            throw Self.rewriting(error, status: 404, as: Self.noticeGoneMessage)
        }
    }

    static let noticeGoneMessage =
        "That auction notice is no longer in the IBBI feed."

    // MARK: - Watchlists

    /// - Important: `userId` is **required**, and its absence is reported as HTTP **500**
    ///   `{"error":"Missing userId"}` rather than a 400 (`sync-server.js:10371`) — the route
    ///   throws and the catch-all writes a 500. `RetryPolicy` retries 5xx, so a missing id would
    ///   be sent three times before failing. `makeRequest` attaches it for every GET, and this
    ///   route is unreachable without credentials, so the case cannot arise from here.
    func watchlists() async throws -> [AuctionWatchlist] {
        let response = try await withRetry {
            let request = try await client.makeRequest("GET", "/auction-watchlists")
            return try await client.send(request, as: AuctionWatchlistsResponse.self)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return response.watchlists ?? []
    }

    private struct WatchPayload: Encodable {
        let userId: String
        let cin: String?
        let keyword: String?
    }

    /// Starts watching a company or a keyword. Returns the new watch's id.
    ///
    /// - Important: **not** wrapped in `withRetry`. The insert has no dedup key and no
    ///   uniqueness constraint (`sync-server.js:10386`), so a retried write leaves two identical
    ///   watches and the user is notified twice for every future notice, with nothing on screen
    ///   to explain why.
    ///
    ///   The cin-or-keyword requirement is enforced here rather than left to the server, whose
    ///   refusal is a 500 — which `RetryPolicy` would classify as transient and `LoadFailure`
    ///   would present as "the server is unhappy", when in fact the form was empty.
    func watch(cin: String?, keyword: String?) async throws -> String {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        let cin = Self.text(cin)
        let keyword = Self.text(keyword)
        guard cin != nil || keyword != nil else {
            throw APIError.server(
                status: 400,
                message: "Enter a company CIN or a keyword to watch for.")
        }

        let request = try await client.makeRequest(
            "POST", "/auction-watchlists",
            body: WatchPayload(userId: credentials.userIDString, cin: cin, keyword: keyword))
        let response = try await client.send(request, as: WriteResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        guard let id = response.id else {
            throw APIError.server(status: 500, message: "That watch could not be saved.")
        }
        return id
    }

    /// Stops watching.
    ///
    /// - Important: `id` and `userId` go in the **query string**. This DELETE reads
    ///   `url.searchParams` and never looks at the body (`sync-server.js:10396-10397`), so a
    ///   JSON payload is ignored and the route answers 500 "Missing id or userId".
    ///
    ///   A 403 covers **both** "that watch belongs to someone else" and "there is no such row"
    ///   (`sync-server.js:10399`) — the two are indistinguishable from here. Since the second is
    ///   overwhelmingly the likely one for a list this client just fetched, it is worded as
    ///   already-gone, and the caller re-reads the list rather than assuming the row survived.
    func unwatch(id: String) async throws {
        do {
            let request = try await client.makeRequest(
                "DELETE", "/auction-watchlists", query: ["id": id])
            let response = try await client.send(request, as: WriteResponse.self)
            try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        } catch let error as APIError {
            throw Self.rewriting(error, status: 403, as: Self.watchGoneMessage)
        }
    }

    static let watchGoneMessage = "That watch is no longer on your list."

    // MARK: - Helpers

    /// Replaces the server's terse refusal on one status with wording a reader can act on,
    /// leaving every other failure exactly as it was.
    private static func rewriting(
        _ error: APIError, status: Int, as message: String
    ) -> APIError {
        guard case .server(let received, _) = error, received == status else { return error }
        return .server(status: status, message: message)
    }

    private static func text(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
