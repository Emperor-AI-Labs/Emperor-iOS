import Foundation
#if canImport(Darwin)
import Observation
#endif

/// How one collection is browsed: which facets it offers, how it is laid out, what its
/// documents are called, and what a card says. The web keeps one file per collection
/// (`categories/<Key>.jsx`); here it is one description each, read by one view model.
struct LibraryCollectionProfile: Equatable, Sendable {
    enum Facet: String, Sendable { case courts, years, docTypes, jurisdictions, series, publishers, kinds, letters }
    enum Layout: String, Sendable { case grid, list }
    /// What the collection shows before any search or filter.
    enum Overview: Equatable, Sendable {
        /// The paged grid or list straight away.
        case browse
        /// Books: one shelf per series, then "Standalone books" and an index of every series.
        case seriesShelves
        /// Professional institutes: three shelves, one per institute.
        case publisherShelves
        /// Parliament: the whole collection as a list grouped by kind.
        case groupedByKind
        /// Legal aid: a handful of documents, each shown large with its full title.
        case feature
    }

    var key: String
    var facets: [Facet]
    var facetLabels: [Facet: String]
    var layout: Layout
    var defaultSort: String?
    var noun: (one: String, many: String)
    var fullText: Bool
    var overview: Overview

    static func == (lhs: LibraryCollectionProfile, rhs: LibraryCollectionProfile) -> Bool { lhs.key == rhs.key }

    static func profile(for key: String) -> LibraryCollectionProfile {
        switch LibraryCollection(rawValue: key) {
        case .caseLaw:
            return .init(key: key, facets: [.courts, .years], facetLabels: [.courts: "Court"], layout: .list,
                         defaultSort: "date_desc", noun: ("judgment", "judgments"), fullText: true, overview: .browse)
        case .booksAndReports:
            return .init(key: key, facets: [.letters, .years], facetLabels: [:], layout: .grid,
                         defaultSort: nil, noun: ("volume", "volumes"), fullText: false, overview: .seriesShelves)
        case .regulatorOrders:
            return .init(key: key, facets: [.publishers, .kinds, .years], facetLabels: [.publishers: "Regulator", .kinds: "Type"],
                         layout: .list, defaultSort: "year_desc", noun: ("order", "orders"), fullText: false, overview: .browse)
        case .tribunals:
            return .init(key: key, facets: [.publishers, .years], facetLabels: [.publishers: "Tribunal"], layout: .grid,
                         defaultSort: "year_desc", noun: ("decision", "decisions"), fullText: false, overview: .browse)
        case .lawCommission:
            return .init(key: key, facets: [.years], facetLabels: [:], layout: .grid,
                         defaultSort: nil, noun: ("report", "reports"), fullText: false, overview: .browse)
        case .professionalInstitutes:
            return .init(key: key, facets: [.publishers, .letters], facetLabels: [.publishers: "Institute"], layout: .grid,
                         defaultSort: nil, noun: ("publication", "publications"), fullText: false, overview: .publisherShelves)
        case .parliament:
            return .init(key: key, facets: [.kinds, .years], facetLabels: [.kinds: "Type"], layout: .list,
                         defaultSort: nil, noun: ("paper", "papers"), fullText: false, overview: .groupedByKind)
        case .legalAid:
            return .init(key: key, facets: [], facetLabels: [:], layout: .grid,
                         defaultSort: nil, noun: ("paper", "papers"), fullText: false, overview: .feature)
        case .bareActs:
            // Browsed through its own index (`BareActsIndexViewModel`); this profile serves a search.
            return .init(key: key, facets: [.jurisdictions, .docTypes, .years], facetLabels: [.jurisdictions: "Jurisdiction", .docTypes: "Type"],
                         layout: .grid, defaultSort: nil, noun: ("document", "documents"), fullText: false, overview: .browse)
        case nil:
            return .init(key: key, facets: [.docTypes, .jurisdictions, .series, .years], facetLabels: [:], layout: .grid,
                         defaultSort: nil, noun: ("document", "documents"), fullText: false, overview: .browse)
        }
    }

