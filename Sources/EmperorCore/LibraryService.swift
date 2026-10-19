import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Filters

/// What `GET /browse` and `GET /search` take. Empty values are not sent, so the request names
/// only the filters in force — and two equal filter sets build one cache key.
struct LibraryBrowseFilters: Equatable, Hashable, Sendable {
    var category: String?
    var court: String?
    var yearFrom: Int?
    var yearTo: Int?
    var docType: String?
    var jurisdiction: String?
    var series: String?
    var parentId: Int?
    var publisher: String?
    var kind: String?
    var letter: String?
    var query: String?
    var sort: String?
    var page: Int = 1
    var pageSize: Int = 36

    init(category: String? = nil, query: String? = nil, sort: String? = nil, page: Int = 1, pageSize: Int = 36) {
        self.category = category
        self.query = query
        self.sort = sort
        self.page = page
        self.pageSize = pageSize
    }

    /// The wire keys (`routes.js` `readFilters`).
    var queryItems: [String: String] {
        var out: [String: String] = [:]
        func put(_ key: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            out[key] = value
        }
        put("category", category)
        put("court", court)
        put("yearFrom", yearFrom.map(String.init))
        put("yearTo", yearTo.map(String.init))
        put("docType", docType)
        put("jurisdiction", jurisdiction)
        put("series", series)
        put("parentId", parentId.map(String.init))
        put("publisher", publisher)
        put("kind", kind)
        put("letter", letter)
        // Clipped as the server clips it (256 chars), so the request and the cache key agree.
        put("q", query.map { String($0.prefix(256)) })
        put("sort", sort)
        out["page"] = String(max(1, page))
        out["pageSize"] = String(min(max(pageSize, 1), 100))
        return out
    }

    /// Whether any narrowing filter is set (the "Clear filters" chip).
    var activeFilterCount: Int {
        [court, docType, jurisdiction, series, publisher, kind, letter].compactMap { $0?.nilIfEmpty }.count
            + (yearFrom == nil ? 0 : 1) + (yearTo == nil ? 0 : 1)
    }
}

/// What `GET /folders` — the A–Z index of Acts — takes.
struct ActIndexFilters: Equatable, Hashable, Sendable {
    var letter: String?
    var jurisdiction: String?
    var query: String?
    /// `acts` (default), `all`, `folders`, `featured`.
    var kind: String?
    var has: String?
    /// `title` (default), `size`, `year`.
    var sort: String?
    var page: Int = 1
    var pageSize: Int = 60

    var queryItems: [String: String] {
        var out: [String: String] = [:]
        func put(_ key: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            out[key] = value
        }
        put("letter", letter)
        put("jurisdiction", jurisdiction)
        put("q", query.map { String($0.prefix(256)) })
        put("kind", kind)
        put("has", has)
        put("sort", sort)
        out["page"] = String(max(1, page))
        out["pageSize"] = String(min(max(pageSize, 1), 200))
        return out
    }
}

/// What came back for a cover: the image, or why there is none yet.
enum LibraryCoverOutcome: Equatable, Sendable {
    case image(Data)
    /// Rendering is still running server-side; ask again after `retryAfter` seconds.
    case pending(retryAfter: Int)
    /// No page image is possible (`reason`): draw the typographic cover.
    case none(reason: String?)
}

/// Which rendering of a document's bytes to fetch.
enum LibraryFilePreference: String, Sendable {
    case original, html, text
}

// MARK: - The protocol

/// The catalogue, as a screen sees it. Everything a view model needs and nothing the server does
/// not offer, so a screen can be driven with no server (`FakeLibrary` in the tests).
protocol LibraryProviding: Sendable {
    func categories() async throws -> [LibraryCategoryCount]
    func facets(category: String) async throws -> LibraryFacets
    func browse(_ filters: LibraryBrowseFilters) async throws -> LibraryPage
    /// A title search over every collection in one call (`/browse?groupBy=category`).
    func browseGrouped(query: String, pageSize: Int) async throws -> LibraryGroupedSearch
    /// Words inside judgments (`/search`).
    func search(_ filters: LibraryBrowseFilters) async throws -> LibraryPage
    func shelf(category: String, limit: Int) async throws -> LibraryShelf
    func seriesShelves(limit: Int, per: Int) async throws -> LibrarySeriesShelves
    func document(id: Int) async throws -> LibraryDocumentDetail
    func act(id: Int) async throws -> ActBundle
    func actIndex(_ filters: ActIndexFilters) async throws -> ActIndexPage
    func judgment(id: Int) async throws -> JudgmentDocument
    func cover(id: Int, width: Int) async throws -> LibraryCoverOutcome
    /// Whether the file's bytes are on this host (`HEAD /file`).
    func fileExists(id: Int) async throws -> Bool
    /// The document's bytes — a PDF, or a judgment's text when `prefer` asks for it.
    func file(id: Int, prefer: LibraryFilePreference) async throws -> Data
}

extension LibraryProviding {
    func shelf(category: String) async throws -> LibraryShelf { try await shelf(category: category, limit: 14) }
    func browseGrouped(query: String) async throws -> LibraryGroupedSearch { try await browseGrouped(query: query, pageSize: 6) }
    func seriesShelves() async throws -> LibrarySeriesShelves { try await seriesShelves(limit: 12, per: 14) }
    func file(id: Int) async throws -> Data { try await file(id: id, prefer: .original) }
}

// MARK: - The service

/// The catalogue-backed Library (`/library/catalogue/*`, `lib/library/routes.js`).
///
/// Any signed-in user may read it: the routes take the bearer token this client sends on every
/// request, and answer `401 auth_required` to anything without one — so a dead token here is a
/// sign-out like anywhere else, not a library fault. Errors are JSON `{error}` with a code
/// (`LibraryCatalogueError`), which is why this reads the body on every non-2xx rather than
/// trusting the status alone.
///
/// The cover widths the server renders are 160, 320 and 640; anything else is `400 bad_width`.
struct LibraryService: LibraryProviding {
    let client: APIClient

