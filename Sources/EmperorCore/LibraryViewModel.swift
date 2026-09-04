import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Browsing the reference corpus.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class LibraryViewModel {

    private(set) var categories: [LibraryCategory] = []
    private(set) var subFilters: [String] = []
    private(set) var documents: [LibraryDocument] = []
    private(set) var total = 0
    private(set) var state: LoadState = .idle
    private(set) var isLoadingMore = false

    private(set) var selectedCategory: String?
    var selectedSubFilter: String?
    var sort: LibrarySort = .titleAscending
    var query = "" {
        didSet { if query != oldValue { pendingSearchChange = true } }
    }

    var openDocument: OpenLibraryDocument?
    var openError: String?

    struct OpenLibraryDocument: Identifiable, Sendable {
        let id = UUID()
        let data: Data
        let title: String
        let isPDF: Bool
    }

    private let service: any LibraryProviding
    private var page = 1
    private var pendingSearchChange = false

    init(service: any LibraryProviding) {
        self.service = service
    }

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: documents.isEmpty)
    }

    var currentCategory: LibraryCategory? {
        categories.first { $0.key == selectedCategory }
    }

    var canLoadMore: Bool { documents.count < total }

    /// **The corpus is unreachable, not empty.**
    ///
    /// The library lives on a mounted volume. When that volume is detached the routes return
    /// success with zero rows everywhere rather than failing, so the web client shows silent
    /// empty tabs. A reference library with genuinely nothing in it is not a state this product
    /// has, so every-category-zero is reported as unavailable.
    var corpusLooksUnavailable: Bool {
        !categories.isEmpty && categories.allSatisfy { ($0.count ?? 0) == 0 }
    }

    var unavailableMessage: String {
        """
        The reference library is not available right now. This is usually the corpus volume \
        being detached on the server rather than anything on your device.
        """
    }

    /// Whether the *current* result set is empty because the search matched nothing, as opposed
    /// to the tab being empty.
    var showsNoSearchResults: Bool {
        documents.isEmpty && state.hasLoaded
            && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Loading

    func loadCategories() async {
        state = .loading
        do {
            categories = try await service.categories()
            if selectedCategory == nil {
                // Open on the first tab that actually has something in it.
                selectedCategory = categories.first { ($0.count ?? 0) > 0 }?.key
                    ?? categories.first?.key
            }
            state = .loaded
            await reload()
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    func select(category: String) async {
        guard category != selectedCategory else { return }
        selectedCategory = category
        selectedSubFilter = nil
        subFilters = []
        query = ""
        pendingSearchChange = false
        await reload()
    }

    /// Re-runs the browse from page one. Called on every filter change.
    func reload() async {
        guard let category = selectedCategory else { return }
        page = 1
        state = .loading
        do {
            async let fetchedFilters = loadSubFiltersIfNeeded(category)
            let result = try await service.browse(
                category: category,
                subFilter: selectedSubFilter,
                search: query.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                sort: sort,
                page: 1,
                pageSize: LibraryService.pageSize)
            documents = result.items
            total = result.total
            subFilters = await fetchedFilters
            pendingSearchChange = false
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    private func loadSubFiltersIfNeeded(_ category: String) async -> [String] {
        guard currentCategory?.hasSubFilters == true else { return [] }
        return (try? await service.subFilters(category: category)) ?? []
    }

    /// Appends the next page. Paging is server-side, so this is not a local slice.
    func loadMore() async {
        guard let category = selectedCategory, canLoadMore, !isLoadingMore,
              state.hasLoaded else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let next = page + 1
            let result = try await service.browse(
                category: category,
                subFilter: selectedSubFilter,
                search: query.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                sort: sort,
                page: next,
                pageSize: LibraryService.pageSize)
            guard !result.items.isEmpty else { total = documents.count; return }
            // Guard against a duplicate page — the server has no cursor, so a shifting corpus
            // can repeat rows and `ForEach` would trap on a duplicate id.
            let known = Set(documents.map(\.id))
            documents += result.items.filter { !known.contains($0.id) }
            total = result.total
            page = next
        } catch {
            // A failed page does not invalidate what is already on screen.
            openError = DisplayText.message(for: error)
        }
    }

    // MARK: - Opening

    func open(_ document: LibraryDocument) async {
        do {
            let data = try await service.document(id: document.id)
            openDocument = OpenLibraryDocument(
                data: data,
                title: document.displayTitle,
                isPDF: document.isPDF || CaseService.looksLikePDF(data))
        } catch {
            openError = DisplayText.message(for: error)
        }
    }
}
