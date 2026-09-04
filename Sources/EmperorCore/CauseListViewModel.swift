import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The day view of what is listed.
///
/// ## What this is NOT
///
/// **It is not the court's published cause list.** There is no upstream feed for that anywhere
/// in this product — the server derives every row from hearing dates on cases the user has
/// added (`sync-server.js:9697-9782`). A screen titled "cause list" that silently showed only a
/// subset of the real one would be worse than no screen: a litigator who reads it as the
/// court's list and finds nothing has been told their day is clear when it may not be.
///
/// That is why `Copy.subtitle` appears on every state including the empty one, and why the
/// empty state ends with "Always confirm against the court's official cause list."
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class CauseListViewModel {

    /// Framing copy, carried over verbatim from the web client so the two products cannot
    /// disagree about what this screen claims to be (`src/pages/home/TodayCauseList.jsx:290`,
    /// `src/pages/CaseManagement.jsx:493`).
    enum Copy {
        static let subtitle = "Your cases, by hearing date"
        static let nothingAtAll = "Nothing listed."
        /// Deliberately not "No cases added yet" — this screen only ever sees *listings*, so it
        /// cannot tell an empty docket from a docket whose matters have no hearing date yet.
        /// Asserting the former would be a guess presented as fact.
        static let nothingAtAllDetail =
            "No hearing dates have come through for your matters. New cases appear here once the court sync has run."
        static let nothingToday = "Nothing listed for today."
        static let nothingThisDay = "Nothing listed for this day."
        /// The safety sentence. Never drop it: it is the only thing standing between an empty
        /// day and a practitioner concluding they are free.
        static let confirmWithCourt = "Always confirm against the court's official cause list."
    }

    private(set) var listings: [CauseListing] = []
    private(set) var state: LoadState = .idle
    private(set) var cachedAt: Date?

    /// The day being shown, as a `YYYY-MM-DD` key in India.
    ///
    /// A string rather than a `Date` on purpose: the server buckets by India's day and so must
    /// the client. Holding a `Date` invites `Calendar.current`, which shows the wrong day's
    /// hearings to anyone whose device is not on IST.
    private(set) var selectedDay: String

    private let service: any CaseProviding
    private let cache: ResponseCache?
    private let now: @Sendable () -> Date

    init(
        service: any CaseProviding,
        cache: ResponseCache? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.cache = cache
        self.now = now
        self.selectedDay = WireDate.dayKey(now())
    }

    // MARK: - Presentation

    var presentation: ListPresentation {
        ListPresentation(
            state: state, isEmpty: listingsForSelectedDay.isEmpty, cachedAt: cachedAt)
    }

    var todayKey: String { WireDate.dayKey(now()) }
    var isShowingToday: Bool { selectedDay == todayKey }

    /// Whether anything at all is listed, on any date.
    ///
    /// Note this is **not** "the user has cases" — this screen only receives listings, so it
    /// cannot distinguish an empty docket from matters that simply have no hearing date yet.
    var hasAnyListings: Bool { !listings.isEmpty }

    /// The listings for the selected day, ordered so the most informative rows come first.
    ///
    /// Sorted client-side because the server's pass-1 query has no `ORDER BY`
    /// (`sync-server.js:9750-9754`), so both the row order and which row wins a
    /// `(case, date)` collision are engine-dependent.
    var listingsForSelectedDay: [CauseListing] {
        listings
            .filter { $0.date == selectedDay }
            .sorted { Self.sortKey($0) < Self.sortKey($1) }
    }

    /// A **total** order over a listing.
    ///
    /// The obvious hand-written comparator is not one. Mixing numeric item numbers with
    /// alphanumeric ones ("12A", "7/3" — both routine in Indian cause lists) and falling through
    /// to the title produces a cycle: with items `20`/`x`/`3` and titles `A`/`M`/`Z`, all three
    /// of `20 < x`, `x < 3` and `3 < 20` hold. `sort` is undefined on an invalid comparator and
    /// can trap. A tuple key cannot have that shape.
    ///
    /// Ordering: leading number first (so item 2 precedes item 10), then the item string (so
    /// "12A" follows "12"), then the title. Unnumbered rows sort last rather than first — an
    /// item without a number is not item zero.
    private static func sortKey(_ listing: CauseListing) -> (Int, String, String) {
        let item = listing.itemNo?.trimmingCharacters(in: .whitespaces) ?? ""
        let leadingDigits = item.prefix { $0.isNumber }
        let number = Int(leadingDigits) ?? Int.max
        return (number, item, listing.displayTitle.lowercased())
    }

    /// Every day that actually has a listing, ascending.
    var listedDays: [String] { Array(Set(listings.map(\.date))).sorted() }

    /// The heading for the empty state.
    var emptyTitle: String {
        guard hasAnyListings else { return Copy.nothingAtAll }
        return isShowingToday ? Copy.nothingToday : Copy.nothingThisDay
    }

    /// The sentence under it. Always ends with the confirm-with-the-court line when the user
    /// has cases, because that is the case where a blank screen could be misread.
    var emptyDetail: String {
        // The confirm-with-the-court line is on **every** empty state, including the
        // nothing-at-all case. A blank screen must never read as "your day is clear".
        guard hasAnyListings else {
            return "\(Copy.nothingAtAllDetail) \(Copy.confirmWithCourt)"
        }
        let day = isShowingToday ? "today's date" : DisplayText.longDay(selectedDay)
        return "None of your cases has a hearing on \(day). \(Copy.confirmWithCourt)"
    }

    // MARK: - Day navigation

    /// The next day that actually has something listed.
    ///
    /// Jumps to a **listed** day rather than stepping the calendar blindly. An empty day is a
    /// real answer and the arrows never skip one, but a blank screen should still say where the
    /// next listing is rather than being a dead end.
    var nextListedDay: String? { listedDays.first { $0 > selectedDay } }
    var previousListedDay: String? { listedDays.last { $0 < selectedDay } }

    func select(day: String) { selectedDay = day }
    func goToToday() { selectedDay = todayKey }

    func goToNextListedDay() {
        if let next = nextListedDay { selectedDay = next }
    }

    func goToPreviousListedDay() {
        if let previous = previousListedDay { selectedDay = previous }
    }

    /// Steps one calendar day, for the plain next/previous arrows.
    func step(days: Int) {
        guard let current = WireDate.parseDay(selectedDay) else { return }
        let stepped = current.addingTimeInterval(TimeInterval(days) * 86_400)
        selectedDay = WireDate.dayKey(stepped)
    }

    // MARK: - Loading

    /// Fetches the whole cause list, once.
    ///
    /// The route takes no date range and returns every listing for every date, so this is a
    /// single fetch windowed locally rather than a per-day request — asking per day would
    /// re-download the entire hearing history each time.
    func load() async {
        if state == .idle, listings.isEmpty,
           let cached = cache?.load([CauseListing].self, for: .causeList) {
            listings = cached.value
            cachedAt = cached.storedAt
        }

        state = .loading
        do {
            listings = try await service.causeList()
            cachedAt = nil
            cache?.save(listings, for: .causeList)
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    /// One day, as shareable plain text.
    func shareText() -> String {
        let heading = "\(Copy.subtitle) — \(DisplayText.longDay(selectedDay))"
        guard !listingsForSelectedDay.isEmpty else {
            return "\(heading)\n\n\(emptyTitle) \(Copy.confirmWithCourt)"
        }
        let rows = listingsForSelectedDay.map { listing -> String in
            var line = listing.displayTitle
            if let reference = [listing.caseNumber, listing.caseYear]
                .compactMap({ $0 }).joined(separator: "/").nilIfEmpty {
                line += " (\(reference))"
            }
            if let court = listing.courtName { line += "\n  \(court)" }
            if let purpose = listing.purpose { line += "\n  \(purpose)" }
            if let bench = listing.bench { line += "\n  \(bench)" }
            return line
        }
        return heading + "\n\n" + rows.joined(separator: "\n\n")
            + "\n\n" + Copy.confirmWithCourt
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
