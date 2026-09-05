import Foundation

/// One entry a court dropdown can offer — a coded value and the words for it.
///
/// The value is what the court's own system understands and the label is what a person reads;
/// they are unrelated strings and neither can be derived from the other. Sending a label, or
/// showing a value, are the two ways to get this wrong.
struct CourtOption: Codable, Equatable, Identifiable, Sendable {
    let value: String
    let label: String

    var id: String { value }
}

/// A court, tribunal or commission a matter can belong to.
struct Court: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let family: CourtFamily

    /// Whether a lookup here reaches the court at all.
    ///
    /// False for the district and subordinate courts, and that is the whole reason this property
    /// exists. Their only route fabricates a card from the request — it echoes back the case type
    /// and number the user just typed, with `parties`, `judge` and `status` all null, and marks
    /// it `preview: true`. It never contacts a court.
    ///
    /// They are still **listed**, disabled, rather than hidden. An enormous share of Indian
    /// litigation is in these courts, and a picker that silently omits them reads as a product
    /// that has not heard of district courts rather than one that is being careful. Listed with
    /// the reason attached, a practitioner knows where they stand.
    var isSearchable: Bool { family != .districtCourt }
}

/// Every court the platform knows, and the static catalogues three of them need.
///
/// Ported from the platform's `src/lib/courts.js`, which is the list its own search panel
/// renders. Generated from that file rather than retyped: a wrong court id does not fail
/// loudly — it is persisted verbatim as the matter's `court_code` and quietly files the case
/// under a court it does not belong to.
enum CourtCatalogue {

