import Foundation

/*
 * CIN — Corporate Identity Number, decoded offline.
 *
 * A CIN is self-describing: all 21 characters are meaning-bearing, so a company's listing status,
 * industry, registrar, year of incorporation and class can be read from the number alone. That is
 * why this file has no network, no serialization and no UI import — it is a pure function of its
 * argument, and every CIN ever allotted decodes here.
 *
 * What it CANNOT do, and never pretends to:
 *   A CIN carries NO check digit. There is no arithmetic that distinguishes a real CIN from a
 *   well-formed invention. `Cin.parse` verifies SHAPE and the meaning of each coded field — it
 *   does not and cannot verify that the company exists, that it is active, or that MCA allotted
 *   the number. Callers must not present a shape-valid result as authentication. See
 *   `Cin.verificationNote`, which every result carries so the caller cannot forget to show it.
 *
 * Ported from the platform's `src/lib/cin.js` by way of the Android client's `Cin.kt`. The lookup
 * tables were generated from those files rather than retyped; the logic mirrors them clause for
 * clause. There is no backend route for any of this — `src/pages/McaRegistry.jsx` decodes entirely
 * in the browser, and so does this.
 */

// MARK: - Result types

/// A decoded segment, in the order the characters appear.
///
/// `code` is always the raw characters; `label` is what they mean, or a plain statement that they
/// were not recognised. `known` is false when this decoder has no entry for the code — in which
/// case `label` repeats the code rather than guessing at a meaning.
struct CinField: Equatable, Sendable {
    let key: String
    let code: String
    let known: Bool
    let label: String
    /// The longer gloss, where there is one: a listing description or a company-class note.
    let note: String?

    init(key: String, code: String, known: Bool, label: String, note: String? = nil) {
        self.key = key
        self.code = code
        self.known = known
        self.label = label
        self.note = note
    }
}

/// Everything `Cin.parse` could read out of the number, or `nil` where it could not.
struct CinFields: Equatable, Sendable {
    let listing: CinField
    let industry: CinField
    let roc: CinField
    let year: CinField
    let companyClass: CinField
    let registration: CinField
    /// `NIC-1987/2004, as used by MCA` — shown beside the industry so the edition is never implied.
    let industryScheme: String
    /// The two leading digits of the 5-digit industry code, which is all that is mapped.
    let industryDivision: String
    /// True when the industry reading came from an MCA catch-all rather than a NIC division.
    let industryIsSentinel: Bool
    /// The registrar's state, where the code was recognised.
    let rocState: String?
    /// The registrar's seat, where one can be asserted. `nil` is a deliberate "not certain".
    let rocOffice: String?
    /// True for PN and TZ — a registrar whose seat is a city inside a state that has its own code.
    let rocIsCityRegistrar: Bool
    /// The year as a number, when it fell inside a plausible range.
    let yearValue: Int?

    init(
        listing: CinField,
        industry: CinField,
        roc: CinField,
        year: CinField,
        companyClass: CinField,
        registration: CinField,
        industryScheme: String = Cin.nicSchemeLabel,
        industryDivision: String,
        industryIsSentinel: Bool,
        rocState: String? = nil,
        rocOffice: String? = nil,
        rocIsCityRegistrar: Bool = false,
        yearValue: Int? = nil
    ) {
        self.listing = listing
        self.industry = industry
        self.roc = roc
        self.year = year
        self.companyClass = companyClass
        self.registration = registration
        self.industryScheme = industryScheme
        self.industryDivision = industryDivision
        self.industryIsSentinel = industryIsSentinel
        self.rocState = rocState
        self.rocOffice = rocOffice
        self.rocIsCityRegistrar = rocIsCityRegistrar
        self.yearValue = yearValue
    }

    var ordered: [CinField] {
        [listing, industry, roc, year, companyClass, registration]
    }
}