    func label(for facet: Facet) -> String {
        if let custom = facetLabels[facet] { return custom }
        switch facet {
        case .courts: return "Court"
        case .years: return "Year"
        case .docTypes: return "Type"
        case .jurisdictions: return "Jurisdiction"
        case .series: return "Series"
        case .publishers: return "Publisher"
        case .kinds: return "Type"
        case .letters: return "A–Z"
        }
    }
}

/// What a card prints for a document in this collection — the web's per-collection `caption`.
struct LibraryCaption: Equatable, Sendable {
    /// A reference line above the title ("RBI/DOR/2025-26/232 · 28 Nov 2025").
    var eyebrow: String?
    /// A display-serif line above the title ("Report No. 277"); also what the cover prints.
    var headline: String?
    var title: String
    var meta: [String]
    /// The cover's top line when it should not be the series ("SEBI", "TDSAT").
    var kicker: String?
    /// The call-number label on the spine.
    var label: (top: String, bottom: String)?

    static func == (lhs: LibraryCaption, rhs: LibraryCaption) -> Bool {
        lhs.eyebrow == rhs.eyebrow && lhs.headline == rhs.headline && lhs.title == rhs.title
            && lhs.meta == rhs.meta && lhs.kicker == rhs.kicker
            && lhs.label?.top == rhs.label?.top && lhs.label?.bottom == rhs.label?.bottom
    }
}

