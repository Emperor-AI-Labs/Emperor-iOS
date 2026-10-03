import Foundation

/*
 * Litigator's drafting taxonomy, and the two resolvers that turn one of its ids into a tool.
 *
 * Litigator is the one role the platform does not give a card deck. Its workspace is a taxonomy:
 * a matter (Civil, Criminal, or one of ten practice areas), an optional proceeding that hides the
 * stages a case of that kind never reaches, and sections of documents. Two id shapes reach a
 * form, and `getTool` dispatches on their prefixes (`registry.js:853-856`):
 *
 *   ldoc-<matter>-<item>      one document — `resolveDraftTool`
 *   lsec-<matter>-<section>   a section's heading card, whose first field picks the document —
 *                             `resolveSectionTool`
 *
 * The data is generated (`LitigatorTaxonomy.swift`, by `scripts/generate-litigator-fixtures.mjs`).
 * What is here is the code: `sectionsFor`, `getDraftItem` and `getDraftSection` from
 * `src/roles/litigatorDrafting.js`, and the resolvers and `buildSectionPrompt` from
 * `src/tools/registry.js:551-641`. Every id the workspace offers — 175 documents and 47 heading
 * cards — is pinned against the platform's own output by `LitigatorGoldenTests`.
 *
 * Each rule below copies JavaScript's truthiness where the platform leans on it. An empty
 * `template` is the platform's way of saying "no skeleton" (four practice-area sections carry
 * `''`), so "present" here always means present and non-empty.
 */

// MARK: - The shapes

/// One matter the workspace offers — Civil, Criminal, or a practice area.
struct LitigatorMatter: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    /// The compact name `MatterSeg` shows when space is short; only the practice areas carry one.
    let short: String?
    /// One line about what the matter covers — `LitigatorMatter.jsx`'s `META`, which describes
    /// Civil and Criminal only.
    let summary: String?

    init(id: String, label: String, short: String? = nil, summary: String? = nil) {
        self.id = id
        self.label = label
        self.short = short
        self.summary = summary
    }

    /// What a chip says: `m.short || m.label`, the compact segmented control's rule.
    var chipLabel: String { short ?? label }

    /// A practice area drafts from its own sections; Civil and Criminal share `DRAFT_SECTIONS`.
    var isPracticeArea: Bool { LITIGATOR_AREAS[id] != nil }

    /// The matter a fresh install opens on — the first the platform lists, which is also what the
    /// web's store starts with (`store.js:87`, `litMatter: 'civil'`).
    static var `default`: LitigatorMatter { LITIGATOR_MATTERS[0] }

    // MARK: Storage

    /// A device preference, as the web keeps it (`store.js:1570` persists `litMatter` to local
    /// storage). Not an account setting: nothing on the server records it.
    static let storageKey = "litigator.matter.v1"

    /// The remembered matter, falling back to the first for an absent or unrecognised value —
    /// the web's `role.matters.find(x => x.id === litMatter) || role.matters[0]`, and what a
    /// matter retired in a later build leaves behind.
    static func stored(in store: any PreferenceStore) -> LitigatorMatter {
        guard let raw = store.string(for: storageKey),
              let matter = LITIGATOR_MATTERS.first(where: { $0.id == raw })
        else { return .default }
        return matter
    }

    func save(to store: any PreferenceStore) {
        store.setString(id, for: Self.storageKey)
    }
}

/// Which of Civil and Criminal a document belongs to — the platform's `b` flag.
enum LitigatorBranch: Sendable {
    case civil, criminal, both
}

/// One document in the taxonomy.
struct LitigatorItem: Identifiable, Equatable, Sendable {
    let id: String
    /// The full name, statutory reference and all — "Plaint (suit, Order 7)".
    let label: String
    /// `nil` for a practice area's documents, which carry no flag because their matter is fixed.
    let branch: LitigatorBranch?
    /// A short qualifier the platform shows under the name, and appends to the form's blurb.
    let note: String?
    /// A skeleton of the document's own. None carries one today; `resolveDraftTool` reads it first.
    let template: String?