/// Which register the number belongs to. Only `.cin` decodes.
enum CinKind: String, CaseIterable, Sendable {
    case cin = "CIN"
    case llpin = "LLPIN"
    case fcrn = "FCRN"
    case unknown = "UNKNOWN"
}

/// The result of decoding.
///
/// `shapeValid` means the 21 characters are laid out correctly. `confident` is the stricter flag:
/// shape-valid AND every coded segment recognised. Parse noise from upstream PDFs (a listing flag
/// of `A`, a class of `SKM`) yields `shapeValid == true`, `confident == false`, and an entry in
/// `anomalies` — the number is structurally a CIN but part of it cannot be read, and the caller
/// should say so rather than guess.
struct CinResult: Equatable, Sendable {
    let input: String
    let normalised: String
    let kind: CinKind
    let shapeValid: Bool
    let confident: Bool
    /// Why this is not a decodable CIN, when it is not. `nil` on success.
    let reason: String?
    let fields: CinFields?
    let anomalies: [String]
    let summary: String
    let verificationNote: String

    init(
        input: String,
        normalised: String,
        kind: CinKind,
        shapeValid: Bool,
        confident: Bool,
        reason: String? = nil,
        fields: CinFields? = nil,
        anomalies: [String] = [],
        summary: String = "",
        verificationNote: String = Cin.verificationNote
    ) {
        self.input = input
        self.normalised = normalised
        self.kind = kind
        self.shapeValid = shapeValid
        self.confident = confident
        self.reason = reason
        self.fields = fields
        self.anomalies = anomalies
        self.summary = summary
        self.verificationNote = verificationNote
    }

    /// True while the input is too short to be a CIN but has not yet been ruled out as one.
    ///
    /// This exists for typing. A CIN is 21 characters, so a caller that decodes on every keystroke
    /// spends the first twenty of them holding a result whose `reason` reads "A CIN is exactly 21
    /// characters" — a true statement, presented as a verdict, about a number the user is halfway
    /// through entering. Rendering that in an error colour teaches the reader to ignore the error
    /// colour, which is the one signal that has to still work when a CIN really is malformed.
    ///
    /// A caller showing live feedback should treat this as "keep going", and only show the failure
    /// when it is false. Nothing is suppressed: `reason` is unchanged and a finished input that is
    /// genuinely wrong still reports as wrong.
    ///
    /// False for LLPIN and FCRN — those are decided, not incomplete — and false at exactly
    /// `Cin.length` characters, where a wrong shape is a real answer rather than an unfinished one.
    var isIncomplete: Bool {
        kind == .unknown && !normalised.isEmpty && normalised.count < Cin.length
    }

    /// How many characters are still owed, for the "keep going" hint. Zero once `isIncomplete` is
    /// false.
    var charactersRemaining: Int {
        isIncomplete ? Cin.length - normalised.count : 0
    }
}

/// One thing a CIN cannot tell you, and why this app does not show it anyway.
struct MasterDataGap: Equatable, Sendable {
    let field: String
    let why: String
}

// MARK: - The decoder

enum Cin {
    static let length = 21

    static let verificationNote =
        "A CIN has no check digit, so it cannot be verified arithmetically. This decode confirms "
        + "that the number is correctly SHAPED and that each coded segment is one MCA recognises. "
        + "It is not proof that the company exists, is active, or that MCA allotted this number."

    static let nicSchemeLabel = "NIC-1987/2004, as used by MCA"

    static let portalURL = "https://www.mca.gov.in/mcafoportal/viewCompanyMasterData.do"

    private static let minIncorporationYear = 1850

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// Uppercase and strip whitespace and full stops.
    ///
    /// Hyphens are deliberately left in place: they are how an LLPIN is conventionally written
    /// (`AAA-1234`), and stripping them here would erase the distinction the LLPIN branch relies
    /// on.
    static func normalise(_ raw: String?) -> String {
        (raw ?? "").uppercased().filter { !$0.isWhitespace && $0 != "." }
    }

