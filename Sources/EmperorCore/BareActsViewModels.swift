import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The Bare Acts index — the web's `categories/BareActs.jsx`: an A–Z thumb index, jurisdiction
/// chips (Central and each State), a "Contains" filter, find by name or short name (the backend
/// knows PMLA, CrPC, IPC, BNS…), sort, and "On every advocate's desk" — the Constitution and the
/// codes — while the whole index is being browsed. Every row opens the Act page.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class BareActsIndexViewModel {

    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case title = ""
        case year
        case size
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: return "A–Z"
            case .year: return "Newest first"
            case .size: return "Most instruments"
            }
        }
    }

    private(set) var letter: String?
    private(set) var jurisdiction: String?
    private(set) var has: String?
    private(set) var sort: Sort = .title
    var query: String
    var showsList = false

    private(set) var items: [CatalogueDocument] = []
    private(set) var total = 0
    private(set) var letters: [LibraryLetterCount] = []
    private(set) var jurisdictions: [LibraryFacetOption] = []
    private(set) var state: LoadState = .idle
    private(set) var isLoadingMore = false

    private(set) var featured: [CatalogueDocument] = []
    private(set) var featuredState: LoadState = .idle

    private(set) var collectionCount: Int?

    private let service: any LibraryProviding
    private var page = 1
    #if canImport(Darwin)
    @ObservationIgnored private var generation = 0
    #else
    private var generation = 0
    #endif

    static let pageSize = 60

    init(query: String = "", collectionCount: Int? = nil, service: any LibraryProviding) {
        self.query = query
        self.collectionCount = collectionCount
        self.service = service
    }

    var presentation: ListPresentation { ListPresentation(state: state, isEmpty: items.isEmpty) }
    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var isFiltered: Bool { hasQuery || letter != nil || jurisdiction != nil || has != nil }
    /// The whole index, untouched: the only time the featured shelf is drawn.
    var isBrowsing: Bool { !isFiltered && sort == .title && page == 1 }
    var canLoadMore: Bool { items.count < total && !isLoadingMore && state.hasLoaded }

    var filters: ActIndexFilters {
        var f = ActIndexFilters()
        f.letter = letter
        f.jurisdiction = jurisdiction
        f.query = hasQuery ? query.trimmingCharacters(in: .whitespaces) : nil
        f.has = has
        f.sort = sort == .title ? nil : sort.rawValue
        // A search reaches everything, stand-alone amending Acts included; browsing shows the Acts.
        f.kind = hasQuery ? "all" : nil
        f.pageSize = Self.pageSize
        return f
    }

    // MARK: - Loading

    func load() async {
        async let index: Void = reload()
        async let shelf: Void = loadFeatured()
        _ = await (index, shelf)
    }

    func reload() async {
        generation += 1
        let ticket = generation
        page = 1
        state = .loading
        var request = filters
        request.page = 1
        do {
            let result = try await service.actIndex(request)
            guard ticket == generation else { return }
            items = result.items
            total = result.total
            if !result.letters.isEmpty { letters = result.letters }
            if !result.jurisdictions.isEmpty || jurisdictions.isEmpty { jurisdictions = result.jurisdictions }
            state = .loaded
        } catch {
            guard ticket == generation else { return }
            items = []
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
        do {
            let result = try await service.actIndex(request)
            guard ticket == generation else { return }
            guard !result.items.isEmpty else { total = items.count; return }
            let known = Set(items.map(\.id))
            items += result.items.filter { !known.contains($0.id) }
            total = result.total
            page = request.page
        } catch {
            // The rows already on screen stand.
        }
    }

    func loadFeatured() async {
        guard featured.isEmpty, !featuredState.hasLoaded else { return }
        featuredState = .loading
        var request = ActIndexFilters()
        request.kind = "featured"
        request.pageSize = 40
        do {
            featured = try await service.actIndex(request).items
            featuredState = .loaded
        } catch {
            featuredState = .failed(LoadFailure(error))
        }
    }

    // MARK: - Changing the index

    func pick(letter value: String?) async {
        letter = letter == value ? nil : value
        await reload()
    }

    func pick(jurisdiction value: String?) async {
        jurisdiction = jurisdiction == value ? nil : value
        await reload()
    }

    func pick(has value: String?) async {
        has = has == value ? nil : value
        await reload()
    }

    func set(sort value: Sort) async {
        guard sort != value else { return }
        sort = value
        await reload()
    }

    /// Runs the box; a search drops the letter, which no longer applies.
    func search() async {
        if hasQuery { letter = nil }
        await reload()
    }

    func clearFilters() async {
        letter = nil
        jurisdiction = nil
        has = nil
        query = ""
        await reload()
    }

    // MARK: - What the screen says

    /// "83 Central Acts under I, with rules" / "12 Acts matching “pmla”".
    var countLine: String? {
        guard state.hasLoaded else { return nil }
        let jurWord = (jurisdiction != nil && jurisdiction != "none") ? "\(jurisdiction!) " : ""
        var described: [String] = []
        if jurisdiction == "none" { described.append("with no jurisdiction recorded") }
        if let letter { described.append(letter == "#" ? "under numbers and other scripts" : "under \(letter)") }
        if let has { described.append("with \(LibraryActText.hasLabel(has).lowercased())") }
        if hasQuery { described.append("matching “\(query.trimmingCharacters(in: .whitespaces))”") }
        return "\(LibraryTitles.count(total)) \(jurWord)\(total == 1 ? "Act" : "Acts")"
            + (described.isEmpty ? "" : " " + described.joined(separator: ", "))
    }

    /// "5,369 documents, 3,154 volumes."
    var headerStat: String? {
        guard let count = collectionCount, count > 0 else { return nil }
        var line = "\(LibraryTitles.count(count)) documents"
        if isBrowsing, state.hasLoaded { line += ", \(LibraryTitles.count(total)) volumes" }
        return line + "."
    }

    var letterTotal: Int { letters.reduce(0) { $0 + $1.count } }
    var jurisdictionTotal: Int { jurisdictions.reduce(0) { $0 + ($1.count ?? 0) } }

    var emptyHint: String {
        hasQuery
            ? "Try the short name lawyers use (PMLA, CrPC, NI Act), or fewer words."
            : "Choose another letter or jurisdiction, or clear the filters."
    }

    enum Copy {
        static let heading = "Bare acts"
        static let blurb = "Every Central and State Act, bound with its rules, regulations, notifications and amendments."
        static let featuredTitle = "On every advocate’s desk"
        static let featuredBlurb = "The Constitution, the criminal and civil codes, and the Central Acts opened every day."
        static let searchPrompt = "Find an Act: name, or PMLA, CrPC, BNS…"
        static let contains = "Contains"
        static let empty = "No Act in this part of the index"
        static let notInLibrary = "Act not in the library"
    }
}

