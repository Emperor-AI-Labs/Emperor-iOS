import Foundation

// Wire models for the projects feature — hand-made matters, as opposed to the court-scraped
// `LegalCase`.
//
// The two are the same mental object seen two ways, and the platform says so in its own schema
// comment (`sync-server.js:3380-3389`), but they are **different tables with different owners**.
// A case belongs to a `team_id` and is filled in by the court scrapers under a
// `UNIQUE(team_id, ext_id)` index; a project belongs to a `user_id` and is typed in by hand.
// `linked_case_id` is the bridge when a user has joined one to the other.
//
// The envelope conventions are the same as everywhere else on this API: a 200 carries
// `success: true`, a 404 carries `success: false`, and a 500 carries **no `success` key at all**
// (`sync-server.js:9932-9936`). So `success` is `Bool?` and absence is read as failure.

/// A hand-made matter, as `GET /projects` and `GET /project` return it.
struct Project: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// `NOT NULL` in the DDL but optional here, because `POST /project` only trims — a matter
    /// created before that check existed can still hold an empty string. `displayName` is what
    /// screens read.
    var name: String?
    var client: String?
    /// The wire key is `description`. Renamed because a stored property called `description` on
    /// a Swift type reads as the type's own description and quietly shadows the
    /// `String(describing:)` idiom every reader expects. `ProjectDetailView` labels it "Notes",
    /// which is also what it holds.
    var notes: String?
    /// Drives grouping and iconography on the web; `'other'` by default.
    var forumType: String?
    /// Free text — "NCLT New Delhi Bench-III" is not an enumerable set, and the DDL says so
    /// (`sync-server.js:3397-3398`).
    var forumName: String?
    /// **`String?`, not `Int?`.** `case_number` and `case_year` are TEXT columns, on the same
    /// terms as `LegalCase.caseNumber` — a JSON number sent in round-trips out as a string.
    var caseNumber: String?
    var caseYear: String?
    var caseType: String?
    var cnr: String?
    var stage: String?
    /// `'active'` by default. `'archived'` is filtered out server-side unless asked for — see
    /// `ProjectService.projects(includeArchived:)`.
    var status: String?
    /// `'high'`, `'normal'`, or anything else. Drives the server's own ordering.
    var priority: String?
    var nextHearingDateRaw: String?
    var filingDateRaw: String?
    /// The scraped case this matter is joined to, when the user has joined one.
    var linkedCaseID: String?
    /// A palette **key** such as `teal`, never a CSS value — the client re-cuts it per theme.
    /// Carried so nothing the server sent is dropped; this build does not tint rows by it.
    var color: String?
    var updatedAtRaw: String?

    // MARK: - List-only, computed by the query

    // The list route selects `p.*` plus four correlated sub-selects (`sync-server.js:9919-9927`).
    // They exist only on `GET /projects` and are **absent** from `GET /project`.
    //
    // That is why they are optional rather than defaulted to zero: zero would mean "this matter
    // has no documents", and on the detail route the honest answer is "not stated". A row
    // reading "0 documents" on one screen and nothing on the other is the kind of disagreement
    // a practitioner reads as data loss.

    var fileCount: Int?
    var chatCount: Int?
    var updateCount: Int?
    /// `COALESCE(u.event_date, u.created_at)` of the newest update — so it is a bare day on some
    /// rows and a zoneless SQLite timestamp on others. `parseAny` covers both.
    var lastActivityRaw: String?

    // MARK: - Derived

    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled matter" : trimmed
    }

    /// A court reference to show under the title — `ARB.P. 112/2025`.
    ///
    /// - Note: deliberately **not** `LegalCase.caseReference`'s rule. That one joins
    ///   `[caseNumber, caseYear]` with `/` after compacting, so a matter with a number and no
    ///   year renders as `112` — a bare integer that reads as nothing at all. A project is typed
    ///   in by hand and half-filled far more often than a scraped case, so the year is required
    ///   before the slash is drawn, and the CNR is the fallback rather than a suffix.
    var caseReference: String? {
        let number: String
        switch (Self.text(caseNumber), Self.text(caseYear), Self.text(cnr)) {
        case (let n?, let y?, _): number = "\(n)/\(y)"
        case (let n?, nil, _): number = n
        case (nil, _, let cnr?): number = cnr
        default: return nil
        }
        guard let type = Self.text(caseType) else { return number }
        return "\(type) \(number)"
    }

    /// Where it is heard. The free-text name wins over the grouping key, because "NCLT New Delhi
    /// Bench-III" is what a litigator recognises and `tribunal` is what a database does.
    var forumLabel: String? { Self.text(forumName) ?? Self.text(forumType) }

    var isHighPriority: Bool { priority?.caseInsensitiveCompare("high") == .orderedSame }

    var isArchived: Bool { status?.caseInsensitiveCompare("archived") == .orderedSame }

    var nextHearingDate: Date? { WireDate.parseDay(nextHearingDateRaw) }
    var filingDate: Date? { WireDate.parseDay(filingDateRaw) }
    var updatedAt: Date? { WireDate.parseAny(updatedAtRaw) }
    var lastActivity: Date? { WireDate.parseAny(lastActivityRaw) }

    private static func text(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case id, name, client, cnr, stage, status, priority, color
        case notes = "description"
        case forumType = "forum_type"
        case forumName = "forum_name"
        case caseNumber = "case_number"
        case caseYear = "case_year"
        case caseType = "case_type"
        case nextHearingDateRaw = "next_hearing_date"
        case filingDateRaw = "filing_date"
        case linkedCaseID = "linked_case_id"
        case updatedAtRaw = "updated_at"
        case fileCount = "file_count"
        case chatCount = "chat_count"
        case updateCount = "update_count"
        case lastActivityRaw = "last_activity"
    }
}

