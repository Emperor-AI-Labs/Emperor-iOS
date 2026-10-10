import Foundation

/// What the Matters tab and Home's "Next sitting" card show, read off the cause list.
///
/// The cause list (`/cause-list`) arrives whole — every listing on every date — and is windowed
/// here, in India's days (`WireDate`), never the device's. Three views of it:
///
/// - **Next sitting**: the first day, today or later, on which anything of the user's is listed,
///   in the order a court day is walked (`CauseListViewModel.sortKey`).
/// - **Upcoming**: every listed day after that one, each with its listings.
/// - **All matters** is the docket (`CaseListViewModel`), not the cause list.
///
/// - Important: like the Home screen it replaces, this is the user's own matters by hearing date,
///   not the court's published list. Every empty state still ends with
///   `CauseListViewModel.Copy.confirmWithCourt`.
struct MattersOverview: Equatable, Sendable {

    /// One listed day.
    struct Day: Equatable, Sendable, Identifiable {
        /// `YYYY-MM-DD`, in India.
        let key: String
        let listings: [CauseListing]
        var id: String { key }
    }

    let todayKey: String
    /// The next day with anything listed, today or later.
    let nextSitting: Day?
    /// Every listed day after the next sitting, earliest first.
    let upcoming: [Day]

    init(listings: [CauseListing], todayKey: String) {
        self.todayKey = todayKey
        let byDay = Dictionary(grouping: listings.filter { $0.date >= todayKey }, by: \.date)
        let days = byDay.keys.sorted().map { key in
            Day(key: key, listings: Self.ordered(byDay[key] ?? []))
        }
        nextSitting = days.first
        upcoming = Array(days.dropFirst())
    }

    /// A day's listings in the order the matters will be called.
    static func ordered(_ listings: [CauseListing]) -> [CauseListing] {
        listings
            .map { ($0, CauseListViewModel.sortKey($0)) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    // MARK: - Words

    /// The segment's name and the card's heading: "Today", "Tomorrow", or "Mon 12 Oct".
    func dayLabel(_ key: String) -> String {
        if key == todayKey { return "Today" }
        if let today = WireDate.parseDay(todayKey),
           WireDate.dayKey(today.addingTimeInterval(86_400 + 3_600)) == key {
            return "Tomorrow"
        }
        return Self.shortDay(key)
    }

    /// "Mon 12 Oct" — a court day, in India.
    static func shortDay(_ key: String) -> String {
        guard let date = WireDate.parseDay(key) else { return key }
        return shortDayFormatter.string(from: date)
    }

    /// "Monday" — the weekday of a court day, in India.
    static func weekday(_ key: String) -> String {
        guard let date = WireDate.parseDay(key) else { return key }
        return weekdayFormatter.string(from: date)
    }

    /// The month and the day of the month, for an upcoming day's calendar block: ("OCT", "14").
    static func calendarBlock(_ key: String) -> (month: String, day: String) {
        guard let date = WireDate.parseDay(key) else { return ("", key) }
        return (monthFormatter.string(from: date).uppercased(), dayFormatter.string(from: date))
    }

    /// The line under the Matters title: "3 listed on Monday · 14 matters tracked".
    func subtitle(trackedMatters: Int?) -> String {
        var parts: [String] = []
        if let next = nextSitting {
            let count = next.listings.count
            let when = next.key == todayKey ? "today" : "on \(Self.weekday(next.key))"
            parts.append("\(count) listed \(when)")
        } else {
            parts.append("Nothing listed ahead")
        }
        if let trackedMatters {
            parts.append(trackedMatters == 1 ? "1 matter tracked" : "\(trackedMatters) matters tracked")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - A listing

    /// Whether the listing came from a supplementary list — the "SUPPL" badge.
    static func isSupplementary(_ listing: CauseListing) -> Bool {
        let type = (listing.listType ?? "").lowercased()
        return type.contains("suppl")
    }

    /// A court's short name for the badge and the card's gutter: "SC", "DHC", "NCLT".
    ///
    /// An acronym the name already carries wins (NCLT, NCLAT, DRT, ITAT); the Supreme Court is
    /// "SC"; a High Court is the first letter of its seat and "HC"; anything else is the initials
    /// of its capitalised words, at most four.
    static func courtShortName(_ courtName: String?) -> String? {
        guard let name = courtName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if let acronym = words.first(where: { $0.count >= 2 && $0 == $0.uppercased() && $0.allSatisfy(\.isLetter) }) {
            return acronym
        }
        let lower = name.lowercased()
        if lower.contains("supreme court") { return "SC" }
        if lower.contains("high court") {
            let ignored: Set<String> = ["high", "court", "of", "the", "at", "judicature", "bench"]
            if let seat = words.first(where: { !ignored.contains($0.lowercased()) }) {
                return "\(seat.prefix(1).uppercased())HC"
            }
            return "HC"
        }
        let initials = words
            .filter { $0.first?.isUppercase == true }
            .prefix(4)
            .compactMap(\.first)
        return initials.isEmpty ? String(name.prefix(4)) : String(initials)
    }

    /// The listing's earlier days, latest first: the "History" of the hearing sheet. Only what
    /// the cause list itself says, and at most five — the case's own page has the rest.
    static func history(of listing: CauseListing, in all: [CauseListing]) -> [(day: String, text: String)] {
        all
            .filter { $0.caseID == listing.caseID && $0.date < listing.date }
            .sorted { $0.date > $1.date }
            .prefix(5)
            .map { earlier in
                let display = earlier.display
                let item = display.item.map { "item \($0)" }
                let what = display.note ?? earlier.purpose.flatMap(CauseListText.trimmed)
                let text = ["Listed", item, what].compactMap { $0 }.joined(separator: " · ")
                return (day: shortDay(earlier.date), text: text)
            }
    }

    /// The question "Ask about it" starts a conversation with — the matter named the way the list
    /// names it, and what a person preparing for the day wants to know.
    static func askPrompt(for listing: CauseListing) -> String {
        let display = listing.display
        let reference = display.reference.map { " (\($0))" } ?? ""
        var where_ = [display.item.map { "item \($0)" }, display.room, listing.courtName]
            .compactMap { $0 }
            .joined(separator: ", ")
        if !where_.isEmpty { where_ = " at \(where_)" }
        return "\(listing.displayTitle)\(reference) is listed on \(DisplayText.longDay(listing.date))"
            + "\(where_). What is it about, where does it stand, and what should I prepare for the hearing?"
    }

    // MARK: - Formatters

    nonisolated(unsafe) private static let shortDayFormatter = formatter("EEE d MMM")
    nonisolated(unsafe) private static let weekdayFormatter = formatter("EEEE")
    nonisolated(unsafe) private static let monthFormatter = formatter("MMM")
    nonisolated(unsafe) private static let dayFormatter = formatter("d")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.timeZone = WireDate.india
        f.locale = Locale(identifier: "en_IN")
        return f
    }
}
