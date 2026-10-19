import XCTest
@testable import EmperorCore

/// Hops onto the main actor: the models are `@MainActor`, and a test class is not (Linux XCTest
/// cannot invoke a `@MainActor` test method).
@MainActor
private func onMain(_ body: @MainActor () async throws -> Void) async rethrows {
    try await body()
}


// The Library's screens, driven with no server: the home, a collection, the Bare Acts index,
// the Act page, the judgment reader and the reading room.

private func doc(_ id: Int, _ title: String, category: String = "case-law", pdf: Bool = false) -> CatalogueDocument {
    var d = CatalogueDocument(id: id, title: title, category: category)
    d.ext = pdf ? ".pdf" : ".txt"
    d.render = pdf ? "pdf" : "html"
    return d
}

private func page(_ docs: [CatalogueDocument], total: Int? = nil, pageSize: Int = 36) -> LibraryPage {
    LibraryPage(items: docs, total: total ?? docs.count, page: 1, pageSize: pageSize)
}

@MainActor
private func withHome(_ body: @MainActor (FakeLibrary, LibraryViewModel) async -> Void) async {
    let service = FakeLibrary()
    await body(service, LibraryViewModel(service: service, todayKey: { "2026-10-19" }))
}

@MainActor
private func withCollection(
    _ key: String, query: String = "", _ body: @MainActor (FakeLibrary, LibraryCollectionViewModel) async -> Void
) async {
    let service = FakeLibrary()
    let category = LibraryCategoryCount(key: key, label: LibraryCollectionTheme.theme(for: key).label, count: 100)
    await body(service, LibraryCollectionViewModel(category: category, query: query, service: service, todayKey: { "2026-10-19" }))
}

final class LibraryHomeViewModelTests: XCTestCase {

    func testTheHomeLoadsTheStripAndOneShelfPerCollection() async {
        await withHome { service, model in
            service.categories = [
                .init(key: "case-law", label: "Case law", count: 271_480),
                .init(key: "bare-acts", label: "Bare acts", count: 5_369),
                .init(key: "gazettes", label: "Gazettes", count: 2),
            ]
            service.shelves["case-law"] = LibraryShelf(items: [doc(1, "A vs B")])
            service.shelves["bare-acts"] = LibraryShelf(items: [doc(2, "IPC", category: "bare-acts", pdf: true)])
            await model.load()
            XCTAssertTrue(model.state.hasLoaded)
            XCTAssertEqual(model.orderedCategories.map(\.key), ["bare-acts", "case-law", "gazettes"], "shelf order, the unknown last")
            XCTAssertEqual(model.totalDocuments, 276_851)
            XCTAssertTrue(model.heroLine.hasPrefix("2,76,851 documents"))
            XCTAssertEqual(model.shelf(for: "case-law").items.map(\.id), [1])
            XCTAssertTrue(model.shelf(for: "gazettes").state.hasLoaded)
            XCTAssertEqual(Set(service.shelfCalls), ["case-law", "bare-acts", "gazettes"])
            XCTAssertFalse(model.corpusLooksUnavailable)
        }
    }

    /// **The corpus is unreachable, not empty.** Every count at zero is a detached volume.
    func testEveryCountZeroReadsAsUnavailable() async {
        await withHome { service, model in
            service.categories = [.init(key: "case-law", label: "Case law", count: 0), .init(key: "bare-acts", label: nil, count: 0)]
            await model.load()
            XCTAssertTrue(model.corpusLooksUnavailable)
            XCTAssertTrue(model.unavailableMessage.contains("server"))
        }
    }

    func testAFailedStripIsAFailureAndAFailedShelfStaysOnItsPlank() async {
        await withHome { service, model in
            service.error = APIError.transport("offline")
            await model.load()
            XCTAssertNotNil(model.state.failure)
            XCTAssertTrue(model.shelves.isEmpty)

            service.error = nil
            service.categories = [.init(key: "case-law", label: "Case law", count: 1), .init(key: "tribunals", label: "Tribunals", count: 1)]
            service.shelfError = LibraryCatalogueError(status: 500, code: "library_failed")
            await model.load()
            XCTAssertTrue(model.state.hasLoaded)
            XCTAssertNotNil(model.shelf(for: "case-law").failure)
            XCTAssertNotNil(model.shelf(for: "tribunals").failure)
        }
    }

    /// A backend without `/shelf`: the first page of `/browse`, scraper leftovers dropped.
    func testAMissingShelfRouteFallsBackToBrowse() async {
        await withHome { service, model in
            service.categories = [.init(key: "case-law", label: "Case law", count: 10)]
            service.shelfError = LibraryCatalogueError(status: 404, code: "unknown_library_route")
            var future = doc(9, "Future case")
            future.year = 2050
            service.pages = [page([doc(1, "A vs B"), doc(2, "View"), future])]
            await model.load()
            XCTAssertEqual(model.shelf(for: "case-law").items.map(\.id), [1])
            let call = service.browseCalls.first
            XCTAssertEqual(call?.sort, "date_desc")
            XCTAssertEqual(call?.court, "supremecourt")
            XCTAssertEqual(call?.pageSize, 28)
        }
    }