    init(
        id: String, label: String, branch: LitigatorBranch? = nil, note: String? = nil,
        template: String? = nil
    ) {
        self.id = id
        self.label = label
        self.branch = branch
        self.note = note
        self.template = template
    }

    /// Whether Civil or Criminal lists this document — `itemInMatter`. Every other matter is a
    /// practice area with its own list, so nothing in `DRAFT_SECTIONS` belongs to it.
    func belongs(to matter: String) -> Bool {
        switch (matter, branch) {
        case (_, .both?): return matter == "civil" || matter == "criminal"
        case ("civil", .civil?), ("criminal", .criminal?): return true
        default: return false
        }
    }
}

/// The stage a section belongs to, which a proceeding can rule out.
enum LitigatorGate: Sendable {
    /// Framing issues — a civil suit alone.
    case issues
    /// Evidence and cross-examination — any proceeding that goes to trial.
    case trial
}

/// One heading in the taxonomy, with its documents.
struct LitigatorSection: Identifiable, Equatable, Sendable {
    let key: String
    let title: String
    /// The `load_drafting_template` skeleton the model is told to draft to.
    let template: String?
    let gate: LitigatorGate?
    /// What to draft, for a section with no form of its own in `LITIGATOR_SECTION_FORMS`.
    let draftInstruction: String?
    let items: [LitigatorItem]

    var id: String { key }

    init(
        key: String, title: String, template: String? = nil, gate: LitigatorGate? = nil,
        draftInstruction: String? = nil, items: [LitigatorItem]
    ) {
        self.key = key
        self.title = title
        self.template = template
        self.gate = gate
        self.draftInstruction = draftInstruction
        self.items = items
    }

    /// The same section showing only `items` — `{ ...s, items }`.
    func keeping(_ items: [LitigatorItem]) -> LitigatorSection {
        LitigatorSection(
            key: key, title: title, template: template, gate: gate,
            draftInstruction: draftInstruction, items: items)
    }
}

/// A practice area: its label, the governing law the model is told to apply, and its sections.
struct LitigatorArea: Sendable {
    let label: String
    let codeNote: String
    let sections: [LitigatorSection]
}

/// One field of a section's form, before the forum is expanded into a list of courts.
struct LitigatorFormField: Sendable {
    enum Kind: Sendable {
        case text, textarea, select
        /// "The court or forum", which `expandFormInputs` turns into a select over `FORUMS`.
        case forum
    }

    let key: String
    let label: String
    let type: Kind
    let required: Bool
    let placeholder: String?
    let options: [String]
    let big: Bool

    init(
        key: String, label: String, type: Kind, required: Bool = false,
        placeholder: String? = nil, options: [String] = [], big: Bool = false
    ) {
        self.key = key
        self.label = label
        self.type = type
        self.required = required
        self.placeholder = placeholder
        self.options = options
        self.big = big
    }
}

/// A section's own form — its fields, and the instruction that says how to draft it.
struct LitigatorSectionForm: Sendable {
    let inputs: [LitigatorFormField]
    let draftInstruction: String
}

/// What `getDraftItem` answers: the matter as the id spelled it, the document, its section, and —
/// for a practice area — the area, which brings its label and governing-law note.
struct LitigatorDocumentReference: Sendable {
    let matter: String
    let item: LitigatorItem
    let section: LitigatorSection
    let area: LitigatorArea?
}

/// What `getDraftSection` answers. For Civil and Criminal, `section.items` holds only that
/// matter's documents.
struct LitigatorSectionReference: Sendable {
    let matter: String
    let section: LitigatorSection
    let area: LitigatorArea?
}

// MARK: - The taxonomy

enum LitigatorDrafting {
    static let documentPrefix = "ldoc-"
    static let sectionPrefix = "lsec-"

