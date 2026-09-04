import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol LibraryProviding: Sendable {
    func categories() async throws -> [LibraryCategory]
    func subFilters(category: String) async throws -> [String]
    func browse(
        category: String, subFilter: String?, search: String?,
        sort: LibrarySort, page: Int, pageSize: Int
    ) async throws -> (items: [LibraryDocument], total: Int)
    func document(id: Int) async throws -> Data
}

/// The shared reference corpus: bare acts, case law, rules.
///
/// ## The empty-library trap
///
/// This corpus lives on a volume at `/mnt/EmpData` (`lib/referenceLibrary.js:15`). When that
/// volume is not mounted the routes do **not** error — `browse` returns `{items: [], total: 0}`
/// and `listCategories` returns every tab with `count: 0`. So a detached volume is
/// indistinguishable from an empty corpus, and the web client renders silent empty tabs.
///
/// `LibraryViewModel` therefore treats "every category reports zero" as *unavailable* rather
/// than *empty*, because a reference library with genuinely nothing in it is not a state this
/// product has.
struct LibraryService: LibraryProviding {
    let client: APIClient

    /// These routes are public — they serve a shared corpus, not user data — but the client
    /// sends its credentials anyway, as it does everywhere else.
    func categories() async throws -> [LibraryCategory] {
        let request = try await client.makeRequest("GET", "/library/categories")
        let response = try await client.send(request, as: LibraryCategoriesResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return response.categories ?? []
    }

    func subFilters(category: String) async throws -> [String] {
        let request = try await client.makeRequest(
            "GET", "/library/subfilters", query: ["category": category])
        let response = try await client.send(request, as: LibrarySubFiltersResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return response.subFilters ?? []
    }

    /// - Note: `pageSize` is clamped server-side to 1...100 with no signal that it happened
    ///   (`lib/referenceLibrary.js:20`), so asking for more silently yields 100.
    func browse(
        category: String,
        subFilter: String? = nil,
        search: String? = nil,
        sort: LibrarySort = .titleAscending,
        page: Int = 1,
        pageSize: Int = Self.pageSize
    ) async throws -> (items: [LibraryDocument], total: Int) {
        var query = [
            "category": category,
            "sort": sort.rawValue,
            "page": String(max(1, page)),
            "pageSize": String(min(max(pageSize, 1), 100)),
        ]
        if let subFilter, !subFilter.isEmpty { query["subFilter"] = subFilter }
        if let search, !search.isEmpty { query["search"] = search }

        let request = try await client.makeRequest("GET", "/library/browse", query: query)
        let response = try await client.send(request, as: LibraryBrowseResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return (response.items ?? [], response.total ?? 0)
    }

    static let pageSize = 40

    /// Fetches a document's bytes.
    ///
    /// This route answers a **JSON 404** when the row is missing or the file is not downloaded,
    /// and raw bytes otherwise — so the body has to be sniffed rather than assumed, as with the
    /// court order proxies.
    func document(id: Int) async throws -> Data {
        let request = try await client.makeRequest(
            "GET", "/library/file", query: ["id": String(id)])
        let (data, response) = try await client.perform(request)

        guard (200..<300).contains(response.statusCode) else {
            throw APIError.server(
                status: response.statusCode,
                message: response.statusCode == 404
                    ? "That document is no longer in the library."
                    : "That document could not be opened.")
        }
        return data
    }
}
