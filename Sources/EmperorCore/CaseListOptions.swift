import Foundation

// The docket's sort, grouping and filters, and how each is remembered between launches.
//
// Every choice is stored as its raw value, one key per choice, and read back leniently: a value
// this build does not recognise — left by a later build, or by a downgrade — falls back to the
// default rather than failing, the way `PractitionerRole.stored(in:)` does. A filter set keeps
// the values it recognises and drops the rest, so one retired value does not throw away the
// whole filter.

/// The order of the cases under each heading.
enum CaseSort: String, CaseIterable, Identifiable, Sendable {
    /// Soonest upcoming hearing first, then hearings already past (most recent first), then
    /// the matters with no date. What the screen is opened to answer.
    case nextHearing = "next-hearing"
    /// `updated_at`, newest first — the web's default, offered rather than imposed.
    case recentlyUpdated = "recently-updated"
    case nameAscending = "name-asc"
    case nameDescending = "name-desc"
    /// Newest filing first; matters with no filing date last.
    case filingDate = "filing-date"

    static let `default`: CaseSort = .nextHearing
    static let storageKey = "cases.sort.v1"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nextHearing: return "Next hearing"
        case .recentlyUpdated: return "Recently updated"
        case .nameAscending: return "Name A–Z"
        case .nameDescending: return "Name Z–A"
        case .filingDate: return "Filing date"
        }
    }

    static func stored(in store: any PreferenceStore) -> CaseSort {
        store.string(for: storageKey).flatMap(CaseSort.init(rawValue:)) ?? .default
    }

    func save(to store: any PreferenceStore) {
        store.setString(rawValue, for: Self.storageKey)
    }
}

/// The headings the docket is divided under.
enum CaseGrouping: String, CaseIterable, Identifiable, Sendable {
    /// One heading per `CourtTier`, in order of importance.
    case court
    /// "Next in court", "Last listed" and "No hearing date".
    case hearingDate = "hearing-date"
    /// One list.
    case none

    static let `default`: CaseGrouping = .court
    static let storageKey = "cases.grouping.v1"

    var id: String { rawValue }

    /// Short, because the three sit side by side under a "Group by" heading.
    var label: String {
        switch self {
        case .court: return "Court"
        case .hearingDate: return "Hearing date"
        case .none: return "None"
        }
    }

    static func stored(in store: any PreferenceStore) -> CaseGrouping {
        store.string(for: storageKey).flatMap(CaseGrouping.init(rawValue:)) ?? .default
    }

    func save(to store: any PreferenceStore) {
        store.setString(rawValue, for: Self.storageKey)
    }
}

/// Where a matter's next hearing falls, relative to today in India.
enum HearingFilter: String, CaseIterable, Identifiable, Sendable {
    /// Today or later. A hearing today is still ahead of the practitioner, not behind them.
    case upcoming
    /// Before today — usually heard, with the next date not yet synced.
    case past
    /// No hearing date, or one that is not a real day.
    case undated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .upcoming: return "Upcoming"
        case .past: return "Past"
        case .undated: return "No date"
        }
    }

    /// What a chip says once the filter is on, away from the "Hearing" heading that gives
    /// `label` its meaning.
    var chipLabel: String {
        switch self {
        case .upcoming: return "Upcoming hearing"
        case .past: return "Past hearing"
        case .undated: return "No hearing date"
        }
    }

    /// Which of the three a case is, against `today`'s `YYYY-MM-DD` key in India.
    ///
    /// The day is read the way the Calendar reads it (`CalendarListings.hearingDay`), so a
    /// value that is not a real date counts as no date here too, rather than being compared as
    /// text and landing among the upcoming hearings.
    static func of(_ legalCase: LegalCase, today: String) -> HearingFilter {
        guard let day = CalendarListings.hearingDay(of: legalCase) else { return .undated }
        return day < today ? .past : .upcoming
    }
}

/// Whether the court maintains the matter or someone typed it in.
enum SourceFilter: String, CaseIterable, Identifiable, Sendable {
    case court
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .court: return "From court"
        case .manual: return "Added by hand"
        }
    }

    static func of(_ legalCase: LegalCase) -> SourceFilter {
        legalCase.isCourtSynced ? .court : .manual
    }
}

/// The filters on the docket.
///
/// Each dimension is a set, empty meaning "no filter". Within a dimension the choices widen
/// (Supreme Court *or* High Courts); across dimensions they narrow (High Courts *and* upcoming).
/// That is how every filter a practitioner has used elsewhere behaves, and the only reading in
/// which choosing two courts does not hide everything.
struct CaseFilters: Equatable, Sendable {
    var courts: Set<CourtTier> = []
    var hearings: Set<HearingFilter> = []
    var sources: Set<SourceFilter> = []