    /// `draftToolId`.
    static func documentID(matter: String, item: String) -> String {
        "\(documentPrefix)\(matter)-\(item)"
    }

    /// `sectionToolId`.
    static func sectionID(matter: String, section: String) -> String {
        "\(sectionPrefix)\(matter)-\(section)"
    }

    /// The sections a matter offers, narrowed to a proceeding — `sectionsFor`.
    ///
    /// A practice area has its own list and no proceedings, so the proceeding is ignored there.
    /// For Civil and Criminal each section keeps only that matter's documents, a section left with
    /// none is dropped, and a proceeding hides the stages it never reaches.
    static func sections(for matter: String, proceeding: String? = nil) -> [LitigatorSection] {
        if let area = LITIGATOR_AREAS[matter] { return area.sections }
        return LITIGATOR_DRAFT_SECTIONS
            .filter { allowed($0, matter: matter, proceeding: proceeding) }
            .map { section in section.keeping(section.items.filter { $0.belongs(to: matter) }) }
            .filter { !$0.items.isEmpty }
    }

    /// Stage-gating — `sectionAllowed`. Issues are framed only in a civil suit; evidence and
    /// cross-examination arise in anything that goes to trial, which a writ or a civil appeal does
    /// not, and nor does a criminal appeal, revision or bail matter.
    static func allowed(_ section: LitigatorSection, matter: String, proceeding: String?) -> Bool {
        guard let proceeding, !proceeding.isEmpty else { return true }
        switch section.gate {
        case .issues?:
            return matter == "civil" && proceeding == "Suit"
        case .trial?:
            let noTrial = matter == "civil"
                ? ["Writ petition", "Appeal"]
                : ["Appeal / revision", "Bail matter"]
            return !noTrial.contains(proceeding)
        case nil:
            return true
        }
    }

    /// The document an `ldoc-` id names — `getDraftItem`.
    ///
    /// As permissive as the platform's, deliberately: for Civil and Criminal it finds the item in
    /// any section without asking which branch lists it, so `ldoc-civil-bail-reply` answers even
    /// though Civil never offers it. The workspace builds its ids from `sections(for:)` and never
    /// produces one of those; matching the platform exactly is what lets a fixture pin this.
    static func document(_ toolID: String) -> LitigatorDocumentReference? {
        guard let (matter, itemID) = split(toolID, prefix: documentPrefix) else { return nil }
        if let area = LITIGATOR_AREAS[matter] {
            for section in area.sections {
                if let item = section.items.first(where: { $0.id == itemID }) {
                    return LitigatorDocumentReference(
                        matter: matter, item: item, section: section, area: area)
                }
            }
            return nil
        }
        for section in LITIGATOR_DRAFT_SECTIONS {
            if let item = section.items.first(where: { $0.id == itemID }) {
                return LitigatorDocumentReference(
                    matter: matter, item: item, section: section, area: nil)
            }
        }
        return nil
    }

    /// The section an `lsec-` id names — `getDraftSection`. Unlike a document, a Civil or
    /// Criminal section is narrowed to that matter's documents, and one with none is no section.
    static func section(_ toolID: String) -> LitigatorSectionReference? {
        guard let (matter, key) = split(toolID, prefix: sectionPrefix) else { return nil }
        if let area = LITIGATOR_AREAS[matter] {
            guard let section = area.sections.first(where: { $0.key == key }) else { return nil }
            return LitigatorSectionReference(matter: matter, section: section, area: area)
        }
        guard let section = LITIGATOR_DRAFT_SECTIONS.first(where: { $0.key == key }) else {
            return nil
        }
        let items = section.items.filter { $0.belongs(to: matter) }
        guard !items.isEmpty else { return nil }
        return LitigatorSectionReference(matter: matter, section: section.keeping(items), area: nil)
    }

