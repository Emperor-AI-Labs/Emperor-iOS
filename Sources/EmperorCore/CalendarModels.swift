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

/// One day's worth of everything: hearings from the docket and obligations from the calendar.
struct CalendarDay: Identifiable, Equatable, Sendable {
    let key: String
    var hearings: [LegalCase]
    var events: [ComplianceEvent]

    var id: String { key }
    var isEmpty: Bool { hearings.isEmpty && events.isEmpty }
    var itemCount: Int { hearings.count + events.count }
}

struct ComplianceListResponse: Codable, Sendable {
    var success: Bool?
    var events: [ComplianceEvent]?
    var error: String?
}