    /// Cheap predicate for callers that only need a yes/no before hitting the API.
    static func isWellFormed(_ raw: String?) -> Bool {
        groups(of: shape, in: normalise(raw)) != nil
    }

    /// `U16001AP2005PLC048552` → `U 16001 AP 2005 PLC 048552`, the form the segments are usually
    /// written in when a CIN is explained. Falls back to the raw input when the value is not a
    /// shape-valid CIN, so it is safe to call on anything.
    static func format(_ raw: String?) -> String {
        let s = normalise(raw)
        guard let m = groups(of: shape, in: s) else { return s.isEmpty ? (raw ?? "") : s }
        return m.joined(separator: " ")
    }

    /// Decode a CIN offline.
    ///
    /// `now` exists so the plausible-year ceiling is testable; it defaults to the system clock and
    /// callers have no reason to pass it.
    static func parse(_ raw: String?, now: @Sendable () -> Date = { Date() }) -> CinResult {
        let input = raw ?? ""
        let normalised = normalise(input)

        func fail(_ kind: CinKind, _ reason: String, summary: String = "") -> CinResult {
            CinResult(
                input: input,
                normalised: normalised,
                kind: kind,
                shapeValid: false,
                confident: false,
                reason: reason,
                summary: summary)
        }

        if normalised.isEmpty { return fail(.unknown, "Enter a CIN to decode it.") }

        // Recognise the neighbouring registers before rejecting. An LLPIN is a valid identifier
        // that simply is not a CIN, and telling a lawyer "this is an LLPIN, look on the LLP
        // register" is useful where "invalid" would just be wrong.
        if let m = groups(of: llpinShape, in: normalised) {
            return fail(
                .llpin,
                "This is an LLPIN, not a CIN. LLPs are registered under the LLP Act 2008 and are "
                    + "not allotted a CIN, so there is nothing here to decode. An LLPIN carries no "
                    + "industry, registrar or year segment.",
                summary: "LLPIN \(m[0])-\(m[1]) — a Limited Liability Partnership.")
        }
        if let m = groups(of: fcrnShape, in: normalised) {
            return fail(
                .fcrn,
                "This is an FCRN, not a CIN. Foreign companies registered under Chapter XXII of "
                    + "the Companies Act 2013 are allotted an FCRN, which carries no decodable "
                    + "segments.",
                summary: "FCRN F\(m[0]) — a foreign company registered in India.")
        }

        // Grapheme clusters rather than UTF-16 units, because this number is shown to the user as
        // "characters". The two agree on every CIN — the shape is ASCII — and diverge only on
        // paste noise, which the shape check rejects either way.
        if normalised.count != length {
            return fail(
                .unknown,
                "A CIN is exactly \(length) characters; this is \(normalised.count).")
        }

        guard let match = groups(of: shape, in: normalised) else {
            return fail(
                .unknown,
                "Wrong shape for a CIN. Expected 1 letter, 5 digits, 2 letters, 4 digits, "
                    + "3 letters, 6 digits — for example U16001AP2005PLC048552.")
        }

        let (listingCode, industryCode, rocCode) = (match[0], match[1], match[2])
        let (yearCode, classCode, serial) = (match[3], match[4], match[5])
        var anomalies: [String] = []

        // ── Listing status ────────────────────────────────────────────────────
        let listingHit = CinTables.listingStatus[listingCode]
        let listing = CinField(
            key: "listing",
            code: listingCode,
            known: listingHit != nil,
            label: listingHit?.label ?? "Listing code: \(listingCode) (unrecognised)",
            note: listingHit?.description)
        if listingHit == nil {
            anomalies.append(
                "Listing status \"\(listingCode)\" is not a code MCA uses; "
                    + "only L (listed) and U (unlisted) are valid.")
        }

        // ── Industry ──────────────────────────────────────────────────────────
        let division = String(industryCode.prefix(2))
        let sentinel = CinTables.industrySentinels[industryCode]
        let divisionLabel = CinTables.nicDivisions[division]
        // A sentinel is exact-match on all 5 digits, so it outranks the division reading.
        let industryLabel = sentinel ?? divisionLabel
        let industry = CinField(
            key: "industry",
            code: industryCode,
            known: industryLabel != nil,
            label: industryLabel ?? "NIC code: \(industryCode) (division \(division) unrecognised)")
        if industryLabel == nil {
            anomalies.append(
                "NIC division \"\(division)\" is not one this decoder recognises, "
                    + "so the industry is left undecoded.")
        }

        // ── Registrar ─────────────────────────────────────────────────────────
        let rocHit = CinTables.rocOffices[rocCode]
        let rocLabel: String
        // Where the registrar's seat is not certain, name the state and stop.
        if let rocHit {
            rocLabel = rocHit.office.map { "\($0), \(rocHit.state)" } ?? "Registrar in \(rocHit.state)"
        } else {
            rocLabel = "Registrar code: \(rocCode) (unrecognised)"
        }
        let roc = CinField(key: "roc", code: rocCode, known: rocHit != nil, label: rocLabel)
        if rocHit == nil {
            anomalies.append(
                "Registrar code \"\(rocCode)\" is not one this decoder recognises; "
                    + "it is shown raw rather than guessed at.")
        }

        // ── Year of incorporation ─────────────────────────────────────────────
        // A year cannot be checked against anything authoritative, but one outside the life of
        // Indian company registration is parse noise rather than a real incorporation.
        let year = Int(yearCode) ?? 0
        let yearSane = year >= minIncorporationYear && year <= currentYear(now()) + 1
        let yearField = CinField(
            key: "year",
            code: yearCode,
            known: yearSane,
            label: yearSane ? String(year) : "Year: \(yearCode) (implausible)")
        if !yearSane {
            anomalies.append(
                "Year of incorporation \"\(yearCode)\" falls outside a plausible range.")
        }

        // ── Company class ─────────────────────────────────────────────────────
        let classHit = CinTables.companyClasses[classCode]
        let companyClass = CinField(
            key: "class",
            code: classCode,
            known: classHit != nil,
            label: classHit?.label ?? "Class code: \(classCode) (unrecognised)",
            note: classHit?.note)
        if classHit == nil {
            anomalies.append("Company class \"\(classCode)\" is not a code MCA uses.")
        }

        let fields = CinFields(
            listing: listing,
            industry: industry,
            roc: roc,
            year: yearField,
            companyClass: companyClass,
            registration: CinField(
                key: "registration", code: serial, known: true, label: serial),
            industryDivision: division,
            industryIsSentinel: sentinel != nil,
            rocState: rocHit?.state,
            rocOffice: rocHit?.office,
            rocIsCityRegistrar: rocHit?.cityRoc == true,
            yearValue: yearSane ? year : nil)

        return CinResult(
            input: input,
            normalised: normalised,
            kind: .cin,
            shapeValid: true,
            confident: anomalies.isEmpty,
            reason: nil,
            fields: fields,
            anomalies: anomalies,
            summary: buildSummary(fields))
    }

