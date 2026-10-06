import Foundation

/// What Siri says — and the Shortcuts snippet shows — for "What's listed today?" and "What's
/// listed tomorrow?".
///
/// ## From the cache, never the network
///
/// The answer comes from the cause list the app last saved (`ResponseCache.Key.causeList`), so it
/// is immediate, works with no signal in a court corridor, and asks the server nothing. When that
/// list is older than `TodayCopy.staleAfter`, the answer says how old — a practitioner deciding
/// whether to trust it needs to know.
///
/// ## What it never says
///
/// It never says the day is free. With nothing listed it says "none of your matters", names the
/// next day that has any, and ends with the sentence every empty day in this app carries
/// (`CauseListViewModel.Copy.confirmWithCourt`) — these are hearings on matters the person has
/// added, not the court's list.
struct ListedDayAnswer: Equatable, Sendable {

    enum Day: Sendable {
        case today, tomorrow

        var word: String { self == .today ? "today" : "tomorrow" }
    }

    /// What Siri says.
    let dialog: String
    /// The day asked about, India's `YYYY-MM-DD`. `nil` when there is nothing to answer from.
    let day: String?
    /// The first few matters, for the snippet.
    let matters: [TodayMatter]
    /// How many are listed that day.
    let total: Int
    /// "Updated 2 days ago", when the list is stale.
    let age: String?
    /// The next day with listings, when the day asked about has none.
    let next: TodayDay?

    /// How many matters the answer names before "and 4 more". Spoken, three is already a lot.
    static let namedMatters = 3
    /// How many the snippet lists.
    static let shownMatters = 4

    enum Copy {
        static let signIn = "Sign in to Emperor first."
        static let notLoaded = """
            Emperor hasn't loaded your listings on this device yet. Open the app once to load them.
            """
    }

    /// The answer about `day`, from what is cached.
    ///
    /// - Parameters:
    ///   - isSignedIn: whether anyone is. With nobody, the answer asks for a sign-in and says
    ///     nothing about any matter, whatever is cached.
    ///   - listings: the cached cause list, or `nil` when none has been saved on this device.
    ///   - fetchedAt: when it was saved.
    static func make(
        day: Day, isSignedIn: Bool, listings: [CauseListing]?, fetchedAt: Date?, now: Date
    ) -> ListedDayAnswer {
        guard isSignedIn else { return .plain(Copy.signIn) }
        guard let listings else { return .plain(Copy.notLoaded) }

        let today = IndianDay.key(now)
        let key = day == .today ? today : (IndianDay.adding(1, to: today) ?? today)
        let age = TodayCopy.age(fetchedAt: fetchedAt, now: now)
        // Only the days from the one asked about onward matter, and narrowing first spares
        // ordering the whole hearing history.
        let ahead = listings.filter { $0.date >= key }
        let byDay = CalendarListings.byDay(causeList: ahead, cases: [])
        let rows = byDay[key] ?? []
        let ageSentence = TodayCopy.staleAge(fetchedAt: fetchedAt, now: now)
            .map { " These listings were last updated \($0)." } ?? ""

        guard rows.isEmpty else {
            let matters = rows.prefix(shownMatters).map(TodayMatter.init)
            let named = rows.prefix(namedMatters).map { spoken(TodayMatter($0)) }
            var sentence = rows.count == 1
                ? "1 of your matters is listed \(day.word): \(named[0])."
                : "\(rows.count) of your matters are listed \(day.word): "
                    + named.joined(separator: "; ")
            if rows.count > 1 {
                sentence += TodayCopy.more(shown: named.count, of: rows.count)
                    .map { "; \($0)." } ?? "."
            }
            return ListedDayAnswer(
                dialog: sentence + ageSentence, day: key, matters: matters,
                total: rows.count, age: age, next: nil)
        }

        let next = byDay.keys.filter { $0 > key }.sorted().first.flatMap { nextKey in
            byDay[nextKey].map {
                TodayDay(
                    day: nextKey, total: $0.count,
                    matters: $0.prefix(shownMatters).map(TodayMatter.init))
            }
        }
        var sentence = "None of your matters are listed \(day.word)."
        if let next {
            let when = IndianDay.long(next.day)
            sentence += " The next is on \(when): \(TodayCopy.count(next.total))."
        }
        sentence += ageSentence + " " + CauseListViewModel.Copy.confirmWithCourt
        return ListedDayAnswer(
            dialog: sentence, day: key, matters: [], total: 0, age: age, next: next)
    }

    /// "Bakshi v. State of Maharashtra, Court 12, item 7, at 10:30 AM".
    static func spoken(_ matter: TodayMatter) -> String {
        TodayCopy.spokenLocation(matter).map { "\(matter.title), \($0)" } ?? matter.title
    }

    private static func plain(_ dialog: String) -> ListedDayAnswer {
        ListedDayAnswer(dialog: dialog, day: nil, matters: [], total: 0, age: nil, next: nil)
    }
}
