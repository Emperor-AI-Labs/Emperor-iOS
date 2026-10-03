import Foundation

/// A dated obligation: a filing, a limitation date, a task.
///
/// Note the asymmetry — `GET /compliance` returns **snake_case** columns verbatim, while
/// `POST /compliance-event` accepts **camelCase**. They are two different shapes for one row.
struct ComplianceEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var teamID: String?
    var caseID: String?
    var title: String?
    /// An open string with no CHECK constraint. The Corporate Calendar writes its own category
    /// names here (`mca`, `gst`, …), so this must never be a closed enum.
    var type: String?
    /// `YYYY-MM-DD` by convention, stored **verbatim with zero validation**
    /// (`sync-server.js:10268`). Every consumer anchors on that shape.
    var dueDateRaw: String?
    var status: String?
    var notes: String?
    /// Written, returned, rendered — and **read by nothing**. See `Calendar.remindersAreInert`.
    var remindDays: Int?
    var createdByUserID: String?
    /// ISO8601 with milliseconds and a trailing `Z`. The DDL says
    /// `DEFAULT CURRENT_TIMESTAMP`, but that default never fires because the INSERT always
    /// binds `new Date().toISOString()` (`sync-server.js:10263`).
    var createdAtRaw: String?
    var updatedAtRaw: String?

    var dueDate: Date? { WireDate.parseDay(dueDateRaw) }
    var updatedAt: Date? { WireDate.parseAny(updatedAtRaw) }
    var isDone: Bool { status?.lowercased() == "done" }

    /// The `YYYY-MM-DD` bucket this belongs in, or nil if the stored value is not a date.
    var dayKey: String? {
        guard let dueDateRaw, dueDateRaw.count >= 10 else { return nil }
        let prefix = String(dueDateRaw.prefix(10))
        return WireDate.parseDay(prefix) == nil ? nil : prefix
    }

    /// Whether this row is a statutory-obligation marker rather than a real to-do.
    ///
    /// The Corporate Calendar records "this statutory obligation was done" by writing a row
    /// with a client-chosen id of the form `stat:<ID>:<YYYY-MM-DD>`
    /// (`ComplianceCalendar.jsx:288-291`). The server excludes these from the ICS feed
    /// (`sync-server.js:10247`) and the web to-do list filters them out (`MyCalendar.jsx:97`).
    /// Showing them here would fill a practitioner's calendar with markers they never created.
    var isStatutoryMarker: Bool { id.hasPrefix("stat:") }

    var kind: ComplianceKind { ComplianceKind(wire: type) }

    enum CodingKeys: String, CodingKey {
        case id, title, type, status, notes
        case teamID = "team_id"
        case caseID = "case_id"
        case dueDateRaw = "due_date"
        case remindDays = "remind_days"
        case createdByUserID = "created_by_user_id"
        case createdAtRaw = "created_at"
        case updatedAtRaw = "updated_at"
    }
}

/// The event types the app renders. Open, because the column is.
enum ComplianceKind: Hashable, Sendable {
    case task, filing, limitation, renewal, hearing, custom
    case other(String)

    init(wire: String?) {
        switch (wire ?? "").lowercased() {
        case "task": self = .task
        case "filing": self = .filing
        case "limitation": self = .limitation
        case "renewal": self = .renewal
        case "hearing": self = .hearing
        case "custom", "": self = .custom
        case let raw: self = .other(raw)
        }
    }

    /// The types offered when creating an event. Deliberately not `allCases`: `hearing` is
    /// written by the court sync, not by hand, and `other` is a decoding fallback.
    static let selectable: [ComplianceKind] = [.task, .filing, .limitation, .renewal, .custom]

    var wireValue: String {
        switch self {
        case .task: return "task"
        case .filing: return "filing"
        case .limitation: return "limitation"
        case .renewal: return "renewal"
        case .hearing: return "hearing"
        case .custom: return "custom"
        case .other(let raw): return raw
        }
    }

    var label: String {
        switch self {
        case .task: return "Task"
        case .filing: return "Filing"
        case .limitation: return "Limitation"
        case .renewal: return "Renewal"
        case .hearing: return "Hearing"
        case .custom: return "Other"
        case .other(let raw): return raw.capitalized
        }
    }

