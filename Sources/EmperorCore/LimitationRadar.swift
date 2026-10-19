import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The Limitation Landmine Radar (the web's `/w/limitation-radar`): is a suit in time, and by how
// much? The server answers with date arithmetic against the Schedule to the Limitation Act, 1963 —
// no model is involved, so the same dates give the same answer twice. This client sends the
// dates, draws the answer, and offers the same suit types the web's picker does.

// MARK: - Suit types

/// One suit type the audit counts under: an article of the Schedule, its period, and the event
/// time runs from.
///
/// The table is the platform's `PROFILES` (`src/features/limitation-radar/audit.js`), in its
/// order. It is held to that module by `scripts/generate-limitation-fixtures.mjs`; when the golden
/// test fails, regenerate the fixture and bring this table to it — never the other way round.
struct LimitationProfile: Equatable, Identifiable, Sendable {
    let key: String
    let label: String
    let article: String
    let years: Int
    /// The Schedule's third column. Shown beside the date field, because the date entered has to
    /// be *this* event — and it differs by article.
    let runsFrom: String

    var id: String { key }

    /// The picker's wording: "Compensation for breach of contract — Article 55, 3 years".
    var pickerLabel: String { "\(label) — \(article), \(years) years" }

    /// The hint under "Date time began to run".
    var runsFromHint: String { "Under \(article): \(runsFrom)" }

    static let defaultKey = "contract_compensation"

    static let all: [LimitationProfile] = [
        LimitationProfile(
            key: "contract_compensation", label: "Compensation for breach of contract",
            article: "Article 55", years: 3,
            runsFrom: "When the contract is broken; for successive breaches, when the breach sued on occurs; for a continuing breach, when it ceases."),
        LimitationProfile(
            key: "money_lent", label: "Money payable for money lent",
            article: "Article 19", years: 3,
            runsFrom: "When the loan is made."),
        LimitationProfile(
            key: "specific_performance", label: "Specific performance of a contract",
            article: "Article 54", years: 3,
            runsFrom: "The date fixed for performance or, if none was fixed, when the plaintiff had notice that performance was refused."),
        LimitationProfile(
            key: "declaration", label: "Any other declaration",
            article: "Article 58", years: 3,
            runsFrom: "When the right to sue first accrues."),
        LimitationProfile(
            key: "mortgage_money", label: "Money secured by a mortgage or charged on immovable property",
            article: "Article 62", years: 12,
            runsFrom: "When the money sued for becomes due."),
        LimitationProfile(
            key: "mortgage_foreclosure", label: "Foreclosure by a mortgagee",
            article: "Article 63(a)", years: 30,
            runsFrom: "When the money secured by the mortgage becomes due."),
        LimitationProfile(
            key: "residuary", label: "Any other suit (residuary)",
            article: "Article 113", years: 3,
            runsFrom: "When the right to sue accrues."),
    ]

    /// The profile for a key, or the default for one this table does not hold.
    static func profile(for key: String) -> LimitationProfile {
        all.first { $0.key == key } ?? all.first { $0.key == defaultKey } ?? all[0]
    }
}

// MARK: - The request

/// The dispute timeline, as `POST /limitation-radar` takes it. Every date is a bare
/// `YYYY-MM-DD` day — a date in a limitation computation has no time and no zone.
struct LimitationRequest: Equatable, Sendable {
    var profile: String
    var causeOfAction: String
    var intendedFiling: String
    var mediationStart: String = ""
    var mediationEnd: String = ""

    /// The body. A blank optional date is left out rather than sent empty.
    func body(userID: String?) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "profile": .string(profile),
            "cause_of_action": .string(causeOfAction),
            "intended_filing": .string(intendedFiling),
        ]
        func put(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { body[key] = .string(trimmed) }
        }
        put("mediation_start", mediationStart)
        put("mediation_end", mediationEnd)
        if let userID { body["userId"] = .string(userID) }
        return body
    }
}

// MARK: - The answer

/// The audit's verdict colour. Three outcomes, not two: amber is "in time only if the mediation
/// exclusion applies", which is a different answer from "in time" and must not wear its green.
enum LimitationTone: String, Equatable, Sendable {
    case emerald, amber, red

    /// An unknown colour is drawn as red, as the web does: the cautious reading.
    init(wire: String?) {
        self = wire.flatMap(LimitationTone.init(rawValue:)) ?? .red
    }
}

/// The Section 12A pre-institution mediation the audit took into account.
struct LimitationMediation: Codable, Equatable, Sendable {
    var start: String
    var end: String
    /// No end date was entered; the filing date or the five-month cap was used.
    var endAssumed: Bool
    /// The dates entered ran past five months, and were cut there.
    var capped: Bool
    /// Mediation began after the period had expired, so nothing is excluded.
    var beganAfterExpiry: Bool
    var excludedDays: Int

    enum CodingKeys: String, CodingKey {
        case start, end, capped
        case endAssumed = "end_assumed"
        case beganAfterExpiry = "began_after_expiry"
        case excludedDays = "excluded_days"
    }
}

/// The audit, as the server computes it.
struct LimitationAudit: Codable, Equatable, Sendable {
    var success: Bool?
    var status: String
    var statusColor: String
    var statuteApplied: String
    /// Days past the bare deadline; zero or negative is in time.
    var daysOverdue: Int
    var fatalFlaw: String
    var curativeStrategies: [String]
    var profile: String?
    var profileLabel: String?
    var article: String?
    var limitationYears: Int?
    var periodRunsFrom: String
    var causeOfAction: String?
    var intendedFiling: String?
    var bareDeadline: String
    var mediation: LimitationMediation?
    var adjustedDeadline: String
    var adjustedDaysOverdue: Int
    var reliesOnMediationExclusion: Bool

