import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The Library's front room: the collection strip with live counts, one shelf of covers per
/// collection, and the one search box that looks in every collection at once — titles and
/// parties in each, and the words inside judgments.
///
/// What the web's `pages/Library.jsx` + `LibraryHome.jsx` + `SearchResults.jsx` do, with the
/// same honesty rules: a shelf that failed says so on its own plank, and a search that reached
/// nothing says "could not reach" rather than "nothing found".
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class LibraryViewModel {

    private(set) var categories: [LibraryCategoryCount] = []
    private(set) var state: LoadState = .idle

    /// One shelf per collection, loaded independently of the strip.
    struct Shelf: Equatable, Sendable {
        var items: [CatalogueDocument] = []
        var state: LoadState = .idle
        var failure: String? { state.failure?.message }
    }

    private(set) var shelves: [String: Shelf] = [:]

    // MARK: Search

    var query = ""
    private(set) var searchState: LoadState = .idle
    private(set) var searchedFor = ""
    private(set) var titleGroups: [LibraryGroupedSearch.Group] = []
    private(set) var passages: LibraryPage?
    private(set) var passagesFailed = false

    private let service: any LibraryProviding
    private let todayKey: () -> String

    #if canImport(Darwin)
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    #else
    private var searchTask: Task<Void, Never>?
    #endif

    init(service: any LibraryProviding, todayKey: @escaping () -> String = { WireDate.todayKey() }) {
        self.service = service
        self.todayKey = todayKey
    }

    // MARK: - What is on the page

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: categories.isEmpty)
    }

    /// Shelf order: the nine known collections first, then anything the platform added.
    var orderedCategories: [LibraryCategoryCount] {
        let known = LibraryCollection.shelfOrder.compactMap { key in categories.first { $0.key == key.rawValue } }
        let extra = categories.filter { LibraryCollection(rawValue: $0.key) == nil }
        return known + extra
    }

    var totalDocuments: Int { categories.reduce(0) { $0 + ($1.count ?? 0) } }

    /// "3,00,000 documents — every Supreme Court and High Court judgment we hold…"
    var heroLine: String {
        let lead = totalDocuments > 0 ? "\(LibraryTitles.count(totalDocuments)) documents" : "Judgments, Acts, books and orders"
        return lead + " — every Supreme Court and High Court judgment we hold, every Act with its rules, "
            + "and the books lawyers reach for. Search inside any of them, or browse the shelves."
    }

    /// **The corpus is unreachable, not empty.** A catalogue with every count at zero is a host
    /// whose library volume is detached, not a library with nothing in it.
    var corpusLooksUnavailable: Bool {
        !categories.isEmpty && categories.allSatisfy { ($0.count ?? 0) == 0 }
    }

    var unavailableMessage: String {
        "The reference library is not available right now. This is usually the library volume being "
            + "detached on the server rather than anything on your device."
    }

    func shelf(for key: String) -> Shelf { shelves[key] ?? Shelf() }

    func count(for key: String) -> Int? { categories.first { $0.key == key }?.count }

    // MARK: - Loading

    func load() async {
        state = .loading
        do {
            categories = try await service.categories()
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
            return
        }
        await loadShelves()
    }

    /// Every shelf at once, each on its own: a slow or failed shelf never holds the others.
    func loadShelves() async {
        let keys = orderedCategories.map(\.key)
        for key in keys where shelves[key]?.state.hasLoaded != true {
            shelves[key] = Shelf(items: shelves[key]?.items ?? [], state: .loading)
        }
        let pending = keys.filter { shelves[$0]?.state == .loading }
        let service = self.service
        let thisYear = Self.year(of: todayKey())
        let results = await withTaskGroup(of: (String, Result<[CatalogueDocument], Error>).self, returning: [(String, Result<[CatalogueDocument], Error>)].self) { group in
            for key in pending {
                group.addTask {
                    do {
                        return (key, .success(try await Self.shelfItems(for: key, service: service, thisYear: thisYear)))
                    } catch {
                        return (key, .failure(error))
                    }
                }
            }
            var out: [(String, Result<[CatalogueDocument], Error>)] = []
            for await item in group { out.append(item) }
            return out
        }
        for (key, result) in results {
            switch result {
            case .success(let items): shelves[key] = Shelf(items: items, state: .loaded)
            case .failure(let error): shelves[key] = Shelf(items: [], state: .failed(LoadFailure(error)))
            }
        }
    }

    func reloadShelf(_ key: String) async {
        shelves[key] = Shelf(items: shelves[key]?.items ?? [], state: .loading)
        do {
            let items = try await Self.shelfItems(for: key, service: service, thisYear: Self.year(of: todayKey()))
            shelves[key] = Shelf(items: items, state: .loaded)
        } catch {
            shelves[key] = Shelf(items: [], state: .failed(LoadFailure(error)))
        }
    }

    /// `/shelf`, falling back to the first page of `/browse` on a backend without it: newest
    /// first, the Supreme Court for case law, Acts rather than loose notifications for Bare
    /// Acts, and scraper leftovers dropped.
    static func shelfItems(for key: String, service: any LibraryProviding, thisYear: Int) async throws -> [CatalogueDocument] {
        do {
            return try await service.shelf(category: key, limit: LibraryService.shelfLimit).items
        } catch let error as LibraryCatalogueError where error.isMissingRoute {
            var filters = LibraryBrowseFilters(category: key)
            filters.pageSize = LibraryService.shelfLimit * 2
            filters.sort = key == LibraryCollection.caseLaw.rawValue ? "date_desc" : "year_desc"
            if key == LibraryCollection.bareActs.rawValue { filters.docType = "act" }
            if key == LibraryCollection.caseLaw.rawValue { filters.court = "supremecourt" }
            let page = try await service.browse(filters)
            return Array(page.items.filter { LibraryTitles.isShelfWorthy($0, thisYear: thisYear) }.prefix(LibraryService.shelfLimit))
        }
    }

    private static func year(of dayKey: String) -> Int {
        Int(dayKey.prefix(4)) ?? 2026
    }

    // MARK: - Searching

    var isSearching: Bool { !searchedFor.isEmpty || searchState.isLoading }

    /// Submits the box. Never per keystroke: body search reads the index.
    func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !text.isEmpty else { clearSearch(); return }
        searchTask = Task { await runSearch(text) }
    }

    func clearSearch() {
        searchTask?.cancel()
        query = ""
        searchedFor = ""
        titleGroups = []
        passages = nil
        passagesFailed = false
        searchState = .idle
    }

    func runSearch(_ text: String) async {
        searchedFor = text
        searchState = .loading
        passagesFailed = false
        async let grouped = fetchGrouped(text)
        async let inside = fetchPassages(text)
        let (groupResult, passageResult) = await (grouped, inside)
        guard !Task.isCancelled, searchedFor == text else { return }
        switch passageResult {
        case .success(let page): passages = page
        case .failure: passages = nil; passagesFailed = true
        }
        switch groupResult {
        case .success(let groups):
            titleGroups = groups
            searchState = .loaded
        case .failure(let error):
            titleGroups = []
            // Every request failed: say so rather than "Nothing found".
            if passages == nil { searchState = .failed(LoadFailure(error)) } else { searchState = .loaded }
        }
    }

    private func fetchGrouped(_ text: String) async -> Result<[LibraryGroupedSearch.Group], Error> {
        do {
            return .success(try await service.browseGrouped(query: text, pageSize: 6).groups)
        } catch let error as LibraryCatalogueError where error.isMissingRoute {
            // An older backend: one small /browse per collection, as the web did before the
            // grouped route existed.
            var groups: [LibraryGroupedSearch.Group] = []
            for category in orderedCategories {
                var filters = LibraryBrowseFilters(category: category.key, query: text)
                filters.pageSize = 6
                if let page = try? await service.browse(filters), page.total > 0 {
                    groups.append(.init(category: category.key, label: category.label, total: page.total, items: page.items))
                }
            }
            return .success(groups)
        } catch {
            return .failure(error)
        }
    }

    private func fetchPassages(_ text: String) async -> Result<LibraryPage, Error> {
        do {
            var filters = LibraryBrowseFilters(category: LibraryCollection.caseLaw.rawValue, query: text)
            filters.pageSize = 5
            return .success(try await service.search(filters))
        } catch {
            return .failure(error)
        }
    }

    /// Title groups in shelf order, empty collections omitted.
    var orderedGroups: [LibraryGroupedSearch.Group] {
        let order = LibraryCollection.shelfOrder.map(\.rawValue)
        return titleGroups.filter { $0.total > 0 }.sorted { a, b in
            (order.firstIndex(of: a.category) ?? 99) < (order.firstIndex(of: b.category) ?? 99)
        }
    }

    var passageItems: [CatalogueDocument] { passages?.items ?? [] }

    /// Nothing anywhere, after everything answered.
    var searchFoundNothing: Bool {
        searchState.hasLoaded && orderedGroups.isEmpty && passageItems.isEmpty
    }

    /// Both halves failed: the library could not be reached.
    var searchUnreachable: Bool {
        searchState.failure != nil && passages == nil
    }

    enum Copy {
        static let title = "Library"
        static let heroTitle = "The law, properly shelved."
        static let searchPrompt = "Search judgments, acts, books…"
        static let insideJudgments = "Inside judgments"
        static let caseLawByName = "Case law by name"
        static let nothingHint = "Check the spelling, try fewer words, or put a phrase in quotes — \"bona fide purchaser\" — to find it inside judgments."
        static let unreachable = "The library did not answer. Try again in a moment."
        static let emptyShelf = "Nothing on this shelf yet."
    }
}