    /// `<prefix><matter>-<rest>`, split at the first dash after the prefix. A matter id never holds
    /// a dash and an item id often does, which is why it is the first and not the last.
    private static func split(_ toolID: String, prefix: String) -> (String, String)? {
        guard toolID.hasPrefix(prefix) else { return nil }
        let rest = toolID.dropFirst(prefix.count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return (String(rest[..<dash]), String(rest[rest.index(after: dash)...]))
    }
}

// MARK: - The resolvers

extension LitigatorDrafting {
    /// The tool an `ldoc-` or `lsec-` id resolves to, or `nil` — `getTool`'s first two branches.
    static func tool(_ toolID: String) -> ToolSpec? {
        if toolID.hasPrefix(documentPrefix) { return documentTool(toolID) }
        if toolID.hasPrefix(sectionPrefix) { return sectionTool(toolID) }
        return nil
    }

    /// One document's form — `resolveDraftTool`.
    static func documentTool(_ toolID: String) -> ToolSpec? {
        guard let found = document(toolID) else { return nil }
        return documentTool(
            id: toolID, matter: found.matter, item: found.item, section: found.section,
            area: found.area)
    }

    /// The document form for an item, wherever it came from.
    ///
    /// The document type is fixed — it is the item — so the form is the section's own fields:
    /// a court, and whatever that stage of a matter needs.
    static func documentTool(
        id: String, matter: String, item: LitigatorItem, section: LitigatorSection,
        area: LitigatorArea?
    ) -> ToolSpec {
        let form = LITIGATOR_SECTION_FORMS[section.key]
        let fields = inputs(form?.inputs ?? LITIGATOR_GENERIC_SECTION_FIELDS)
        let note = present(item.note).map { " — \($0)" } ?? ""
        let instruction = present(form?.draftInstruction) ?? present(section.draftInstruction)
        // `item.template || section.template`: an item's own skeleton first. An empty one on
        // the section is still passed on — `prompt` is where an empty template means none, as
        // `buildSectionPrompt` is on the web.
        let template = present(item.template) ?? section.template
        let codeNote = present(area?.codeNote) ?? self.codeNote(for: matter)
        return ToolSpec(
            id: id, title: title(for: item.label), short: section.title,
            blurb: "\(matterLabel(matter, area)) · \(section.title)\(note)",
            output: .document, inputs: fields,
            build: { values, _ in
                prompt(
                    values, matter: matter, documentType: item.label,
                    stage: section.title.lowercased(), fields: fields,
                    instruction: instruction, codeNote: codeNote, template: template)
            })
    }

    /// A section's heading form — `resolveSectionTool`. Its first field chooses the document,
    /// from that section's documents for this matter; the rest are the section's own.
    static func sectionTool(_ toolID: String) -> ToolSpec? {
        guard let found = section(toolID) else { return nil }
        let section = found.section
        let form = LITIGATOR_SECTION_FORMS[section.key]
        let fields = [
            ToolField(
                key: "subhead", label: "Document type", type: .select,
                placeholder: "Choose a \(section.title.lowercased())…",
                options: section.items.map(\.label)),
        ] + inputs(form?.inputs ?? LITIGATOR_GENERIC_SECTION_FIELDS)
        let label = matterLabel(found.matter, found.area)
        let instruction = present(form?.draftInstruction) ?? present(section.draftInstruction)
        let template = section.template
        let codeNote = present(found.area?.codeNote) ?? self.codeNote(for: found.matter)
        let matter = found.matter
        return ToolSpec(
            id: toolID, title: section.title, short: label,
            blurb: "\(label) · \(section.title) — pick the specific document below.",
            output: .document, inputs: fields,
            build: { values, _ in
                prompt(
                    values, matter: matter,
                    documentType: values.text("subhead", section.title),
                    stage: section.title.lowercased(), fields: fields,
                    instruction: instruction, codeNote: codeNote, template: template)
            })
    }