    func testASearchAsksEveryCollectionAndTheJudgmentsText() async {
        await withHome { service, model in
            service.categories = [.init(key: "case-law", label: "Case law", count: 10), .init(key: "bare-acts", label: "Bare acts", count: 10)]
            service.grouped = LibraryGroupedSearch(groups: [
                .init(category: "case-law", label: "Case law", total: 3_400, items: [doc(1, "Money v. Laundering")]),
                .init(category: "bare-acts", label: "Bare acts", total: 12, items: [doc(2, "PMLA", category: "bare-acts", pdf: true)]),
                .init(category: "tribunals", label: "Tribunals", total: 0, items: []),
            ])
            var passage = doc(3, "State v. X")
            passage.snippet = LibrarySnippet(text: "money laundering is", before: true, after: true)
            service.searchPages = [LibraryPage(items: [passage], total: 1000, page: 1, pageSize: 5, totalIsCapped: true)]
            model.query = "  money laundering "
            model.search()
            await Task.yield()
            while model.searchState.isLoading { await Task.yield() }
            XCTAssertEqual(model.searchedFor, "money laundering")
            XCTAssertEqual(model.orderedGroups.map(\.category), ["bare-acts", "case-law"], "shelf order, empty collections omitted")
            XCTAssertEqual(model.passageItems.first?.snippet?.text, "money laundering is")
            XCTAssertEqual(model.passages?.totalIsCapped, true)
            XCTAssertEqual(service.searchCalls.first?.category, "case-law")
            XCTAssertEqual(service.searchCalls.first?.pageSize, 5)
            XCTAssertFalse(model.searchFoundNothing)

            model.clearSearch()
            XCTAssertEqual(model.query, "")
            XCTAssertFalse(model.isSearching)
            XCTAssertTrue(model.orderedGroups.isEmpty)
        }
    }

    func testNothingFoundIsNotTheSameAsCouldNotReach() async {
        await withHome { service, model in
            service.grouped = LibraryGroupedSearch()
            model.query = "zzz"
            await model.runSearch("zzz")
            XCTAssertTrue(model.searchFoundNothing)
            XCTAssertFalse(model.searchUnreachable)

            service.groupedError = APIError.transport("offline")
            service.searchError = APIError.transport("offline")
            await model.runSearch("zzz")
            XCTAssertTrue(model.searchUnreachable)
            XCTAssertFalse(model.searchFoundNothing)
            XCTAssertTrue(model.passagesFailed)
        }
    }

    /// An older backend without the grouped route: one small browse per collection.
    func testAMissingGroupedRouteAsksEachCollection() async {
        await withHome { service, model in
            service.categories = [.init(key: "case-law", label: "Case law", count: 10), .init(key: "bare-acts", label: "Bare acts", count: 10)]
            service.groupedError = LibraryCatalogueError(status: 404, code: "unknown_library_route")
            service.pages = [page([doc(1, "PMLA")], total: 12)]
            await model.load()
            await model.runSearch("pmla")
            XCTAssertEqual(model.orderedGroups.count, 2)
            XCTAssertEqual(service.browseCalls.filter { $0.query == "pmla" }.map(\.category), ["bare-acts", "case-law"])
        }
    }
}

final class LibraryCollectionViewModelTests: XCTestCase {

    func testACollectionLoadsFacetsAndItsFirstPage() async {
        await withCollection("regulator-orders") { service, model in
            var facets = LibraryFacets()
            facets.publishers = [.init(value: "sebi", label: "SEBI", count: 1200), .init(value: "rbi", label: "RBI", count: 900)]
            facets.kinds = [.init(value: "adjudication", label: "Adjudication orders", count: 300)]
            facets.yearRange = LibraryYearRange(min: 1990, max: 2095)
            facets.sorts = [.init(value: "year_desc", label: "Newest")]
            service.facets["regulator-orders"] = facets
            service.pages = [page([doc(1, "Order 1", category: "regulator-orders", pdf: true)], total: 2650, pageSize: 25)]
            await model.load()
            XCTAssertEqual(model.layout, .list, "orders are read by reference, not browsed by look")
            XCTAssertEqual(model.filters.sort, "year_desc")
            XCTAssertEqual(service.browseCalls.first?.pageSize, 25)
            XCTAssertEqual(model.facetRows, [.publishers, .years], "a row of one kind is not offered")
            XCTAssertEqual(model.yearRange?.max, 2027, "a year parsed from a title is not a hint")
            XCTAssertEqual(model.countLine, "2,650 orders")
            XCTAssertEqual(model.options(for: .publishers).map(\.value), ["sebi", "rbi"])
        }
    }

    func testChoosingAFacetReloadsAndChoosingItAgainClears() async {
        await withCollection("tribunals") { service, model in
            service.pages = [page([doc(1, "O.A. 1", category: "tribunals", pdf: true)], total: 1)]
            await model.load()
            await model.select(.publishers, value: "tdsat")
            XCTAssertEqual(model.filters.publisher, "tdsat")
            XCTAssertEqual(service.browseCalls.last?.publisher, "tdsat")
            XCTAssertEqual(model.activeFilters.map(\.label), ["TDSAT"])
            await model.select(.publishers, value: "tdsat")
            XCTAssertNil(model.filters.publisher)
            await model.setYears(from: 2015, to: 2020)
            XCTAssertEqual(model.yearText, "2015–2020")
            XCTAssertEqual(model.activeFilters.map(\.facet), [.years])
            await model.clear(.years)
            XCTAssertNil(model.yearText)
            let calls = service.browseCalls.count
            await model.select(.publishers, value: nil)
            XCTAssertEqual(service.browseCalls.count, calls, "clearing nothing asks nothing")
        }
    }

