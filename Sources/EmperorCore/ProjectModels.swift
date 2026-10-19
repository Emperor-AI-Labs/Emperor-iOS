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

    // MARK: - Added with Matters (docs/projects.md, 2026-10-12)

    /// One of `MatterVocabulary.practiceAreas`.
    var practiceArea: String?
    /// Which side the client is on — `petitioner`, `respondent`, … or free text.
    var ourSide: String?
    var oppositeParty: String?
    /// A banner preset key, or `image` when a picture was uploaded.
    var banner: String?
    /// The banner is an uploaded picture, fetched from `GET /project-banner`. The preset under
    /// it (`BannerPreset.preset(for:)`) is drawn while it loads, and if it cannot be shown.
    var hasBannerImage: Bool { banner == "image" }
    /// `not_filed` when the matter has no court case yet by the user's own say-so — which is
    /// what lets the setup count the court step as done instead of nagging about it.
    var courtStatus: String?

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
    /// Open tasks, and the soonest of their due days (`YYYY-MM-DD`). List route only.
    var openTasks: Int?
    var nextTaskDueRaw: String?
    /// Rupees billed and received, summed by the list route.
    var billed: Double?
    var received: Double?

    /// When the row was made. The Matters list's "Recent activity" counts it as the floor of a
    /// matter's activity, and the oldest of two matters linked to one case is the one a tracked
    /// case opens.
    var createdAtRaw: String?

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

    /// The user has said there is no court case to track yet.
    var isNotFiledYet: Bool { courtStatus?.caseInsensitiveCompare("not_filed") == .orderedSame }

    var hasLinkedCase: Bool {
        !(linkedCaseID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var practiceAreaLabel: String? { MatterVocabulary.label(for: practiceArea, in: MatterVocabulary.practiceAreas) }
    var ourSideLabel: String? { MatterVocabulary.label(for: ourSide, in: MatterVocabulary.ourSides) }
    var statusLabel: String? {
        guard let status = Self.text(status) else { return nil }
        switch status.lowercased() {
        case "active": return "Active"
        case "on_hold": return "On hold"
        case "disposed": return "Disposed"
        case "archived": return "Archived"
        default: return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var nextTaskDue: Date? { WireDate.parseDay(nextTaskDueRaw) }

    /// Rupees still to come in, from the list route's two sums.
    var outstanding: Double? {
        guard let billed, let received else { return nil }
        return billed - received
    }

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
        case practiceArea = "practice_area"
        case ourSide = "our_side"
        case oppositeParty = "opposite_party"
        case banner
        case courtStatus = "court_status"
        case openTasks = "open_tasks"
        case nextTaskDueRaw = "next_task_due"
        case billed, received
        case createdAtRaw = "created_at"
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
    /// `manual` (typed in), `court` (from the linked case), or `ai` (extracted from the
    /// documents and accepted). Where the entry came from is part of what it says.
    var source: String?
    /// "Plaint.pdf, p. 4" — the page an extracted fact was read from.
    var sourceRef: String?

    var kindLabel: String { MatterVocabulary.label(for: kind, in: MatterVocabulary.updateKinds) ?? "Note" }

    /// A short word for where the entry came from, for everything but a typed-in one.
    var sourceLabel: String? {
        switch source?.lowercased() {
        case "court": return "From the court"
        case "ai": return sourceRef.flatMap { $0.isEmpty ? nil : "From \($0)" } ?? "From the documents"
        default: return nil
        }
    }

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
        case id, kind, title, body, status, source
        case eventDateRaw = "event_date"
        case createdAtRaw = "created_at"
        case sourceRef = "source_ref"
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
///   The response also carries `files`, deliberately unmodelled: the matter's documents are
///   listed by `/project-files`, which is the tree the Files section and the pickers read.
///   `chats` is modelled — the matter's own conversations, opened from its Ask section with the
///   matter named on every turn (`ProjectChatRow`).
struct ProjectDetailResponse: Codable, Sendable {
    var success: Bool?
    var project: Project?
    var updates: [ProjectUpdate]?
    /// Reuses `CaseItem` because these rows **are** `case_items` — the route selects six of its
    /// columns straight out of that table for the linked case. Every other field on `CaseItem`
    /// is optional, so the narrower projection decodes without a shim.
    var courtHistory: [CaseItem]?
    // The Matters workspace (docs/projects.md). Every one camelCase, like `courtHistory`, because
    // the server builds the payload in JavaScript (`store.projectPayload`).
    var linkedCase: LinkedCaseSummary?
    var tasks: [ProjectTask]?
    var ledger: [LedgerEntry]?
    var people: [ProjectPerson]?
    var totals: LedgerTotals?
    /// The matter's conversations, newest first.
    var chats: [ProjectChatRow]?
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