    /// One plain-English sentence, assembled only from segments that decoded.
    ///
    /// Anything unrecognised is simply left out rather than filled with a plausible stand-in,
    /// which is why the clauses are appended conditionally instead of formatted from a template.
    private static func buildSummary(_ f: CinFields) -> String {
        var parts: [String] = []
        if f.listing.known && f.companyClass.known {
            parts.append("\(f.listing.label.lowercased()) \(f.companyClass.label.lowercased())")
        } else if f.companyClass.known {
            parts.append(f.companyClass.label.lowercased())
        } else if f.listing.known {
            parts.append("\(f.listing.label.lowercased()) company")
        } else {
            parts.append("company")
        }

        if f.roc.known {
            let seat = f.rocOffice ?? "the registrar in \(f.rocState ?? "")"
            parts.append("registered with \(seat)")
        }
        // "incorporated in 2013" rather than a bare "in 2013" when there is no registrar clause
        // for the year to hang off — the sentence has to read whichever parts drop out.
        if f.year.known, let value = f.yearValue {
            parts.append(f.roc.known ? "in \(value)" : "incorporated in \(value)")
        }

        let body = parts.joined(separator: " ")
        let article = body.lowercased().first.map(vowels.contains) == true ? "An" : "A"
        let sentence = "\(article) \(body)."
        guard f.industry.known, !f.industryIsSentinel else { return sentence }
        return "\(sentence) Industry division: \(f.industry.label)."
    }

