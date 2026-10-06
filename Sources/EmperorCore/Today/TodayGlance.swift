import Foundation

/// What the Today widget shows at a given moment, decided from the snapshot.
///
/// ## The four answers
///
/// - **Today's listings**, when today has any.
/// - **The next day that has listings**, when today has none but a later day the snapshot covers
///   does — "Nothing listed today · Next: Thu 9 Oct, 2 matters".
/// - **Nothing through the last day it knows**, when no day it covers has listings.
/// - **Open the app**, when there is nothing to go on: no snapshot, nobody signed in, or a
///   snapshot too old to cover today. Never "nothing listed" — a day the snapshot does not cover
///   is unknown, and an unknown day reading as a free one is the failure this product is built
///   to avoid (`CauseListViewModel.Copy`).
///
/// Today is India's today at `now`, so the timeline's midnight entries move the widget on to the
/// next day without the app having run.
enum TodayGlance: Equatable, Sendable {
    case openApp
    case today(TodayDay)
    case next(TodayDay)
    case clear(through: String)

    static func decide(_ snapshot: TodaySnapshot?, now: Date) -> TodayGlance {
        guard let snapshot, snapshot.isSignedIn else { return .openApp }
        let today = IndianDay.key(now)
        // Outside the days it speaks for — past the last, or before the first when the clock
        // has been moved back: what it says about today is nothing at all.
        guard today >= snapshot.firstDay, today <= snapshot.lastDay else { return .openApp }
        // Keys compare correctly as strings — fixed-width, most significant first.
        let ahead = snapshot.days
            .filter { $0.day >= today && $0.total > 0 }
            .sorted { $0.day < $1.day }
        if let first = ahead.first {
            return first.day == today ? .today(first) : .next(first)
        }
        return .clear(through: snapshot.lastDay)
    }

    /// The day tapping the widget opens the Calendar on: the one it is showing. `nil` opens the
    /// Calendar on today.
    var day: String? {
        switch self {
        case .today(let day), .next(let day): return day.day
        case .clear, .openApp: return nil
        }
    }

    /// The matters to list, in order.
    var matters: [TodayMatter] {
        switch self {
        case .today(let day), .next(let day): return day.matters
        case .clear, .openApp: return []
        }
    }

    /// Where tapping the widget leads.
    var link: EmperorLink { .calendar(day: day) }
}

/// Every word the widget and the Siri answers say, in one place so both say it the same way.
///
/// British English, matching the app. A day with listings is always "your matters", never "your
/// day": these are hearings on matters the person has added, not the court's own list.
enum TodayCopy {

    static let openApp = "Open Emperor to load your listings"
    static let nothingToday = "Nothing listed today"
    static let nothingTomorrow = "Nothing listed tomorrow"
    /// Under the listings wherever there is room — `CauseListViewModel.Copy`'s framing, shortened
    /// for a widget.
    static let framing = "Your matters only. Confirm with the court's list."

    /// How old a cause list may be before anything showing it says how old it is.
    static let staleAfter: TimeInterval = 6 * 60 * 60

    /// "1 matter", "12 matters".
    static func count(_ number: Int) -> String {
        number == 1 ? "1 matter" : "\(number) matters"
    }

    /// "3 matters listed today".
    static func listedToday(_ number: Int) -> String { "\(count(number)) listed today" }

    /// "Next: Thu 9 Oct, 2 matters".
    static func next(_ day: TodayDay) -> String {
        "Next: \(IndianDay.short(day.day)), \(count(day.total))"
    }

    /// "None of your matters through Sun 12 Oct".
    static func clear(through day: String) -> String {
        "None of your matters through \(IndianDay.short(day))"
    }

    /// The Lock Screen's one line. Counts and days only — never a matter's name, so it says
    /// nothing about a client to whoever glances at a locked phone.
    static func inline(_ glance: TodayGlance) -> String {
        switch glance {
        case .today(let day): return listedToday(day.total)
        case .next(let day): return "Next listed: \(IndianDay.short(day.day))"
        case .clear: return nothingToday
        case .openApp: return "Open Emperor"
        }
    }

    /// The widget's heading: the day it is in India — "Tue 13 Oct".
    static func heading(at now: Date) -> String { IndianDay.short(IndianDay.key(now)) }

    /// "Court 12 · Item 7 · 10:30 AM" — where and when, as much as the list printed. `nil` when it
    /// printed none of the three.
    static func location(_ matter: TodayMatter) -> String? {
        let parts = [matter.room, matter.item.map { "Item \($0)" }, matter.time].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Court 12, item 7, at 10:30 AM" — the same, as a sentence is spoken.
    static func spokenLocation(_ matter: TodayMatter) -> String? {
        var parts = [matter.room, matter.item.map { "item \($0)" }].compactMap { $0 }
        if let time = matter.time { parts.append("at \(time)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "and 4 more", when the day has more matters than are shown.
    static func more(shown: Int, of total: Int) -> String? {
        total > shown ? "and \(total - shown) more" : nil
    }

    /// "Updated 2 days ago", once the list is older than `staleAfter`; `nil` while it is fresh, or
    /// when its age is unknown.
    static func age(fetchedAt: Date?, now: Date) -> String? {
        staleAge(fetchedAt: fetchedAt, now: now).map { "Updated \($0)" }
    }

    /// "2 days ago", once the list is older than `staleAfter`; `nil` while it is fresh, or when its
    /// age is unknown.
    static func staleAge(fetchedAt: Date?, now: Date) -> String? {
        guard let fetchedAt else { return nil }
        let seconds = now.timeIntervalSince(fetchedAt)
        guard seconds >= staleAfter else { return nil }
        return ago(seconds: seconds, from: fetchedAt, to: now)
    }

    /// "7 hours ago", "yesterday", "3 days ago" — days counted in India, so "yesterday" means the
    /// court's yesterday.
    static func ago(seconds: TimeInterval, from earlier: Date, to now: Date) -> String {
        if seconds < 86_400 {
            let hours = max(1, Int(seconds / 3_600))
            return hours == 1 ? "an hour ago" : "\(hours) hours ago"
        }
        let days = max(1, IndianDay.daysBetween(earlier, now))
        return days == 1 ? "yesterday" : "\(days) days ago"
    }
}

/// When the widget's timeline needs a new entry: now, and each midnight in India after it.
enum TodayTimeline {

    /// `now`, then the next `days` midnights in India. The snapshot already holds the coming
    /// week, so each midnight entry draws the next day from it with no app involved; the app
    /// asks for a fresh timeline whenever it writes a new snapshot.
    static func entryDates(now: Date, days: Int = TodaySnapshot.horizonDays) -> [Date] {
        var dates = [now]
        var cursor = now
        for _ in 0..<max(0, days) {
            cursor = IndianDay.nextMidnight(after: cursor)
            dates.append(cursor)
        }
        return dates
    }
}
