import Foundation

/// Which court a lookup goes to.
///
/// The four forums take genuinely different inputs — the Supreme Court by diary number, the
/// tribunals by bench plus filing number, a High Court by a bench-and-case-type combination —
/// so this is not a cosmetic label. It decides which fields the form shows and which route the
/// request takes.
enum CourtForum: String, CaseIterable, Identifiable, Sendable {
    case supremeCourt = "sc"
    case highCourt = "hc"
    case nclt
    case nclat

    var id: String { rawValue }

    /// The route for a lookup at this forum, in this mode.
    ///
    /// The two modes are genuinely different endpoints rather than a parameter, and they behave
    /// differently: the diary routes go straight to a case's detail page and need no captcha,
    /// while the case-number routes have to search a listing and — at the Supreme Court and the
    /// High Courts — get past one.
    func path(for mode: CourtSearchMode) -> String {
        switch mode {
        case .diaryNumber:
            return "/court/\(rawValue)/diary"
        case .caseNumber:
            // The Supreme Court's is `auto` rather than `search` because the route's whole job
            // is to try the captcha itself first; it is the only one that can hand the problem
            // back to the user. See `SupremeCourtCaptcha`.
            return self == .supremeCourt ? "/court/sc/auto" : "/court/\(rawValue)/search"
        }
    }

    var name: String {
        switch self {
        case .supremeCourt: return "Supreme Court"
        case .highCourt: return "High Court"
        case .nclt: return "NCLT"
        case .nclat: return "NCLAT"
        }
    }

    /// What the number field is actually called at this forum, in this mode. Getting this wrong
    /// sends a lawyer looking for a number that does not exist on their papers.
    ///
    /// The Supreme Court is the only forum that says "diary number"; everywhere else the same
    /// pre-registration number is a "filing number". Once a matter is registered they all call
    /// the result a case number.
    func numberLabel(for mode: CourtSearchMode) -> String {
        switch mode {
        case .caseNumber: return "Case number"
        case .diaryNumber: return self == .supremeCourt ? "Diary number" : "Filing number"
        }
    }

    /// Whether a lookup here waits on a captcha the server solves for itself.
    ///
    /// The High Court route drives eCourts' securimage: up to eight attempts, each followed by
    /// a 700ms sleep, all inside the request. Ten seconds is a normal success, not a hang, and
    /// the screen has to say so or it reads as broken.
    ///
    /// The Supreme Court does the same on `/court/sc/auto`, but only in case-number mode — a
    /// diary lookup there needs no captcha at all.
    func solvesCaptcha(in mode: CourtSearchMode) -> Bool {
        switch self {
        case .highCourt: return true
        case .supremeCourt: return mode == .caseNumber
        case .nclt, .nclat: return false
        }
    }

    /// Whether this forum can be looked up by diary number at all.
    ///
    /// All four can today. Kept as a property rather than assumed because the wider court
    /// catalogue does not — no tribunal or consumer forum has a diary route — and a screen that
    /// offers the mode and then refuses it is worse than one that hides it.
    var supportsDiaryLookup: Bool { true }
}

/// Which of the two lookups a search is.
///
/// Not a cosmetic filter over one result set: they are separate routes taking different fields.
/// A diary number is the receipt the registry gave you when you filed; a case number is what the
/// matter is called once it has been registered, and it is what appears on every subsequent
/// piece of paper. Most people looking a matter up have the second and not the first, which is
/// why offering only diary lookup left the feature unreachable for its commonest use.
enum CourtSearchMode: String, CaseIterable, Identifiable, Sendable {
    case caseNumber
    case diaryNumber

    var id: String { rawValue }

    /// The pill label. Phrased as the thing you have, not the thing the route is called.
    func label(for forum: CourtForum) -> String {
        switch self {
        case .caseNumber: return "By case number"
        case .diaryNumber: return forum == .supremeCourt ? "By diary number" : "By filing number"
        }
    }
}

/// A case as a court's own site describes it, before it is saved.
///
/// Every field is optional because the source is a scraper over four different sites, and a
/// forum that omits one simply omits it. `nil` here means "the court did not say", never
/// "empty" — which is why nothing in this type substitutes a placeholder.
struct CourtSearchResult: Codable, Equatable, Identifiable, Sendable {
    var courtType: String?
    var courtCode: String?
    var courtName: String?
    var caseType: String?
    var caseNumber: String?
    var caseYear: String?
    var cnr: String?
    var diaryNumber: String?
    var registrationNo: String?
    var title: String?
    var parties: String?
    var status: String?
    var caseNumberText: String?
    var source: String?
    /// What the server needs to re-scrape this case later. Opaque: pass it back untouched.
    var scrapeRef: JSONValue?

