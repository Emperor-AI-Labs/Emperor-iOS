import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The month view: hearings from the docket alongside obligations from the calendar.
///
/// Both sources matter and neither is complete on its own — a limitation date lives in
/// `compliance_events` while the hearing it relates to lives on the case. Showing one without
/// the other is how a date gets missed.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class CalendarViewModel {

    private(set) var events: [ComplianceEvent] = []
    private(set) var cases: [LegalCase] = []
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
        events.isEmpty && cases.isEmpty && !state.hasLoaded
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

    /// Everything on a given day, from both sources.
    func day(_ key: String) -> CalendarDay {
        CalendarDay(
            key: key,
            hearings: cases.filter { $0.nextHearingDateRaw?.prefix(10) == Substring(key) },
            events: events.filter { $0.dayKey == key })
    }

    /// Every day that has anything on it, ascending. Drives the dots on a month grid.
    var populatedDays: Set<String> {
        var days = Set(events.compactMap(\.dayKey))
        for legalCase in cases {
            if let raw = legalCase.nextHearingDateRaw, raw.count >= 10 {
                days.insert(String(raw.prefix(10)))
            }
        }
        return days
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
        if state == .idle, events.isEmpty,
           let cached = cache?.load([ComplianceEvent].self, for: .calendarEvents) {
            events = cached.value
            cachedAt = cached.storedAt
        }

        state = .loading
        do {
            // Both, because a calendar showing only half the dates is worse than none.
            async let fetchedEvents = calendar.events()
            async let fetchedCases = caseService.cases()
            events = try await fetchedEvents
            cases = try await fetchedCases
            cachedAt = nil
            cache?.save(events, for: .calendarEvents)
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
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