    /// The calendar year of an instant, in India.
    ///
    /// Pinned rather than taken from `Calendar.current` because the ceiling this feeds is a claim
    /// about Indian company registration, not about the reader's location: a CIN decoded in
    /// London on 31 December must read the same as one decoded in Delhi the moment after. The
    /// Kotlin port uses the system zone, which differs from this only in the hours around a New
    /// Year — and only ever in the direction of accepting one extra future year.
    private static func currentYear(_ instant: Date) -> Int {
        indiaCalendar.component(.year, from: instant)
    }

    private static let indiaCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WireDate.india
        return calendar
    }()

    // MARK: Shapes

    // `[0-9]` rather than `\d` on purpose. ICU — which is what `NSRegularExpression` runs — reads
    // `\d` as the whole Unicode `Nd` category, so `U١٦٠٠١AP…` in Arabic-Indic digits would match
    // here and then fail `Int(_:)`, producing a "shape-valid" CIN with an implausible year. Both
    // the JavaScript original (no `/u` flag) and the Kotlin port (Java's default `Pattern`) match
    // ASCII digits only; this restores that.
    private static let shape = regex("^([A-Z])([0-9]{5})([A-Z]{2})([0-9]{4})([A-Z]{3})([0-9]{6})$")

    // LLPINs identify limited liability partnerships, which are on a separate register under the
    // LLP Act 2008 and have no CIN at all. Both the hyphenated form (AAA-1234) and the bare form
    // that upstream PDFs produce (AAB5824) occur in practice.
    private static let llpinShape = regex("^([A-Z]{3})-?([0-9]{4})$")

    // FCRN identifies a foreign company registered under Chapter XXII, also not a CIN.
    private static let fcrnShape = regex("^F-?([0-9]{5})$")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Force-unwrapped because these are literals fixed at compile time: a throw here would
        // mean the file itself is broken, not that the input was.
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    /// The capture groups of a whole-string match, or `nil` when the shape does not fit.
    private static func groups(of regex: NSRegularExpression, in value: String) -> [String]? {
        let ns = value as NSString
        let whole = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: value, options: [], range: whole) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }
}

// MARK: - The honest gap

/*
 * The brief for this feature was to pull MCA master data. Neither the platform nor this app ships
 * it, because it cannot be sourced: mca.gov.in exposes no free public API, its V3 master-data
 * views are captcha-gated with parts behind paid download, and no paid-provider credential exists.
 * Everything below is therefore absent, and the screen names it rather than filling the space with
 * a guess.
 *
 * These strings live here, beside the decoder, so the one place that knows what a CIN does and
 * does not tell you also states what the product does not know.
 */

extension Cin {
    static let masterDataGaps: [MasterDataGap] = [
        MasterDataGap(
            field: "Registered office address",
            why: "Held only in MCA master data. A wrong address on a notice or affidavit is a "
                + "service defect, so no address is shown at all rather than an inferred one."),
        MasterDataGap(
            field: "Directors and DIN",
            why: "The DIN-to-company mapping is behind MCA V3 sign-in; there is no free feed and "
                + "none is licensed here."),
        MasterDataGap(
            field: "Registered and satisfied charges",
            why: "Index of Charges is a paid MCA download. Security interest cannot be inferred "
                + "from a CIN or from an auction notice."),
        MasterDataGap(
            field: "Filing history and company status",
            why: "Annual returns, financial statements and active/struck-off status come from MCA "
                + "master data. Whether a company is still active cannot be read from its CIN."),
        MasterDataGap(
            field: "Authorised and paid-up capital",
            why: "MCA master data only. Nothing in the CIN or in an IBBI auction notice carries "
                + "it."),
    ]