    // MARK: - Only the search routes send these

    /// Where the matter has got to — "Disposed", "Part Heard". Absent from the diary routes.
    var stage: String?
    var judge: String?
    /// The court's own next date. Not a `WireDate` because the search routes hand it back as
    /// whatever string the portal printed, which is not one of the four encodings the rest of
    /// the wire uses.
    var nextHearingDate: String?
    /// The Supreme Court splits the cause title; the other forums send only the joined `parties`.
    var petitioner: String?
    var respondent: String?

    /// **The card is fabricated, not scraped.**
    ///
    /// `GET /court/search` answers for any court whose adapter has not been built by echoing the
    /// user's own input back as a case record — `title` becomes `"<caseType> <number>/<year>"`,
    /// and `parties`, `judge`, `status` and `stage` are all `null` (`sync-server.js:9561-9570`).
    /// Every other field it sends is something the user typed a moment earlier.
    ///
    /// Decoded **only so it can be refused**. Once this struct is populated a fabricated row is
    /// indistinguishable from a scraped one, and on a product whose entire claim is that a
    /// citation names a real page, showing a lawyer their own typing back as a court record is
    /// the worst failure available. See `CourtSearchService.search`.
    var preview: Bool?

    /// Stable only within one set of results. The wire carries no id — these are rows scraped
    /// seconds ago, not database records — so this is composed from what identifies a case at
    /// the court, and falls back to the whole description when even that is absent.
    var id: String {
        if let cnr, !cnr.isEmpty { return cnr }
        let parts = [courtCode, caseType, caseNumber, caseYear, diaryNumber, title]
        return parts.compactMap { $0 }.joined(separator: "|")
    }

    var displayTitle: String {
        for candidate in [title, parties, registrationNo, caseNumberText] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty, trimmed != "[]" { return trimmed }
        }
        return "Untitled case"
    }

    /// The court's own reference, e.g. `C.A. 1234/2025`.
    var reference: String? {
        for candidate in [registrationNo, caseNumberText] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        guard let caseNumber, !caseNumber.isEmpty else { return nil }
        let type = caseType.map { "\($0) " } ?? ""
        let year = caseYear.map { "/\($0)" } ?? ""
        return "\(type)\(caseNumber)\(year)"
    }

    /// Whether this card carries a number that tells it apart from another case at the same
    /// forum.
    ///
    /// The server files every saved matter under
    /// `ext_id = cnr || courtCode|caseType|caseNumber|caseYear` (`sync-server.js:9619`) and puts
    /// a **UNIQUE index on `(team_id, ext_id)`** (`:3492`). So `ext_id` is not a hint — it is
    /// the primary key of "a matter", and two cases that compute the same one cannot coexist.
    ///
    /// `courtCode` is constant per forum and `caseType`/`caseYear` describe a *class* of case,
    /// so neither distinguishes anything. Only a CNR or a case number does. That is why this
    /// checks those two and nothing else — an earlier version accepted any non-empty field,
    /// which made it return `true` for every card ever produced and rendered the warning it
    /// guards into dead code.
    ///
    /// - Important: this is **not** a duplicate check. Getting it wrong the other way was the
    ///   original mistake here: a thin card does not silently create a second row, it
    ///   *collides* with an unrelated one and is refused. See `CourtSearchService.save`.
    var hasDistinguishingNumber: Bool {
        for candidate in [cnr, caseNumber] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return true }
        }
        return false
    }
}

/// The one response shape every diary and search route shares.
///
/// - Important: **almost all of them answer HTTP 200**, success and failure alike. The status
///   code carries no information; `success` is the only signal. And an empty `results` on a
///   `success: true` means the court had nothing — which is a normal answer, not an error.
///   `/court/sc/session` is the single exception: it fails with a 502.
struct CourtSearchResponse: Codable, Sendable {
    var success: Bool?
    var results: [CourtSearchResult]?
    var error: String?

    // MARK: - Why it failed
    //
    // The search routes distinguish their failures and the diary routes do not, so these are
    // all optional and all absent on a diary lookup. The web client decodes none of them, which
    // is why a mistyped case number and a court outage read identically there. They are cheap
    // to carry and they are the difference between "check the year" and "try again later".

    /// The court could be reached and had no such case. Distinct from an outage.
    var notFound: Bool?
    /// The **court's** site is down, not ours. Only the High Court route sets it.
    var portalDown: Bool?
    /// The server's own captcha solver gave up; a human has to solve one. Supreme Court and
    /// High Court. See `SupremeCourtCaptcha`.
    var fallback: Bool?
    /// The Supreme Court captcha session is gone — 8 minutes old, or already spent.
    var expired: Bool?
    /// The captcha answer was wrong. Requires a **new** session, not a resubmit.
    var captchaError: Bool?
    /// Extra detail behind `error`, where the High Court route has any.
    var detail: String?
    /// Used instead of `error` when the Supreme Court answers `success: true` with no results.
    var message: String?
}