    static let coverWidths = [160, 320, 640]
    /// The reader opens judgments up to this; the server refuses to format past 8 MB anyway.
    static let maxReaderBytes = 4 * 1024 * 1024
    static let shelfLimit = 14

    private static let root = "/library/catalogue"

    func categories() async throws -> [LibraryCategoryCount] {
        struct Envelope: Decodable { var categories: [LibraryCategoryCount]? }
        let envelope: Envelope = try await get("/categories")
        return envelope.categories ?? []
    }

    func facets(category: String) async throws -> LibraryFacets {
        struct Envelope: Decodable { var facets: LibraryFacets? }
        let envelope: Envelope = try await get("/facets", query: ["category": category])
        return envelope.facets ?? LibraryFacets()
    }

    func browse(_ filters: LibraryBrowseFilters) async throws -> LibraryPage {
        try await get("/browse", query: filters.queryItems)
    }

    func browseGrouped(query: String, pageSize: Int) async throws -> LibraryGroupedSearch {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return LibraryGroupedSearch() }
        return try await get("/browse", query: [
            "groupBy": "category", "q": String(trimmed.prefix(256)),
            "pageSize": String(min(max(pageSize, 1), 20)),
        ])
    }

    func search(_ filters: LibraryBrowseFilters) async throws -> LibraryPage {
        var items = filters.queryItems
        items["pageSize"] = String(min(max(filters.pageSize, 1), 50))
        return try await get("/search", query: items)
    }

    func shelf(category: String, limit: Int) async throws -> LibraryShelf {
        try await get("/shelf", query: ["category": category, "limit": String(min(max(limit, 1), 40))])
    }

    func seriesShelves(limit: Int, per: Int) async throws -> LibrarySeriesShelves {
        try await get("/shelf", query: [
            "category": LibraryCollection.booksAndReports.rawValue, "by": "series",
            "limit": String(min(max(limit, 1), 30)), "per": String(min(max(per, 1), 40)),
        ])
    }

    func document(id: Int) async throws -> LibraryDocumentDetail {
        struct Envelope: Decodable { var doc: LibraryDocumentDetail }
        let envelope: Envelope = try await get("/doc", query: ["id": String(id)])
        return envelope.doc
    }

    func act(id: Int) async throws -> ActBundle {
        try await get("/act", query: ["id": String(id)])
    }

    func actIndex(_ filters: ActIndexFilters) async throws -> ActIndexPage {
        try await get("/folders", query: filters.queryItems)
    }

    func judgment(id: Int) async throws -> JudgmentDocument {
        try await get("/judgment", query: ["id": String(id)])
    }

    /// `GET /cover?id=&w=`: a JPEG, `404 cover_pending` while it renders, `404 no_cover` when
    /// none can be made.
    func cover(id: Int, width: Int) async throws -> LibraryCoverOutcome {
        let w = Self.coverWidths.contains(width) ? width : 320
        let request = try await client.makeRequest("GET", Self.root + "/cover", query: ["id": String(id), "w": String(w)])
        let (data, http) = try await client.perform(request)
        if (200..<300).contains(http.statusCode) { return .image(data) }
        let failure = try await failure(status: http.statusCode, body: data, response: http)
        if failure.code == "cover_pending" { return .pending(retryAfter: failure.retryAfter ?? 5) }
        if failure.code == "no_cover" { return .none(reason: failure.reason) }
        throw failure
    }

    func fileExists(id: Int) async throws -> Bool {
        let request = try await client.makeRequest("HEAD", Self.root + "/file", query: ["id": String(id)])
        let (data, http) = try await client.perform(request)
        if (200..<300).contains(http.statusCode) { return true }
        if http.statusCode == 404 { return false }
        throw try await failure(status: http.statusCode, body: data, response: http)
    }

    /// The bytes. A row whose file is not on this host answers a JSON 404, which is why the
    /// status is checked before the body is handed to a PDF viewer.
    func file(id: Int, prefer: LibraryFilePreference) async throws -> Data {
        let request = try await client.makeRequest(
            "GET", Self.root + "/file", query: ["id": String(id), "prefer": prefer.rawValue])
        let (data, http) = try await client.perform(request)
        guard (200..<300).contains(http.statusCode) else {
            throw try await failure(status: http.statusCode, body: data, response: http)
        }
        return data
    }

    // MARK: - Plumbing

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let request = try await client.makeRequest("GET", Self.root + path, query: query)
        let (data, http) = try await client.perform(request)
        guard (200..<300).contains(http.statusCode) else {
            throw try await failure(status: http.statusCode, body: data, response: http)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    private struct ErrorBody: Decodable {
        var error: String?
        var message: String?
        var reason: String?
        var hint: String?
    }

    /// Reads a refusal. A 401 is the session ending and is reported as such everywhere else
    /// in the app — the client is told, so it signs out as it would from any other route; the
    /// rest carry the catalogue's own codes.
    private func failure(status: Int, body: Data, response: HTTPURLResponse) async throws -> LibraryCatalogueError {
        let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body)
        if status == 401 {
            await client.noteAuthenticationLost()
            throw APIError.invalidCredentials
        }
        if status == 503, decoded?.error == nil {
            // The front door's own 503, not the catalogue's: the platform is being restarted.
            throw APIError.classify(status: status, body: body)
        }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return LibraryCatalogueError(
            status: status,
            code: decoded?.error ?? "http_\(status)",
            message: decoded?.message,
            reason: decoded?.reason,
            retryAfter: retryAfter)
    }
}