    /// A document's title on its form: the label without a closing parenthetical —
    /// `item.label.replace(/\s*\([^)]*\)\s*$/, '').trim() || item.label`.
    ///
    /// Ported by hand rather than as a regular expression, because the rule's edges are where the
    /// meaning is. "Plaint (suit, Order 7)" becomes "Plaint". But a label that ends in a *nested*
    /// parenthesis — "… (old 156(3))", "Recovery of dues (s.33C(2))" — is left whole: the last
    /// `(` before the closing `)` is followed by another `)`, so the pattern cannot match, and the
    /// platform shows the full label as the title. A label that is nothing but a parenthetical
    /// keeps itself rather than becoming blank.
    static func title(for label: String) -> String {
        let scalars = Array(label.unicodeScalars)
        // The closing `)`, after any trailing whitespace.
        var end = scalars.count
        while end > 0, JSText.isSpace(scalars[end - 1]) { end -= 1 }
        guard end > 0, scalars[end - 1] == ")" else { return fallback(label, JSText.trim(label)) }
        let close = end - 1
        // `[^)]*` cannot cross a `)`, so the opening `(` lies after the previous `)`. The match
        // starts at the leftmost `(` in that stretch — the regex engine tries starts left to right.
        var previousClose = close - 1
        while previousClose >= 0, scalars[previousClose] != ")" { previousClose -= 1 }
        guard let open = (previousClose + 1..<close).first(where: { scalars[$0] == "(" }) else {
            return fallback(label, JSText.trim(label))
        }
        // `\s*` before it belongs to the match too.
        var start = open
        while start > 0, JSText.isSpace(scalars[start - 1]) { start -= 1 }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars[..<start])
        return fallback(label, JSText.trim(String(kept)))
    }

    private static func fallback(_ label: String, _ cleaned: String) -> String {
        cleaned.isEmpty ? label : cleaned
    }

    /// The governing law a matter's drafts are told to apply — `codeNoteFor`. A practice area
    /// supplies its own instead; this is for Civil and Criminal, and anything that is neither is
    /// treated as civil, as the platform treats it.
    static func codeNote(for matter: String) -> String {
        matter == "criminal"
            ? "Apply BNSS / BNS / BSA for offences on or after 1 July 2024, else CrPC / IPC / Evidence Act — cite both where relevant during the transition."
            : "Apply the Code of Civil Procedure and relevant substantive law."
    }

    /// The name a form gives its matter: an area's own label, else Criminal or Civil.
    static func matterLabel(_ matter: String, _ area: LitigatorArea?) -> String {
        present(area?.label) ?? (matter == "criminal" ? "Criminal" : "Civil")
    }

    /// A section form's fields as a tool asks them — `expandFormInputs`. The forum becomes a
    /// select over the shared court list and keeps only its key, label and `required`; the
    /// platform builds a fresh object for it, so a forum field never carries a placeholder.
    static func inputs(_ fields: [LitigatorFormField]) -> [ToolField] {
        fields.map { field in
            switch field.type {
            case .forum:
                return ToolField(
                    key: field.key.isEmpty ? "forum" : field.key,
                    label: field.label.isEmpty ? "Court / forum" : field.label,
                    type: .select, required: field.required, options: FORUMS)
            case .text, .textarea, .select:
                return ToolField(
                    key: field.key, label: field.label, type: field.type.toolFieldType,
                    required: field.required, placeholder: field.placeholder,
                    options: field.options, big: field.big)
            }
        }
    }