/// What a diary lookup needs, per forum.
struct CourtSearchQuery: Equatable, Sendable {
    var forum: CourtForum
    var mode: CourtSearchMode = .caseNumber
    /// **Whichever number the current `mode` asks for**, and only that one.
    ///
    /// One field rather than two because a diary number and a case number are different numbers
    /// for the same matter, and a second field would sit there holding a stale value from the
    /// other mode. The screen clears this when the mode changes; carrying it across would look
    /// like the app had filled it in.
    var number: String = ""
    var year: String = ""
    /// NCLT/NCLAT bench, or the High Court's state.
    var bench: String = ""
    var courtName: String = ""

    // High Court only.
    var stateCode: String = ""
    /// The eCourts **bench** code, e.g. `"2"`.
    ///
    /// - Warning: unrelated to `CourtSearchResult.courtCode`, which holds a High Court *id*
    ///   like `"hc-delhi"`. Same name, different things; never wire one to the other.
    var courtCode: String = ""
    var courtComplexCode: String = ""
    var caseType: String = ""
    var caseTypeLabel: String = ""

    /// Whether this is complete enough to send.
    ///
    /// Worth checking locally because the server does **not** report a validation failure as
    /// one: a missing `year` throws, is caught, and comes back as
    /// "Could not reach the Supreme Court site" — so an incomplete form looks exactly like an
    /// outage, and the user retries something that can never work.
    var isComplete: Bool { missingFields.isEmpty }

    /// The fields this forum and mode require, as `(value, label)`.
    ///
    /// One list drives both `isComplete` and `missingFields`, because when they were written
    /// separately they disagreed: a rule added to one was forgotten in the other, and the form
    /// then refused to submit while reporting nothing missing.
    private var requiredFields: [(String, String)] {
        switch (forum, mode) {
        case (.supremeCourt, .diaryNumber):
            return [(number, forum.numberLabel(for: mode)), (year, "Year")]
        case (.supremeCourt, .caseNumber):
            return [
                (caseType, "Case type"), (number, forum.numberLabel(for: mode)), (year, "Year"),
            ]
        // The High Court needs the same five either way: its diary route still searches a
        // bench's listing rather than going straight to a case.
        case (.highCourt, _):
            return [
                (stateCode, "State"), (courtCode, "Court"), (caseType, "Case type"),
                (number, forum.numberLabel(for: mode)), (year, "Year"),
            ]
        case (.nclt, .diaryNumber), (.nclat, .diaryNumber):
            return [(bench, "Bench"), (number, forum.numberLabel(for: mode))]
        // A year is required here where the diary lookup does not take one: `/search` filters
        // the bench's listing on an exact number *and* year, so without it every row is
        // rejected and the answer is an empty list rather than an error.
        case (.nclt, .caseNumber), (.nclat, .caseNumber):
            return [
                (bench, "Bench"), (caseType, "Case type"),
                (number, forum.numberLabel(for: mode)), (year, "Year"),
            ]
        }
    }

    /// What is still missing, phrased for the user, in the order the form shows the fields.
    var missingFields: [String] {
        requiredFields
            .filter { $0.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.1)
    }