    static let masterDataGapReason =
        "MCA does not publish a free public API, and its V3 master-data views are captcha-gated "
        + "with parts available only as a paid download. No paid data provider is connected to "
        + "this deployment. Rather than show plausible-looking figures that no one has verified, "
        + "this screen shows only what it can stand behind: the CIN decoded from its own "
        + "structure. For master data, search the CIN on the MCA portal directly."
}

// MARK: - Lookup tables

/// Position 1: listing status.
///
/// MCA re-allots the CIN when a company's listing status changes, so this reflects the status for
/// as long as this particular CIN is the current one.
private struct ListingInfo: Sendable {
    let label: String
    let description: String
}

/// Positions 7-8: Registrar of Companies.
///
/// This segment is the ROC OFFICE, not a state. Most codes coincide with a state or UT, but
/// several are city registrars: PN is ROC Pune and TZ is ROC Coimbatore, both of which sit inside
/// states that also have their own code (MH, TN). Labelling these "state" would misfile every
/// company registered at either office.
///
/// `office` is deliberately `nil` wherever the registrar's seat is not something this module can
/// assert with confidence. The consumer then shows the state alone rather than a plausible-looking
/// invention — a wrong ROC on a legal document is worse than an incomplete one, and the same rule
/// governs the unrecognised-code path in `Cin.parse`.
private struct RocInfo: Sendable {
    let office: String?
    let state: String
    var cityRoc: Bool = false
}

/// Positions 13-15: company class.
private struct ClassInfo: Sendable {
    let label: String
    let note: String?
}

private enum CinTables {
    static let listingStatus: [String: ListingInfo] = [
        "L": ListingInfo(
            label: "Listed", description: "Listed on a recognised stock exchange in India."),
        "U": ListingInfo(
            label: "Unlisted", description: "Not listed on a recognised stock exchange."),
    ]

    static let rocOffices: [String: RocInfo] = [
        "AP": RocInfo(office: "ROC Vijayawada", state: "Andhra Pradesh"),
        "AR": RocInfo(office: "ROC Shillong", state: "Arunachal Pradesh"),
        "AS": RocInfo(office: "ROC Shillong", state: "Assam"),
        "BR": RocInfo(office: "ROC Patna", state: "Bihar"),
        "CH": RocInfo(office: "ROC Chandigarh", state: "Chandigarh"),
        "CT": RocInfo(office: nil, state: "Chhattisgarh"),
        "DD": RocInfo(office: "ROC Goa", state: "Daman and Diu"),
        "DL": RocInfo(office: "ROC Delhi", state: "Delhi"),
        "DN": RocInfo(office: "ROC Ahmedabad", state: "Dadra and Nagar Haveli"),
        "GA": RocInfo(office: "ROC Goa", state: "Goa"),
        "GJ": RocInfo(office: "ROC Ahmedabad", state: "Gujarat"),
        "HP": RocInfo(office: nil, state: "Himachal Pradesh"),
        "HR": RocInfo(office: "ROC Delhi", state: "Haryana"),
        "JH": RocInfo(office: nil, state: "Jharkhand"),
        "JK": RocInfo(office: "ROC Jammu", state: "Jammu and Kashmir"),
        "KA": RocInfo(office: "ROC Bangalore", state: "Karnataka"),
        "KL": RocInfo(office: "ROC Ernakulam", state: "Kerala"),
        "LD": RocInfo(office: nil, state: "Lakshadweep"),
        "MH": RocInfo(office: "ROC Mumbai", state: "Maharashtra"),
        "ML": RocInfo(office: "ROC Shillong", state: "Meghalaya"),
        "MN": RocInfo(office: "ROC Shillong", state: "Manipur"),
        "MP": RocInfo(office: "ROC Gwalior", state: "Madhya Pradesh"),
        "MZ": RocInfo(office: "ROC Shillong", state: "Mizoram"),
        "NL": RocInfo(office: "ROC Shillong", state: "Nagaland"),
        "OR": RocInfo(office: "ROC Cuttack", state: "Odisha"),
        "PB": RocInfo(office: "ROC Chandigarh", state: "Punjab"),
        "PY": RocInfo(office: "ROC Puducherry", state: "Puducherry"),
        "RJ": RocInfo(office: "ROC Jaipur", state: "Rajasthan"),
        "SK": RocInfo(office: nil, state: "Sikkim"),
        "TN": RocInfo(office: "ROC Chennai", state: "Tamil Nadu"),
        "TR": RocInfo(office: "ROC Shillong", state: "Tripura"),
        "TG": RocInfo(office: "ROC Hyderabad", state: "Telangana"),
        "UP": RocInfo(office: "ROC Kanpur", state: "Uttar Pradesh"),
        "UT": RocInfo(office: nil, state: "Uttarakhand"),
        "UK": RocInfo(office: nil, state: "Uttarakhand"),
        "WB": RocInfo(office: "ROC Kolkata", state: "West Bengal"),
        "AN": RocInfo(office: nil, state: "Andaman and Nicobar Islands"),
        // City registrars — the reason this field is "Registrar" and not "State".
        "PN": RocInfo(office: "ROC Pune", state: "Maharashtra", cityRoc: true),
        "TZ": RocInfo(office: "ROC Coimbatore", state: "Tamil Nadu", cityRoc: true),
    ]