/// One collection, browsed: facets, a sort, the paged documents, and the collection's own
/// front room (series shelves, institute shelves, papers by kind) before any filter is set.
///
/// Paging appends rather than numbering: a phone scrolls. The server pages, so `loadMore` asks
/// for the next page and drops any row already on screen (the corpus can shift between pages).
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class LibraryCollectionViewModel {

    let key: String
    let profile: LibraryCollectionProfile
    private(set) var category: LibraryCategoryCount

    private(set) var facets: LibraryFacets?
    private(set) var facetsState: LoadState = .idle

    private(set) var documents: [CatalogueDocument] = []
    private(set) var total = 0
    private(set) var totalIsCapped = false
    private(set) var state: LoadState = .idle
    private(set) var isLoadingMore = false
    private(set) var indexStatus: LibrarySearchIndexStatus?

    /// The filters in force. Changing one restarts from page one (`apply`).
    private(set) var filters: LibraryBrowseFilters
    /// Words inside judgments rather than titles and parties (case law, with a search).
    private(set) var inText = false
    /// The search the documents on screen answer, so clearing an empty box asks nothing.
    private(set) var appliedQuery: String?
    var layout: LibraryCollectionProfile.Layout
    var query: String

    // The collection's front room.
    private(set) var seriesShelves: LibrarySeriesShelves?
    private(set) var overviewItems: [CatalogueDocument] = []
    private(set) var overviewState: LoadState = .idle
    /// A series opened from the shelves (Books): its name, and every volume.
    private(set) var openSeries: String?
    private(set) var seriesVolumes: [CatalogueDocument] = []
    private(set) var seriesTotal = 0
    private(set) var seriesState: LoadState = .idle
    /// Books: the whole index (A–Z grid) rather than the shelves, by choice.
    var showsAllBooks = false

    private let service: any LibraryProviding
    private let todayKey: () -> String
    private var page = 1
    #if canImport(Darwin)
    @ObservationIgnored private var generation = 0
    #else
    private var generation = 0
    #endif

    init(category: LibraryCategoryCount, query: String = "", service: any LibraryProviding,
         todayKey: @escaping () -> String = { WireDate.todayKey() }) {
        self.key = category.key
        self.category = category
        self.profile = LibraryCollectionProfile.profile(for: category.key)
        self.query = query
        self.service = service
        self.todayKey = todayKey
        self.layout = profile.layout
        var f = LibraryBrowseFilters(category: category.key)
        f.sort = profile.defaultSort
        f.pageSize = profile.layout == .list ? 25 : 36
        self.filters = f
    }

    convenience init(key: String, query: String = "", service: any LibraryProviding) {
        self.init(category: LibraryCategoryCount(key: key, label: LibraryCollectionTheme.theme(for: key).label, count: nil),
                  query: query, service: service)
    }

    var theme: LibraryCollectionTheme { category.theme }
    var presentation: ListPresentation { ListPresentation(state: state, isEmpty: documents.isEmpty) }
    var canLoadMore: Bool { documents.count < total && !isLoadingMore && state.hasLoaded }
    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var isCaseLaw: Bool { key == LibraryCollection.caseLaw.rawValue }

    /// Whether the collection's own front room is what to show: nothing searched, nothing
    /// filtered, and the reader has not asked for the whole index.
    var showsOverview: Bool {
        guard profile.overview != .browse, !hasQuery, filters.activeFilterCount == 0 else { return false }
        if profile.overview == .seriesShelves { return !showsAllBooks }
        return true
    }

    // MARK: - Loading

    func load() async {
        async let facetsLoad: Void = loadFacets()
        async let items: Void = reload()
        async let front: Void = loadOverviewIfNeeded()
        _ = await (facetsLoad, items, front)
    }

    func loadFacets() async {
        guard facets == nil else { return }
        facetsState = .loading
        do {
            facets = try await service.facets(category: key)
            facetsState = .loaded
        } catch {
            facetsState = .failed(LoadFailure(error))
        }
    }

    /// Page one, for the filters in force.
    func reload() async {
        generation += 1
        let ticket = generation
        page = 1
        state = .loading
        var request = filters
        request.page = 1
        request.query = hasQuery ? query.trimmingCharacters(in: .whitespaces) : nil
        appliedQuery = request.query
        do {
            let result = try await fetch(request)
            guard ticket == generation else { return }
            documents = CaseLawVocabulary.arrange(result.items, sort: request.sort, today: todayKey())
            total = result.total
            totalIsCapped = result.totalIsCapped ?? false
            indexStatus = result.index
            state = .loaded
        } catch {
            guard ticket == generation else { return }
            documents = []
            total = 0
            state = .failed(LoadFailure(error))
        }
    }

    func loadMore() async {
        guard canLoadMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let ticket = generation
        var request = filters
        request.page = page + 1
        request.query = hasQuery ? query.trimmingCharacters(in: .whitespaces) : nil
        do {
            let result = try await fetch(request)
            guard ticket == generation else { return }
            guard !result.items.isEmpty else { total = documents.count; return }
            let known = Set(documents.map(\.id))
            documents += result.items.filter { !known.contains($0.id) }
            total = result.total
            page = request.page
        } catch {
            // A failed page does not invalidate what is already on screen.
        }
    }

    private func fetch(_ request: LibraryBrowseFilters) async throws -> LibraryPage {
        if inText, hasQuery {
            var r = request
            r.pageSize = min(r.pageSize, 50)
            return try await service.search(r)
        }
        return try await service.browse(request)
    }

    // MARK: - Changing what is shown

    /// Edits the filters and starts again from page one.
    func apply(_ change: (inout LibraryBrowseFilters) -> Void) async {
        var next = filters
        change(&next)
        next.page = 1
        guard next != filters else { return }
        filters = next
        await reload()
    }

    func setCourt(_ value: String?) async { await apply { $0.court = value?.nilIfEmpty } }
    func setDocType(_ value: String?) async { await apply { $0.docType = value?.nilIfEmpty } }
    func setJurisdiction(_ value: String?) async { await apply { $0.jurisdiction = value?.nilIfEmpty } }
    func setSeries(_ value: String?) async { await apply { $0.series = value?.nilIfEmpty } }
    func setPublisher(_ value: String?) async { await apply { $0.publisher = value?.nilIfEmpty } }
    func setKind(_ value: String?) async { await apply { $0.kind = value?.nilIfEmpty } }

    func setLetter(_ value: String?) async {
        await apply {
            $0.letter = value?.nilIfEmpty
            // A letter implies A–Z order unless the reader chose a sort.
            if $0.letter != nil, $0.sort == nil || $0.sort == profile.defaultSort { $0.sort = "title_asc" }
        }
    }

    func setYears(from: Int?, to: Int?) async {
        await apply {
            $0.yearFrom = from
            $0.yearTo = to
        }
    }

    func setSort(_ value: String?) async { await apply { $0.sort = value?.nilIfEmpty } }

    /// Titles and parties ↔ words inside (case law only, with a search).
    func setInText(_ on: Bool) async {
        guard profile.fullText, on != inText else { return }
        inText = on
        filters.sort = on ? nil : profile.defaultSort
        await reload()
    }

    /// Runs the box: a search reaches past the front room, straight to the results.
    func search() async {
        if !hasQuery { inText = false }
        showsAllBooks = showsAllBooks || hasQuery
        await reload()
    }

    func clearQuery() async {
        query = ""
        inText = false
        guard appliedQuery != nil else { return }
        await reload()
    }

    func clearFilters() async {
        await apply { f in
            f.court = nil; f.docType = nil; f.jurisdiction = nil; f.series = nil
            f.publisher = nil; f.kind = nil; f.letter = nil; f.yearFrom = nil; f.yearTo = nil
            f.sort = profile.defaultSort
        }
    }

    func setLayout(_ layout: LibraryCollectionProfile.Layout) async {
        guard layout != self.layout else { return }
        self.layout = layout
        await apply { $0.pageSize = layout == .list ? 25 : 36 }
    }

    // MARK: - Facets as the screen offers them

    /// The facet rows worth drawing: a row needs two choices, a year row needs a range.
    var facetRows: [LibraryCollectionProfile.Facet] {
        guard let facets else { return [] }
        return profile.facets.filter { facet in
            switch facet {
            case .courts: return (facets.courts?.count ?? 0) > 1
            case .years: return facets.yearRange != nil
            case .docTypes: return (facets.docTypes?.count ?? 0) > 1
            case .jurisdictions: return (facets.jurisdictions?.count ?? 0) > 1
            case .series: return (facets.series?.count ?? 0) > 1
            case .publishers: return (facets.publishers?.count ?? 0) > 1
            case .kinds: return (facets.kinds?.count ?? 0) > 1
            case .letters: return !(facets.letters ?? []).isEmpty
            }
        }
    }

    func options(for facet: LibraryCollectionProfile.Facet) -> [LibraryFacetOption] {
        guard let facets else { return [] }
        switch facet {
        case .courts: return CaseLawVocabulary.orderCourts(facets.courts ?? [])
        case .docTypes: return facets.docTypes ?? []
        case .jurisdictions: return facets.jurisdictions ?? []
        case .series: return facets.series ?? []
        case .publishers: return facets.publishers ?? []
        case .kinds: return facets.kinds ?? []
        case .years, .letters: return []
        }
    }

    func selection(for facet: LibraryCollectionProfile.Facet) -> String? {
        switch facet {
        case .courts: return filters.court
        case .docTypes: return filters.docType
        case .jurisdictions: return filters.jurisdiction
        case .series: return filters.series
        case .publishers: return filters.publisher
        case .kinds: return filters.kind
        case .letters: return filters.letter
        case .years: return nil
        }
    }

    func select(_ facet: LibraryCollectionProfile.Facet, value: String?) async {
        // Choosing the active one clears it.
        let next = selection(for: facet) == value ? nil : value
        switch facet {
        case .courts: await setCourt(next)
        case .docTypes: await setDocType(next)
        case .jurisdictions: await setJurisdiction(next)
        case .series: await setSeries(next)
        case .publishers: await setPublisher(next)
        case .kinds: await setKind(next)
        case .letters: await setLetter(next)
        case .years: break
        }
    }

    /// Year inputs suggest a range no later than next year: a "2095" parsed from a title is
    /// not a hint.
    var yearRange: LibraryYearRange? {
        guard let range = facets?.yearRange else { return nil }
        let latest = (Int(todayKey().prefix(4)) ?? 2026) + 1
        return LibraryYearRange(min: range.min, max: isCaseLaw ? range.max : min(range.max, latest))
    }

    var letters: [LibraryLetterCount] { facets?.letters ?? [] }
    var yearCounts: [LibraryYearCount] { facets?.years ?? [] }

    /// Case law's own sorts; elsewhere the server's list.
    var sortOptions: [LibrarySortOption] {
        if isCaseLaw {
            return inText
                ? [.init(value: "", label: "Best match"), .init(value: "date_desc", label: "Newest"), .init(value: "date_asc", label: "Oldest")]
                : [.init(value: "date_desc", label: "Newest"), .init(value: "date_asc", label: "Oldest"), .init(value: "title_asc", label: "A–Z")]
        }
        return facets?.sorts ?? []
    }

    var currentSort: String { filters.sort ?? (isCaseLaw && !inText ? "date_desc" : "") }

    /// The chips naming what is in force, each removable.
    struct ActiveFilter: Equatable, Identifiable, Sendable {
        var facet: LibraryCollectionProfile.Facet
        var label: String
        var id: String { facet.rawValue }
    }

    var activeFilters: [ActiveFilter] {
        var out: [ActiveFilter] = []
        if let court = filters.court {
            out.append(.init(facet: .courts, label: CaseLawVocabulary.court(court, label: options(for: .courts).first { $0.value == court }?.label).short))
        }
        if let v = filters.docType { out.append(.init(facet: .docTypes, label: options(for: .docTypes).first { $0.value == v }?.displayLabel ?? v)) }
        if let v = filters.jurisdiction { out.append(.init(facet: .jurisdictions, label: v)) }
        if let v = filters.series { out.append(.init(facet: .series, label: LibraryBooksFormat.seriesName(v))) }
        if let v = filters.publisher { out.append(.init(facet: .publishers, label: options(for: .publishers).first { $0.value == v }?.displayLabel ?? v.uppercased())) }
        if let v = filters.kind { out.append(.init(facet: .kinds, label: options(for: .kinds).first { $0.value == v }?.displayLabel ?? v)) }
        if let v = filters.letter { out.append(.init(facet: .letters, label: v == "#" ? "Other characters" : v)) }
        if let years = yearText { out.append(.init(facet: .years, label: years)) }
        return out
    }

    func clear(_ facet: LibraryCollectionProfile.Facet) async {
        if facet == .years { await setYears(from: nil, to: nil) } else { await select(facet, value: selection(for: facet)) }
    }

    /// "2015–2020", "1979", or nil when the years are open.
    var yearText: String? {
        guard filters.yearFrom != nil || filters.yearTo != nil else { return nil }
        if let a = filters.yearFrom, let b = filters.yearTo, a == b { return String(a) }
        let lo = filters.yearFrom.map(String.init) ?? yearRange.map { String($0.min) } ?? ""
        let hi = filters.yearTo.map(String.init) ?? yearRange.map { String($0.max) } ?? ""
        return "\(lo)–\(hi)"
    }

    // MARK: - What the toolbar says

    /// "2,71,480 judgments with “x” in the text · Delhi High Court · 2015–2020".
    var countLine: String? {
        guard state.hasLoaded else { return nil }
        var line = "\(LibraryTitles.count(total))\(totalIsCapped ? "+" : "") \(total == 1 ? profile.noun.one : profile.noun.many)"
        if hasQuery {
            line += isCaseLaw
                ? " with “\(query)” \(inText ? "in the text" : "in the case name")"
                : " matching “\(query)”"
        }
        if isCaseLaw, let court = filters.court {
            line += " · " + CaseLawVocabulary.court(court, label: options(for: .courts).first { $0.value == court }?.label).name
        }
        if isCaseLaw, let years = yearText { line += " · \(years)" }
        return line
    }

    /// How many judgments the year range holds (the timeline's note).
    func judgments(inYears lo: Int, _ hi: Int) -> Int {
        yearCounts.filter { $0.year >= lo && $0.year <= hi }.reduce(0) { $0 + $1.count }
    }

    var emptyTitle: String {
        if hasQuery {
            return isCaseLaw
                ? "No judgments \(inText ? "contain" : "are named") “\(query)”"
                : "No \(profile.noun.many) match “\(query)”"
        }
        return "No \(profile.noun.many) match these filters"
    }

    var emptyHint: String {
        if inText { return "Try fewer words, or put a phrase in quotes to match it exactly, like \"bona fide purchaser\"." }
        if hasQuery {
            return isCaseLaw
                ? "Try one party’s name, or switch to “Words inside” to search the text of every judgment."
                : "Try a shorter search, or switch to all shelves."
        }
        if filters.activeFilterCount > 0 { return isCaseLaw ? "Try another court, or widen the years." : "Try removing a filter, or widen the years." }
        return "Try a shorter search, or switch to all shelves."
    }

    /// The body index is still being built: a search answers over the part it covers.
    var indexNote: String? {
        guard inText, let index = indexStatus, index.complete == false, let done = index.indexed, let all = index.total, all > 0 else { return nil }
        return "The text of \(LibraryTitles.count(done)) of \(LibraryTitles.count(all)) judgments is searchable so far."
    }

    // MARK: - The collection's front room

    func loadOverviewIfNeeded() async {
        guard showsOverview else { return }
        switch profile.overview {
        case .seriesShelves:
            guard seriesShelves == nil else { return }
            overviewState = .loading
            do {
                seriesShelves = try await service.seriesShelves(limit: 12, per: 14)
                overviewState = .loaded
            } catch {
                overviewState = .failed(LoadFailure(error))
            }
        case .publisherShelves, .groupedByKind, .feature:
            guard overviewItems.isEmpty, !overviewState.hasLoaded else { return }
            overviewState = .loading
            do {
                overviewItems = try await Self.wholeCollection(key, sort: profile.overview == .feature ? "year_desc" : "title_asc", service: service)
                overviewState = .loaded
            } catch {
                overviewState = .failed(LoadFailure(error))
            }
        case .browse:
            break
        }
    }

    /// Up to 300 rows of a small collection (PRS 51, NALSA 3, an institute's shelf) — three
    /// pages of a hundred.
    static func wholeCollection(_ key: String, sort: String?, max: Int = 300, service: any LibraryProviding) async throws -> [CatalogueDocument] {
        var filters = LibraryBrowseFilters(category: key, sort: sort)
        filters.pageSize = 100
        let first = try await service.browse(filters)
        var items = first.items
        let pages = min(Int((Double(max) / 100).rounded(.up)), Int((Double(first.total) / 100).rounded(.up)))
        if pages >= 2 {
            for p in 2...pages {
                filters.page = p
                items += try await service.browse(filters).items
            }
        }
        return items
    }

    /// Professional institutes: the three shelves, with each institute's rows.
    static let institutes: [(key: String, label: String, name: String, blurb: String)] = [
        ("icai", "ICAI", "The Institute of Chartered Accountants of India", "Standards on auditing, accounting standards for local bodies and their clarifications."),
        ("icsi", "ICSI", "The Institute of Company Secretaries of India", "Secretarial standards, guidance notes and study material."),
        ("icmai", "ICMAI", "The Institute of Cost Accountants of India", "Code of ethics, policies and publications."),
    ]

    func institute(_ label: String) -> [CatalogueDocument] {
        overviewItems.filter { $0.publisher == label }
    }

    /// Parliament: the papers by what each is, in the web's order.
    static let parliamentKindOrder = ["act", "committee", "comparison", "amendments", "other"]

    struct KindGroup: Equatable, Identifiable, Sendable {
        var key: String
        var label: String
        var items: [CatalogueDocument]
        var id: String { key }
    }

    var kindGroups: [KindGroup] {
        let labels = Dictionary(uniqueKeysWithValues: (facets?.kinds ?? []).map { ($0.value, $0.displayLabel) })
        return Self.parliamentKindOrder.compactMap { k in
            let items = overviewItems.filter { ($0.kind ?? "other") == k }
            guard !items.isEmpty else { return nil }
            return KindGroup(key: k, label: labels[k] ?? k.capitalized, items: items)
        }
    }

    /// Legal aid's closing line: "3 papers so far."
    var featureNote: String {
        let n = overviewItems.count
        return "\(n == 1 ? "One paper" : "\(n) papers") so far. The National Legal Services Authority publishes reports of its "
            + "conferences and its schemes for free legal aid; more will appear here as they are added to the library."
    }

    // MARK: Books: a series

    func open(series name: String) async {
        openSeries = name
        seriesVolumes = []
        seriesState = .loading
        do {
            var filters = LibraryBrowseFilters(category: key, sort: "year_asc")
            filters.series = name
            filters.pageSize = 100
            let first = try await service.browse(filters)
            var items = first.items
            let pages = min(3, Int((Double(first.total) / 100).rounded(.up)))
            if pages >= 2 {
                for p in 2...pages {
                    filters.page = p
                    items += try await service.browse(filters).items
                }
            }
            guard openSeries == name else { return }
            seriesVolumes = items.sorted(by: LibraryBooksFormat.volumeOrder)
            seriesTotal = max(first.total, items.count)
            seriesState = .loaded
        } catch {
            guard openSeries == name else { return }
            seriesState = .failed(LoadFailure(error))
        }
    }

    func closeSeries() {
        openSeries = nil
        seriesVolumes = []
        seriesState = .idle
    }

    var seriesGroups: [LibraryBooksFormat.DecadeGroup] {
        LibraryBooksFormat.groupByDecade(seriesVolumes, thisYear: Int(todayKey().prefix(4)) ?? 2026)
    }

    /// "66 volumes · 1904–1952 · 3 undated".
    var seriesLine: String {
        guard seriesState.hasLoaded else { return "Loading volumes…" }
        let years = seriesVolumes.compactMap(\.year).filter { $0 > 1500 }
        return [
            "\(LibraryTitles.count(seriesTotal)) volume\(seriesTotal == 1 ? "" : "s")",
            years.isEmpty ? "" : LibraryBooksFormat.yearSpan(years.min(), years.max()),
            (!years.isEmpty && years.count < seriesVolumes.count) ? "\(seriesVolumes.count - years.count) undated" : "",
        ].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Every series the facets know, for the index under the shelves.
    var allSeries: [LibraryFacetOption] { facets?.series ?? [] }

    // MARK: - Captions

    /// What a card says for a document here.
    func caption(for doc: CatalogueDocument) -> LibraryCaption {
        switch LibraryCollection(rawValue: key) {
        case .regulatorOrders:
            return LibraryCaption(
                eyebrow: LibraryBooksFormat.referenceLine(doc).nilIfEmpty, headline: nil, title: LibraryTitles.tidyTitle(doc),
                meta: [doc.publisher, doc.kind.flatMap { LibraryBooksFormat.kindLabels[$0] }, doc.decidedOn == nil ? doc.year.map(String.init) : nil].compactMap { $0?.nilIfEmpty },
                kicker: doc.publisher, label: LibraryBooksFormat.volumeLabel(doc))
        case .tribunals:
            return LibraryCaption(
                eyebrow: LibraryBooksFormat.referenceLine(doc).nilIfEmpty, headline: nil, title: LibraryTitles.tidyTitle(doc),
                meta: [doc.publisher, doc.decidedOn == nil ? doc.year.map(String.init) : nil].compactMap { $0?.nilIfEmpty },
                kicker: doc.publisher, label: LibraryBooksFormat.volumeLabel(doc))
        case .lawCommission:
            let headline = doc.reportNo.map { "Report No. \($0)" }
            return LibraryCaption(
                eyebrow: nil, headline: headline,
                title: doc.subject?.nilIfEmpty ?? (headline == nil ? LibraryTitles.tidyTitle(doc) : "Law Commission of India"),
                meta: [doc.year.map(String.init), doc.lang.map { "\($0) edition" }].compactMap { $0 },
                kicker: nil, label: LibraryBooksFormat.volumeLabel(doc))
        case .professionalInstitutes:
            return LibraryCaption(
                eyebrow: nil, headline: nil, title: LibraryTitles.tidyTitle(doc),
                meta: [doc.publisher, doc.year.map(String.init)].compactMap { $0?.nilIfEmpty },
                kicker: doc.publisher, label: nil)
        case .parliament:
            return LibraryCaption(
                eyebrow: nil, headline: nil, title: LibraryTitles.tidyTitle(doc),
                meta: LibraryBooksFormat.captionMeta(doc, withSeries: false, withSize: true) + (doc.genericTitle == true ? ["Bill name not recorded"] : []),
                kicker: nil, label: nil)
        case .legalAid:
            return LibraryCaption(
                eyebrow: "NALSA", headline: nil, title: LibraryTitles.tidyTitle(doc),
                meta: LibraryBooksFormat.captionMeta(doc, withSeries: false, withSize: true), kicker: nil, label: nil)
        case .booksAndReports:
            if let series = openSeries {
                return LibraryCaption(
                    eyebrow: nil, headline: nil, title: LibraryBooksFormat.volumeTitle(doc, series: series),
                    meta: LibraryBooksFormat.captionMeta(doc, withSeries: false, withSize: true),
                    kicker: LibraryBooksFormat.seriesName(series), label: LibraryBooksFormat.volumeLabel(doc))
            }
            return LibraryCaption(
                eyebrow: nil, headline: nil, title: LibraryTitles.tidyTitle(doc),
                meta: LibraryBooksFormat.captionMeta(doc), kicker: nil, label: LibraryBooksFormat.volumeLabel(doc))
        default:
            return LibraryCaption(eyebrow: nil, headline: nil, title: LibraryTitles.tidyTitle(doc), meta: LibraryTitles.meta(doc), kicker: nil, label: nil)
        }
    }

    /// A volume on a series shelf: the series on the cover, "Vol. 12" in the caption.
    func shelfCaption(for doc: CatalogueDocument, series: String) -> LibraryCaption {
        LibraryCaption(
            eyebrow: nil, headline: nil, title: LibraryBooksFormat.volumeTitle(doc, series: series),
            meta: LibraryBooksFormat.captionMeta(doc, withSeries: false),
            kicker: LibraryBooksFormat.seriesName(series), label: LibraryBooksFormat.volumeLabel(doc))
    }

    // MARK: Case law rows

    /// What a judgment's row prints under its title.
    struct CaseRowFacts: Equatable, Sendable {
        var courtShort: String
        var courtKey: String
        var monogram: String
        var date: String?
        var dateUnclear: Bool
        var citation: String?
        var number: String?
        var bench: String?
        var passage: LibrarySnippet?
        var noPassage: Bool
    }

    func caseRow(for doc: CatalogueDocument) -> CaseRowFacts {
        let c = CaseLawVocabulary.court(doc.court, label: doc.courtLabel)
        let odd = CaseLawVocabulary.isFutureDate(doc.decidedOn, today: todayKey())
        let date = odd ? "Date unclear" : (doc.decidedOn.map(LibraryTitles.shortDay) ?? doc.year.map(String.init))
        return CaseRowFacts(
            courtShort: c.short, courtKey: c.key, monogram: c.monogram, date: date, dateUnclear: odd,
            citation: doc.neutralCitation?.nilIfEmpty,
            number: CaseLawVocabulary.caseNumberText(doc).nilIfEmpty,
            bench: doc.bench?.nilIfEmpty.map { TextPattern(#"\s*,\s*"#).replacing($0, with: ", ") },
            passage: inText ? doc.snippet : nil,
            noPassage: inText && doc.snippet == nil)
    }

    enum Copy {
        static let titlesAndParties = "Titles and parties"
        static let wordsInside = "Words inside"
        static let noPassage = "The words appear inside this judgment."
        static let shelves = "Shelves"
        static let allBooks = "All books, A–Z"
        static let standalone = "Standalone books"
        static let standaloneBlurb = "Commentaries, treatises, reports and pamphlets that stand on their own."
        static let everySeries = "Every series"
        static let allYears = "All years"
    }
}
