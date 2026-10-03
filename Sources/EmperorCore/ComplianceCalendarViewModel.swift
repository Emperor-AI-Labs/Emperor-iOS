import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The Corporate Calendar: every dated statutory deadline the platform tracks, soonest first.
///
/// ## What the web page does, and what this keeps
///
/// `ComplianceCalendar.jsx` lays these out as a month grid beside an agenda, with category
/// chips, a status filter and three counts (overdue, next seven days, open). A month grid of
/// twenty-odd deadlines spread over a year is mostly empty cells on a phone, so the agenda
/// becomes the screen: what is overdue, what falls due in the next seven days, then each later
/// month. The chips, the status filter and the counts are kept as they are; a regulator filter
/// is added beside them, because "everything RBI wants from us" is the other way a company
/// secretary asks the question.
///
/// ## What it does not do
///
/// - **No company profiles.** The web can also generate deadlines from companies the user
///   describes, kept in that browser's `localStorage` and never sent to the server. With no
///   company it shows exactly this feed, which is what this screen is: the general calendar.
/// - **No "mark done".** What the web has recorded as done is shown; recording it from here is
///   held back — see `ComplianceCalendarService.statutoryMarkers()`.
/// - **No pipeline history.** The web has a page listing every circular the pipeline read
///   (`ComplianceHistory.jsx`), but it reads a service the platform does not serve through its
///   API. Held back until it does.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class ComplianceCalendarViewModel {

    enum Copy {
        static let title = "Corporate Calendar"
        static let subtitle = "The next due date for each statutory obligation Emperor tracks"
        /// The safety sentence, in the same spirit as the cause list's: a date here is the
        /// pipeline's reading of a rule and of the notifications it has seen, not the
        /// regulator's own word.
        static let confirmWithRegulator =
            "Confirm each date against the regulator's current notification before you file."
        static let nothingTracked = "No dated deadlines"
        static let nothingTrackedDetail =
            "Emperor is not tracking a dated statutory deadline right now."
        static let nothingMatches = "Nothing matches these filters."
        static let shareFooter =
            "From Emperor's statutory calendar. Confirm the date against the regulator's current notification before relying on it."
    }

    enum StatusFilter: String, CaseIterable, Identifiable, Sendable {
        case all, open, done

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All statuses"
            case .open: return "Open"
            case .done: return "Done"
            }
        }
    }

    /// What is cached, so a cold launch offline still has the calendar.
    struct Snapshot: Codable, Equatable, Sendable {
        var deadlines: [StatutoryDeadline]
        var doneIDs: [String]
    }

    /// The web's three counts, over whatever the filters leave.
    struct Summary: Equatable, Sendable {
        var overdue: Int
        var dueSoon: Int
        var open: Int
    }

    /// One heading's worth of the agenda.
    struct DeadlineGroup: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case overdue
            case dueSoon
            /// A later month, keyed `YYYY-MM`.
            case month(String)
            /// Past and already marked done. Rare — the feed only carries next dates — but an
            /// old cached copy or a request made just after midnight can produce one, and it
            /// belongs neither under "Overdue" nor in a month that has gone.
            case doneEarlier
        }

        let kind: Kind
        let deadlines: [StatutoryDeadline]

        var id: String {
            switch kind {
            case .overdue: return "overdue"
            case .dueSoon: return "due-soon"
            case .month(let key): return "month-\(key)"
            case .doneEarlier: return "done-earlier"
            }
        }

        var title: String {
            switch kind {
            case .overdue: return "Overdue"
            case .dueSoon: return "Next 7 days"
            case .month(let key): return CourtCalendar.monthTitle(key) ?? key
            case .doneEarlier: return "Done earlier"
            }
        }
    }

    /// Every row the feed returned, dated or not, in the server's order.
    private(set) var rows: [StatutoryDeadline] = []
    /// The dated rows, soonest first — what the screen is made of.
    private(set) var deadlines: [StatutoryDeadline] = []
    private(set) var doneIDs: Set<String> = []
    private(set) var state: LoadState = .idle
    private(set) var cachedAt: Date?

    private(set) var category: ComplianceCategory?
    private(set) var regulator: String?
    private(set) var status: StatusFilter = .all

    private let service: any ComplianceCalendarProviding
    private let cache: ResponseCache?
    private let now: @Sendable () -> Date

    init(
        service: any ComplianceCalendarProviding,
        cache: ResponseCache? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.cache = cache
        self.now = now
    }

    // MARK: - Presentation

    /// Empty means the *feed* has nothing dated. A filter that hides everything is not that,
    /// and is said inside the list — beside the chips that caused it — rather than by replacing
    /// the screen with an empty state the user would have no way back from.
    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: deadlines.isEmpty, cachedAt: cachedAt)
    }

    var todayKey: String { WireDate.dayKey(now()) }

    func isDone(_ deadline: StatutoryDeadline) -> Bool { doneIDs.contains(deadline.id) }

    func daysUntilDue(_ deadline: StatutoryDeadline) -> Int? {
        guard let day = deadline.dueDay else { return nil }
        return CourtCalendar.days(from: todayKey, to: day)
    }

    func urgency(of deadline: StatutoryDeadline) -> DeadlineUrgency {
        DeadlineUrgency(daysUntilDue: daysUntilDue(deadline) ?? 0, isDone: isDone(deadline))
    }

    /// How many tracked obligations have no date, because they run from the company's own
    /// events — the AGM, a director change, an allotment. The web drops them silently; here
    /// they are counted in a footnote, so a short list is not read as a complete one.
    var undatedCount: Int { rows.count - deadlines.count }

    var undatedFootnote: String? {
        switch undatedCount {
        case ..<1: return nil
        case 1:
            return "One more tracked obligation runs from your company's own dates — an AGM, a board resolution, an allotment — so it has no date here."
        default:
            return "\(undatedCount) more tracked obligations run from your company's own dates — an AGM, a board resolution, an allotment — so they have no date here."
        }
    }

    // MARK: - Filters

    var visibleDeadlines: [StatutoryDeadline] {
        deadlines.filter(matchesFilters)
    }

    private func matchesFilters(_ deadline: StatutoryDeadline) -> Bool {
        matches(deadline, category: category, regulator: regulator)
            && (status == .all || (status == .done) == isDone(deadline))
    }

    private func matches(
        _ deadline: StatutoryDeadline, category: ComplianceCategory?, regulator: String?
    ) -> Bool {
        (category == nil || deadline.category == category)
            && (regulator == nil || deadline.regulator == regulator)
    }

    var hasActiveFilters: Bool { category != nil || regulator != nil || status != .all }

    /// The filters hid every deadline the feed has. Distinct from the feed being empty.
    var isFilteredToNothing: Bool { !deadlines.isEmpty && visibleDeadlines.isEmpty }

    /// Categories that actually have a dated deadline, in the web's order. The web shows all
    /// twelve chips always; on a phone a chip that can only ever produce an empty list is a
    /// row of dead ends.
    var availableCategories: [ComplianceCategory] {
        ComplianceCategory.allCases.filter { category in
            deadlines.contains { $0.category == category }
        }
    }

    /// How many dated deadlines a category chip stands for, whatever else is filtered — the
    /// chip names the whole category, so its count does too. `nil` counts everything.
    func count(in category: ComplianceCategory?) -> Int {
        guard let category else { return deadlines.count }
        return deadlines.filter { $0.category == category }.count
    }

    /// Regulators with a dated deadline in the chosen category, alphabetically.
    var availableRegulators: [String] {
        let names = Set(deadlines.filter { category == nil || $0.category == category }
            .compactMap(\.regulator))
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Choosing a category drops a regulator that has nothing in it, rather than leaving the
    /// two filters to cancel each other out into an empty list.
    func select(category: ComplianceCategory?) {
        self.category = category
        if let regulator,
           !deadlines.contains(where: { matches($0, category: category, regulator: regulator) }) {
            self.regulator = nil
        }
    }

    func select(regulator: String?) { self.regulator = regulator }
    func select(status: StatusFilter) { self.status = status }

    func clearFilters() {
        category = nil
        regulator = nil
        status = .all
    }

    // MARK: - The agenda

    var summary: Summary {
        var summary = Summary(overdue: 0, dueSoon: 0, open: 0)
        for deadline in visibleDeadlines where !isDone(deadline) {
            summary.open += 1
            guard let days = daysUntilDue(deadline) else { continue }
            if days < 0 {
                summary.overdue += 1
            } else if days <= DeadlineUrgency.dueSoonWindow {
                summary.dueSoon += 1
            }
        }
        return summary
    }

    /// Overdue, then the next seven days, then each later month.
    ///
    /// The seven-day line is the web's (`urgency()` calls anything 0–7 days out "soon"), so a
    /// row's pill and the heading above it can never disagree.
    var groups: [DeadlineGroup] {
        var overdue: [StatutoryDeadline] = []
        var dueSoon: [StatutoryDeadline] = []
        var doneEarlier: [StatutoryDeadline] = []
        var months: [String: [StatutoryDeadline]] = [:]

        for deadline in visibleDeadlines {
            guard let day = deadline.dueDay, let days = daysUntilDue(deadline) else { continue }
            if days < 0 {
                if isDone(deadline) { doneEarlier.append(deadline) } else { overdue.append(deadline) }
            } else if days <= DeadlineUrgency.dueSoonWindow {
                dueSoon.append(deadline)
            } else {
                months[String(day.prefix(7)), default: []].append(deadline)
            }
        }

        var groups: [DeadlineGroup] = []
        if !overdue.isEmpty { groups.append(DeadlineGroup(kind: .overdue, deadlines: overdue)) }
        if !dueSoon.isEmpty { groups.append(DeadlineGroup(kind: .dueSoon, deadlines: dueSoon)) }
        for month in months.keys.sorted() {
            groups.append(DeadlineGroup(kind: .month(month), deadlines: months[month] ?? []))
        }
        if !doneEarlier.isEmpty {
            groups.append(DeadlineGroup(kind: .doneEarlier, deadlines: doneEarlier))
        }
        // `visibleDeadlines` is already in agenda order, and appending preserves it.
        return groups
    }

    // MARK: - Loading

    func load() async {
        if state == .idle, rows.isEmpty,
           let cached = cache?.load(Snapshot.self, for: .complianceCalendar) {
            apply(cached.value)
            cachedAt = cached.storedAt
        }

        state = .loading
        do {
            // Both, because a deadline the team has already filed must not be shown as overdue
            // for want of the second request.
            async let fetchedRows = service.deadlines()
            async let fetchedMarkers = service.statutoryMarkers()
            let snapshot = Snapshot(
                deadlines: try await fetchedRows,
                doneIDs: try await fetchedMarkers.filter(\.isDone).map(\.id))
            apply(snapshot)
            cachedAt = nil
            cache?.save(snapshot, for: .complianceCalendar)
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    private func apply(_ snapshot: Snapshot) {
        let done = Set(snapshot.doneIDs)
        rows = snapshot.deadlines
        doneIDs = done
        deadlines = snapshot.deadlines
            .filter { $0.dueDay != nil }
            .sorted(by: Self.agendaOrder(isDone: { done.contains($0.id) }))

        // A filter naming something the refreshed feed no longer has would leave the list empty
        // with no chip on screen to clear it.
        if let category, !availableCategories.contains(category) { self.category = nil }
        if let regulator, !availableRegulators.contains(regulator) { self.regulator = nil }
    }

    /// Soonest first; on one day, open before done (the web's per-day order), then by title so
    /// the order does not depend on the server's.
    private static func agendaOrder(
        isDone: @escaping (StatutoryDeadline) -> Bool
    ) -> (StatutoryDeadline, StatutoryDeadline) -> Bool {
        { lhs, rhs in
            let left = (lhs.dueDay ?? "", isDone(lhs) ? 1 : 0, lhs.displayTitle.lowercased(), lhs.id)
            let right = (rhs.dueDay ?? "", isDone(rhs) ? 1 : 0, rhs.displayTitle.lowercased(), rhs.id)
            return left < right
        }
    }

    // MARK: - Detail

    func detail(for deadline: StatutoryDeadline) -> DeadlineDetail {
        DeadlineDetail(deadline: deadline, urgency: urgency(of: deadline), isDone: isDone(deadline))
    }
}

/// Everything the detail screen says about one deadline, worked out here so the view only lays
/// it out.
struct DeadlineDetail: Equatable, Sendable {
    let title: String
    let dueDay: String?
    let urgency: DeadlineUrgency
    let isDone: Bool
    let regulator: String?
    let category: ComplianceCategory?
    let code: String?
    let frequency: String?
    let usualSchedule: String?
    let differsFromUsualSchedule: Bool
    let note: String?
    let verification: DeadlineVerification

    init(deadline: StatutoryDeadline, urgency: DeadlineUrgency, isDone: Bool) {
        title = deadline.displayTitle
        dueDay = deadline.dueDay
        self.urgency = urgency
        self.isDone = isDone
        regulator = deadline.regulator
        category = deadline.category
        code = deadline.complianceID?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        frequency = deadline.frequencyLabel
        usualSchedule = deadline.schedule?.summary
        differsFromUsualSchedule = deadline.differsFromUsualSchedule
        note = deadline.note
        verification = deadline.verification
    }

    var dueLong: String? { dueDay.map(DisplayText.longDay) }

    /// Shown under the usual rule when the date above it does not follow from it.
    static let movedNotice =
        "This date is not the usual one, which usually means a notification has moved it. Check the notification before relying on either."

    var verificationText: String? {
        switch verification {
        case .checked(let day): return "Last verified on \(DisplayText.longDay(day))."
        case .unconfirmed:
            return "Not yet verified. Check the regulator's current notification before relying on this date."
        case .unknown: return nil
        }
    }

    /// What "Share" sends — enough to act on, and the caveat with it, because a forwarded date
    /// loses the screen it was read on.
    var shareText: String {
        var lines: [String] = []
        if let dueLong {
            lines.append("\(title) — due \(dueLong)")
        } else {
            lines.append(title)
        }
        let source = [regulator, category?.label].compactMap { $0 }
        if !source.isEmpty { lines.append(source.joined(separator: " · ")) }
        if let usualSchedule {
            lines.append("Usual deadline: \(usualSchedule)."
                + (differsFromUsualSchedule ? " This date differs from it." : ""))
        }
        if let note { lines.append(note) }
        if isDone { lines.append("Marked done.") }
        return lines.joined(separator: "\n") + "\n\n" + ComplianceCalendarViewModel.Copy.shareFooter
    }
}