    /// The JSON body for this forum's route, in this mode.
    ///
    /// Only the keys that route reads are included. `courtComplexCode` is deliberately allowed
    /// to be absent — the server defaults it to `courtCode`, which is right far more often
    /// than any guess we could make here.
    ///
    /// - Important: **`year` goes out as a string, never a number.** Every search route echoes
    ///   the body's `year` straight back as `caseYear` without converting it, and `caseYear` is
    ///   `String?` here — so sending `2024` returns `2024` and the decode throws a type mismatch
    ///   on a search that otherwise worked.
    var body: [String: JSONValue] {
        func trimmed(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// The keys naming the forum, which every route takes and none requires.
        func addLabels(to body: inout [String: JSONValue]) {
            if !trimmed(caseTypeLabel).isEmpty {
                body["caseTypeLabel"] = .string(trimmed(caseTypeLabel))
            }
            if !trimmed(courtName).isEmpty { body["courtName"] = .string(trimmed(courtName)) }
        }

        switch (forum, mode) {
        case (.supremeCourt, .diaryNumber):
            // Non-digits are stripped server-side anyway; doing it here too means the field
            // shows the user what will actually be looked up.
            return [
                "diaryNumber": .string(trimmed(number).filter(\.isNumber)),
                "year": .string(trimmed(year)),
            ]

        case (.supremeCourt, .caseNumber):
            var body: [String: JSONValue] = [
                "caseType": .string(trimmed(caseType)),
                "caseNumber": .string(trimmed(number)),
                "year": .string(trimmed(year)),
            ]
            addLabels(to: &body)
            return body

        case (.highCourt, let mode):
            var body: [String: JSONValue] = [
                "stateCode": .string(trimmed(stateCode)),
                "courtCode": .string(trimmed(courtCode)),
                "caseType": .string(trimmed(caseType)),
                "year": .string(trimmed(year)),
            ]
            // The only difference between the two High Court routes: the same number is
            // `filingNo` on one and `caseNumber` on the other.
            body[mode == .diaryNumber ? "filingNo" : "caseNumber"] = .string(trimmed(number))
            if !trimmed(courtComplexCode).isEmpty {
                body["courtComplexCode"] = .string(trimmed(courtComplexCode))
            }
            addLabels(to: &body)
            // Omitted when the state code is not one we recognise. The route does not validate
            // it — `resolveById` is only called by `/court/hc/benches` — so a wrong value would
            // be persisted verbatim as the case's `court_code`, which is worse than absent.
            if let id = CourtSearchQuery.highCourtID(forStateCode: trimmed(stateCode)) {
                body["courtId"] = .string(id)
            }
            return body

        case (.nclt, .diaryNumber), (.nclat, .diaryNumber):
            var body: [String: JSONValue] = [
                "bench": .string(trimmed(bench)),
                // Whitespace inside a filing number is stripped server-side; a number typed
                // with spaces should look up the same case.
                "filingNo": .string(trimmed(number).filter { !$0.isWhitespace }),
            ]
            if !trimmed(courtName).isEmpty { body["courtName"] = .string(trimmed(courtName)) }
            return body

        case (.nclt, .caseNumber), (.nclat, .caseNumber):
            var body: [String: JSONValue] = [
                "bench": .string(trimmed(bench)),
                "caseType": .string(trimmed(caseType)),
                "caseNumber": .string(trimmed(number).filter { !$0.isWhitespace }),
                "year": .string(trimmed(year)),
            ]
            addLabels(to: &body)
            return body
        }
    }
}

extension CourtSearchQuery {
    /// The platform's High Court id for an eCourts state code.
    ///
    /// Sent because the server never derives it: `/court/hc/diary` reads `courtId` straight off
    /// the request body and `hcRowToCase` stamps the card with `ctx.courtId || 'hc'`. Omit it
    /// and **every** High Court card is filed as plain `"hc"`, which costs two things:
    ///
    /// - **Refresh routing.** Six High Courts have their own portal adapter, selected by
    ///   matching the saved `court_code`. Filed as `"hc"` they miss, and the matter is
    ///   refreshed through the general eCourts aggregator instead of its own registry.
    /// - **Dedupe identity.** For a row where the portal returns no CNR, `ext_id` becomes
    ///   `hc|WP|1234|2025` — identical across all 25 High Courts. A Delhi and a Madras
    ///   `WP 1234/2025` on one team then collide on the unique index and the second save is
    ///   refused. `hc-delhi|…` and `hc-madras|…` do not.
    ///
    /// The mapping is a bijection over the 25 state codes, so it is fully determined by the
    /// state code the user already types. Mirrors `src/lib/courts.js:161` and its server-side
    /// twin `court-scraper/adapters/hc-registry.js:78`, which are themselves kept in sync by
    /// hand — so this is a third copy, and a state code missing from it must be *omitted*
    /// rather than guessed.
    static func highCourtID(forStateCode code: String) -> String? {
        highCourtIDsByStateCode[code].map { "hc-\($0)" }
    }

    static let highCourtIDsByStateCode: [String: String] = [
        "1": "bombay", "2": "andhra", "3": "karnataka", "4": "kerala", "5": "himachal",
        "6": "gauhati", "7": "jharkhand", "8": "patna", "9": "rajasthan", "10": "madras",
        "11": "orissa", "12": "jk", "13": "allahabad", "15": "uttarakhand", "16": "calcutta",
        "17": "gujarat", "18": "chhattisgarh", "20": "tripura", "21": "meghalaya",
        "22": "punjab-haryana", "23": "mp", "24": "sikkim", "25": "manipur", "26": "delhi",
        "29": "telangana",
    ]
}

struct SaveCaseResponse: Codable, Sendable {
    var success: Bool?
    var id: String?
    var error: String?
}