    var systemImage: String {
        switch self {
        case .task: return "checkmark.circle"
        case .filing: return "tray.and.arrow.up"
        case .limitation: return "hourglass"
        case .renewal: return "arrow.clockwise"
        case .hearing: return "building.columns"
        case .custom, .other: return "calendar"
        }
    }
}

/// One day's worth of everything: the user's matters listed that day, in the order the day will
/// run (`CalendarListings`), and their own diary entries.
struct CalendarDay: Identifiable, Equatable, Sendable {
    let key: String
    var listings: [CauseListing]
    var events: [ComplianceEvent]

    var id: String { key }
    var isEmpty: Bool { listings.isEmpty && events.isEmpty }
    var itemCount: Int { listings.count + events.count }
}

struct ComplianceListResponse: Codable, Sendable {
    var success: Bool?
    var events: [ComplianceEvent]?
    var error: String?
}

/// One month, laid out as a grid of whole weeks.
///
/// The layout lives here rather than in the view because it is the part with edge cases:
/// February in a leap year, a 31-day month starting on Saturday that needs six rows, and above
/// all the timezone. Laid out against `Calendar.current` the grid would put a hearing under the
/// wrong date for anyone reading it outside India — silently, which is the worst way for a
/// court date to be wrong. Everything here is pinned to `WireDate.india`.
struct CalendarMonth: Equatable, Sendable {
    /// One cell.
    ///
    /// Padding carries the neighbouring month's real date rather than a blank, so every cell
    /// has a stable identity for `ForEach` and the grid can grey those days instead of leaving
    /// holes where the eye expects dates.
    struct Day: Identifiable, Equatable, Sendable {
        let key: String
        let isInMonth: Bool
        /// The number to print, 1...31.
        let number: Int

        var id: String { key }
    }

    /// "September 2026".
    let title: String
    /// `YYYY-MM-DD` of the first of the month.
    let firstKey: String
    /// Whole weeks, Sunday first.
    let weeks: [[Day]]
}

extension CalendarMonth {
    /// Sunday first, which is what the dashboard and an Indian court diary both use.
    ///
    /// Pinned rather than read from `Calendar.current`: these headings are fixed, so a locale
    /// that begins its week on Monday would slide every date one column out from under the
    /// heading naming it.
    static let weekdayInitials = ["S", "M", "T", "W", "T", "F", "S"]

    nonisolated(unsafe) private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        formatter.timeZone = WireDate.india
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static var gridCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WireDate.india
        calendar.firstWeekday = 1
        return calendar
    }

    /// The month holding `dayKey`, or nil if that is not a date.
    static func containing(_ dayKey: String) -> CalendarMonth? {
        guard let anchor = WireDate.parseDay(dayKey) else { return nil }
        let calendar = gridCalendar
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: anchor)),
              let daysInMonth = calendar.range(of: .day, in: .month, for: first)?.count
        else { return nil }

        // Back up to the Sunday on or before the first, then run whole weeks until the month is
        // covered. How many rows that takes is not fixed: a 31-day month beginning on Saturday
        // needs six, a 28-day February beginning on Sunday needs four.
        let leading = calendar.component(.weekday, from: first) - calendar.firstWeekday
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: first) else {
            return nil
        }
        let rows = Int((Double(leading + daysInMonth) / 7).rounded(.up))

        var weeks: [[Day]] = []
        for row in 0..<rows {
            var week: [Day] = []
            for column in 0..<7 {
                guard let date = calendar.date(
                    byAdding: .day, value: row * 7 + column, to: gridStart)
                else { continue }
                week.append(Day(
                    key: WireDate.dayKey(date),
                    isInMonth: calendar.isDate(date, equalTo: first, toGranularity: .month),
                    number: calendar.component(.day, from: date)))
            }
            weeks.append(week)
        }

        return CalendarMonth(
            title: titleFormatter.string(from: first),
            firstKey: WireDate.dayKey(first),
            weeks: weeks)
    }
}
