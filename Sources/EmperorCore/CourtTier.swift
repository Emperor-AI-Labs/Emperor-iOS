import Foundation

/// Where a matter is heard, as the docket heads it — one heading per tier, in order of
/// importance.
///
/// ## The order
///
/// Supreme Court, High Courts, NCLAT, NCLT, the other tribunals, district courts, consumer
/// commissions, and last whatever the app cannot place. `allCases` **is** that order, and
/// nothing else restates it.
///
/// It is the product owner's ordering — "according to their importance" — and it departs from
/// the web's in one place, on purpose. The web's `COURT_ORDER` (`src/pages/CaseManagement.jsx`)
/// runs `sc, hc, nclt, nclat, tribunal, district, forum`, putting NCLT above NCLAT. NCLAT hears
/// the appeals *from* NCLT, so a docket that lists the appellate tribunal under the one it
/// reviews reads upside down to anyone who practises there. Here the appellate tribunal comes
/// first, as the High Courts come before the courts below them.
///
/// ## Where the tier comes from
///
/// `court_type` first, because it is what the court lookup stamped on the case when it was
/// saved — the web's values `sc`, `hc`, `nclt`, `nclat`, `tribunal`, `district` and `forum`.
/// Where that is missing or unrecognised, the court's code and then its name are read instead:
/// a case typed in elsewhere, or saved by an older build, still lands under the right heading
/// rather than in "Other courts". See `tier(courtType:courtCode:courtName:)` for the two cases
/// where a stored type is refined rather than taken as it stands.
enum CourtTier: String, CaseIterable, Identifiable, Sendable {
    case supremeCourt = "sc"
    case highCourt = "hc"
    /// Above NCLT deliberately — see the type's notes.
    case nclat
    case nclt
    /// Every other tribunal: DRT, DRAT, NGT, CAT, ITAT, CESTAT, TDSAT, AFT, SAT, APTEL.
    case tribunal
    case districtCourt = "district"
    /// NCDRC, the State Commissions and the District Commissions — the web's `forum`.
    case consumerCommission = "forum"
    /// Nothing about the case says where it is heard.
    case other

    var id: String { rawValue }

    /// The heading the docket draws over this tier's cases.
    var title: String {
        switch self {
        case .supremeCourt: return "Supreme Court"
        case .highCourt: return "High Courts"
        case .nclat: return "NCLAT"
        case .nclt: return "NCLT"
        case .tribunal: return "Tribunals"
        case .districtCourt: return "District Courts"
        case .consumerCommission: return "Consumer Commissions"
        case .other: return "Other courts"
        }
    }

    /// The tier for the court lookup's own family of courts — the families it saves cases under.
    init(family: CourtFamily) {
        switch family {
        case .supremeCourt: self = .supremeCourt
        case .highCourt: self = .highCourt
        case .nclat: self = .nclat
        case .nclt: self = .nclt
        case .tribunal: self = .tribunal
        case .districtCourt: self = .districtCourt
        case .consumerForum: self = .consumerCommission
        }
    }

    // MARK: - Placing a case

    static func of(_ legalCase: LegalCase) -> CourtTier {
        tier(
            courtType: legalCase.courtType, courtCode: legalCase.courtCode,
            courtName: legalCase.courtName)
    }

    /// The tier for a stored type, code and name.
    ///
    /// A stored type is taken as it stands, with two exceptions where it says less than it
    /// appears to:
    ///
    /// - **`district` is also the column's default.** The `cases` table declares
    ///   `court_type TEXT DEFAULT 'district'` and `/save-case` writes `'district'` whenever the
    ///   body carries no type, so a High Court matter saved without one comes back calling itself
    ///   a district case. `district` therefore yields to a code or name that positively says
    ///   otherwise, and stands only when neither does.
    /// - **`tribunal` is generic.** Where the code or name names NCLT or NCLAT in particular,
    ///   the case goes under that heading rather than the catch-all one.
    static func tier(courtType: String?, courtCode: String?, courtName: String?) -> CourtTier {
        let inferred = inferred(courtCode: courtCode, courtName: courtName)
        switch normalized(courtType) {
        case "sc": return .supremeCourt
        case "hc": return .highCourt
        case "nclat": return .nclat
        case "nclt": return .nclt
        case "forum": return .consumerCommission
        case "tribunal":
            if let inferred, inferred == .nclat || inferred == .nclt { return inferred }
            return .tribunal
        case "district":
            return inferred ?? .districtCourt
        default:
            return inferred ?? .other
        }
    }