    func testLoadMoreAppendsTheNextServerPageOnce() async {
        await withCollection("law-commission-reports") { service, model in
            service.pages = [page([doc(1, "R1", category: "law-commission-reports", pdf: true), doc(2, "R2", category: "law-commission-reports", pdf: true)], total: 4),
                             page([doc(2, "R2", category: "law-commission-reports", pdf: true), doc(3, "R3", category: "law-commission-reports", pdf: true)], total: 4),
                             page([], total: 4)]
            await model.load()
            XCTAssertTrue(model.canLoadMore)
            await model.loadMore()
            XCTAssertEqual(model.documents.map(\.id), [1, 2, 3], "a row repeated across pages is not appended twice")
            XCTAssertEqual(service.browseCalls.last?.page, 2)
            await model.loadMore()
            XCTAssertEqual(model.total, 3, "an empty page ends paging")
            XCTAssertFalse(model.canLoadMore)
        }
    }

    func testCaseLawSearchesNamesOrWordsInside() async {
        await withCollection("case-law", query: "bona fide") { service, model in
            var facets = LibraryFacets()
            facets.courts = [.init(value: "delhi", label: "Delhi High Court", count: 65_998), .init(value: "supremecourt", label: "Supreme Court", count: 30_724)]
            facets.yearRange = LibraryYearRange(min: 1950, max: 2027)
            facets.years = [.init(year: 2020, count: 10), .init(year: 2021, count: 5)]
            service.facets["case-law"] = facets
            var future = doc(9, "Future v. Case")
            future.decidedOn = "2026-12-17"
            var now = doc(1, "Bona v. Fide")
            now.decidedOn = "2026-10-01"
            service.pages = [page([future, now], total: 2, pageSize: 25)]
            var inside = doc(5, "Words v. Inside")
            inside.snippet = LibrarySnippet(text: "bona fide purchaser", before: true, after: false)
            service.searchPages = [LibraryPage(items: [inside], total: 1000, page: 1, pageSize: 25, totalIsCapped: true,
                                               index: LibrarySearchIndexStatus(available: true, ready: true, complete: false, indexed: 200_000, pending: 71_480, noText: 0, total: 271_480))]
            await model.load()
            XCTAssertEqual(model.documents.map(\.id), [1, 9], "a future-dated row goes to the end of a newest list")
            XCTAssertEqual(model.countLine, "2 judgments with “bona fide” in the case name")
            XCTAssertEqual(model.options(for: .courts).map(\.value), ["supremecourt", "delhi"], "rail order")
            XCTAssertEqual(model.sortOptions.map(\.value), ["date_desc", "date_asc", "title_asc"])
            XCTAssertEqual(model.currentSort, "date_desc")
            XCTAssertEqual(model.judgments(inYears: 2020, 2021), 15)

            await model.setInText(true)
            XCTAssertEqual(service.searchCalls.count, 1)
            XCTAssertEqual(model.documents.map(\.id), [5])
            XCTAssertEqual(model.countLine, "1,000+ judgments with “bona fide” in the text")
            XCTAssertEqual(model.sortOptions.first?.label, "Best match")
            XCTAssertEqual(model.currentSort, "")
            XCTAssertEqual(model.indexNote, "The text of 2,00,000 of 2,71,480 judgments is searchable so far.")
            let row = model.caseRow(for: inside)
            XCTAssertEqual(row.passage?.text, "bona fide purchaser")
            XCTAssertFalse(row.noPassage)
            XCTAssertEqual(model.caseRow(for: future).date, "Date unclear")
            XCTAssertEqual(model.caseRow(for: now).date, "1 Oct 2026")

            await model.setCourt("delhi")
            XCTAssertEqual(service.searchCalls.last?.court, "delhi")
            XCTAssertTrue(model.countLine?.hasSuffix("· Delhi High Court") ?? false)
            XCTAssertEqual(model.activeFilters.map(\.label), ["Delhi HC"])
            XCTAssertEqual(model.emptyTitle, "No judgments contain “bona fide”")
        }
    }

    func testBooksOpenOnTheirShelvesAndASeries() async {
        await withCollection("books-and-law-reports") { service, model in
            var vol = doc(10, "Calcutta Law Journal, Vol-01", category: "books-and-law-reports", pdf: true)
            vol.series = "Calcutta Law Journal"
            vol.volume = "Vol-01"
            vol.year = 1904
            service.seriesShelves = LibrarySeriesShelves(
                seriesTotal: 200, shelves: [.init(series: "CALCUTTA LAW JOURNAL", count: 66, yearMin: 1904, yearMax: 1952, items: [vol])],
                standalone: .init(count: 1000, items: [doc(11, "A Treatise", category: "books-and-law-reports", pdf: true)]))
            var v2 = doc(12, "Calcutta Law Journal, Vol-02", category: "books-and-law-reports", pdf: true)
            v2.series = "Calcutta Law Journal"
            v2.volume = "Vol-02"
            v2.year = 1905
            service.pages = [page([v2, vol], total: 2)]
            await model.load()
            XCTAssertTrue(model.showsOverview)
            XCTAssertEqual(model.seriesShelves?.shelves.first?.count, 66)
            XCTAssertEqual(model.shelfCaption(for: vol, series: "CALCUTTA LAW JOURNAL").kicker, "Calcutta Law Journal")

            await model.open(series: "CALCUTTA LAW JOURNAL")
            XCTAssertEqual(model.openSeries, "CALCUTTA LAW JOURNAL")
            XCTAssertEqual(service.browseCalls.last?.series, "CALCUTTA LAW JOURNAL")
            XCTAssertEqual(service.browseCalls.last?.sort, "year_asc")
            XCTAssertEqual(model.seriesVolumes.map(\.id), [10, 12], "volume order")
            XCTAssertEqual(model.seriesLine, "2 volumes · 1904–1905")
            XCTAssertEqual(model.caption(for: v2).title, "Vol. 2")
            model.closeSeries()
            XCTAssertNil(model.openSeries)

            model.showsAllBooks = true
            XCTAssertFalse(model.showsOverview)
            model.showsAllBooks = false
            model.query = "evidence"
            await model.search()
            XCTAssertFalse(model.showsOverview, "a search reaches past the shelves")
            XCTAssertTrue(model.showsAllBooks)
        }
    }

