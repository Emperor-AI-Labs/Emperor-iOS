import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The docket: every matter, under headings — by court unless the user chooses otherwise — in
/// the order they choose, through the filters they choose, narrowed by their own search.
///
/// The search and the filters are separate on purpose. The search is for finding one matter you
/// can name ("Bakshi", a CNR, a diary number) and is forgotten when you leave; the filters and
/// the sort are how you want the docket laid out, and are remembered between launches. One field
/// doing both — as it used to — meant the only way to see just your NCLT matters was to type
/// "NCLT" and hope every one of them said so.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class CaseListViewModel {

    enum Copy {
        static let title = "Cases"
        /// "Your" because what it searches is this docket — the court lookup behind "Add case" is
        /// the search of everything else, and the two must not read as one control.
        static let searchPrompt = "Search your cases"
        /// Words, not a bare "+": beside a search bar a plus reads as "search for more".
        static let addCase = "Add case"
        static let arrange = "Sort and filter"
        static let arrangeTitle = "Sort & filter"
        static let clearAll = "Clear all"
        static let noMattersTitle = "No matters yet"
        static let noMattersMessage = "Cases added on the web appear here, with their hearing dates."
    }

    /// A heading in the list.
    struct Group: Identifiable, Equatable, Sendable {
        let key: String
        let title: String
        let cases: [LegalCase]
        var id: String { key }
    }

    /// What to say when there are cases but the search and filters hide every one of them —
    /// a different thing from having no cases, and worded so it cannot be mistaken for it.
    struct NoMatches: Equatable, Sendable {
        let title: String
        let message: String
        /// The button that clears whatever is hiding them.
        let action: String
    }

    private(set) var cases: [LegalCase] = []
    private(set) var state: LoadState = .idle
    private(set) var cachedAt: Date?

    /// The search. Deliberately not remembered: a search left over from yesterday would quietly
    /// hide matters from someone who has forgotten it is there.
    var query = ""

    var sort: CaseSort = .default {
        didSet { if sort != oldValue { sort.save(to: store) } }
    }

    var grouping: CaseGrouping = .default {
        didSet { if grouping != oldValue { grouping.save(to: store) } }
    }

    var filters = CaseFilters() {
        didSet { if filters != oldValue { filters.save(to: store) } }
    }

    private let service: any CaseProviding
    private let cache: ResponseCache?
    private let store: any PreferenceStore
    private let now: @Sendable () -> Date

    init(
        service: any CaseProviding,
        cache: ResponseCache? = nil,
        store: any PreferenceStore = InMemoryPreferenceStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.cache = cache
        self.store = store
        self.now = now
        sort = CaseSort.stored(in: store)
        grouping = CaseGrouping.stored(in: store)
        filters = CaseFilters.stored(in: store)
    }

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: cases.isEmpty, cachedAt: cachedAt)
    }

    /// There are cases, and the search and filters hide all of them.
    ///
    /// `presentation` reads the whole docket, not what is visible, so this case reaches the
    /// screen's content rather than its empty state — which is what keeps the search bar, the
    /// filter chips and their Clear in front of the person who needs them.
    var showsNoSearchResults: Bool { !cases.isEmpty && visible.isEmpty }

    var noMatches: NoMatches? {
        guard showsNoSearchResults else { return nil }
        let searched = trimmedQuery
        guard !filters.isEmpty else {
            return NoMatches(
                title: "No cases match “\(searched)”",
                message: "Check the spelling, or try a case number, CNR or diary number.",
                action: "Clear search")
        }
        if searched.isEmpty {
            return NoMatches(
                title: "No cases match these filters",
                message: "None of your cases fits every filter you have chosen.",
                action: "Clear filters")
        }
        return NoMatches(
            title: "No cases match these filters",
            message: "Nothing under the filters you have chosen matches “\(searched)”.",
            action: "Clear search and filters")
    }

    // MARK: - What is shown

    /// The cases the filters and the search let through, in the chosen order.
    var visible: [LegalCase] {
        let today = todayKey
        let terms = searchTerms
        let kept = cases.filter {
            filters.matches($0, today: today) && Self.matches($0, terms: terms)
        }
        return CaseOrdering.sorted(kept, by: sort, today: today)
    }

    /// `visible`, under headings. A heading with nothing under it is left out.
    ///
    /// Each heading keeps the chosen order inside it, so a High Courts heading sorted by name is
    /// sorted by name — the row itself says which High Court.
    var groups: [Group] {
        let ordered = visible
        switch grouping {
        case .court:
            let byTier = Dictionary(grouping: ordered, by: CourtTier.of)
            return CourtTier.allCases.compactMap { tier in
                guard let list = byTier[tier], !list.isEmpty else { return nil }
                return Group(key: tier.rawValue, title: tier.title, cases: list)
            }

        case .hearingDate:
            let today = todayKey
            let byHearing = Dictionary(grouping: ordered) { HearingFilter.of($0, today: today) }
            // Named "Last listed" rather than "Overdue": a past hearing date usually means the
            // matter was heard and the next date has not been synced yet, not that anything is
            // late. Calling it overdue would be an accusation the data cannot support.
            let headings: [(HearingFilter, String, String)] = [
                (.upcoming, "upcoming", "Next in court"),
                (.past, "past", "Last listed"),
                (.undated, "undated", "No hearing date"),
            ]
            return headings.compactMap { hearing, key, title in
                guard let list = byHearing[hearing], !list.isEmpty else { return nil }
                return Group(key: key, title: title, cases: list)
            }

        case .none:
            return ordered.isEmpty ? [] : [Group(key: "all", title: "All cases", cases: ordered)]
        }
    }

    // MARK: - Filters

    /// The chips under the search bar, one per filter that is on.
    var filterChips: [CaseFilterChip] { filters.chips }

    /// "2 filters on", for the toolbar button's spoken value.
    var filterSummary: String {
        switch filters.count {
        case 0: return "No filters"
        case 1: return "1 filter on"
        case let count: return "\(count) filters on"
        }
    }

    /// The court headings worth offering as filters: those the docket has cases under, plus any
    /// already chosen — so a filter whose cases have since gone can still be turned off.
    var courtTierOptions: [CourtTier] {
        let offered = Set(cases.map(CourtTier.of)).union(filters.courts)
        return CourtTier.allCases.filter(offered.contains)
    }

    /// How many cases on the whole docket one choice would keep, shown beside it.
    func count(for chip: CaseFilterChip) -> Int {
        let today = todayKey
        return cases.filter { legalCase in
            switch chip {
            case .court(let tier): return CourtTier.of(legalCase) == tier
            case .hearing(let hearing): return HearingFilter.of(legalCase, today: today) == hearing
            case .source(let source): return SourceFilter.of(legalCase) == source
            }
        }.count
    }

    func isOn(_ chip: CaseFilterChip) -> Bool { filters.contains(chip) }

    func toggle(_ chip: CaseFilterChip) { filters.toggle(chip) }

    func remove(_ chip: CaseFilterChip) { filters.remove(chip) }

    func clearFilters() { filters = CaseFilters() }

    /// What the no-matches state's button does: everything that is hiding cases goes.
    func clearSearchAndFilters() {
        query = ""
        filters = CaseFilters()
    }

    /// Whether sort, grouping and filters are all as a fresh install has them.
    var isAtDefaults: Bool {
        sort == .default && grouping == .default && filters.isEmpty
    }

    /// Back to the defaults — sort, grouping and filters. The search is left alone; it has its
    /// own clear button.
    func resetOptions() {
        sort = .default
        grouping = .default
        filters = CaseFilters()
    }

    // MARK: - Loading

    func load() async {
        if state == .idle, cases.isEmpty,
           let cached = cache?.load([LegalCase].self, for: .caseList) {
            cases = cached.value
            cachedAt = cached.storedAt
        }

        state = .loading
        do {
            cases = try await service.cases()
            cachedAt = nil
            cache?.save(cases, for: .caseList)
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    // MARK: - Search

    private var todayKey: String { WireDate.dayKey(now()) }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchTerms: [String] {
        trimmedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Matches on everything a practitioner might reach for: the matter name, the parties, the
    /// court, the case type, number and year, the CNR, the diary number, the judge, the status
    /// and the stage — and the court's heading, so "NCLAT" finds a case whose court is spelt
    /// out in full.
    ///
    /// Every word typed has to be found, but not side by side: "Bakshi 2025" finds the Bakshi
    /// matter of 2025 though its title and its year are different fields. The reference as the
    /// row prints it is included too, so "1234/2024" is found as it is read off the screen.
    private static func matches(_ legalCase: LegalCase, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let tier = CourtTier.of(legalCase)
        let haystack = [
            legalCase.title, legalCase.parties, legalCase.courtName, legalCase.caseType,
            legalCase.caseNumber, legalCase.caseYear, legalCase.caseReference, legalCase.cnr,
            legalCase.diaryNumber, legalCase.judge, legalCase.status, legalCase.stage,
            tier == .other ? nil : tier.title,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }
}

/// The orders `CaseSort` names, kept apart from the view model so each can be read on its own.
///
/// None of them is the server's own. `GET /cases` answers `ORDER BY c.updated_at DESC`
/// (`sync-server.js`), under which adding a note to a matter moves it to the top of the docket;
/// "Recently updated" offers that order when it is what someone wants, and only then. Every
/// order ends in the matter's name and then its id, so two cases that tie never trade places
/// between one refresh and the next.
enum CaseOrdering {

    static func sorted(_ cases: [LegalCase], by sort: CaseSort, today: String) -> [LegalCase] {
        // Each key is worked out once rather than inside the comparison: dates are parsed with
        // formatters, and a sort compares each case many times.
        let keyed = cases.map { Keyed($0, today: today) }
        return keyed.sorted { lhs, rhs in
            switch sort {
            case .nextHearing: return byNextHearing(lhs, rhs)
            case .recentlyUpdated: return newestFirst(lhs.updated, rhs.updated, lhs, rhs)
            case .nameAscending: return byName(lhs, rhs)
            case .nameDescending: return byName(rhs, lhs)
            case .filingDate: return newestFirst(lhs.filed, rhs.filed, lhs, rhs)
            }
        }
        .map(\.legalCase)
    }

    private struct Keyed {
        let legalCase: LegalCase
        let name: String
        /// `YYYY-MM-DD`, or `nil` when there is no real date.
        let hearingDay: String?
        let hearing: HearingFilter
        let updated: Date?
        let filed: Date?

        init(_ legalCase: LegalCase, today: String) {
            self.legalCase = legalCase
            name = legalCase.displayTitle
            hearingDay = CalendarListings.hearingDay(of: legalCase)
            hearing = HearingFilter.of(legalCase, today: today)
            // Parsed rather than compared as text: `updated_at` arrives in more than one
            // encoding, and "2026-09-14 10:00:00" sorts before "2026-09-14T09:00:00.000Z" as a
            // string though it is the later moment.
            updated = legalCase.updatedAt
            filed = legalCase.filingDate
        }
    }

    /// Upcoming hearings soonest first, then past ones most recent first, then the undated.
    private static func byNextHearing(_ lhs: Keyed, _ rhs: Keyed) -> Bool {
        let order: [HearingFilter] = [.upcoming, .past, .undated]
        let left = order.firstIndex(of: lhs.hearing) ?? order.count
        let right = order.firstIndex(of: rhs.hearing) ?? order.count
        if left != right { return left < right }
        if let leftDay = lhs.hearingDay, let rightDay = rhs.hearingDay, leftDay != rightDay {
            return lhs.hearing == .past ? leftDay > rightDay : leftDay < rightDay
        }
        return byName(lhs, rhs)
    }

    /// Newest first; a case with no date goes after every case that has one.
    private static func newestFirst(_ left: Date?, _ right: Date?, _ lhs: Keyed, _ rhs: Keyed) -> Bool {
        switch (left, right) {
        case let (left?, right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return byName(lhs, rhs)
        }
    }

    private static func byName(_ lhs: Keyed, _ rhs: Keyed) -> Bool {
        switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.legalCase.id < rhs.legalCase.id
        }
    }
}