/// One entry on a matter's own timeline — a row of `project_updates`.
///
/// A note, a hearing that happened, an order received, a filing made, a task, a milestone. The
/// server sorts them `COALESCE(event_date, created_at) DESC` (`sync-server.js:9955-9957`), which
/// is the order this client keeps: `event_date` is when the **thing** happened and `created_at`
/// is when it was recorded, so backdating an order received last week must not reshuffle the
/// whole file.
struct ProjectUpdate: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// `note`, `hearing`, `order`, `filing`, `task`, `milestone` — an open string with no
    /// server-side whitelist, so it is carried raw and shown as a tag rather than switched on.
    var kind: String?
    var title: String?
    var body: String?
    var eventDateRaw: String?
    var status: String?
    /// Zoneless SQLite `CURRENT_TIMESTAMP`, not ISO8601 — the DDL default fires.
    var createdAtRaw: String?

    /// When this entry belongs on the timeline, falling back the same way the server's own
    /// `ORDER BY` does.
    var day: Date? { WireDate.parseAny(eventDateRaw) ?? WireDate.parseAny(createdAtRaw) }

    /// Whether there is anything to draw.
    ///
    /// A row with neither a title nor a body renders as a bare date with blank space beside it,
    /// which reads as a rendering fault rather than as an empty note. `ProjectService` filters
    /// on this rather than the view, so the count in the section header and the number of rows
    /// under it cannot disagree.
    var isRenderable: Bool {
        title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, status
        case eventDateRaw = "event_date"
        case createdAtRaw = "created_at"
    }
}

// MARK: - Envelopes

struct ProjectListResponse: Codable, Sendable {
    var success: Bool?
    var projects: [Project]?
    var error: String?
}

/// `GET /project`.
///
/// - Important: `courtHistory` is **camelCase on the wire** — the one key in this feature that
///   is, because the server builds it in JavaScript rather than selecting it from a column
///   (`sync-server.js:9985`). Spelling it `court_history` here decodes to `nil` with no error,
///   and the linked case's whole hearing record silently disappears from the screen.
///
///   The response also carries `files` and `chats`. Both are deliberately unmodelled: a project
///   file cannot be opened without the write routes this client does not call, and a project
///   chat would need the chat surface to accept a foreign thread. The Android client made the
///   same cut.
struct ProjectDetailResponse: Codable, Sendable {
    var success: Bool?
    var project: Project?
    var updates: [ProjectUpdate]?
    /// Reuses `CaseItem` because these rows **are** `case_items` — the route selects six of its
    /// columns straight out of that table for the linked case. Every other field on `CaseItem`
    /// is optional, so the narrower projection decodes without a shim.
    var courtHistory: [CaseItem]?
    var error: String?
}

// MARK: - Court history rows

/// The two things a court-history row needs that a case row never did.
///
/// Kept here rather than on `CaseModels.swift` because both exist for this screen: the case
/// workspace groups its items under headings it chooses and never renders a bare one, so
/// neither question arises there.
extension CaseItem {
    /// Whether there is anything to draw. Same rule as `ProjectUpdate.isRenderable`, and for the
    /// same reason — the projection here drops `data`, so a row with no title and no subtitle
    /// has nothing left to show at all.
    var isRenderable: Bool {
        title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// `hearings` → `Hearings`. Falls back to the raw section, tidied, because `section` is an
    /// open string with no server-side whitelist — a value this build has not heard of must
    /// still label itself rather than render blank.
    var sectionLabel: String {
        if let known = CaseSection(rawValue: section) { return known.label }
        let tidied = DisplayText.fileName(section).trimmingCharacters(in: .whitespacesAndNewlines)
        return tidied.isEmpty ? "Other" : tidied.capitalized
    }
}