    func testTheSmallCollectionsLoadWholeForTheirFrontRooms() async {
        await withCollection("professional-institutes") { service, model in
            var icai = doc(1, "SA 200", category: "professional-institutes", pdf: true)
            icai.publisher = "ICAI"
            var icsi = doc(2, "SS-1", category: "professional-institutes", pdf: true)
            icsi.publisher = "ICSI"
            service.pages = [page([icai, icsi], total: 150), page([], total: 150)]
            await model.load()
            XCTAssertTrue(model.showsOverview)
            XCTAssertEqual(model.institute("ICAI").map(\.id), [1])
            XCTAssertEqual(model.institute("ICMAI").count, 0)
            XCTAssertEqual(service.browseCalls.first { $0.pageSize == 100 }?.sort, "title_asc")
            XCTAssertEqual(service.browseCalls.filter { $0.pageSize == 100 }.count, 2, "150 rows take two pages of a hundred")
        }
        await withCollection("parliament-prs") { service, model in
            var facets = LibraryFacets()
            facets.kinds = [.init(value: "act", label: "Acts and bills", count: 20), .init(value: "committee", label: "Committee reports", count: 10)]
            service.facets["parliament-prs"] = facets
            var bill = doc(1, "Bill", category: "parliament-prs", pdf: true)
            bill.kind = "act"
            var other = doc(2, "Other", category: "parliament-prs", pdf: true)
            other.genericTitle = true
            service.pages = [page([bill, other], total: 2)]
            await model.load()
            XCTAssertEqual(model.kindGroups.map(\.label), ["Acts and bills", "Other"])
            XCTAssertEqual(model.caption(for: other).meta.last, "Bill name not recorded")
        }
        await withCollection("legal-aid-nalsa") { service, model in
            service.pages = [page([doc(1, "Report", category: "legal-aid-nalsa", pdf: true)], total: 1)]
            await model.load()
            XCTAssertTrue(model.featureNote.hasPrefix("One paper so far."))
            XCTAssertEqual(model.caption(for: model.overviewItems[0]).eyebrow, "NALSA")
        }
    }

    func testCaptionsPerCollection() async {
        await withCollection("law-commission-reports") { _, model in
            var report = doc(1, "Accessible_(PDF 5.80MB)", category: "law-commission-reports", pdf: true)
            report.reportNo = 277
            report.year = 2018
            report.subject = "Wrongful Prosecution"
            report.lang = "Hindi"
            let caption = model.caption(for: report)
            XCTAssertEqual(caption.headline, "Report No. 277")
            XCTAssertEqual(caption.title, "Wrongful Prosecution")
            XCTAssertEqual(caption.meta, ["2018", "Hindi edition"])
            XCTAssertEqual(caption.label?.top, "No. 277")
        }
        await withCollection("regulator-orders") { _, model in
            var order = doc(1, "Adjudication order in the matter of X", category: "regulator-orders", pdf: true)
            order.publisher = "SEBI"
            order.kind = "adjudication"
            order.displayRef = "Order No. 12"
            order.decidedOn = "2025-11-28"
            let caption = model.caption(for: order)
            XCTAssertEqual(caption.eyebrow, "Order No. 12 · 28 Nov 2025")
            XCTAssertEqual(caption.meta, ["SEBI", "Adjudication order"])
            XCTAssertEqual(caption.kicker, "SEBI")
        }
    }

    func testAFailedPageIsAFailureNotAnEmptyShelf() async {
        await withCollection("tribunals") { service, model in
            service.error = APIError.transport("offline")
            await model.load()
            XCTAssertNotNil(model.state.failure)
            XCTAssertNotNil(model.presentation.state.failure)
            XCTAssertTrue(model.documents.isEmpty)
        }
    }
}

private func actIndexItem(_ id: Int, _ title: String, letter: String = "P") -> CatalogueDocument {
    var d = doc(id, title, category: "bare-acts", pdf: true)
    d.docType = "act"
    d.firstLetter = letter
    d.jurisdiction = "Central"
    return d
}

@MainActor
private func makeActIndex(count: Int? = 5369) -> (FakeLibrary, BareActsIndexViewModel) {
    let service = FakeLibrary()
    return (service, BareActsIndexViewModel(collectionCount: count, service: service))
}

final class BareActsIndexViewModelTests: XCTestCase {

