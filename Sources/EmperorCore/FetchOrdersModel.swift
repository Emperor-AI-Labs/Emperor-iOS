import Foundation

// Fetch Orders (docs/fetch-orders.md): the pure half of reading a case from the court's records —
// the names courts print, what the dossier's cards say, the timeline, the recent-lookups list,
// and the "Add to Matters" step. Ported from the web's `lib/courtNames.js`, `lookup/lookupModel.js`
// and `lib/fetchOrdersApi.js`; pinned by `FetchOrdersModelTests`.

// MARK: - Names as courts print them

// `CourtNames` (CourtNames.swift) reads the names courts print, held to the platform's
// `src/lib/courtNames.js` by `CourtNamesGolden`; the dossier's cards and the matter list share it.

// MARK: - What the dossier says

/// The plain functions behind a looked-up record's cards.
enum LookupModel {
    private static let disposed = TextPattern(#"dispos|decided|dismiss|closed|withdrawn"#, options: [.caseInsensitive])
    private static let statusWords = ["Pending": "Still going", "Disposed": "Decided", "Dismissed": "Dismissed", "Allowed": "Allowed", "Withdrawn": "Withdrawn"]

    /// "ARB.P. 112/2025".
    static func caseNumber(type: String?, number: String?, year: String?) -> String {
        [type?.nilIfEmpty, number?.nilIfEmpty.map { n in year?.nilIfEmpty.map { "\(n)/\($0)" } ?? n }]
            .compactMap { $0 }.joined(separator: " ")
    }

    static func caseNumber(of facts: CourtRecord.Facts) -> String {
        caseNumber(type: facts.caseType, number: facts.caseNumber, year: facts.caseYear)
    }

    /// The case's name, read as a court prints it, else its number.
    static func title(of facts: CourtRecord.Facts) -> String {
        if let title = facts.title?.nilIfEmpty { return CourtNames.tidy(title, title: true) }
        return caseNumber(of: facts).nilIfEmpty ?? "Untitled case"
    }

    static func isDisposed(_ facts: CourtRecord.Facts) -> Bool { disposed.test(facts.status ?? "") }

    /// The court's status in a client's words: "Pending" → "Still going".
    static func statusWord(_ status: String?) -> String? {
        guard let status = status?.nilIfEmpty else { return nil }
        return statusWords[status] ?? status
    }

    /// One side of the case: its names, its counsel, and the lead name for a matter's client.
    struct Side: Equatable, Sendable {
        var names: [String]
        var counsel: [String]
        var lead: String
    }

    static func sides(of parties: CourtRecord.Parties) -> (first: Side, second: Side) {
        func tidy(_ list: [String]) -> [String] { list.map { CourtNames.tidy($0) } }
        return (
            Side(names: tidy(parties.petitioners), counsel: tidy(parties.petitionerAdvocates), lead: parties.petitioners.first.map { CourtNames.tidy($0) } ?? ""),
            Side(names: tidy(parties.respondents), counsel: tidy(parties.respondentAdvocates), lead: parties.respondents.first.map { CourtNames.tidy($0) } ?? "")
        )
    }

    private static let bareRoom = TextPattern(#"^\d+[A-Za-z]?$"#)
    private static let courtNoWord = TextPattern(#"\bcourt\s*no\.?\s*"#, options: [.caseInsensitive])
    private static let strayBracket = TextPattern(#"\)+$"#)
    private static let capsRun = TextPattern(#"[A-Z]{3}"#)
    private static let spaces = TextPattern(#"\s+"#)

    /// A courtroom as people say it: "Court 51", or the court's own words when its number is a
    /// location.
    static func room(_ courtNo: String?) -> String {
        let t = spaces.replacing(courtNo ?? "", with: " ").trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "" }
        return bareRoom.test(t) ? "Court \(t)" : plainCourtText(t)
    }

    /// A court's shouted phrase, read quietly: "LISTED FOR ARGUMENTS" → "Listed for arguments".
    static func plainCourtText(_ raw: String?) -> String {
        var t = spaces.replacing(raw ?? "", with: " ").trimmingCharacters(in: .whitespaces)
        if t.hasSuffix(")"), !t.contains("(") { t = strayBracket.replacing(t, with: "") }
        if !t.isEmpty, t == t.uppercased(), capsRun.test(t) { t = t.prefix(1) + t.dropFirst().lowercased() }
        return spaces.replacing(courtNoWord.replacing(t, with: "Court "), with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// How long ago / how far off, in words a client would use: "3 weeks ago", "in 2 days".
    static func ago(_ day: String?, today: String) -> String {
        guard let day = day?.nilIfEmpty, WireDate.parseDay(day) != nil else { return "" }
        let d = MatterStanding.days(from: today, to: day)
        let n = abs(d)
        if d == 0 { return "today" }
        let unit: String
        if n >= 365 { let y = n / 365; unit = "\(y) year\(y == 1 ? "" : "s")" }
        else if n >= 60 { unit = "\(n / 30) months" }
        else if n >= 14 { unit = "\(n / 7) weeks" }
        else { unit = "\(n) day\(n == 1 ? "" : "s")" }
        return d < 0 ? "\(unit) ago" : "in \(unit)"
    }

    /// "Today", "Tomorrow", "in 9 days".
    static func countdown(to day: String, today: String) -> String {
        let d = MatterStanding.days(from: today, to: day)
        return d == 0 ? "Today" : d == 1 ? "Tomorrow" : "in \(d) days"
    }

    /// One row of what happened: a hearing, an upcoming listing, or an order.
    struct TimelineRow: Equatable, Identifiable, Sendable {
        enum Kind: Equatable, Sendable { case hearing, next, order }
        var id: String
        var day: String
        var kind: Kind
        var title: String
        var subtitle: String
    }

    /// Hearings and orders together, newest first — the timeline's input.
    static func timeline(of record: CourtRecord, today: String) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        for h in record.hearings {
            guard let date = h.date?.nilIfEmpty else { continue }
            rows.append(TimelineRow(
                id: "h\(date)\(h.purpose ?? "")", day: date, kind: date > today ? .next : .hearing,
                title: plainCourtText(h.purpose).nilIfEmpty ?? "Listed before the court", subtitle: room(h.courtNo)))
        }
        for o in record.orders {
            guard let date = o.date?.nilIfEmpty else { continue }
            rows.append(TimelineRow(id: "o\(date)\(o.url ?? "")", day: date, kind: .order, title: o.displayTitle, subtitle: ""))
        }
        return rows.sorted { $0.day > $1.day }
    }

    /// The years the orders span, newest first, for the filter chips.
    static func years(of orders: [CourtRecord.Order]) -> [String] {
        Array(Set(orders.compactMap { $0.date?.nilIfEmpty.map { String($0.prefix(4)) } })).sorted(by: >)
    }

    private static let appeal = TextPattern(#"APPEAL|^(RFA|RSA|FAO|LPA|CRL ?A|CRA|CA|SA|FA|MFA|CMA|EFA|EXFA|OSA|AS|ITA|MAC ?APP|CO ?APP)\b"#)
    private static let suit = TextPattern(#"SUIT|^(CS|OS|COS|TS|MS|SCS)\b"#)

    /// The words a case's own kind of proceeding uses for its two sides: a suit has a plaintiff,
    /// an appeal an appellant, everything else (writs, petitions, applications) a petitioner.
    static func sideKeys(for caseType: String?) -> (first: String, second: String) {
        let t = spaces.replacing((caseType ?? "").uppercased().replacingOccurrences(of: ".", with: ""), with: " ").trimmingCharacters(in: .whitespaces)
        if appeal.test(t) { return ("appellant", "respondent") }
        if suit.test(t) { return ("plaintiff", "defendant") }
        return ("petitioner", "respondent")
    }

    /// "Diary no." for a `52650/2026`, "CNR" otherwise.
    static func identifierLabel(_ value: String) -> String {
        TextPattern(#"^\s*\d+\s*/\s*\d{4}\s*$"#).test(value) ? "Diary no." : "CNR"
    }
}

// MARK: - Keeping it

/// What "Add to Matters" asks: what to call the matter, and which side the user is on. Everything
/// else is filled from the court record (`/project-from-case`) or left to the matter's setup.
struct AddToMattersDraft: Equatable, Sendable {
    enum SideChoice: Equatable, Sendable {
        /// The first-named side (petitioner / appellant / plaintiff).
        case first
        /// The other side.
        case second
        /// Not sure yet — just follow the case.
        case none
    }

    var name: String
    var side: SideChoice = .none
    let sideKeys: (first: String, second: String)
    let leads: (first: String?, second: String?)

    static func == (lhs: AddToMattersDraft, rhs: AddToMattersDraft) -> Bool {
        lhs.name == rhs.name && lhs.side == rhs.side
    }

    init(record: CourtRecord) {
        name = LookupModel.title(of: record.case)
        sideKeys = LookupModel.sideKeys(for: record.case.caseType)
        leads = (record.parties.petitioners.first, record.parties.respondents.first)
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSubmit: Bool { !trimmedName.isEmpty }

    /// "I act for the petitioner side", with the lead name under it.
    func sideTitle(_ choice: SideChoice) -> String {
        switch choice {
        case .first: return "I act for the \(MatterVocabulary.label(for: sideKeys.first, in: MatterVocabulary.ourSides)?.lowercased() ?? sideKeys.first) side"
        case .second: return "I act for the \(MatterVocabulary.label(for: sideKeys.second, in: MatterVocabulary.ourSides)?.lowercased() ?? sideKeys.second) side"
        case .none: return "Not sure yet — just follow the case"
        }
    }

    func sideDetail(_ choice: SideChoice) -> String? {
        switch choice {
        case .first: return leads.first.map { CourtNames.tidy($0) }?.nilIfEmpty
        case .second: return leads.second.map { CourtNames.tidy($0) }?.nilIfEmpty
        case .none: return nil
        }
    }

    /// The `/project-patch` fields a chosen side writes: our side, the client, the opposite party.
    var patchFields: [String: JSONValue] {
        let (mine, theirs): (String?, String?)
        switch side {
        case .first: (mine, theirs) = (leads.first, leads.second)
        case .second: (mine, theirs) = (leads.second, leads.first)
        case .none: return [:]
        }
        return [
            "ourSide": .string(side == .first ? sideKeys.first : sideKeys.second),
            "client": .string(CourtNames.tidy(mine ?? "")),
            "oppositeParty": .string(CourtNames.tidy(theirs ?? "")),
        ]
    }

    /// What adding does, said plainly.
    static let promises = [
        "We check the court every hour and keep the record up to date.",
        "You get an alert when a new order or hearing date appears.",
        "You also get a workspace for files, tasks, fees and notes.",
    ]
}

// MARK: - Looked up recently

/// The last few cases looked up on this device, newest first — a shortcut back, not a record.
/// Held in the preference store under one key, as the web keeps them in `localStorage`.
struct RecentLookup: Codable, Equatable, Identifiable, Sendable {
    var key: String
    var card: CourtSearchResult
    var title: String
    /// ISO instant.
    var at: String

    var id: String { key }

    /// "Helios v. Northgrid", else "ARB.P. 112/2025".
    var displayTitle: String {
        if !title.isEmpty { return CourtNames.tidy(title, title: true) }
        return LookupModel.caseNumber(type: card.caseType, number: card.caseNumber, year: card.caseYear).nilIfEmpty ?? "Untitled case"
    }

    /// "Delhi High Court · ARB.P. 112/2025 · 4 Oct 2026".
    var detailLine: String {
        [card.courtName?.nilIfEmpty,
         LookupModel.caseNumber(type: card.caseType, number: card.caseNumber, year: card.caseYear).nilIfEmpty,
         LibraryTitles.shortDay(String(at.prefix(10))).nilIfEmpty]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct RecentLookups: Sendable {
    static let key = "ex-fetch-orders-recent"
    static let limit = 6

    let store: any PreferenceStore
    let now: @Sendable () -> Date

    init(store: any PreferenceStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    func read() -> [RecentLookup] {
        guard let raw = store.string(for: Self.key), let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([RecentLookup].self, from: data) else { return [] }
        return Array(list.prefix(Self.limit))
    }

    /// The identity of a card: its CNR, its diary number, else court + type + number + year.
    static func key(for card: CourtSearchResult) -> String {
        card.cnr?.nilIfEmpty ?? card.diaryNumber?.nilIfEmpty
            ?? [card.courtName, card.caseType, card.caseNumber, card.caseYear].map { $0 ?? "" }.joined(separator: "|")
    }

    func remember(_ card: CourtSearchResult, title: String?) {
        let key = Self.key(for: card)
        let rest = read().filter { $0.key != key }
        let stamp = ISO8601DateFormatter().string(from: now())
        let entry = RecentLookup(key: key, card: card, title: title ?? card.title ?? "", at: stamp)
        let list = Array(([entry] + rest).prefix(Self.limit))
        if let data = try? JSONEncoder().encode(list), let raw = String(data: data, encoding: .utf8) {
            store.setString(raw, for: Self.key)
        }
    }

    func forget(_ key: String) {
        let list = read().filter { $0.key != key }
        if let data = try? JSONEncoder().encode(list), let raw = String(data: data, encoding: .utf8) {
            store.setString(raw, for: Self.key)
        }
    }
}

// MARK: - Already tracked?

/// Whether a card is a case the user already tracks — matched the way the server would recognise
/// it: the CNR (or the diary number, kept in the same column for the Supreme Court and the
/// tribunals), else the same number, year and type in the same court. A card with neither a
/// number nor a CNR has no identity, and matches nothing rather than any case saved bare.
enum TrackedCases {
    private static func canon(_ s: String?) -> String {
        (s ?? "").uppercased().filter { $0.isLetter || $0.isNumber }
    }

    static func find(_ card: CourtSearchResult, in cases: [LegalCase]) -> LegalCase? {
        let id = canon(card.cnr?.nilIfEmpty ?? card.diaryNumber)
        let number = canon(card.caseNumber)
        guard !id.isEmpty || !number.isEmpty else { return nil }
        if !id.isEmpty, let hit = cases.first(where: { canon($0.cnr) == id || canon($0.diaryNumber) == id }) { return hit }
        guard !number.isEmpty else { return nil }
        return cases.first { c in
            canon(c.caseNumber) == number && canon(c.caseYear) == canon(card.caseYear) && canon(c.caseType) == canon(card.caseType)
                && ((card.courtCode?.nilIfEmpty != nil && canon(c.courtCode) == canon(card.courtCode)) || canon(c.courtName) == canon(card.courtName))
        }
    }
}