    static let companyClasses: [String: ClassInfo] = [
        "PLC": ClassInfo(label: "Public Limited Company", note: "Limited by shares, public."),
        "PTC": ClassInfo(label: "Private Limited Company", note: "Limited by shares, private."),
        "OPC": ClassInfo(
            label: "One Person Company",
            note: "Private company with a single member (s. 2(62), Companies Act 2013)."),
        "FLC": ClassInfo(
            label: "Financial Lease Company as Public Limited Company", note: nil),
        "FTC": ClassInfo(
            label: "Subsidiary of a Foreign Company as Private Limited Company", note: nil),
        "GAP": ClassInfo(label: "General Association Public", note: nil),
        "GAT": ClassInfo(label: "General Association Private", note: nil),
        "SGC": ClassInfo(
            label: "State Government Company",
            note: "Owned or controlled by a State Government."),
        "GOI": ClassInfo(
            label: "Union Government Company",
            note: "Owned or controlled by the Government of India."),
        "NPL": ClassInfo(
            label: "Not-for-Profit Company",
            note: "Licensed under s. 8, Companies Act 2013 (formerly s. 25, 1956 Act)."),
        "ULL": ClassInfo(
            label: "Public Limited Company with Unlimited Liability", note: nil),
        "ULT": ClassInfo(
            label: "Private Limited Company with Unlimited Liability", note: nil),
    ]