    /// The opening message for a litigator draft — `buildSectionPrompt`.
    ///
    /// Every field is written out under its label, filled or not, so nothing the advocate typed is
    /// dropped and nothing left blank is silently assumed. The heading form's document-type field
    /// is the one exception: it is already the opening sentence's subject.
    static func prompt(
        _ values: ToolValues, matter: String, documentType: String, stage: String,
        fields: [ToolField], instruction: String?, codeNote: String, template: String?
    ) -> String {
        let detail = fields
            .filter { $0.key != "subhead" }
            .map { "\($0.label.uppercased()):\n\(values.text($0.key, "(not provided)"))" }
            .joined(separator: "\n\n")
        let skeleton = present(template).map {
            " Draft to the platform's \"\($0)\" skeleton (load it via load_drafting_template with template set to \"\($0)\") and adapt it to the document type above."
        } ?? ""
        let forumFormat = values.raw("forum").flatMap { FORUM_FORMATS[$0] }.map { " \($0)" } ?? ""
        let body = present(instruction)
            ?? "Produce a complete, properly formatted draft with all mandatory components for this document type (caption/cause title, jurisdiction, party details, chronological facts with dates, grounds, prayer, and verification/affidavit as applicable)."
        return """
            The user has asked for: "\(documentType)" — a \(matter) matter, \(stage) stage, before the \(values.text("forum", "appropriate court/forum")) in India. If this names a formal document, draft it court-ready. If it instead asks for a summary, explanation, or analysis rather than a filing, produce that in the most appropriate format instead. \(codeNote)\(forumFormat)

            \(detail)

            \(body)\(skeleton) Use correct Indian court formatting and clearly marked [placeholders] for any missing specifics.
            """
    }

    /// A heading card's one line — `sectionDesc` (`pages/home/RoleCards.jsx`): its first three
    /// documents with their statutory references and anything after a dash taken off, and
    /// "& more" when there are others.
    ///
    /// The reference stripping is the platform's, quirks included: `/\([^)]*\)/g` takes a
    /// parenthesis up to its *first* closing bracket, so "(old 156(3))" leaves a stray ")" behind
    /// — and the web shows it. Matching it is the point; this summary is the web's own words.
    static func summary(of section: LitigatorSection) -> String {
        let names = section.items.map { cleanName($0.label) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return section.title }
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) & more" : shown
    }

    /// `l.replace(/\([^)]*\)/g, '').replace(/—.*$/, '').replace(/\s+/g, ' ').trim()`.
    static func cleanName(_ label: String) -> String {
        var scalars = Array(label.unicodeScalars)

        // Every `(` that has a `)` after it, up to and including the first such `)`.
        var stripped: [Unicode.Scalar] = []
        var index = 0
        while index < scalars.count {
            if scalars[index] == "(",
               let close = scalars[(index + 1)...].firstIndex(of: ")") {
                index = close + 1
            } else {
                stripped.append(scalars[index])
                index += 1
            }
        }
        scalars = stripped

        // The first em dash with no line break after it, and everything to the end. `.` does not
        // cross a line terminator and `$` is the end of the input.
        if let dash = scalars.indices.first(where: { position in
            scalars[position] == "\u{2014}"
                && !scalars[(position + 1)...].contains(where: JSText.isLineTerminator)
        }) {
            scalars.removeSubrange(dash...)
        }

        // Runs of whitespace become one space.
        var collapsed = String.UnicodeScalarView()
        var inSpace = false
        for scalar in scalars {
            if JSText.isSpace(scalar) {
                if !inSpace { collapsed.append(" ") }
                inSpace = true
            } else {
                collapsed.append(scalar)
                inSpace = false
            }
        }
        return JSText.trim(String(collapsed))
    }

    /// JavaScript's `||` on a string: present means present and non-empty.
    private static func present(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private extension LitigatorFormField.Kind {
    var toolFieldType: ToolFieldType {
        switch self {
        case .text: return .text
        case .textarea: return .textarea
        case .select, .forum: return .select
        }
    }
}

/// Whitespace as JavaScript's `\s` and `String.prototype.trim` define it, which is not quite
/// Foundation's: JavaScript counts U+FEFF and not U+0085. The platform's text is plain enough that
/// the two would agree today; the rules above are ports, so they use the platform's definition.
enum JSText {
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F,
             0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    static func isLineTerminator(_ scalar: Unicode.Scalar) -> Bool {
        [0x0A, 0x0D, 0x2028, 0x2029].contains(scalar.value)
    }

    static func trim(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
              let last = scalars.lastIndex(where: { !isSpace($0) })
        else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[first...last])
        return String(view)
    }
}