    func testTheIndexLoadsWithTheFeaturedShelfWhileBrowsing() async throws {
        try await onMain {
        let (service, model) = await makeActIndex()
        service.actIndexPages = [ActIndexPage(items: [actIndexItem(1, "PMLA")], total: 3154, page: 1, pageSize: 60,
                                              letters: [.init(letter: "A", count: 210), .init(letter: "#", count: 4)],
                                              jurisdictions: [.init(value: "Central", label: "Central", count: 1206)])]
        await model.load()
        XCTAssertTrue(model.state.hasLoaded)
        XCTAssertTrue(model.isBrowsing)
        XCTAssertEqual(model.countLine, "3,154 Acts")
        XCTAssertEqual(model.headerStat, "5,369 documents, 3,154 volumes.")
        XCTAssertEqual(model.letters.count, 2)
        XCTAssertEqual(model.letterTotal, 214)
        XCTAssertTrue(service.actIndexCalls.contains { $0.kind == "featured" && $0.pageSize == 40 })
        XCTAssertNil(service.actIndexCalls.first?.kind)
        }
    }

    func testFiltersAreDescribedAndASearchReachesEverything() async throws {
        try await onMain {
        let (service, model) = await makeActIndex()
        service.actIndexPages = [ActIndexPage(items: [actIndexItem(1, "PMLA")], total: 83, page: 1, pageSize: 60)]
        await model.load()
        await model.pick(letter: "I")
        await model.pick(jurisdiction: "Central")
        await model.pick(has: "rules")
        XCTAssertEqual(model.countLine, "83 Central Acts under I, with rules")
        XCTAssertFalse(model.isBrowsing)
        XCTAssertEqual(service.actIndexCalls.last?.letter, "I")
        XCTAssertEqual(service.actIndexCalls.last?.has, "rules")
        await model.pick(letter: "I")
        XCTAssertNil(model.letter, "choosing the active letter clears it")
        model.query = "pmla"
        await model.search()
        XCTAssertEqual(service.actIndexCalls.last?.kind, "all")
        XCTAssertEqual(service.actIndexCalls.last?.query, "pmla")
        XCTAssertEqual(model.countLine, "83 Central Acts with rules, matching “pmla”")
        await model.pick(jurisdiction: "none")
        XCTAssertTrue(model.countLine?.contains("with no jurisdiction recorded") ?? false)
        await model.set(sort: .year)
        XCTAssertEqual(service.actIndexCalls.last?.sort, "year")
        await model.clearFilters()
        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.has)
        }
    }

    func testLoadMoreAppendsWithoutRepeats() async throws {
        try await onMain {
        let (service, model) = await makeActIndex()
        service.actIndexPages = [ActIndexPage(items: [actIndexItem(1, "A"), actIndexItem(2, "B")], total: 3, page: 1, pageSize: 2),
                                 ActIndexPage(items: [actIndexItem(2, "B"), actIndexItem(3, "C")], total: 3, page: 2, pageSize: 2)]
        await model.load()
        XCTAssertTrue(model.canLoadMore)
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id), [1, 2, 3])
        XCTAssertFalse(model.canLoadMore)
        }
    }
}

private func actBundleFixture() -> ActBundle {
        func d(_ id: Int, _ title: String, type: String = "rules", year: Int = 2005, size: Int = 1000) -> CatalogueDocument {
            var x = doc(id, title, category: "bare-acts", pdf: true)
            x.docType = type
            x.year = year
            x.fileSize = size
            x.jurisdiction = "Central"
            return x
        }
        var act = d(2478, "THE PREVENTION OF MONEY-LAUNDERING ACT, 2002", type: "act", year: 2002, size: 512_000)
        act.aliases = ["PMLA"]
        var repealed = d(5334, "Forms Rules, 2005 (Rep., Act 1 of 2020)", year: 2006)
        repealed.repealed = true
        var assam = d(7001, "The Prevention of Money-Laundering Act, 2002", type: "act", year: 2002, size: 40_000)
        assam.jurisdiction = "Assam"
        return ActBundle(
            act: act, bundleId: 2478, requestedId: 5333, selectedId: 5333, selectedTab: "rules", orphan: false, kind: "act",
            tabs: [.init(key: "act", label: "The Act", count: 1, docs: [act]),
                   .init(key: "rules", label: "Rules", count: 2, docs: [d(5333, "Appeal Rules, 2005"), repealed]),
                   .init(key: "editions", label: "Other editions", count: 1, docs: [assam])])
    }

@MainActor
private func makeActPage(id: Int = 5333) -> (FakeLibrary, ActPageViewModel) {
    let service = FakeLibrary()
    service.acts[id] = actBundleFixture()
    service.files[2478] = Data("%PDF-1.4 act".utf8)
    service.files[5333] = Data("%PDF-1.4 rules".utf8)
    service.files[5334] = Data("%PDF-1.4 old".utf8)
    return (service, ActPageViewModel(id: id, service: service))
}

final class ActPageViewModelTests: XCTestCase {

    func testLandingOnARuleOpensItsTabWithItSelected() async throws {
        try await onMain {
        let (service, model) = await makeActPage()
        await model.load()
        XCTAssertEqual(model.activeTab?.key, "rules")
        XCTAssertEqual(model.current?.id, 5333)
        XCTAssertEqual(model.tabs.map(\.label), ["The Act", "Rules", "Other editions"])
        XCTAssertEqual(model.title, "The Prevention of Money-Laundering Act")
        XCTAssertEqual(model.kickerParts, ["Central Act", "2002", "PMLA"])
        XCTAssertEqual(model.holdsLine, "2 rules")
        XCTAssertEqual(model.position?.index, 0)
        XCTAssertEqual(model.position?.total, 2)
        XCTAssertEqual(model.latestID, 5334)
        XCTAssertEqual(service.headCalls, [5333])
        XCTAssertEqual(model.currentData, Data("%PDF-1.4 rules".utf8))
        XCTAssertEqual(model.paneKindLabel, "Rules")
        XCTAssertFalse(model.isPrincipal)
        }
    }

