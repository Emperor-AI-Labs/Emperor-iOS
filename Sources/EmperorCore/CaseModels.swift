import Foundation

// Wire models for the cases feature. Every optionality below is load-bearing and traced to
// source; see the notes on each. The governing constraint is that this API's envelope is not
// uniform — a 200 carries `success: true`, a 403/404/409 carries `success: false`, and a 500
// carries **no `success` key at all** (`sync-server.js:9687-9689`). So `success` is `Bool?`
// everywhere, and absence is treated as failure rather than as a decode error.

/// A matter on the user's docket.
struct LegalCase: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var teamID: String?
    var cnr: String?
    var courtType: String?
    var courtCode: String?
    /// **`String?`, not `Int?`.** `case_number` and `case_year` are TEXT columns
    /// (`sync-server.js:3333-3334`), so a JSON number sent in round-trips out as a string and
    /// an `Int?` model fails to decode.
    var caseNumber: String?
    var caseYear: String?
    var title: String?
    /// A polymorphic string: a JSON array serialised into a string, the literal `"[]"` when
    /// omitted, or free prose `"A vs. B"` written by the scraper
    /// (`sync-server.js:9616`, `court-scraper/materialize.js:33-36`). Never JSON-parse it
    /// blindly, and never test it for emptiness — `"[]"` is two characters, not empty.
    var parties: String?
    var status: String?
    var stage: String?
    var nextHearingDateRaw: String?
    var filingDateRaw: String?
    var judge: String?
    var courtName: String?
    var caseType: String?
    var diaryNumber: String?
    var category: String?
    var lastSyncedAtRaw: String?
    var createdAtRaw: String?
    var updatedAtRaw: String?
    /// Present only on `GET /cases` and `GET /case`, which INNER JOIN `teams`.
    var teamName: String?

    var nextHearingDate: Date? { WireDate.parseDay(nextHearingDateRaw) }
    var filingDate: Date? { WireDate.parseDay(filingDateRaw) }
    var lastSyncedAt: Date? { WireDate.parseAny(lastSyncedAtRaw) }
    var updatedAt: Date? { WireDate.parseAny(updatedAtRaw) }

    /// What to show as the matter's name.
    ///
    /// Falls through to `parties` the way the server's own cause list does
    /// (`sync-server.js:9739`) — but guards the `"[]"` sentinel, which would otherwise render
    /// as a matter literally titled `[]`.
    var displayTitle: String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty, trimmedTitle != "[]" { return trimmedTitle }
        let trimmedParties = parties?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedParties.isEmpty, trimmedParties != "[]" { return trimmedParties }
        return "Untitled case"
    }

    /// A court reference to show under the title, e.g. `W.P.(C) 1234/2024`.
    var caseReference: String? {
        let number = [caseNumber, caseYear].compactMap { $0 }.joined(separator: "/")
        let parts = [caseType, number.isEmpty ? nil : number].compactMap { $0 }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? (cnr ?? diaryNumber) : joined
    }

    /// Whether this matter is maintained by the court scraper rather than by hand.
    var isCourtSynced: Bool { lastSyncedAtRaw?.isEmpty == false }

    enum CodingKeys: String, CodingKey {
        case id, cnr, title, parties, status, stage, judge, category
        case teamID = "team_id"
        case courtType = "court_type"
        case courtCode = "court_code"
        case caseNumber = "case_number"
        case caseYear = "case_year"
        case nextHearingDateRaw = "next_hearing_date"
        case filingDateRaw = "filing_date"
        case courtName = "court_name"
        case caseType = "case_type"
        case diaryNumber = "diary_number"
        case lastSyncedAtRaw = "last_synced_at"
        case createdAtRaw = "created_at"
        case updatedAtRaw = "updated_at"
        case teamName = "team_name"
    }
}

/// A note or timeline entry on a matter.
///
/// `type` is `'note'` in practice for everything this API writes: the only
/// `INSERT INTO case_events` in the repo is `sync-server.js:9823`, which writes
/// `b.type || 'note'`. The `'order'`/`'hearing'`/`'status'` literals elsewhere in the codebase
/// are *notification* types and never reach this table.
struct CaseEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var caseID: String?
    var type: String?
    var title: String?
    var body: String?
    var eventDateRaw: String?
    var createdByUserID: String?
    /// **Zoneless SQLite `CURRENT_TIMESTAMP`**, not ISO8601 — the INSERT omits the column so
    /// the DDL default fires (`sync-server.js:9823` + `:3357`). A different encoding from
    /// `cases.created_at` in the very same response.
    var createdAtRaw: String?

    var eventDate: Date? { WireDate.parseAny(eventDateRaw) ?? WireDate.parseAny(createdAtRaw) }

    enum CodingKeys: String, CodingKey {
        case id, type, title, body
        case caseID = "case_id"
        case eventDateRaw = "event_date"
        case createdByUserID = "created_by_user_id"
        case createdAtRaw = "created_at"
    }
}

