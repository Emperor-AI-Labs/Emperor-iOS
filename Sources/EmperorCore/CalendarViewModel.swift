import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The Calendar tab: the user's case listings, day by day, alongside their diary.
///
/// Both matter and neither is complete on its own — a limitation date lives in
/// `compliance_events` while the hearing it relates to lives on the case. Showing one without
/// the other is how a date gets missed.
///
/// A day's listings come from the cause list, topped up from the docket's next hearing dates, in
/// the order the day will run — see `CalendarListings` for both rules. Opening one is not this
/// screen's job: it hands the case to `AppNavigator`, which shows it on the Cases tab.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class CalendarViewModel {

    private(set) var events: [ComplianceEvent] = []
    private(set) var cases: [LegalCase] = []
    /// Every listing for every date — `/cause-list` takes no range (README trap 10).
    private(set) var causeList: [CauseListing] = []
    /// `causeList` and `cases` merged into days, each in calendar order. Rebuilt whenever either
    /// changes, and only then, because building it is the expensive part.
    private(set) var listingsByDay: [String: [CauseListing]] = [:]
    private(set) var state: LoadState = .idle
    private(set) var cachedAt: Date?
    private(set) var isWriting = false
    var writeError: String?

    /// The day in focus, as a `YYYY-MM-DD` key in India.
    private(set) var selectedDay: String

    private let calendar: any CalendarProviding
    private let caseService: any CaseProviding
    private let cache: ResponseCache?
    private let now: @Sendable () -> Date

    init(
        calendar: any CalendarProviding,
        caseService: any CaseProviding,
        cache: ResponseCache? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.calendar = calendar
        self.caseService = caseService
        self.cache = cache
        self.now = now
        self.selectedDay = WireDate.dayKey(now())
    }

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: hasNothingOnScreen, cachedAt: cachedAt)
    }

    /// Whether there is nothing on screen *yet* — the question `ListPresentation` asks to choose
    /// between a spinner, a failure and content.
    ///
    /// Not "the calendar has no rows". Once a load has returned, the grid is itself content and
    /// must not be replaced: `ListStateView`'s empty branch takes the whole screen, and the grid
    /// is exactly what a reader with nothing scheduled still needs — to step to another month,
    /// or to pick a day to add one to. Which kind of nothing it is gets said inside the day's
    /// own section, where an empty day can be told from an empty calendar.
    ///
    /// Before that first load returns, holding nothing *does* mean a spinner or an error, so
    /// this stays true until then. `isEmpty` decides four things here, not one — flatten it to
    /// `false` and a failed first load draws an empty grid under a stale banner instead of the
    /// failure and its retry, and the initial spinner never appears at all.
    private var hasNothingOnScreen: Bool {
        events.isEmpty && cases.isEmpty && causeList.isEmpty && !state.hasLoaded
    }

    /// Whether the calendar holds a single row anywhere — not merely on the day being shown.
    ///
    /// It separates "nothing on this day" from "nothing at all", which are different things to
    /// tell someone looking at an empty grid. Deliberately not `events.isEmpty && cases.isEmpty`:
    /// both buckets the screen draws from are filtered — `upcoming()` keeps today onward, and a
    /// past hearing is not overdue, see `overdue` — so a user whose matters have all been heard
    /// has data and no rows. Asking the raw arrays answers "not empty", and for a while that
    /// rendered a list of zero sections, which is a blank screen.
    ///
    /// Asked without building `upcoming()`: whether any populated day falls on or after today is
    /// the same question for one pass, where assembling the days re-filters both arrays per day.
    var hasNothingToShow: Bool {
        let today = todayKey
        return overdue.isEmpty && !populatedDays.contains { $0 >= today }
    }

    /// The month the grid is showing — whichever one holds `selectedDay`.
    var month: CalendarMonth? { CalendarMonth.containing(selectedDay) }

    /// Everything on the day the grid has selected.
    var selectedCalendarDay: CalendarDay { day(selectedDay) }

    var todayKey: String { WireDate.dayKey(now()) }
    var isShowingToday: Bool { selectedDay == todayKey }

    // MARK: - Days

    /// Everything on a given day: its listings in calendar order, then its diary entries.
    func day(_ key: String) -> CalendarDay {
        CalendarDay(
            key: key,
            listings: listingsByDay[key] ?? [],
            events: events.filter { $0.dayKey == key })
    }

    /// Every day that has anything on it.
    var populatedDays: Set<String> {
        Set(events.compactMap(\.dayKey)).union(listingsByDay.keys)
    }

    /// What each marked cell of the month grid says. A day with a listing is marked as listed
    /// whatever else is on it — a hearing is the thing on a day that cannot move.
    ///
    /// Read once per render: the grid asks about forty-odd days.
    var marks: [String: CalendarDayMark] {
        var marks: [String: CalendarDayMark] = [:]
        for key in events.compactMap(\.dayKey) { marks[key] = .diary }
        for key in listingsByDay.keys { marks[key] = .listed }
        return marks
    }

    // MARK: - Copy

    enum Copy {
        /// Under the day's listings on every state, empty included. These are the user's own
        /// matters, not the court's list, and an empty day must never read as a free one — the
        /// same framing Home carries (`CauseListViewModel.Copy`).
        static let listingsFooter =
            "\(CauseListViewModel.Copy.subtitle). \(CauseListViewModel.Copy.confirmWithCourt)"
        static let nothingScheduled =
            "Nothing scheduled yet. Hearings on your matters appear here, and you can add a diary entry with the + above."
    }

    /// What the selected day says in place of listings when it has none — and which kind of
    /// nothing it is. An empty day in a full calendar and an empty calendar are different things
    /// to be told.
    var selectedDayEmptyText: String {
        if hasNothingToShow && selectedCalendarDay.isEmpty { return Copy.nothingScheduled }
        return isShowingToday
            ? CauseListViewModel.Copy.nothingToday : CauseListViewModel.Copy.nothingThisDay
    }

    /// What is coming, soonest first — the agenda beneath the grid.
    ///
    /// `excluding` drops the day the grid has selected. That day is listed in full immediately
    /// above the agenda, and would otherwise be read twice on the same screen.
    func upcoming(limit: Int = 50, excluding excluded: String? = nil) -> [CalendarDay] {
        let today = todayKey
        return populatedDays
            .filter { $0 >= today && $0 != excluded }
            .sorted()
            .prefix(limit)
            .map { day($0) }
    }

    /// Obligations that are past due and still open. Overdue is a real category here, unlike on
    /// the docket — someone typed this date in as a thing they had to do by then.
    var overdue: [ComplianceEvent] {
        let today = todayKey
        return events
            .filter { !$0.isDone && ($0.dayKey.map { $0 < today } ?? false) }
            .sorted { ($0.dayKey ?? "") < ($1.dayKey ?? "") }
    }

    func select(day: String) { selectedDay = day }
    func goToToday() { selectedDay = todayKey }

    func step(months: Int) {
        guard let current = WireDate.parseDay(selectedDay) else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WireDate.india
        guard let stepped = calendar.date(byAdding: .month, value: months, to: current) else {
            return
        }
        selectedDay = WireDate.dayKey(stepped)
    }

    // MARK: - Loading

    func load() async {
        if state == .idle, events.isEmpty, cases.isEmpty, causeList.isEmpty {
            restoreFromCache()
        }

        state = .loading
        do {
            // All three, and all or nothing, because a calendar showing only some of the dates
            // is worse than none — a day without its listings reads as a day without hearings.
            async let fetchedEvents = calendar.events()
            async let fetchedCases = caseService.cases()
            async let fetchedListings = caseService.causeList()
            let (newEvents, newCases, newListings) =
                try await (fetchedEvents, fetchedCases, fetchedListings)
            events = newEvents
            cases = newCases
            causeList = newListings
            rebuildListings()
            cachedAt = nil
            cache?.save(events, for: .calendarEvents)
            // The same routes Cases and Home cache under, so whichever screen loaded last
            // leaves the freshest copy for the others to open on.
            cache?.save(cases, for: .caseList)
            cache?.save(causeList, for: .causeList)
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    /// Opens on what was last loaded, stamped with when — the oldest of the three, since that
    /// is how stale the screen is.
    private func restoreFromCache() {
        guard let cache else { return }
        var stamps: [Date] = []
        if let cached = cache.load([ComplianceEvent].self, for: .calendarEvents) {
            events = cached.value
            stamps.append(cached.storedAt)
        }
        if let cached = cache.load([LegalCase].self, for: .caseList) {
            cases = cached.value
            stamps.append(cached.storedAt)
        }
        if let cached = cache.load([CauseListing].self, for: .causeList) {
            causeList = cached.value
            stamps.append(cached.storedAt)
        }
        guard !stamps.isEmpty else { return }
        cachedAt = stamps.min()
        rebuildListings()
    }

    private func rebuildListings() {
        listingsByDay = CalendarListings.byDay(causeList: causeList, cases: cases)
    }

    // MARK: - Writing

    func save(_ draft: ComplianceDraft) async {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        do {
            try await calendar.save(draft)
            await load()
        } catch {
            writeError = DisplayText.message(for: error)
        }
    }

    func toggleDone(_ event: ComplianceEvent) async {
        // `due_date` is nullable and stored verbatim with no validation
        // (`sync-server.js:10268`), so a web-created event can carry nothing usable. Saying so
        // beats a checkbox that silently does nothing.
        guard let dueDate = event.dueDate else {
            writeError = """
                This entry has no usable due date, so it cannot be updated here. Open it on the \
                web to fix the date first.
                """
            return
        }
        // A full draft, not a patch: the upsert replaces every column it names, so anything
        // omitted would be set to NULL.
        var draft = ComplianceDraft(
            id: event.id,
            title: event.title ?? "",
            kind: event.kind,
            dueDate: dueDate,
            notes: event.notes,
            caseID: event.caseID,
            // Carried through untouched. The upsert would otherwise NULL it, wiping a value
            // the user may have set on the web — where the control does exist.
            remindDays: event.remindDays)
        draft.isDone = !event.isDone
        await save(draft)
    }

    func delete(_ event: ComplianceEvent) async {
        isWriting = true
        defer { isWriting = false }
        do {
            try await calendar.delete(id: event.id)
            await load()
        } catch {
            writeError = DisplayText.message(for: error)
        }
    }
}