    /// All 48, in the platform's own order: apex, High Courts, district, tribunals, fora.
    static let all: [Court] = [
        Court(id: "sc", name: "Supreme Court of India", family: .supremeCourt),
        Court(id: "hc-allahabad", name: "High Court — Allahabad", family: .highCourt),
        Court(id: "hc-andhra", name: "High Court — Andhra Pradesh", family: .highCourt),
        Court(id: "hc-bombay", name: "High Court — Bombay", family: .highCourt),
        Court(id: "hc-calcutta", name: "High Court — Calcutta", family: .highCourt),
        Court(id: "hc-chhattisgarh", name: "High Court — Chhattisgarh", family: .highCourt),
        Court(id: "hc-delhi", name: "High Court — Delhi", family: .highCourt),
        Court(id: "hc-gauhati", name: "High Court — Gauhati", family: .highCourt),
        Court(id: "hc-gujarat", name: "High Court — Gujarat", family: .highCourt),
        Court(id: "hc-himachal", name: "High Court — Himachal Pradesh", family: .highCourt),
        Court(id: "hc-jk", name: "High Court — Jammu & Kashmir and Ladakh", family: .highCourt),
        Court(id: "hc-jharkhand", name: "High Court — Jharkhand", family: .highCourt),
        Court(id: "hc-karnataka", name: "High Court — Karnataka", family: .highCourt),
        Court(id: "hc-kerala", name: "High Court — Kerala", family: .highCourt),
        Court(id: "hc-mp", name: "High Court — Madhya Pradesh", family: .highCourt),
        Court(id: "hc-madras", name: "High Court — Madras", family: .highCourt),
        Court(id: "hc-manipur", name: "High Court — Manipur", family: .highCourt),
        Court(id: "hc-meghalaya", name: "High Court — Meghalaya", family: .highCourt),
        Court(id: "hc-orissa", name: "High Court — Orissa", family: .highCourt),
        Court(id: "hc-patna", name: "High Court — Patna", family: .highCourt),
        Court(id: "hc-punjab-haryana", name: "High Court — Punjab & Haryana", family: .highCourt),
        Court(id: "hc-rajasthan", name: "High Court — Rajasthan", family: .highCourt),
        Court(id: "hc-sikkim", name: "High Court — Sikkim", family: .highCourt),
        Court(id: "hc-telangana", name: "High Court — Telangana", family: .highCourt),
        Court(id: "hc-tripura", name: "High Court — Tripura", family: .highCourt),
        Court(id: "hc-uttarakhand", name: "High Court — Uttarakhand", family: .highCourt),
        Court(id: "dist-sessions", name: "District & Sessions Court", family: .districtCourt),
        Court(id: "dist-civil", name: "Civil Court (Junior/Senior Division)", family: .districtCourt),
        Court(id: "dist-cjm", name: "CJM / Metropolitan Magistrate Court", family: .districtCourt),
        Court(id: "dist-family", name: "Family Court", family: .districtCourt),
        Court(id: "dist-commercial", name: "Commercial Court", family: .districtCourt),
        Court(id: "dist-labour", name: "Labour Court / Industrial Tribunal", family: .districtCourt),
        Court(id: "dist-mact", name: "Motor Accident Claims Tribunal (MACT)", family: .districtCourt),
        Court(id: "trib-nclt", name: "National Company Law Tribunal (NCLT)", family: .nclt),
        Court(id: "trib-nclat", name: "National Company Law Appellate Tribunal (NCLAT)", family: .nclat),
        Court(id: "trib-ngt", name: "National Green Tribunal (NGT)", family: .tribunal),
        Court(id: "trib-cat", name: "Central Administrative Tribunal (CAT)", family: .tribunal),
        Court(id: "trib-itat", name: "Income Tax Appellate Tribunal (ITAT)", family: .tribunal),
        Court(id: "trib-drt", name: "Debts Recovery Tribunal (DRT)", family: .tribunal),
        Court(id: "trib-drat", name: "Debts Recovery Appellate Tribunal (DRAT)", family: .tribunal),
        Court(id: "trib-cestat", name: "Customs, Excise & Service Tax Appellate Tribunal (CESTAT)", family: .tribunal),
        Court(id: "trib-tdsat", name: "Telecom Disputes Settlement & Appellate Tribunal (TDSAT)", family: .tribunal),
        Court(id: "trib-aft", name: "Armed Forces Tribunal (AFT)", family: .tribunal),
        Court(id: "trib-sat", name: "Securities Appellate Tribunal (SAT)", family: .tribunal),
        Court(id: "trib-aptel", name: "Appellate Tribunal for Electricity (APTEL)", family: .tribunal),
        Court(id: "forum-ncdrc", name: "National Consumer Disputes Redressal Commission (NCDRC)", family: .consumerForum),
        Court(id: "forum-scdrc", name: "State Consumer Disputes Redressal Commission (SCDRC)", family: .consumerForum),
        Court(id: "forum-dcdrc", name: "District Consumer Disputes Redressal Commission (DCDRC)", family: .consumerForum),
    ]

    static let byID: [String: Court] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func court(_ id: String) -> Court? { byID[id] }

    /// Grouped for a sectioned picker, in the order the platform lists them.
    static var sections: [(title: String, courts: [Court])] {
        CourtFamily.pickerOrder.compactMap { family in
            let matching = all.filter { $0.family == family }
            return matching.isEmpty ? nil : (family.sectionTitle, matching)
        }
    }

    // MARK: - Static option lists
    //
    // These three forums publish a fixed catalogue rather than an endpoint, so the values are
    // carried here. Everything else — High Court benches and case types, tribunal case types,
    // consumer-forum commissions and districts — is fetched, because it changes without notice
    // and a stale copy would offer a bench that no longer exists.