    func testMovingThroughTheTabKeepsEachPDF() async throws {
        try await onMain {
        let (service, model) = await makeActPage()
        await model.load()
        XCTAssertTrue(model.hasNext)
        await model.next()
        XCTAssertEqual(model.current?.id, 5334)
        XCTAssertFalse(model.hasNext)
        await model.previous()
        XCTAssertEqual(model.current?.id, 5333)
        XCTAssertEqual(service.fileCalls.map(\.id), [5333, 5334], "switching back never reloads")
        await model.pickTab("act")
        XCTAssertEqual(model.current?.id, 2478)
        XCTAssertTrue(model.isPrincipal)
        XCTAssertEqual(model.editions.map(\.id), [7001])
        XCTAssertEqual(model.editionLabel(model.editions[0], index: 0), "Edition 2 · Assam copy · 39 KB")
        XCTAssertEqual(model.currentEditionLabel, "Current edition · 500 KB")
        await model.pick(model.editions[0])
        XCTAssertEqual(model.paneKindLabel, "Other edition")
        XCTAssertTrue(model.currentIsMissing, "the Assam copy is not on this server")
        XCTAssertEqual(model.alternatives.map(\.doc.id), [2478])
        XCTAssertEqual(model.alternatives.first?.label, "the current edition")
        }
    }

    func testTheInstrumentFilterAndTheMissingAct() async throws {
        try await onMain {
        let (_, model) = await makeActPage()
        await model.load()
        model.instrumentFilter = "forms"
        XCTAssertEqual(model.filteredList.map(\.id), [5334])
        model.instrumentFilter = "2006"
        XCTAssertEqual(model.filteredList.map(\.id), [5334])
        XCTAssertFalse(model.showsFilter, "ten rows or fewer need no filter")

        let service = FakeLibrary()
        service.error = LibraryCatalogueError(status: 404, code: "not_an_act")
        let gone = await MainActor.run { ActPageViewModel(id: 1, service: service) }
        await gone.load()
        XCTAssertEqual(gone.failureTitle, "There is no such Act")
        }
    }

    func testAnAmendmentGroupReadsAsAChronology() async throws {
        try await onMain {
        let service = FakeLibrary()
        func d(_ id: Int, _ year: Int) -> CatalogueDocument { var x = doc(id, "Assam Motor Vehicles Taxation (Amendment) Act, \(year)", category: "bare-acts", pdf: true); x.year = year; x.jurisdiction = "Assam"; return x }
        service.acts[9] = ActBundle(act: d(9, 2019), kind: "amendments", groupTitle: "Assam Motor Vehicles Taxation Act",
                                    tabs: [.init(key: "act", label: "The Act", count: 1, docs: [d(9, 2019)]),
                                           .init(key: "amendments", label: "Amendments", count: 1, docs: [d(8, 1990)])])
        let model = await MainActor.run { ActPageViewModel(id: 9, service: service) }
        await model.load()
        XCTAssertEqual(model.activeTab?.key, "amendments")
        XCTAssertTrue(model.isChronology)
        XCTAssertEqual(model.list.map(\.id), [8, 9])
        XCTAssertEqual(model.title, "Assam Motor Vehicles Taxation Act")
        XCTAssertEqual(model.kickerParts, ["Amending Acts", "Assam"])
        XCTAssertEqual(model.standingNote, "The Act itself is not in the library")
        XCTAssertEqual(model.holdsLine, "2 amending Acts")
        }
    }
}

private func judgmentFixture() -> JudgmentDocument {
        var header = JudgmentHeader()
        header.court = "supremecourt"
        header.petitioner = "UNION OF INDIA"
        header.respondent = "SISTEMA SHYAM TELESERVICES LIMITED"
        header.caseType = "Civil Appeal"
        header.caseNumber = "4629 of 2008"
        header.decidedOn = "2026-02-20"
        header.bench = ["B.R. Gavai", "K. Vinod Chandran"]
        header.author = "B.R. Gavai"
        header.citations = ["(2026) 3 SCC 1"]
        header.neutralCitation = "2026 INSC 210"
        header.source = "https://indiankanoon.org/doc/1/"
        header.citesCount = 12
        return JudgmentDocument(
            header: header,
            blocks: [JudgmentBlock(id: "h-0", type: "heading", text: "JUDGMENT", level: 1),
                     JudgmentBlock(id: "para-1", type: "para", text: "Leave granted.", n: "1"),
                     JudgmentBlock(id: "para-2", type: "para", text: "The bona fide purchaser prevails.", n: "2"),
                     JudgmentBlock(id: "para-3", type: "para", text: "Dismissed. Bona fide.", n: "3")],
            toc: [JudgmentTOCEntry(id: "h-0", label: "Judgment", level: 1), JudgmentTOCEntry(id: "para-2", label: "Para 2", level: 3)],
            stats: JudgmentStats(paragraphs: 3, words: 1204, blocks: 4, layout: "wrapped", debrisLines: 0, formatMs: 10))
    }