/// The statute reading room — the web's `act/ActPage.jsx`: one Act with everything made under it,
/// one tab each (Rules, Regulations, Notifications, Orders, Amendments, Other editions…), the
/// tab's instruments, and the one open in the reading pane.
///
/// Any Bare Acts id opens its Act's bundle: landing on a rule opens the rule's tab with that rule
/// selected; landing on another copy of the Act opens the Act tab with that edition chosen.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class ActPageViewModel {

    let requestedID: Int
    /// The index row that was tapped, so the head paints before `/act` answers.
    let seed: CatalogueDocument?

    private(set) var bundle: ActBundle?
    private(set) var state: LoadState = .idle
    private(set) var tabs: [ActBundle.Tab] = []
    private(set) var selectedTabKey: String?
    private var selection: [String: Int] = [:]
    private var tabTouched = false

    /// Whether each instrument's file is on this server, once asked.
    private(set) var availability: [Int: Bool] = [:]
    /// The bytes of each PDF opened, kept so switching back never reloads.
    private(set) var bytes: [Int: Data] = [:]
    private(set) var loadingID: Int?
    private(set) var openError: String?
    private var recentIDs: [Int] = []

    /// A filter over a long instrument list.
    var instrumentFilter = ""

    private let service: any LibraryProviding
    static let pool = 4

    init(id: Int, seed: CatalogueDocument? = nil, service: any LibraryProviding) {
        self.requestedID = id
        self.seed = seed
        self.service = service
    }

    var presentation: ListPresentation { ListPresentation(state: state, isEmpty: bundle == nil) }
    var act: CatalogueDocument? { bundle?.act ?? seed }
    var kind: String { bundle?.resolvedKind ?? "act" }

    // MARK: - Loading

    func load() async {
        state = .loading
        do {
            let fetched = try await service.act(id: requestedID)
            bundle = fetched
            tabs = LibraryActText.tabsForView(fetched)
            if !tabTouched {
                var key = "act"
                if let landed = fetched.selectedTab, landed != "act", landed != "editions" { key = landed }
                if fetched.resolvedKind == "amendments", key == "act" { key = "amendments" }
                selectedTabKey = tabs.contains { $0.key == key } ? key : tabs.first?.key
            }
            state = .loaded
            await openCurrent()
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    /// Why the Act could not be opened, in the reader's terms.
    var failureTitle: String {
        if let failure = state.failure, failure.message.contains("no such") || failure.message.contains("not part") {
            return "There is no such Act"
        }
        return "This Act could not be opened"
    }

    // MARK: - Tabs and the open instrument

    var activeTab: ActBundle.Tab? {
        tabs.first { $0.key == selectedTabKey } ?? tabs.first
    }

    /// The instrument open in the pane: the one chosen in this tab, else the tab's default.
    var current: CatalogueDocument? {
        guard let tab = activeTab, let bundle else { return nil }
        let pool = LibraryActText.choices(for: tab, in: tabs)
        if let id = selection[tab.key], let hit = pool.first(where: { $0.id == id }) { return hit }
        return LibraryActText.defaultDocument(for: tab, in: tabs, bundle: bundle)
    }

    var list: [CatalogueDocument] { activeTab?.docs ?? [] }

    /// The list with the filter applied, by title or year.
    var filteredList: [CatalogueDocument] {
        let needle = instrumentFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return list }
        return list.filter { d in
            LibraryActText.actTitle(d).lowercased().contains(needle) || (d.year.map { String($0).contains(needle) } ?? false)
        }
    }

    var showsList: Bool { list.count > 1 }
    var showsFilter: Bool { list.count > 10 }
    var isChronology: Bool { activeTab?.key == "amendments" }
    var latestID: Int? {
        guard let tab = activeTab, tab.key != "editions", tab.key != "related" else { return nil }
        return LibraryActText.latestID(in: tab.docs)
    }

    /// "3 / 17" within the tab, or nil when it holds one document.
    var position: (index: Int, total: Int)? {
        guard showsList, let current, let at = list.firstIndex(where: { $0.id == current.id }) else { return nil }
        return (at, list.count)
    }

    var hasPrevious: Bool { (position?.index ?? 0) > 0 }
    var hasNext: Bool { position.map { $0.index < $0.total - 1 } ?? false }

    func pickTab(_ key: String) async {
        guard tabs.contains(where: { $0.key == key }), key != selectedTabKey else { return }
        tabTouched = true
        selectedTabKey = key
        instrumentFilter = ""
        await openCurrent()
    }

    func pick(_ doc: CatalogueDocument) async {
        guard let tab = activeTab else { return }
        selection[tab.key] = doc.id
        await openCurrent()
    }

    func previous() async {
        guard let p = position, p.index > 0 else { return }
        await pick(list[p.index - 1])
    }

    func next() async {
        guard let p = position, p.index < p.total - 1 else { return }
        await pick(list[p.index + 1])
    }

    /// The other editions of the Act, offered on the Act tab.
    var editions: [CatalogueDocument] {
        guard activeTab?.key == "act" else { return [] }
        return tabs.first { $0.key == "editions" }?.docs ?? []
    }

    /// Other copies to offer when the open one is not on the server.
    var alternatives: [(doc: CatalogueDocument, label: String)] {
        guard let tab = activeTab, tab.key == "act", let current else { return [] }
        return LibraryActText.choices(for: tab, in: tabs).enumerated()
            .map { i, d in (d, i == 0 ? "the current edition" : "edition \(i + 1)") }
            .filter { $0.0.id != current.id }
            .prefix(3)
            .map { ($0.0, $0.1) }
    }

    /// Whether the open document is the Act itself (its name is the page's heading).
    var isPrincipal: Bool {
        guard let current, let act else { return false }
        return current.id == act.id && kind != "amendments"
    }

    /// The pane's kind label: the tab's name, or "Other edition" for another copy of the Act.
    var paneKindLabel: String? {
        guard let tab = activeTab else { return nil }
        if tab.key == "act", let current, let act, current.id != act.id { return "Other edition" }
        return tab.label
    }

    // MARK: - The head

    var title: String {
        if let group = bundle?.groupTitle?.nilIfEmpty { return group }
        guard let act else { return "Act" }
        return LibraryActText.splitTitle(act).name
    }

    var fullTitle: String { act.map(LibraryActText.actTitle) ?? "Act" }

    /// "Central Act · 1860 · IPC" — the pieces over the name.
    var kickerParts: [String] {
        guard let act else { return [] }
        let j = LibraryActText.jurisdiction(of: act)
        let year = LibraryActText.splitTitle(act).year
        let aliases = act.aliases ?? bundle?.act.aliases
        return [
            kind == "orphan" && act.docType != nil && act.docType != "act" ? LibraryActText.kicker(act) : nil,
            kind == "amendments" ? "Amending Acts" : (j.isCentral ? "Central Act" : (j.value == "none" ? nil : j.label)),
            kind == "amendments" && j.value != "none" ? j.label : nil,
            kind != "amendments" ? year.nilIfEmpty : nil,
            aliases?.first?.nilIfEmpty,
        ].compactMap { $0 }
    }

    var isRepealed: Bool { act.map(LibraryActText.isRepealed) ?? false }

    /// The tag beside the kicker for an orphan or an amendment group.
    var standingNote: String? {
        switch kind {
        case "orphan": return "Its Act is not in the library"
        case "amendments": return "The Act itself is not in the library"
        default: return nil
        }
    }

    /// "9 rules · 25 amendments" (at most three parts).
    var holdsLine: String? {
        guard let bundle else { return nil }
        if kind == "amendments" {
            let n = bundle.tabs.filter { $0.key == "act" || $0.key == "amendments" }.reduce(0) { $0 + $1.count }
            return "\(LibraryTitles.count(n)) amending Acts"
        }
        let counts = Dictionary(uniqueKeysWithValues: bundle.tabs.map { ($0.key, $0.count) })
        let parts = LibraryActText.countParts(counts)
        return parts.isEmpty ? nil : parts.prefix(3).joined(separator: " · ")
    }

    /// What a tab's pill says: its label and, except for a lone Act, its count.
    func tabCount(_ tab: ActBundle.Tab) -> String? {
        (tab.key != "act" || tab.count > 1) ? LibraryTitles.count(tab.count) : nil
    }

    /// "Edition 2 · Assam copy · 1.4 MB".
    func editionLabel(_ doc: CatalogueDocument, index: Int) -> String {
        ["Edition \(index + 2)", LibraryActText.copySource(doc), LibraryActText.size(doc.fileSize)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var currentEditionLabel: String {
        guard let act else { return "Current edition" }
        let size = LibraryActText.size(act.fileSize)
        return size.isEmpty ? "Current edition" : "Current edition · \(size)"
    }

    // MARK: - The reading pane

    func isAvailable(_ id: Int) -> Bool? { availability[id] }
    func data(for id: Int) -> Data? { bytes[id] }

    var currentData: Data? { current.flatMap { bytes[$0.id] } }
    var currentIsLoading: Bool { current.map { loadingID == $0.id } ?? false }
    var currentIsMissing: Bool { current.flatMap { availability[$0.id] } == false }

    /// Fetches the open instrument's PDF, once: a HEAD first, so a row whose file is not on this
    /// server says so instead of handing a JSON 404 to the viewer.
    func openCurrent() async {
        guard let doc = current else { return }
        openError = nil
        remember(doc.id)
        if bytes[doc.id] != nil || availability[doc.id] == false { return }
        loadingID = doc.id
        defer { if loadingID == doc.id { loadingID = nil } }
        do {
            if availability[doc.id] == nil {
                availability[doc.id] = try await service.fileExists(id: doc.id)
            }
            guard availability[doc.id] == true else { return }
            let data = try await service.file(id: doc.id, prefer: .original)
            guard current?.id == doc.id || recentIDs.contains(doc.id) else { return }
            bytes[doc.id] = data
            trimPool()
        } catch let error as LibraryCatalogueError where error.status == 404 {
            availability[doc.id] = false
        } catch {
            openError = DisplayText.message(for: error)
        }
    }

    private func remember(_ id: Int) {
        recentIDs.removeAll { $0 == id }
        recentIDs.append(id)
    }

    /// The last few PDFs stay in memory; older ones are dropped, never the open one.
    private func trimPool() {
        while recentIDs.count > Self.pool {
            let dropped = recentIDs.removeFirst()
            if dropped != current?.id { bytes[dropped] = nil }
        }
    }

    enum Copy {
        static let back = "Bare acts"
        static let notOnShelf = "Not on the shelf yet"
        static let notOnShelfHint = "The catalogue lists it, but its PDF has not been copied to this server yet."
        static let otherEdition = "Another edition may be here:"
        static let openAsAct = "Open this Act"
        static let latest = "Latest"
        static let repealed = "Repealed"
    }
}
