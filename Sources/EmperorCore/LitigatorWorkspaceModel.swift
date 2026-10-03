import Foundation

#if canImport(Darwin)
import Observation
#endif

/// A document as the Litigator workspace lists it.
struct LitigatorDocumentRow: Identifiable, Equatable, Sendable {
    /// The `ldoc-` id its form is reached by.
    let id: String
    /// The full name, statutory reference included — the web's card shows the whole label, and
    /// "(BNSS 482, old 438)" is how an advocate tells two bail applications apart.
    let label: String
    let note: String?
}

/// One section of the workspace: its documents, and the heading form that offers them all.
struct LitigatorSectionGroup: Identifiable, Equatable, Sendable {
    /// The `lsec-` id of the section's heading form.
    let id: String
    let title: String
    /// The web's heading-card line — see `LitigatorDrafting.summary(of:)`.
    let summary: String
    let documents: [LitigatorDocumentRow]

    /// The row that opens the heading form. Worded around the section's own title rather than
    /// folding it into a sentence, because the titles do not inflect alike — "Bail", "GST",
    /// "Common documents", "Applications — interlocutory".
    var anyDocumentLabel: String { "Any document in \(title)…" }
}

/// The Litigator workspace: which matter, which proceeding, and the sections that follow from them.
///
/// The web's Home for this role is a matter chooser over the drafting taxonomy
/// (`pages/home/RoleCards.jsx`, `MatterSeg`), with a page per matter that narrows Civil and
/// Criminal to a proceeding (`pages/LitigatorMatter.jsx`). On a phone those are one screen: the
/// matter, the proceeding where the matter has them, then each section's documents with its
/// heading form beside them.
///
/// The matter is remembered on the device, as the web remembers it. The proceeding is not: it
/// narrows one sitting's view, and the web keeps it in component state for the same reason.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class LitigatorWorkspaceModel {
    let matters: [LitigatorMatter] = LITIGATOR_MATTERS
    private(set) var matter: LitigatorMatter
    /// `nil` is "all / any stage".
    private(set) var proceeding: String?

    private let store: any PreferenceStore

    init(store: any PreferenceStore) {
        self.store = store
        self.matter = LitigatorMatter.stored(in: store)
    }

    /// Choosing a matter remembers it, and clears the proceeding — each matter has its own list,
    /// and a civil "Suit" means nothing to a criminal matter.
    func select(_ matter: LitigatorMatter) {
        guard matter != self.matter else { return }
        self.matter = matter
        proceeding = nil
        matter.save(to: store)
    }

    /// Narrows to a proceeding this matter offers. Anything else — including one carried over
    /// from another matter — is "any stage", never a filter that hides sections for no reason.
    func select(proceeding: String?) {
        guard let proceeding, proceedings.contains(proceeding) else {
            self.proceeding = nil
            return
        }
        self.proceeding = proceeding
    }

    /// The proceedings this matter can be narrowed to. Empty for a practice area.
    var proceedings: [String] { LITIGATOR_PROCEEDINGS[matter.id] ?? [] }

    var groups: [LitigatorSectionGroup] {
        LitigatorDrafting.sections(for: matter.id, proceeding: proceeding).map { section in
            LitigatorSectionGroup(
                id: LitigatorDrafting.sectionID(matter: matter.id, section: section.key),
                title: section.title,
                summary: LitigatorDrafting.summary(of: section),
                documents: section.items.map { item in
                    LitigatorDocumentRow(
                        id: LitigatorDrafting.documentID(matter: matter.id, item: item.id),
                        label: item.label,
                        note: item.note.flatMap { $0.isEmpty ? nil : $0 })
                })
        }
    }

    var documentCount: Int { groups.reduce(0) { $0 + $1.documents.count } }

    /// One line under the matter's name: the web's own description where it has one, which is
    /// Civil and Criminal, and otherwise the practice area's sections, so the line still says
    /// what is inside.
    var summary: String {
        if let summary = matter.summary, !summary.isEmpty { return summary }
        return groups.map(\.title).joined(separator: " · ")
    }

    /// The sections this proceeding rules out, by name, in the platform's order.
    var hiddenSections: [String] {
        guard proceeding != nil else { return [] }
        let shown = Set(groups.map(\.title))
        return LitigatorDrafting.sections(for: matter.id)
            .map(\.title)
            .filter { !shown.contains($0) }
    }

    /// Said under the proceeding picker, so a section that disappeared is accounted for rather
    /// than simply missing.
    var stageNote: String? {
        let hidden = hiddenSections
        guard !hidden.isEmpty else { return nil }
        let names = hidden.count == 1
            ? hidden[0]
            : hidden.dropLast().joined(separator: ", ") + " and " + hidden[hidden.count - 1]
        return "Not part of this proceeding: \(names)."
    }
}

extension LitigatorMatter {
    /// The SF Symbol drawn beside a matter, chosen to read as the web's `lucide` icon for it
    /// (`roleConfig.js`). A symbol name that does not exist renders as nothing, silently, so the
    /// names are kept to long-standing ones and `LitigatorWorkspaceTests` checks every matter has
    /// one of its own.
    var systemImage: String {
        switch id {
        case "civil": return "building.columns"        // Landmark
        case "criminal": return "hammer"               // Gavel
        case "ipr": return "lightbulb"                 // Lightbulb
        case "tax": return "percent"                   // Receipt
        case "banking": return "banknote"              // Banknote
        case "arbitration": return "person.2"          // Handshake
        case "cyber": return "lock.shield"             // ShieldCheck
        case "labour": return "wrench.and.screwdriver" // HardHat
        case "property": return "house"                // Building
        case "company": return "briefcase"             // Briefcase
        case "constitutional": return "book.closed"    // BookMarked
        case "international": return "globe"           // Globe
        default: return "doc.text"
        }
    }
}