/// A structured row on a matter — a hearing, an order, a task.
struct CaseItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var caseID: String?
    /// An open string with no server-side whitelist (`sync-server.js:3363`). See
    /// `CaseSection` for the values this product actually uses.
    var section: String
    var title: String?
    var subtitle: String?
    /// A JSON **object serialised into a string** — it arrives as a string that must be parsed
    /// a second time (`sync-server.js:9852`).
    var dataRaw: String?
    var itemDateRaw: String?
    var status: String?
    var amount: Double?
    var createdByUserID: String?
    var createdAtRaw: String?
    var updatedAtRaw: String?
    /// Scraper-only stable identity. **Key scraped rows on this, never on `id`** — every
    /// `source: "scrape"` row is deleted and re-inserted with a fresh `id` on each refresh
    /// (`court-scraper/materialize.js:59-69`), so a cached `id` is a dangling reference.
    var extKey: String?
    /// `"user"` or `"scrape"`. Not settable from the API: `POST /case-item` omits the column
    /// so the `DEFAULT 'user'` fires (`sync-server.js:3481`).
    var source: String?

    var itemDate: Date? { WireDate.parseDay(itemDateRaw) ?? WireDate.parseAny(itemDateRaw) }

    /// True when the court scraper owns this row, so the app must not offer to edit it —
    /// an edit survives until the next refresh and is then deleted with no error.
    var isCourtOwned: Bool { source == "scrape" }

    /// The `data` blob, parsed. Returns `[:]` rather than throwing: this field is
    /// model-adjacent and a malformed blob must not take the whole row down.
    var data: [String: JSONValue] {
        guard let dataRaw, let parsed = JSONValue.decode(from: dataRaw),
              case .object(let object) = parsed
        else { return [:] }
        return object
    }

    func dataString(_ key: String) -> String? { data[key]?.stringValue }

    enum CodingKeys: String, CodingKey {
        case id, section, title, subtitle, status, amount, source
        case caseID = "case_id"
        case dataRaw = "data"
        case itemDateRaw = "item_date"
        case createdByUserID = "created_by_user_id"
        case createdAtRaw = "created_at"
        case updatedAtRaw = "updated_at"
        case extKey = "ext_key"
    }
}

/// The sections a case workspace is divided into.
///
/// `case_items.section` is an unvalidated open string server-side, so this enum is the client's
/// own discipline rather than a wire constraint. It matters for one reason in particular:
/// **`/cause-list` reads only `hearings` and `causelist`** (`sync-server.js:9753`). A hearing
/// written under any other spelling is accepted with a 200 and then never appears in the cause
/// list, with no error anywhere.
enum CaseSection: String, CaseIterable, Sendable {
    case hearings, causelist, orders, applications, documents
    case parties, issues, tasks, notes, fees, judgments

    var label: String {
        switch self {
        case .hearings: return "Hearings"
        case .causelist: return "Cause list"
        case .orders: return "Orders"
        case .applications: return "Applications"
        case .documents: return "Documents"
        case .parties: return "Parties"
        case .issues: return "Issues"
        case .tasks: return "Tasks"
        case .notes: return "Notes"
        case .fees: return "Fees"
        case .judgments: return "Judgments"
        }
    }

    /// The two sections the cause list actually reads.
    static let causeListSections: Set<String> = [
        CaseSection.hearings.rawValue, CaseSection.causelist.rawValue,
    ]
}