    static let courtsKey = "cases.filter.courts.v1"
    static let hearingsKey = "cases.filter.hearings.v1"
    static let sourcesKey = "cases.filter.sources.v1"

    var isEmpty: Bool { courts.isEmpty && hearings.isEmpty && sources.isEmpty }

    /// How many choices are on — what the toolbar button reports.
    var count: Int { courts.count + hearings.count + sources.count }

    func matches(_ legalCase: LegalCase, today: String) -> Bool {
        if !courts.isEmpty, !courts.contains(CourtTier.of(legalCase)) { return false }
        if !hearings.isEmpty, !hearings.contains(HearingFilter.of(legalCase, today: today)) {
            return false
        }
        if !sources.isEmpty, !sources.contains(SourceFilter.of(legalCase)) { return false }
        return true
    }

    /// One chip per choice that is on, in the order the sheet lists them.
    var chips: [CaseFilterChip] {
        CourtTier.allCases.filter(courts.contains).map(CaseFilterChip.court)
            + HearingFilter.allCases.filter(hearings.contains).map(CaseFilterChip.hearing)
            + SourceFilter.allCases.filter(sources.contains).map(CaseFilterChip.source)
    }

    func contains(_ chip: CaseFilterChip) -> Bool {
        switch chip {
        case .court(let tier): return courts.contains(tier)
        case .hearing(let hearing): return hearings.contains(hearing)
        case .source(let source): return sources.contains(source)
        }
    }

    /// Turns one choice on or off.
    mutating func toggle(_ chip: CaseFilterChip) {
        if contains(chip) { remove(chip) } else { insert(chip) }
    }

    mutating func insert(_ chip: CaseFilterChip) {
        switch chip {
        case .court(let tier): courts.insert(tier)
        case .hearing(let hearing): hearings.insert(hearing)
        case .source(let source): sources.insert(source)
        }
    }

    mutating func remove(_ chip: CaseFilterChip) {
        switch chip {
        case .court(let tier): courts.remove(tier)
        case .hearing(let hearing): hearings.remove(hearing)
        case .source(let source): sources.remove(source)
        }
    }

    // MARK: - Storage

    static func stored(in store: any PreferenceStore) -> CaseFilters {
        CaseFilters(
            courts: decode(store.string(for: courtsKey)),
            hearings: decode(store.string(for: hearingsKey)),
            sources: decode(store.string(for: sourcesKey)))
    }

    func save(to store: any PreferenceStore) {
        store.setString(Self.encode(courts), for: Self.courtsKey)
        store.setString(Self.encode(hearings), for: Self.hearingsKey)
        store.setString(Self.encode(sources), for: Self.sourcesKey)
    }

    /// Comma-separated raw values, in declaration order so the stored string is stable.
    private static func encode<Value: CaseIterable & RawRepresentable & Hashable>(
        _ values: Set<Value>
    ) -> String where Value.RawValue == String {
        Value.allCases.filter(values.contains).map(\.rawValue).joined(separator: ",")
    }

    private static func decode<Value: RawRepresentable & Hashable>(
        _ raw: String?
    ) -> Set<Value> where Value.RawValue == String {
        guard let raw else { return [] }
        return Set(raw.split(separator: ",").compactMap {
            Value(rawValue: $0.trimmingCharacters(in: .whitespaces))
        })
    }
}

/// One filter that is on, as a removable chip under the search bar.
enum CaseFilterChip: Hashable, Identifiable, Sendable {
    case court(CourtTier)
    case hearing(HearingFilter)
    case source(SourceFilter)

    /// Stable, and what a UI test names the chip by.
    var id: String {
        switch self {
        case .court(let tier): return "court-\(tier.rawValue)"
        case .hearing(let hearing): return "hearing-\(hearing.rawValue)"
        case .source(let source): return "source-\(source.rawValue)"
        }
    }

    /// What the chip says, standing on its own under the search bar.
    var label: String {
        switch self {
        case .court(let tier): return tier.title
        case .hearing(let hearing): return hearing.chipLabel
        case .source(let source): return source.label
        }
    }

    /// What the choice is called in the sheet, under a heading that already says "Hearing".
    var optionLabel: String {
        switch self {
        case .court(let tier): return tier.title
        case .hearing(let hearing): return hearing.label
        case .source(let source): return source.label
        }
    }
}
