import Foundation

/// Who the user practises as — the platform's organising principle.
///
/// ## Seven of these, three on the wire
///
/// The web's `roleConfig.js` defines seven roles and each carries an `aiRole` field, which is the
/// value the model is actually told. Four of the seven — Senior Counsel, Student, Paralegal and
/// Legal Aid — all send `Litigator`. That is not a mistake to be tidied up: the system prompt
/// only knows three identities, and the other four differ in **what the app offers them**, not in
/// what the model is told it is.
///
/// This app already had `ChatRole`, which is the three wire values. It keeps that job. This type
/// is the layer above it, and `wireRole` is the same narrowing `aiRole` does on the web.
///
/// ## What a role is for
///
/// It scopes the toolkit. Every one of the twenty-nine tools works for anybody, and a role does
/// not lock any of them away — see `ToolsListView`, which keeps the full list one tap behind the
/// scoped one. What a role does is answer "which six of these twenty-nine are mine", which on a
/// phone is the difference between a usable screen and a wall.
///
/// Not stored on the server. `users` carries `avatar`, `title`, `organization`, `preferred_model`
/// and `plan` and no role column, so the web keeps this client-side too. It is a device
/// preference here for the same reason.
enum PractitionerRole: String, CaseIterable, Identifiable, Codable, Sendable {
    case litigator
    case seniorCounsel
    case corporateCounsel
    case adjudicator
    case student
    case paralegal
    case legalAid

    var id: String { rawValue }

    static let `default` = PractitionerRole.litigator

    var label: String {
        switch self {
        case .litigator: return "Litigator"
        case .seniorCounsel: return "Senior Counsel"
        case .corporateCounsel: return "Corporate Counsel"
        case .adjudicator: return "Arbitrators & Judges"
        case .student: return "Student / Academic"
        case .paralegal: return "Paralegal"
        case .legalAid: return "Legal Aid / NGO"
        }
    }

    var tagline: String {
        switch self {
        case .litigator: return "Advocate handling cases"
        case .seniorCounsel: return "Chambers — opinions and advocacy"
        case .corporateCounsel: return "In-house and corporate advisory"
        case .adjudicator: return "Neutral adjudication"
        case .student: return "Learning and research"
        case .paralegal: return "Legal support"
        case .legalAid: return "Public interest and access to justice"
        }
    }

    var detail: String {
        switch self {
        case .litigator:
            return "Research, draft pleadings, review, and build arguments for the courtroom."
        case .seniorCounsel:
            return "Opinions, advice on brief and evidence, merits and strategy, and written submissions — the work of chambers."
        case .corporateCounsel:
            return "Analyse contracts, draft agreements, and manage governance and compliance."
        case .adjudicator:
            return "Summarise the record, analyse evidence, research authorities — and, as an arbitrator, draft awards, orders and costs."
        case .student:
            return "Learn concepts, brief cases, prepare for exams and moots, and get research and writing coaching — taught, not ghostwritten."
        case .paralegal:
            return "Routine drafts, filings and bundles, document summaries and research support — all as drafts for advocate review."
        case .legalAid:
            return "Beneficiary aid — intake, rights, forms and referrals — and advocacy: PIL support, awareness material and NGO compliance."
        }
    }

    var systemImage: String {
        switch self {
        case .litigator: return "scalemass"
        case .seniorCounsel: return "signature"
        case .corporateCounsel: return "building.2"
        case .adjudicator: return "building.columns"
        case .student: return "graduationcap"
        case .paralegal: return "doc.on.doc"
        case .legalAid: return "heart.text.square"
        }
    }

    /// What the model is told it is.
    ///
    /// The narrowing the web calls `aiRole`. Four roles answer `.litigator` here, which is the
    /// contract rather than an approximation — `clerk_identity.js` knows three identities.
    var wireRole: ChatRole {
        switch self {
        case .corporateCounsel: return .corporateCounsel
        case .adjudicator: return .judicialOfficer
        case .litigator, .seniorCounsel, .student, .paralegal, .legalAid: return .litigator
        }
    }

    /// The tools this role reaches for, in the order the web's sidebar lists them.
    ///
    /// Order is the platform's, not alphabetical: the first entry is what the role opens the app
    /// to do. `custom-document` is appended to every one of them — `COMMON_TOOLS` on the web —
    /// because a blank drafting surface belongs to everybody.
    var toolIDs: [String] {
        switch self {
        case .litigator:
            return [
                "research", "draft-pleading", "draft-review", "case-gist", "arguments",
                "clause-extract", "blind-spots", "list-of-dates", "doc-index",
            ] + Self.common
        case .seniorCounsel:
            return [
                "brief-workup", "arguments", "draft-review", "research", "blind-spots",
                "doc-index",
            ] + Self.common
        case .corporateCounsel:
            return [
                "contract-analysis", "draft-contract", "due-diligence", "board-resolution",
                "compliance-calendar", "research", "highlighter", "blind-spots", "doc-index",
            ] + Self.common
        case .adjudicator:
            return [
                "brief-workup", "case-comparison", "draft-judgment", "bench-note", "research",
                "doc-index", "list-of-dates",
            ] + Self.common
        case .student:
            return ["law-timeline", "case-brief", "irac", "simplify", "research"] + Self.common
        case .paralegal:
            return [
                "citation-check", "doc-assembly", "research", "list-of-dates", "doc-index",
                "highlighter",
            ] + Self.common
        case .legalAid:
            return ["know-your-rights", "pil-template", "research"] + Self.common
        }
    }

    /// Available to every role — `COMMON_TOOLS` on the web.
    private static let common = ["custom-document"]

    /// This role's tools, resolved against the registry and in its own order.
    ///
    /// An id with no tool behind it is dropped rather than crashing, but `PractitionerRoleTests`
    /// asserts there are none: a typo here would silently shorten a toolkit, and a missing tool
    /// is the sort of thing that is only noticed by the person who needed it.
    var tools: [ToolSpec] {
        toolIDs.compactMap { id in LEGAL_TOOLS.first { $0.id == id } }
    }

    // MARK: - Storage

    static let storageKey = "practitioner.role.v1"

    /// Reads the stored role, falling back to the default for an absent or unrecognised value —
    /// which is what a downgrade, or a role retired in a later build, leaves behind.
    static func stored(in store: any PreferenceStore) -> PractitionerRole {
        guard let raw = store.string(for: storageKey),
              let role = PractitionerRole(rawValue: raw)
        else { return .default }
        return role
    }

    func save(to store: any PreferenceStore) {
        store.setString(rawValue, for: Self.storageKey)
    }
}
