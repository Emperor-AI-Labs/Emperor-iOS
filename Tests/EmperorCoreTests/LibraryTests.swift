import XCTest
@testable import EmperorCore

final class LibraryTests: XCTestCase {

    private static func doc(_ id: Int, _ title: String = "Indian Contract Act, 1872") -> LibraryDocument {
        LibraryDocument(id: id, title: title, fileSize: 1024, ext: "pdf", added: "2026-08-01")
    }

    private static func category(_ key: String, count: Int, subFilterType: String? = nil)
        -> LibraryCategory {
        LibraryCategory(key: key, label: key.capitalized, count: count, subFilterType: subFilterType)
    }

    // MARK: - The empty-library trap

    /// **The corpus is unreachable, not empty.** The library lives on a mounted volume; when it
    /// is detached the routes return success with zero rows everywhere rather than failing, and
    /// the web client renders silent empty tabs. A reference library with genuinely nothing in
    /// it is not a state this product has.
    func testAnEveryCategoryZeroCorpusReadsAsUnavailableNotEmpty() async {
        await withLibrary { service, model in
            service.categories = [
                Self.category("bare-acts", count: 0), Self.category("case-law", count: 0),
            ]
            await model.loadCategories()

            XCTAssertTrue(model.corpusLooksUnavailable)
            XCTAssertTrue(model.unavailableMessage.contains("not available"))
            XCTAssertTrue(
                model.unavailableMessage.contains("server"),
                "and it says the problem is not the user's device")
        }
    }

    func testAPopulatedCorpusIsNotFlaggedUnavailable() async {
        await withLibrary { service, model in
            service.categories = [
                Self.category("bare-acts", count: 4_312), Self.category("case-law", count: 0),
            ]
            service.pages = [[Self.doc(1)]]
            service.total = 1
            await model.loadCategories()

            XCTAssertFalse(model.corpusLooksUnavailable)
        }
    }

    /// Opening on an empty tab when a populated one exists wastes the first impression.
    func testItOpensOnTheFirstPopulatedCategory() async {
        await withLibrary { service, model in
            service.categories = [
                Self.category("empty-one", count: 0),
                Self.category("bare-acts", count: 900),
            ]
            service.pages = [[Self.doc(1)]]
            service.total = 1
            await model.loadCategories()

            XCTAssertEqual(model.selectedCategory, "bare-acts")
        }
    }

    // MARK: - Paging

    /// Paging is server-side, so "load more" is a request, not a local slice.
    func testLoadMoreAppendsTheNextServerPage() async {
        await withLibrary { service, model in
            service.categories = [Self.category("bare-acts", count: 3)]
            service.pages = [[Self.doc(1), Self.doc(2)], [Self.doc(3)]]
            service.total = 3
            await model.loadCategories()

            XCTAssertEqual(model.documents.count, 2)
            XCTAssertTrue(model.canLoadMore)

            await model.loadMore()

            XCTAssertEqual(model.documents.map(\.id), [1, 2, 3])
            XCTAssertFalse(model.canLoadMore)
            XCTAssertEqual(service.browseCalls.map(\.page), [1, 2])
        }
    }

    /// The route has no cursor, so a corpus that shifts between pages can repeat a row. A
    /// duplicate id would make `ForEach` misbehave.
    func testADuplicatedRowAcrossPagesIsNotAppendedTwice() async {
        await withLibrary { service, model in
            service.categories = [Self.category("bare-acts", count: 3)]
            service.pages = [[Self.doc(1), Self.doc(2)], [Self.doc(2), Self.doc(3)]]
            service.total = 4
            await model.loadCategories()
            await model.loadMore()

            XCTAssertEqual(model.documents.map(\.id), [1, 2, 3])
        }
    }

    /// A page that comes back empty means the corpus shrank — stop asking rather than looping.
    func testAnEmptyPageStopsPaging() async {
        await withLibrary { service, model in
            service.categories = [Self.category("bare-acts", count: 9)]
            service.pages = [[Self.doc(1)], []]
            service.total = 9
            await model.loadCategories()
            await model.loadMore()

            XCTAssertFalse(model.canLoadMore)
            XCTAssertEqual(model.documents.count, 1)
        }
    }