/// One entry in the personalised cause list.
///
/// - Important: the two kinds of entry carry different keys. A `"next"` entry is spread from a
///   smaller object than a hearing entry, so `bench`, `remarks`, `listType`, `time` and
///   `scraped` are **absent keys** — not nulls — on it (`sync-server.js`, the two `pushEntry`
///   calls in `/cause-list`). Every field but `date` and `caseId` is therefore optional:
///   declaring any of them non-optional makes the whole array fail to decode for any user who
///   has a case with a next hearing date.
///
/// The court/item fields (`courtNo`, `itemNo`, `coram`, `time`, `scraped`) arrived with the
/// platform reading published cause lists. Older servers and older cached copies have none of
/// them, which decodes as "nothing to show" — the row simply looks as it did before.
struct CauseListing: Codable, Equatable, Identifiable, Sendable {
    /// `YYYY-MM-DD`, already bucketed by the server. Kept as a string on purpose: it is the
    /// grouping key, and converting it to a `Date` introduces a timezone question that has
    /// only one right answer (India) and many wrong ones.
    let date: String
    let caseID: String
    var teamID: String?
    var title: String?
    var courtName: String?
    var courtType: String?
    var caseNumber: String?
    var caseYear: String?
    /// Carries **either** the CNR or the diary number — the server collapses both into this
    /// one field (`sync-server.js:9742`).
    var cnr: String?
    var judge: String?
    var purpose: String?
    var bench: String?
    var stage: String?
    var itemNo: String?
    var remarks: String?
    /// `"causelist"`, `"hearing"` or `"next"`. Unrelated to `CaseItem.source`.
    var source: String?
    /// The courtroom as that day's list printed it — `"Court No. 4"`, `"COURT NO.270"`,
    /// `"Registrar Court 1"` — already tidied by the server where it could be. Shaped for
    /// display by `courtRoom`, never shown raw.
    var courtNo: String?
    /// The bench, without a courtroom in it. The server strips "Court 14 - " prefixes and drops
    /// values that are only a room, but the client re-checks — see `coramLine`.
    var coram: String?
    /// The bench's sitting time ("10:30 AM"), only where the published list printed one. Never
    /// inferred.
    var time: String?
    /// True when the row was read from a court's own site or published list. Such a row states
    /// its own room and item number, or has none: nothing is read out of its other text. Absent
    /// on `"next"` entries, which are read off the case.
    var scraped: Bool?
    /// Which list it appeared on — "Supplementary List", "Advance List".
    var listType: String?
    /// "P: A | R: B", from the parties the scraper recorded. Hearing entries only.
    var advocates: String?
    var parties: String?
    var caseType: String?
    var category: String?
    var diaryNumber: String?
    /// The case's next date of hearing, as a `YYYY-MM-DD`.
    var ndoh: String?

    var id: String { "\(caseID)|\(date)|\(source ?? "")" }

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == "[]" ? "Untitled case" : trimmed
    }

    var day: Date? { WireDate.parseDay(date) }

    enum CodingKeys: String, CodingKey {
        case date, title, judge, purpose, bench, stage, itemNo, remarks, source, cnr
        case caseID = "caseId"
        case teamID = "teamId"
        case courtName, courtType, caseNumber, caseYear
        case courtNo, coram, time, scraped, listType, advocates, parties, caseType, category
        case diaryNumber, ndoh
    }
}

extension CauseListing {
    /// Decodes every optional text field leniently: a string, or a number written out as one.
    ///
    /// Most of a hearing entry is copied verbatim out of a JSON blob a scraper or a form wrote
    /// (`purpose: d.purpose`, `bench: d.bench || r.subtitle || rawCourt`, `time: d.time`), and
    /// the route never coerces it — so a blob holding `"courtNo": 4` can reach the wire as the
    /// number 4. A strict `String?` would throw on that one value and take the **entire** cause
    /// list down with it, for every day. One row printing "4" is the right failure; a Home
    /// screen showing "Could not load" is not.
    ///
    /// `date` and `caseId` stay strict: a row without them cannot be placed or opened.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
            }
            return nil
        }
        date = try container.decode(String.self, forKey: .date)
        caseID = try container.decode(String.self, forKey: .caseID)
        teamID = text(.teamID)
        title = text(.title)
        courtName = text(.courtName)
        courtType = text(.courtType)
        caseNumber = text(.caseNumber)
        caseYear = text(.caseYear)
        cnr = text(.cnr)
        judge = text(.judge)
        purpose = text(.purpose)
        bench = text(.bench)
        stage = text(.stage)
        itemNo = text(.itemNo)
        remarks = text(.remarks)
        source = text(.source)
        courtNo = text(.courtNo)
        coram = text(.coram)
        time = text(.time)
        if let flag = try? container.decodeIfPresent(Bool.self, forKey: .scraped) {
            scraped = flag
        } else if let number = try? container.decodeIfPresent(Int.self, forKey: .scraped) {
            scraped = number != 0
        } else {
            scraped = nil
        }
        listType = text(.listType)
        advocates = text(.advocates)
        parties = text(.parties)
        caseType = text(.caseType)
        category = text(.category)
        diaryNumber = text(.diaryNumber)
        ndoh = text(.ndoh)
    }
}

// MARK: - Envelopes

struct CaseListResponse: Codable, Sendable {
    var success: Bool?
    var cases: [LegalCase]?
    var error: String?
}

struct CaseDetailResponse: Codable, Sendable {
    var success: Bool?
    var `case`: LegalCase?
    var events: [CaseEvent]?
    var items: [CaseItem]?
    var error: String?
}

struct CauseListResponse: Codable, Sendable {
    var success: Bool?
    var listings: [CauseListing]?
    var error: String?
}

struct WriteResponse: Codable, Sendable {
    var success: Bool?
    var id: String?
    var error: String?
}