@MainActor
private func makeReader(store: InMemoryPreferenceStore = InMemoryPreferenceStore()) -> (FakeLibrary, JudgmentReaderViewModel) {
    let service = FakeLibrary()
    service.judgments[257_708] = judgmentFixture()
    var row = doc(257_708, "Union Of India vs Sistema Shyam Teleservices Limited on 20 February, 2026")
    row.court = "supremecourt"
    return (service, JudgmentReaderViewModel(doc: row, service: service, store: store, todayKey: { "2026-10-19" }))
}

final class JudgmentReaderViewModelTests: XCTestCase {

    func testTheStructuredJudgmentFillsTheHeaderCard() async throws {
        try await onMain {
        let (_, model) = await makeReader()
        await model.load()
        XCTAssertEqual(model.source, .structured)
        XCTAssertEqual(model.court.name, "Supreme Court of India")
        XCTAssertEqual(model.caseTitle, "Union of India v. Sistema Shyam Teleservices Limited")
        XCTAssertEqual(model.caseNumberLine, "Civil Appeal No. 4629 of 2008")
        XCTAssertEqual(model.facts.map(\.label), ["Decided", "Bench of 2", "Judgment by", "Length"])
        XCTAssertEqual(model.facts[0].value, "20 Feb 2026")
        XCTAssertEqual(model.facts[3].value, "3 paragraphs · 5 min read")
        XCTAssertEqual(model.citations, ["2026 INSC 210", "(2026) 3 SCC 1"])
        XCTAssertEqual(model.citationLine, "Union of India v. Sistema Shyam Teleservices Limited, 2026 INSC 210 (Supreme Court, 20 Feb 2026)")
        XCTAssertEqual(model.citesLine, "Cites 12 · Cited by 0")
        XCTAssertNotNil(model.sourceURL)
        XCTAssertEqual(model.headings.map(\.id), ["h-0"])
        XCTAssertEqual(model.lastParagraph, "3")
        XCTAssertEqual(model.lengthLine, "3 paragraphs · 1,204 words · about 5 min")
        XCTAssertNil(model.plainTextNote)
        XCTAssertTrue(model.plainText.contains("2. The bona fide purchaser prevails."))
        }
    }

    func testFindStepsThroughTheMatchesAndGoToParagraphAnswers() async throws {
        try await onMain {
        let (_, model) = await makeReader()
        await model.load()
        model.find = "bona fide"
        XCTAssertEqual(model.findCountLine, "– / 2")
        model.stepFind(1)
        XCTAssertEqual(model.currentHit, 0)
        XCTAssertEqual(model.scrollTarget?.blockID, "para-2")
        XCTAssertEqual(model.findCountLine, "1 / 2")
        model.stepFind(1)
        XCTAssertEqual(model.scrollTarget?.blockID, "para-3")
        model.stepFind(1)
        XCTAssertEqual(model.currentHit, 0, "wraps")
        XCTAssertEqual(model.currentHitIndex(in: 2), 0)
        XCTAssertNil(model.currentHitIndex(in: 3))
        XCTAssertEqual(model.hits(in: 3).count, 1)
        model.find = "x"
        XCTAssertNil(model.findCountLine)
        model.find = "zzz"
        XCTAssertEqual(model.findCountLine, "None")

        model.goToParagraph("2")
        XCTAssertEqual(model.scrollTarget?.blockID, "para-2")
        XCTAssertTrue(model.scrollTarget?.flash ?? false)
        model.goToParagraph("9")
        XCTAssertEqual(model.notice, "There is no paragraph 9. The last is 3.")
        model.goToParagraph("2.5")
        XCTAssertEqual(model.scrollTarget?.blockID, "para-3")
        XCTAssertEqual(model.notice, "No paragraph 2.5; showing 3.")
        let token = model.scrollTarget?.token
        model.jump(to: "h-0", flash: false)
        XCTAssertNotEqual(model.scrollTarget?.token, token, "every jump is new, even to the same block")
        }
    }

    func testReadingComfortIsRemembered() async throws {
        try await onMain {
        let store = InMemoryPreferenceStore()
        let (_, model) = await makeReader(store: store)
        model.grow()
        model.grow()
        model.preferences.face = .sans
        XCTAssertEqual(model.preferences.percent, 117)
        let again = await MainActor.run { JudgmentReaderViewModel(doc: doc(1, "x"), service: FakeLibrary(), store: store) }
        XCTAssertEqual(again.preferences.size, 4)
        XCTAssertEqual(again.preferences.face, .sans)
        for _ in 0..<10 { again.grow() }
        XCTAssertEqual(again.preferences.size, JudgmentReaderModel.sizeSteps.count - 1)
        }
    }

    /// Anything but "the file is not here" falls back to the stored text.
    func testAFormatterFailureFallsBackToPlainText() async throws {
        try await onMain {
        let (service, model) = await makeReader()
        service.judgmentErrors[257_708] = LibraryCatalogueError(status: 500, code: "library_failed")
        service.files[257_708] = Data("Title: Union\n=====\n1. Leave\ngranted.\n\nDismissed.".utf8)
        await model.load()
        XCTAssertEqual(model.source, .plain)
        XCTAssertEqual(model.blocks.map(\.id), ["para-1", "b-1"])
        XCTAssertNotNil(model.plainTextNote)
        XCTAssertEqual(service.fileCalls.first?.prefer, .text)
        XCTAssertEqual(model.caseTitle, "Union of India v. Sistema Shyam Teleservices Limited",
                       "with no header the row's title is read, its date dropped")
        }
    }