    /// The Supreme Court's case types. The value is its registry's own numeric code.
    static let supremeCourtCaseTypes: [CourtOption] = [
        CourtOption(value: "1", label: "Special Leave Petition (Civil)"),
        CourtOption(value: "2", label: "Special Leave Petition (Criminal)"),
        CourtOption(value: "3", label: "Civil Appeal"),
        CourtOption(value: "4", label: "Criminal Appeal"),
        CourtOption(value: "5", label: "Writ Petition (Civil)"),
        CourtOption(value: "6", label: "Writ Petition (Criminal)"),
        CourtOption(value: "7", label: "Transfer Petition (Civil)"),
        CourtOption(value: "8", label: "Transfer Petition (Criminal)"),
        CourtOption(value: "9", label: "Review Petition (Civil)"),
        CourtOption(value: "10", label: "Review Petition (Criminal)"),
        CourtOption(value: "11", label: "Transferred Case (Civil)"),
        CourtOption(value: "12", label: "Transferred Case (Criminal)"),
        CourtOption(value: "13", label: "Special Leave to Petition (Civil)"),
        CourtOption(value: "14", label: "Special Leave to Petition (Criminal)"),
        CourtOption(value: "15", label: "Writ to Petition (Civil)"),
        CourtOption(value: "16", label: "Writ to Petition (Criminal)"),
        CourtOption(value: "17", label: "Original Suit"),
        CourtOption(value: "18", label: "Death Reference Case"),
        CourtOption(value: "19", label: "Contempt Petition (Civil)"),
        CourtOption(value: "20", label: "Contempt Petition (Criminal)"),
        CourtOption(value: "21", label: "Tax Reference Case"),
        CourtOption(value: "22", label: "Special Reference Case"),
        CourtOption(value: "23", label: "Election Petition (Civil)"),
        CourtOption(value: "24", label: "Arbitration Petition"),
        CourtOption(value: "25", label: "Curative Petition (Civil)"),
        CourtOption(value: "26", label: "Curative Petition (Criminal)"),
        CourtOption(value: "27", label: "Ref. U/A 317(1)"),
        CourtOption(value: "28", label: "Motion (Criminal)"),
        CourtOption(value: "32", label: "Suo Moto Writ Petition (Civil)"),
        CourtOption(value: "33", label: "Suo Moto Writ Petition (Criminal)"),
        CourtOption(value: "34", label: "Suo Moto Contempt Petition (Civil)"),
        CourtOption(value: "35", label: "Suo Moto Contempt Petition (Criminal)"),
        CourtOption(value: "37", label: "Ref. U/S 14 RTI"),
        CourtOption(value: "38", label: "Ref. U/S 17 RTI"),
        CourtOption(value: "39", label: "Miscellaneous Application"),
        CourtOption(value: "40", label: "Suo Moto Transfer Petition (Civil)"),
        CourtOption(value: "41", label: "Suo Moto Transfer Petition (Criminal)"),
    ]

    static let ncltBenches: [CourtOption] = [
        CourtOption(value: "ahmedabad", label: "Ahmedabad"),
        CourtOption(value: "allahabad", label: "Allahabad"),
        CourtOption(value: "amravati", label: "Amaravati"),
        CourtOption(value: "bengaluru", label: "Bengaluru"),
        CourtOption(value: "chandigarh", label: "Chandigarh"),
        CourtOption(value: "chennai", label: "Chennai"),
        CourtOption(value: "cuttack", label: "Cuttack"),
        CourtOption(value: "guwahati", label: "Guwahati"),
        CourtOption(value: "hyderabad", label: "Hyderabad"),
        CourtOption(value: "indore", label: "Indore"),
        CourtOption(value: "jaipur", label: "Jaipur"),
        CourtOption(value: "kochi", label: "Kochi"),
        CourtOption(value: "kolkata", label: "Kolkata"),
        CourtOption(value: "mumbai", label: "Mumbai"),
        CourtOption(value: "delhi", label: "New Delhi"),
    ]