    /// A failed page must not blank what is already on screen.
    func testAFailedPageKeepsTheExistingResults() async {
        await withLibrary { service, model in
            service.categories = [Self.category("bare-acts", count: 3)]
            service.pages = [[Self.doc(1), Self.doc(2)]]
            service.total = 3
            await model.loadCategories()

            service.error = APIError.transport("offline")
            await model.loadMore()

            XCTAssertEqual(model.documents.count, 2, "the page on screen survives")
            XCTAssertNotNil(model.openError)
        }
    }

    // MARK: - Filtering

    func testChangingCategoryResetsTheSearchAndSubFilter() async {
        await withLibrary { service, model in
            service.categories = [
                Self.category("bare-acts", count: 5, subFilterType: "state"),
                Self.category("case-law", count: 5),
            ]
            service.pages = [[Self.doc(1)]]
            service.total = 1
            service.subFilters = ["Central", "Maharashtra"]
            await model.loadCategories()

            model.query = "contract"
            model.selectedSubFilter = "Maharashtra"
            await model.select(category: "case-law")

            XCTAssertEqual(model.selectedCategory, "case-law")
            XCTAssertTrue(model.query.isEmpty, "a filter from another tab would be nonsense here")
            XCTAssertNil(model.selectedSubFilter)
        }
    }

    /// Sub-filters are only fetched for tabs that declare one.
    func testSubFiltersAreOnlyFetchedWhereTheyExist() async {
        await withLibrary { service, model in
            service.categories = [Self.category("case-law", count: 5)]
            service.pages = [[Self.doc(1)]]
            service.total = 1
            service.subFilters = ["should not appear"]
            await model.loadCategories()

            XCTAssertTrue(model.subFilters.isEmpty)
        }
    }

    /// An empty result from a search is a different message from an empty tab.
    func testNoSearchResultsIsDistinctFromAnEmptyTab() async {
        await withLibrary { service, model in
            service.categories = [Self.category("bare-acts", count: 900)]
            service.pages = [[]]
            service.total = 0
            await model.loadCategories()

            XCTAssertFalse(model.showsNoSearchResults, "no query yet")

            model.query = "nothing matches this"
            await model.reload()

            XCTAssertTrue(model.showsNoSearchResults)
        }
    }

    /// The sort values must be the exact strings the server accepts — anything else silently
    /// falls back to title order (`lib/referenceLibrary.js:181-188`).
    func testSortValuesMatchTheServersVocabulary() {
        XCTAssertEqual(
            Set(LibrarySort.allCases.map(\.rawValue)),
            ["title_asc", "date_desc", "date_asc", "size_desc"])
    }

    // MARK: - Failure and opening

    func testAFailedCategoryLoadIsAFailureNotAnEmptyLibrary() async {
        await withLibrary { service, model in
            service.error = APIError.server(status: 500, message: "Failed to load categories")
            await model.loadCategories()

            XCTAssertTrue(model.presentation.showsFailureState)
            XCTAssertFalse(model.presentation.showsEmptyState)
        }
    }

    func testOpeningADocumentSniffsThePDF() async {
        await withLibrary { service, model in
            service.categories = [Self.category("bare-acts", count: 1)]
            service.pages = [[Self.doc(1)]]
            service.total = 1
            await model.loadCategories()

            await model.open(model.documents[0])

            XCTAssertEqual(model.openDocument?.title, "Indian Contract Act, 1872")
            XCTAssertTrue(model.openDocument?.isPDF == true)
        }
    }

    /// The file route answers a JSON 404 when the row is missing or not downloaded.
    func testAMissingDocumentExplainsItself() async {
        await withLibrary { service, model in
            service.categories = [Self.category("bare-acts", count: 1)]
            service.pages = [[Self.doc(1)]]
            service.total = 1
            await model.loadCategories()

            service.error = APIError.server(
                status: 404, message: "That document is no longer in the library.")
            await model.open(model.documents[0])

            XCTAssertNil(model.openDocument)
            XCTAssertEqual(model.openError, "That document is no longer in the library.")
        }
    }

    func testDocumentTitleFallsBackWhenBlank() {
        XCTAssertEqual(
            LibraryDocument(id: 1, title: "   ", fileSize: nil, ext: nil, added: nil).displayTitle,
            "Untitled document")
    }
}

@MainActor
private func withLibrary(
    _ body: @MainActor (FakeLibrary, LibraryViewModel) async -> Void
) async {
    let service = FakeLibrary()
    await body(service, LibraryViewModel(service: service))
}