    /// The tier the code, failing that the name, points to — or `nil` when neither says.
    static func inferred(courtCode: String?, courtName: String?) -> CourtTier? {
        fromCode(courtCode) ?? fromName(courtName)
    }

    /// Reads the platform's own court ids — `sc`, `hc-delhi`, `trib-nclat`, `dist-family`,
    /// `forum-scdrc` — which are what the lookup saves as `court_code`.
    ///
    /// The catalogue is consulted first, so an id it knows is placed exactly as the lookup
    /// files it. The prefixes catch what it does not list: the bare `hc` the High Court routes
    /// stamp when no court id was sent, and any court the platform adds after this build.
    static func fromCode(_ raw: String?) -> CourtTier? {
        let code = normalized(raw)
        guard !code.isEmpty else { return nil }
        if let court = CourtCatalogue.court(code) { return CourtTier(family: court.family) }
        switch code {
        case "sc": return .supremeCourt
        case "hc": return .highCourt
        case "nclat", "trib-nclat": return .nclat
        case "nclt", "trib-nclt": return .nclt
        case "tribunal": return .tribunal
        case "district": return .districtCourt
        case "forum": return .consumerCommission
        default: break
        }
        // `forum-dcdrc` is a District Commission, not a district court — which is why the
        // prefixes are read whole rather than searched for "dist".
        if code.hasPrefix("hc-") { return .highCourt }
        if code.hasPrefix("trib-") { return .tribunal }
        if code.hasPrefix("forum-") { return .consumerCommission }
        if code.hasPrefix("dist-") { return .districtCourt }
        // Anything else — a district court's numeric eCourts code, say — names no tier.
        return nil
    }

    /// Reads a court's name the way a practitioner would.
    ///
    /// Words are matched whole ("nclt" is not found inside another word) and the checks run in
    /// an order that matters:
    ///
    /// - **NCLAT before NCLT, both before "tribunal".** "National Company Law Appellate
    ///   Tribunal" is not "Company Law Tribunal", and neither is a generic tribunal.
    /// - **Consumer before district.** "District Consumer Disputes Redressal Commission" is a
    ///   consumer commission that happens to sit at district level.
    /// - **High Court before district.** A High Court's name can mention a district; a district
    ///   court's never calls it a High Court.
    /// - **District before "tribunal".** The Motor Accident Claims Tribunal and the Labour Court
    ///   / Industrial Tribunal are subordinate courts — the platform's own catalogue files them
    ///   there — whatever their names say.
    ///
    /// "SC" is deliberately not read as the Supreme Court: the special courts under the SC/ST
    /// Act carry it in their names and are trial courts.
    static func fromName(_ raw: String?) -> CourtTier? {
        let words = words(in: raw)
        guard words != " " else { return nil }
        func has(_ phrases: String...) -> Bool {
            phrases.contains { words.contains(" \($0) ") }
        }

        if has("supreme court") { return .supremeCourt }
        if has("nclat", "company law appellate tribunal") { return .nclat }
        if has("nclt", "company law tribunal") { return .nclt }
        if has("consumer", "ncdrc", "scdrc", "dcdrc", "cdrc", "forum") {
            return .consumerCommission
        }
        if has("high court", "hc") { return .highCourt }
        if has(
            "district", "sessions", "magistrate", "cjm", "acjm", "civil court", "civil judge",
            "city civil", "family court", "commercial court", "labour court", "small causes",
            "small cause", "munsif", "mact", "motor accident", "junior division",
            "senior division"
        ) {
            return .districtCourt
        }
        if has(
            "tribunal", "drt", "drat", "ngt", "cat", "itat", "cestat", "tdsat", "aft", "sat",
            "aptel"
        ) {
            return .tribunal
        }
        return nil
    }

    // MARK: - Normalising

    private static func normalized(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    /// The name lowercased, with every run of anything that is not a letter or digit turned
    /// into one space, and a space at each end — so `" nclt "` matches "NCLT-Mumbai" and
    /// "(NCLT)" but not a word that merely contains it.
    private static func words(in raw: String?) -> String {
        let lowered = normalized(raw)
        var result = " "
        var lastWasSpace = true
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        if !lastWasSpace { result.append(" ") }
        return result
    }
}