    static let ncltCaseTypes: [CourtOption] = [
        CourtOption(value: "43", label: "Execution Petition (IBC)"),
        CourtOption(value: "42", label: "Rule 63 Appeal"),
        CourtOption(value: "41", label: "IA (Liq.) Progress Report"),
        CourtOption(value: "40", label: "Interlocutory Application(IBC)(Dis.)"),
        CourtOption(value: "39", label: "Interlocutory Application(IBC)(Liq.)"),
        CourtOption(value: "38", label: "Interlocutory Application(IBC)(Plan)"),
        CourtOption(value: "37", label: "Restored Company Petition (Companies Act)"),
        CourtOption(value: "36", label: "Restored Company Petition (IBC)"),
        CourtOption(value: "35", label: "Voluntary Liquidation (IBC)"),
        CourtOption(value: "34", label: "Transfer Application (IBC)"),
        CourtOption(value: "33", label: "Insolvency & Bankruptcy (Pre-Packaged)"),
        CourtOption(value: "32", label: "Transfer Application"),
        CourtOption(value: "31", label: "Interlocutory Application (I.B.C)"),
        CourtOption(value: "30", label: "Execution Petition"),
        CourtOption(value: "29", label: "Transfer Petition (IBC)"),
        CourtOption(value: "28", label: "Cross Appeal (IBC)"),
        CourtOption(value: "27", label: "Company Appeal (IBC)"),
        CourtOption(value: "26", label: "Miscellaneous Application (IBC)"),
        CourtOption(value: "25", label: "Contempt Petition (IBC)"),
        CourtOption(value: "24", label: "Cross Application (IBC)"),
        CourtOption(value: "23", label: "Intervention Petition (IBC)"),
        CourtOption(value: "22", label: "Restoration Application (IBC)"),
        CourtOption(value: "21", label: "Review Application (IBC)"),
        CourtOption(value: "20", label: "Interlocatory Application (IBC)"),
        CourtOption(value: "19", label: "Rehabilitation petition(IBC)"),
        CourtOption(value: "18", label: "Company Application(IBC)"),
        CourtOption(value: "16", label: "Company Petition IB (IBC)"),
        CourtOption(value: "15", label: "CP(AA) Merger and Amalgamation(Companies Act)"),
        CourtOption(value: "14", label: "CA(A) Merger and Amalgamation(Companies Act)"),
        CourtOption(value: "13", label: "Company Application(Companies Act)"),
        CourtOption(value: "12", label: "Cross Appeal(Companies Act)"),
        CourtOption(value: "11", label: "Company Appeal(Companies Act)"),
        CourtOption(value: "10", label: "Miscellaneous Application(Companies Act)"),
        CourtOption(value: "9", label: "Contempt Petition(Companies Act)"),
        CourtOption(value: "8", label: "Cross Application (Companies Act)"),
        CourtOption(value: "7", label: "Intervention Petition(Companies Act)"),
        CourtOption(value: "6", label: "Restoration Application (Companies Act)"),
        CourtOption(value: "5", label: "Review Application (Companies Act)"),
        CourtOption(value: "4", label: "Interlocatory Application(Companies Act)"),
        CourtOption(value: "3", label: "Rehabilitation petition (Companies Act)"),
        CourtOption(value: "2", label: "Company Petition (Companies Act)"),
        CourtOption(value: "1", label: "Transfer Petition(Companies Act)"),
    ]

    static let nclatBenches: [CourtOption] = [
        CourtOption(value: "delhi", label: "Principal Bench, New Delhi"),
        CourtOption(value: "chennai", label: "Chennai Bench"),
    ]

    static let nclatCaseTypes: [CourtOption] = [
        CourtOption(value: "32", label: "Company Appeal (AT)"),
        CourtOption(value: "33", label: "Company Appeal (AT)(Ins)"),
        CourtOption(value: "34", label: "Competition Appeal (AT)"),
        CourtOption(value: "35", label: "Interlocutory Application"),
        CourtOption(value: "36", label: "Compensation Application"),
        CourtOption(value: "37", label: "Contempt Case (AT)"),
        CourtOption(value: "38", label: "Review Application"),
        CourtOption(value: "39", label: "Restoration Application"),
        CourtOption(value: "40", label: "Transfer Appeal"),
        CourtOption(value: "61", label: "Transfer Original Petition (MRTP-AT)"),
    ]

    /// Years a case could carry, newest first. The Supreme Court's own form starts at 1950,
    /// which is when it was constituted.
    static func years(now: Date = Date()) -> [String] {
        let current = Calendar(identifier: .gregorian).component(.year, from: now)
        return (1950...max(1950, current)).reversed().map(String.init)
    }
}
