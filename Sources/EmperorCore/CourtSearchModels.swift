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

    var path: String { "/court/\(rawValue)/diary" }

    var name: String {
        switch self {
        case .supremeCourt: return "Supreme Court"
        case .highCourt: return "High Court"
        case .nclt: return "NCLT"
        case .nclat: return "NCLAT"
        }
    }

    /// What the number field is actually called at this forum. Getting this wrong sends a
    /// lawyer looking for a number that does not exist on their papers.
    var numberLabel: String {
        switch self {
        case .supremeCourt: return "Diary number"
        case .highCourt: return "Filing number"
        case .nclt, .nclat: return "Filing number"
        }
    }

    /// Whether a lookup here waits on a captcha the server solves for itself.
    ///
    /// The High Court route drives eCourts' securimage: up to eight attempts, each followed by
    /// a 700ms sleep, all inside the request. Ten seconds is a normal success, not a hang, and
    /// the screen has to say so or it reads as broken.
    var solvesCaptcha: Bool { self == .highCourt }
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

/// The one response shape all four diary routes share.
///
/// - Important: **every one of them answers HTTP 200**, success and failure alike. The status
///   code carries no information; `success` is the only signal. And an empty `results` on a
///   `success: true` means the court had nothing — which is a normal answer, not an error.
struct CourtSearchResponse: Codable, Sendable {
    var success: Bool?
    var results: [CourtSearchResult]?
    var error: String?
}

/// What a diary lookup needs, per forum.
struct CourtSearchQuery: Equatable, Sendable {
    var forum: CourtForum
    /// Diary number (SC) or filing number (everything else).
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
    var isComplete: Bool {
        func present(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        switch forum {
        case .supremeCourt:
            return present(number) && present(year)
        case .highCourt:
            return present(stateCode) && present(courtCode) && present(caseType)
                && present(number) && present(year)
        case .nclt, .nclat:
            return present(bench) && present(number)
        }
    }

    /// What is still missing, phrased for the user.
    var missingFields: [String] {
        func check(_ value: String, _ label: String) -> String? {
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? label : nil
        }
        switch forum {
        case .supremeCourt:
            return [check(number, forum.numberLabel), check(year, "Year")].compactMap { $0 }
        case .highCourt:
            return [
                check(stateCode, "State"), check(courtCode, "Court"),
                check(caseType, "Case type"), check(number, forum.numberLabel),
                check(year, "Year"),
            ].compactMap { $0 }
        case .nclt, .nclat:
            return [check(bench, "Bench"), check(number, forum.numberLabel)].compactMap { $0 }
        }
    }

    /// The JSON body for this forum's route.
    ///
    /// Only the keys that forum reads are included. `courtComplexCode` is deliberately allowed
    /// to be absent — the server defaults it to `courtCode`, which is right far more often
    /// than any guess we could make here.
    var body: [String: JSONValue] {
        func trimmed(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch forum {
        case .supremeCourt:
            // Non-digits are stripped server-side anyway; doing it here too means the field
            // shows the user what will actually be looked up.
            return [
                "diaryNumber": .string(trimmed(number).filter(\.isNumber)),
                "year": .string(trimmed(year)),
            ]
        case .highCourt:
            var body: [String: JSONValue] = [
                "stateCode": .string(trimmed(stateCode)),
                "courtCode": .string(trimmed(courtCode)),
                "caseType": .string(trimmed(caseType)),
                "filingNo": .string(trimmed(number)),
                "year": .string(trimmed(year)),
            ]
            if !trimmed(courtComplexCode).isEmpty {
                body["courtComplexCode"] = .string(trimmed(courtComplexCode))
            }
            if !trimmed(caseTypeLabel).isEmpty {
                body["caseTypeLabel"] = .string(trimmed(caseTypeLabel))
            }
            if !trimmed(courtName).isEmpty { body["courtName"] = .string(trimmed(courtName)) }
            // Omitted when the state code is not one we recognise. The route does not validate
            // it — `resolveById` is only called by `/court/hc/benches` — so a wrong value would
            // be persisted verbatim as the case's `court_code`, which is worse than absent.
            if let id = CourtSearchQuery.highCourtID(forStateCode: trimmed(stateCode)) {
                body["courtId"] = .string(id)
            }
            return body
        case .nclt, .nclat:
            var body: [String: JSONValue] = [
                "bench": .string(trimmed(bench)),
                // Whitespace inside a filing number is stripped server-side; a number typed
                // with spaces should look up the same case.
                "filingNo": .string(trimmed(number).filter { !$0.isWhitespace }),
            ]
            if !trimmed(courtName).isEmpty { body["courtName"] = .string(trimmed(courtName)) }
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