    // Positions 2-6: industry code.
    //
    // WHICH NIC EDITION: MCA's CIN industry codes come from the NIC-1987/2004 family, NOT
    // NIC-2008, and MCA kept issuing them long after NIC-2008 was published. This was checked
    // against the companies actually held on the platform rather than assumed: division 45 is
    // IVRCL and Pratibha Industries (construction, which NIC-2008 assigns to motor-vehicle trade);
    // division 40 is Lanco Vidarbha Thermal Power and 62 other power companies (a division
    // NIC-2008 does not use at all); division 72 is Net 4 India and Welworth Software (computing,
    // which NIC-2008 assigns to R&D); division 92 is Mi Marathi Media and VNV Productions (media,
    // which NIC-2008 assigns to gambling and betting). Reading this field against NIC-2008 would
    // have mislabelled roughly a third of the companies on record, several of them defamatorily.
    //
    // Only the 2-digit DIVISION is mapped. The full 5-digit code runs to ~1,500 sub-classes and is
    // reported raw — a decoded sub-class nobody verified is exactly the kind of confident-and-wrong
    // detail this feature exists to avoid.
    static let nicDivisions: [String: String] = [
        "01": "Agriculture, hunting and related service activities",
        "02": "Forestry, logging and related service activities",
        "05": "Fishing, aquaculture and fish hatcheries",
        "10": "Mining of coal and lignite; extraction of peat",
        "11": "Extraction of crude petroleum and natural gas",
        "12": "Mining of uranium and thorium ores",
        "13": "Mining of metal ores",
        "14": "Other mining and quarrying",
        "15": "Manufacture of food products and beverages",
        "16": "Manufacture of tobacco products",
        "17": "Manufacture of textiles",
        "18": "Manufacture of wearing apparel; dressing and dyeing of fur",
        "19": "Tanning and dressing of leather; manufacture of luggage, handbags and footwear",
        "20": "Manufacture of wood and wood products, except furniture",
        "21": "Manufacture of paper and paper products",
        "22": "Publishing, printing and reproduction of recorded media",
        "23": "Manufacture of coke, refined petroleum products and nuclear fuel",
        "24": "Manufacture of chemicals and chemical products",
        "25": "Manufacture of rubber and plastics products",
        "26": "Manufacture of other non-metallic mineral products",
        "27": "Manufacture of basic metals",
        "28": "Manufacture of fabricated metal products, except machinery and equipment",
        "29": "Manufacture of machinery and equipment n.e.c.",
        "30": "Manufacture of office, accounting and computing machinery",
        "31": "Manufacture of electrical machinery and apparatus n.e.c.",
        "32": "Manufacture of radio, television and communication equipment",
        "33": "Manufacture of medical, precision and optical instruments, watches and clocks",
        "34": "Manufacture of motor vehicles, trailers and semi-trailers",
        "35": "Manufacture of other transport equipment",
        "36": "Manufacture of furniture; manufacturing n.e.c.",
        "37": "Recycling",
        "40": "Electricity, gas, steam and hot water supply",
        "41": "Collection, purification and distribution of water",
        "45": "Construction",
        "50": "Sale, maintenance and repair of motor vehicles and motorcycles; retail sale of "
            + "automotive fuel",
        "51": "Wholesale and commission trade, except of motor vehicles and motorcycles",
        "52": "Retail trade, except of motor vehicles and motorcycles; repair of personal and "
            + "household goods",
        "55": "Hotels and restaurants",
        "60": "Land transport; transport via pipelines",
        "61": "Water transport",
        "62": "Air transport",
        "63": "Supporting and auxiliary transport activities; travel agencies",
        "64": "Post and telecommunications",
        "65": "Financial intermediation, except insurance and pension funding",
        "66": "Insurance and pension funding, except compulsory social security",
        "67": "Activities auxiliary to financial intermediation",
        "70": "Real estate activities",
        "71": "Renting of machinery and equipment without operator; renting of household goods",
        "72": "Computer and related activities",
        "73": "Research and development",
        "74": "Other business activities",
        "75": "Public administration and defence; compulsory social security",
        "80": "Education",
        "85": "Health and social work",
        "90": "Sewage and refuse disposal, sanitation and similar activities",
        "91": "Activities of membership organisations n.e.c.",
        "92": "Recreational, cultural and sporting activities",
        "93": "Other service activities",
        "95": "Activities of private households as employers of domestic staff",
    ]

    // MCA's own catch-alls, which are not NIC divisions and must not be read as one. 99999 is the
    // "not elsewhere classified" bucket — Jet Airways (India) Limited carries it, so reading
    // division 99 as "extra-territorial organisations and bodies" (its NIC meaning) would be
    // nonsense on real companies.
    static let industrySentinels: [String: String] = [
        "00000": "No industry code recorded against this company",
        "99999": "Not elsewhere classified (MCA general code)",
    ]
}