    enum CodingKeys: String, CodingKey {
        case success, status, profile, article, mediation
        case statusColor = "status_color"
        case statuteApplied = "statute_applied"
        case daysOverdue = "days_overdue"
        case fatalFlaw = "fatal_flaw"
        case curativeStrategies = "curative_strategies"
        case profileLabel = "profile_label"
        case limitationYears = "limitation_years"
        case periodRunsFrom = "period_runs_from"
        case causeOfAction = "cause_of_action"
        case intendedFiling = "intended_filing"
        case bareDeadline = "bare_deadline"
        case adjustedDeadline = "adjusted_deadline"
        case adjustedDaysOverdue = "adjusted_days_overdue"
        case reliesOnMediationExclusion = "relies_on_mediation_exclusion"
    }

    var tone: LimitationTone { LimitationTone(wire: statusColor) }

    // MARK: Lines, worded as the web's result card words them

    /// The line beside the status: how late, or how much time is left.
    var daysLine: String {
        if reliesOnMediationExclusion {
            return "\(Self.days(daysOverdue)) late without the exclusion · \(Self.days(-adjustedDaysOverdue)) remaining with it"
        }
        return daysOverdue > 0
            ? "\(Self.days(daysOverdue)) past the last day to file"
            : "\(Self.days(-daysOverdue)) remaining"
    }

    /// "Last day to file".
    var lastDayLine: String { Self.longDate(bareDeadline) }

    /// "Mediation excluded", when mediation was entered.
    var mediationLine: String? {
        guard let mediation else { return nil }
        if mediation.beganAfterExpiry { return "None — it began after the period had expired" }
        let note = mediation.capped
            ? ", capped at five months"
            : mediation.endAssumed ? ", end date assumed" : ""
        return "\(Self.days(mediation.excludedDays)) (\(Self.longDate(mediation.start)) to \(Self.longDate(mediation.end))\(note))"
    }

    /// "With the exclusion", when the exclusion moved the deadline at all.
    var withExclusionLine: String? {
        guard let mediation, mediation.excludedDays > 0 else { return nil }
        return Self.longDate(adjustedDeadline)
    }

    /// The caution under every result.
    static let disclaimer =
        "A date computation against the Schedule to the Limitation Act, 1963 — not legal advice. "
        + "Limitation turns on the cause of action as actually pleaded, and on facts such as "
        + "acknowledgments, part payments and prior proceedings that this tool does not see. Have "
        + "the position reviewed before you act on it."

    static func days(_ n: Int) -> String { "\(n) day\(n == 1 ? "" : "s")" }

    /// "15 January 2026" — the web's `en-GB` long date, for a bare day.
    static func longDate(_ day: String) -> String {
        guard let date = WireDate.parseDay(day) else { return day }
        return longDateFormatter.string(from: date)
    }

    nonisolated(unsafe) private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = WireDate.india
        f.dateFormat = "d MMMM yyyy"
        return f
    }()
}

/// The error envelope this route answers with: `{success:false, error:{code, message, detail?}}`.
struct LimitationErrorBody: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        var code: String?
        var message: String?
    }
    var success: Bool?
    var error: Detail?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try? c.decodeIfPresent(Bool.self, forKey: .success)
        // An `error` that is a plain string — another route's shape — is still read.
        if let detail = try? c.decodeIfPresent(Detail.self, forKey: .error) {
            error = detail
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .error) {
            error = Detail(code: nil, message: text)
        }
    }

    enum CodingKeys: String, CodingKey { case success, error }
}

// MARK: - The service

protocol LimitationRadarProviding: Sendable {
    func audit(_ request: LimitationRequest) async throws -> LimitationAudit
}

/// `POST /limitation-radar`.
///
/// The route answers honest status codes: 200 with the audit, 400 with a `code`
/// (`MISSING_ARGUMENT`, `UNKNOWN_PROFILE`, `INVALID_TIMELINE`) and a sentence written for the
/// reader — "The filing date is earlier than the cause of action. Check both dates." — which is
/// shown as it is. Never retried: it is cheap, and a second answer would be the same one.
struct LimitationRadarService: LimitationRadarProviding {
    let client: APIClient

    /// The web's words for an answer that carried no sentence.
    static func statusMessage(_ status: Int) -> String {
        "The audit service responded with HTTP \(status)."
    }

    func audit(_ request: LimitationRequest) async throws -> LimitationAudit {
        let userID = await client.currentCredentials()?.userIDString
        let urlRequest = try await client.makeRequest(
            "POST", "/limitation-radar", body: Payload(body: request.body(userID: userID)))
        let (data, http) = try await client.perform(urlRequest)
        return try Self.decode(status: http.statusCode, data: data)
    }

    /// The answer, or the error it amounts to. Separate so it can be driven without a server.
    static func decode(status: Int, data: Data) throws -> LimitationAudit {
        if (200..<300).contains(status),
           let audit = try? JSONDecoder().decode(LimitationAudit.self, from: data),
           audit.success != false {
            return audit
        }
        let envelope = try? JSONDecoder().decode(LimitationErrorBody.self, from: data)
        if let message = envelope?.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            throw APIError.server(status: status, message: message)
        }
        if (200..<300).contains(status) {
            throw APIError.decoding("The limitation audit came back in a shape this app does not read.")
        }
        // A sign-in, a plan refusal or a gateway outage reads as itself; anything else in the
        // web's words.
        let classified = APIError.classify(status: status, body: data)
        if case .server = classified {
            throw APIError.server(status: status, message: statusMessage(status))
        }
        throw classified
    }

    private struct Payload: Encodable {
        let body: [String: JSONValue]
        func encode(to encoder: Encoder) throws { try body.encode(to: encoder) }
    }
}
