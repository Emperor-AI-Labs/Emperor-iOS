import Foundation

/// India's calendar days, for the code the Today widget shares with the app.
///
/// ## Why not `WireDate`
///
/// The widget extension compiles only this folder of the core (see `project.yml`): it reads a
/// file and draws it, and has no business carrying the wire models, the services or the
/// regular expressions the rest of the core is built from. `WireDate` lives beside all of those,
/// so the same rule is restated here in a form small enough to share — **every court date is a
/// day in India** (README trap 9), whatever zone the phone is in. `TodaySnapshotTests` holds the
/// two to the same answers, so they cannot drift apart.
///
/// India keeps no daylight saving, so a day is always exactly 24 hours long and midnight always
/// exists; the arithmetic below still goes through an IST `Calendar` rather than adding seconds,
/// so it stays right if that is ever not so.
enum IndianDay {

    /// `Asia/Kolkata`, falling back to its fixed offset on a system without the zone database.
    static var zone: TimeZone { tools.zone }

    /// The zone, an IST calendar and the formatters, built once.
    ///
    /// Held in one box marked `@unchecked Sendable` rather than as `nonisolated(unsafe)` statics:
    /// which Foundation types count as `Sendable` differs between the Linux toolchain CI runs and
    /// the newer one here, and the box compiles cleanly on both. It is honest — every member is a
    /// `let`, configured once in `init` and only read afterwards, which formatters are documented
    /// as safe for.
    private final class Tools: @unchecked Sendable {
        let zone: TimeZone
        let calendar: Calendar
        /// `YYYY-MM-DD`.
        let key: DateFormatter
        /// "Thu 9 Oct" — the widget's day, short enough for a Lock Screen line.
        let short: DateFormatter
        /// "Thursday 9 October" — as Siri says a day.
        let long: DateFormatter

        init() {
            zone = TimeZone(identifier: "Asia/Kolkata") ?? TimeZone(secondsFromGMT: 19_800) ?? .gmt
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            self.calendar = calendar
            key = Self.formatter("yyyy-MM-dd", locale: "en_US_POSIX", calendar: calendar)
            short = Self.formatter("EEE d MMM", locale: "en_GB", calendar: calendar)
            long = Self.formatter("EEEE d MMMM", locale: "en_GB", calendar: calendar)
        }

        private static func formatter(
            _ format: String, locale: String, calendar: Calendar
        ) -> DateFormatter {
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = Locale(identifier: locale)
            f.dateFormat = format
            return f
        }
    }

    private static let tools = Tools()

    /// The `YYYY-MM-DD` key of the day `date` falls on, in India.
    static func key(_ date: Date) -> String { tools.key.string(from: date) }

    /// Midnight in India at the start of `key`, or `nil` when `key` is not a real day.
    ///
    /// Checked by round trip, so "2026-02-30" — which a lenient reading rolls into March — and
    /// anything with trailing text are refused rather than read as some other day.
    static func start(of key: String) -> Date? {
        guard key.utf8.count == 10, let date = tools.key.date(from: key),
              tools.key.string(from: date) == key
        else { return nil }
        return date
    }

    static func isValid(_ key: String) -> Bool { start(of: key) != nil }

    /// The day `days` after `key` (before, when negative).
    static func adding(_ days: Int, to key: String) -> String? {
        guard let start = start(of: key),
              let moved = tools.calendar.date(byAdding: .day, value: days, to: start)
        else { return nil }
        return self.key(moved)
    }

    /// The first midnight in India strictly after `date` — when "today" next changes.
    static func nextMidnight(after date: Date) -> Date {
        let today = tools.calendar.startOfDay(for: date)
        return tools.calendar.date(byAdding: .day, value: 1, to: today)
            ?? today.addingTimeInterval(86_400)
    }

    /// Whole days from the day `earlier` falls on to the day `later` falls on, in India.
    static func daysBetween(_ earlier: Date, _ later: Date) -> Int {
        let start = tools.calendar.startOfDay(for: earlier)
        let end = tools.calendar.startOfDay(for: later)
        return tools.calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// "Thu 9 Oct", or the key itself when it is not a day.
    static func short(_ key: String) -> String {
        start(of: key).map(tools.short.string(from:)) ?? key
    }

    /// "Thursday 9 October", or the key itself when it is not a day.
    static func long(_ key: String) -> String {
        start(of: key).map(tools.long.string(from:)) ?? key
    }
}