    func testMissingTooLargeAndSessionEndedAreSaidPlainly() async throws {
        try await onMain {
        let (service, model) = await makeReader()
        service.judgmentErrors[257_708] = LibraryCatalogueError(status: 404, code: "file_missing")
        await model.load()
        XCTAssertTrue(model.isMissing)
        XCTAssertEqual(model.failureTitle, "This judgment is not on the shelf yet")
        XCTAssertFalse(model.canRetry)
        XCTAssertFalse(model.offersDownload)
        XCTAssertEqual(service.fileCalls.count, 0, "a missing file is not asked for twice")

        service.judgmentErrors[257_708] = LibraryCatalogueError(status: 413, code: "too_large")
        service.files[257_708] = Data(count: LibraryService.maxReaderBytes + 1)
        await model.load()
        XCTAssertTrue(model.isTooLarge)
        XCTAssertTrue(model.failureHint.contains("4 MB"))

        service.judgmentErrors[257_708] = APIError.invalidCredentials
        await model.load()
        XCTAssertTrue(model.state.requiresReauthentication)
        XCTAssertTrue(model.failureHint.contains("Sign in again"))
        }
    }
}

final class LibraryDocumentViewModelTests: XCTestCase {

    func testAPDFIsFetchedAfterAHeadAndSniffed() async throws {
        try await onMain {
        let service = FakeLibrary()
        var row = doc(3461, "Bihar Motor Vehicles Rules, 1992", category: "bare-acts", pdf: true)
        row.jurisdiction = "Bihar"
        service.files[3461] = Data("%PDF-1.4 rules".utf8)
        var detailRow = row
        detailRow.hasFile = true
        service.documents[3461] = LibraryDocumentDetail(doc: detailRow, childCount: 0)
        let model = await MainActor.run { LibraryDocumentViewModel(doc: row, service: service) }
        await model.load()
        XCTAssertEqual(model.pdf, Data("%PDF-1.4 rules".utf8))
        XCTAssertTrue(model.onShelf)
        XCTAssertEqual(service.headCalls, [3461])
        XCTAssertEqual(model.kind, "Bare act")
        XCTAssertEqual(model.meta, ["Bihar"])
        XCTAssertEqual(model.shareName, "Bihar Motor Vehicles Rules, 1992.pdf")

        service.files[9] = Data("{\"error\":\"not_found\"}".utf8)
        let json = await MainActor.run { LibraryDocumentViewModel(doc: doc(9, "Odd", category: "tribunals", pdf: true), service: service) }
        await json.load()
        XCTAssertNil(json.pdf)
        XCTAssertTrue(json.isMissing, "JSON in a PDF's clothing is a missing file")
        }
    }

    func testAMissingFileSaysSoWithoutOfferingADownload() async throws {
        try await onMain {
        let service = FakeLibrary()
        var row = doc(5, "Scan", category: "books-and-law-reports", pdf: true)
        row.hasFile = false
        let model = await MainActor.run { LibraryDocumentViewModel(doc: row, service: service) }
        await model.load()
        XCTAssertTrue(model.isMissing)
        XCTAssertFalse(model.onShelf)
        XCTAssertEqual(service.headCalls.count, 0, "the row already said the file is elsewhere")
        XCTAssertTrue(model.fileState.hasLoaded)
        }
    }

    func testATextDocumentDoesNotFetchBytesHere() async throws {
        try await onMain {
        let service = FakeLibrary()
        let model = await MainActor.run { LibraryDocumentViewModel(doc: doc(1, "A vs B"), service: service) }
        await model.load()
        XCTAssertTrue(model.isText)
        XCTAssertTrue(service.fileCalls.isEmpty)
        XCTAssertEqual(model.shareName, "A vs B.txt")
        }
    }
}

final class LibraryCoverLoaderTests: XCTestCase {

    func testCoversAreFetchedOnceAndRetriedWhilePending() async {
        let service = FakeLibrary()
        let pdf = doc(1, "Book", category: "books-and-law-reports", pdf: true)
        service.covers[1] = .image(Data([1, 2, 3]))
        let loader = LibraryCoverLoader(service: service)
        let first = await loader.image(for: pdf, width: 320)
        let second = await loader.image(for: pdf, width: 320)
        XCTAssertEqual(first, Data([1, 2, 3]))
        XCTAssertEqual(second, first)
        XCTAssertEqual(service.coverCalls, [1], "once per document and width")
        let cached = await loader.cachedImage(for: pdf, width: 320)
        XCTAssertEqual(cached, first)

        let text = doc(2, "Judgment")
        let none = await loader.image(for: text, width: 320)
        XCTAssertNil(none)
        XCTAssertEqual(service.coverCalls, [1], "a text document is never asked for a cover")

        service.covers[3] = .none(reason: "encrypted")
        let missing = await loader.image(for: doc(3, "Locked", category: "books-and-law-reports", pdf: true), width: 160)
        XCTAssertNil(missing)
        _ = await loader.image(for: doc(3, "Locked", category: "books-and-law-reports", pdf: true), width: 160)
        XCTAssertEqual(service.coverCalls, [1, 3], "no cover is remembered too")
    }

    func testAMissingRoutePausesEveryAttempt() async {
        let service = FakeLibrary()
        service.covers[1] = .image(Data([1]))
        let loader = LibraryCoverLoader(service: service)
        await loader.noteRouteMissing()
        let paused = await loader.image(for: doc(1, "B", category: "books-and-law-reports", pdf: true), width: 320)
        XCTAssertNil(paused)
        XCTAssertTrue(service.coverCalls.isEmpty)
    }
}
