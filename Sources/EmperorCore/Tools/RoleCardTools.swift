import Foundation

/// One card on a role's home grid.
///
/// The platform's Home is a deck of these, and each one resolves to a **synthetic tool** —
/// `registry.js` builds a form and a prompt from the card rather than holding a config per card.
/// So a card is data and the framing around it is a function of the role, which is exactly the
/// split kept here: `ROLE_CARDS` is generated from the platform's modules, and the six card
/// branches of `toolSpec` below are the ported resolvers. Litigator's branch hands over to the
/// drafting taxonomy (`LitigatorDrafting`), which is that role's Home instead of a deck.
///
/// The prompts are the feature. Every one of them is pinned by a golden fixture generated from
/// the platform's own JavaScript — see `RoleCardGoldenTests`.
struct RoleCard: Identifiable, Sendable {
    /// The card's own id, without the role prefix — `award-drafting`, not `adoc-award-drafting`.
    let id: String
    let role: PractitionerRole
    let title: String
    let subtitle: String?
    let section: String?
    let output: ToolOutput
    /// Legal Aid marks some cards as safety-first; the platform labels those rows differently.
    let isSafetyFirst: Bool
    /// Which of the role's filter values show this card — modes, tags, levels or contexts
    /// depending on the role. Every one of the platform's `select*` functions is the same
    /// `filter(c => c.<dimension>.includes(active))`, so one list covers all four.
    let filters: [String]
    let dropdown: [String]
    /// The instruction that makes this card what it is.
    ///
    /// Empty for every Corporate card, and that is the platform's own shape rather than missing
    /// data: `resolveCorpTool` builds its prompt from the title, the section and the chosen
    /// document type, and never reads a note. All 48 other cards carry one.
    let note: String

    /// The id the tool is reached by, which is the platform's `<prefix><cardId>`.
    var toolID: String { "\(Self.prefix(for: role))\(id)" }

    /// Prefixes are the platform's own and are not interchangeable — `getTool` dispatches on
    /// them, and Senior Counsel's is six characters where the rest are five.
    static func prefix(for role: PractitionerRole) -> String {
        switch role {
        case .seniorCounsel: return "scdoc-"
        case .adjudicator: return "adoc-"
        case .corporateCounsel: return "cdoc-"
        case .student: return "sdoc-"
        case .paralegal: return "pdoc-"
        case .legalAid: return "ndoc-"
        case .litigator: return "ldoc-"
        }
    }

    private var isResearch: Bool { output == .research }
}

/// One option on a card grid's filter — a mode, a tag, a level or a context.
struct RoleCardFilter: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
}

extension RoleCard {
    /// The synthetic tool this card resolves to.
    ///
    /// Ported branch for branch from `registry.js`. The role framing around `note` is not
    /// decoration: it carries the guardrail — a paralegal's output is labelled a draft for
    /// advocate review and refuses independent advice, a student's teaches rather than
    /// ghostwrites, legal aid anonymises. Dropping a sentence here would quietly remove one.
    var toolSpec: ToolSpec {
        switch role {
        case .seniorCounsel: return counselSpec
        case .adjudicator: return adjudicatorSpec
        case .corporateCounsel: return corporateSpec
        case .student: return studentSpec
        case .paralegal: return paralegalSpec
        case .legalAid: return legalAidSpec
        case .litigator: return litigatorSpec
        }
    }

    /// The platform shows the first four dropdown entries as a card's blurb.
    private var dropdownBlurb: String {
        dropdown.isEmpty ? title : dropdown.prefix(4).joined(separator: " · ")
    }

    private var chooseFrom: String { "Choose from \(title)…" }

    // MARK: - Senior Counsel

    private var counselSpec: ToolSpec {
        ToolSpec(
            id: toolID, title: title, short: "Chambers", blurb: dropdownBlurb, output: output,
            inputs: [
                ToolField(key: "task", label: "What do you need", type: .select,
                          placeholder: chooseFrom, options: dropdown),
                ToolField(key: "matter", label: "Matter / parties", type: .text,
                          placeholder: "e.g. Sterling Infra Pvt. Ltd. v. NHAI (optional)"),
                ToolField(key: "material", label: "Facts, brief or question", type: .textarea,
                          placeholder: "Set out the facts and the question — or attach the brief above and summarise what you need.",
                          big: true),
            ],
            build: { v, _ in
                let matter = v.has("matter") ? " in \(v.text("matter", ""))" : ""
                return """
                As senior counsel, prepare: "\(v.text("task", title))" (\(title))\(matter).

                \(note) Write in the measured register of senior counsel. Cite authorities with their current standing [Settled] / [Doubted] / [Overruled] / [Pending]; do not fabricate a citation — a candid gap is preferable. Where the answer turns on the client's instructions or on a matter for the court's discretion, flag it with a bracketed note.

                FACTS / BRIEF / QUESTION:
                \(v.text("material", "(none typed — work from the attached brief, or state what is needed)"))
                """
            })
    }

    // MARK: - Litigator

    /// Litigator has no deck — its documents are the drafting taxonomy — but its prefix is
    /// `ldoc-`, and `getTool` sends every `ldoc-` id to `resolveDraftTool`. So a card carrying it
    /// resolves exactly as that id does on the web, through `LitigatorDrafting`.
    ///
    /// One the taxonomy does not hold gets the shape every Litigator document is sent in —
    /// `buildSectionPrompt`, with the generic fields, the civil code note and the default drafting
    /// instruction — because that, and not Senior Counsel's chambers voice, is what the web sends
    /// for a Litigator. No such card exists today; `LitigatorWorkspaceTests` pins both paths.
    private var litigatorSpec: ToolSpec {
        if let resolved = LitigatorDrafting.documentTool(toolID) { return resolved }
        return LitigatorDrafting.documentTool(
            id: toolID, matter: "civil",
            item: LitigatorItem(id: id, label: title, note: subtitle),
            section: LitigatorSection(key: "", title: section ?? title, items: []),
            area: nil)
    }

    // MARK: - Arbitrators and Judges

    private var adjudicatorSpec: ToolSpec {
        // Formatting the adjudicator's *own* text is a different question from drafting from a
        // record, and the platform asks for it differently.
        let isFormatting = id == "judgment-formatting"
        let recordLabel = isFormatting ? "Your own draft text" : "Case record / material"
        let recordPlaceholder: String
        if isFormatting {
            recordPlaceholder = "Paste the draft judgment/order text you have authored…"
        } else if output == .research {
            recordPlaceholder = "Paste the relevant record, authorities cited, or the point to research…"
        } else {
            recordPlaceholder = "Paste the pleadings, depositions, submissions or record this should draw on…"
        }
        // An award and its costs come from a tribunal; everything else from a court.
        let forum = (section == "Award & Adjudicatory Drafting" || section == "Costs & Interest")
            ? "arbitral tribunal" : "court / tribunal"
        let closing = output == .research
            ? "analysis with real, verifiable citations" : "output"

        return ToolSpec(
            id: toolID, title: title, short: section ?? title,
            blurb: subtitle ?? section ?? title, output: output,
            inputs: [
                ToolField(key: "task", label: "What to produce", type: .select,
                          placeholder: chooseFrom, options: dropdown),
                ToolField(key: "title", label: "Case / matter title", type: .text,
                          placeholder: "e.g. Sterling Infra Pvt. Ltd. v. NHAI (optional)"),
                ToolField(key: "record", label: recordLabel, type: .textarea,
                          placeholder: recordPlaceholder, big: true),
            ],
            build: { v, _ in
                let named = v.has("title") ? " — \(v.text("title", ""))" : ""
                return """
                Task: "\(v.text("task", title))" (\(title)\(named)), for an Indian \(forum).

                \(note)

                CASE RECORD / MATERIAL:
                \(v.text("record", "(none provided)"))

                Produce a clear, neutral, well-structured and professionally formatted \(closing). Use [bracketed placeholders] for anything not supplied.
                """
            })
    }

    // MARK: - Corporate Counsel

    private var corporateSpec: ToolSpec {
        ToolSpec(
            id: toolID, title: title, short: section ?? title,
            blurb: subtitle ?? section ?? title, output: .document,
            inputs: [
                ToolField(key: "docType", label: "Document type", type: .select,
                          options: dropdown),
                ToolField(key: "parties", label: "Parties / entities", type: .text,
                          placeholder: "e.g. Helios Renewables Pvt. Ltd. and Meridian Capital LLP"),
                ToolField(key: "details", label: "Key details & instructions", type: .textarea,
                          placeholder: "Scope, commercial terms, special clauses, background…",
                          big: true),
            ],
            build: { v, _ in
                """
                Draft a "\(v.text("docType", title))" (\(section ?? title)) governed by Indian law. Incorporate the details below plus the standard protective clauses appropriate to this document type. Produce a complete, well-structured draft with clear [placeholders] for any missing specifics.

                PARTIES / ENTITIES: \(v.text("parties", "[Party A] and [Party B]"))

                KEY DETAILS:
                \(v.text("details", "(none provided)"))
                """
            })
    }

    // MARK: - Paralegal

    private var paralegalSpec: ToolSpec {
        let isResearch = output == .research
        let detailsLabel = isResearch ? "Material / question" : "Details & instructions"
        let detailsPlaceholder = isResearch
            ? "Paste the material to review, or state the point to look up…"
            : "Names, dates, particulars, and any specifics to include…"
        let closing = isResearch
            ? "research note with real, verifiable citations and good-law flags" : "draft"

        return ToolSpec(
            id: toolID, title: title, short: "Paralegal", blurb: dropdownBlurb, output: output,
            inputs: [
                ToolField(key: "task", label: "Task / template", type: .select,
                          placeholder: chooseFrom, options: dropdown),
                ToolField(key: "title", label: "Matter / party details", type: .text,
                          placeholder: "e.g. Sterling Infra Pvt. Ltd. v. NHAI — Delhi High Court (optional)"),
                ToolField(key: "details", label: detailsLabel, type: .textarea,
                          placeholder: detailsPlaceholder, big: true),
            ],
            build: { v, _ in
                let named = v.has("title") ? " — \(v.text("title", ""))" : ""
                return """
                Prepare, as a paralegal supporting an advocate, the following: "\(v.text("task", title))" (\(title)\(named)).

                Begin the output with the label line "**Draft for advocate review**". \(note) Do NOT give independent legal advice or conclusions — where legal judgement is required, insert "[for supervising advocate to confirm]".

                DETAILS / MATERIAL:
                \(v.text("details", "(none provided)"))

                Produce a clear, well-structured, professionally formatted \(closing). Use [bracketed placeholders] for anything not supplied.
                """
            })
    }

    // MARK: - Student and Academic

    private var studentSpec: ToolSpec {
        ToolSpec(
            id: toolID, title: title, short: "Study", blurb: dropdownBlurb, output: output,
            inputs: [
                ToolField(key: "activity", label: "Activity", type: .select,
                          placeholder: chooseFrom, options: dropdown),
                ToolField(key: "topic", label: "Topic / case / question", type: .text,
                          placeholder: "e.g. doctrine of frustration; Kesavananda Bharati; my moot proposition…"),
                ToolField(key: "material", label: "Your draft / material (optional)",
                          type: .textarea,
                          placeholder: "Paste your draft to critique, the case to brief, or extra context. Leave blank to just be taught.",
                          big: true),
            ],
            build: { v, _ in
                let topic = v.has("topic") ? " on: \(v.text("topic", ""))" : ""
                let material = v.has("material")
                    ? "STUDENT'S DRAFT / MATERIAL:\n\(v.text("material", ""))"
                    : "(No draft supplied — teach the topic and invite the student to attempt.)"
                return """
                Act as a law tutor helping a student with: "\(v.text("activity", title))" (\(title))\(topic).

                \(note) Teach and guide rather than doing the work for the student: explain your reasoning, cite real sources so the student can verify, and where you produce any model/example work, label it clearly as a "Study example" and end with a short "Now try your own" prompt.

                \(material)
                """
            })
    }

    // MARK: - Legal Aid and NGO

    private var legalAidSpec: ToolSpec {
        let closing = output == .research
            ? "research note with real citations (flag good-law status for the lawyer)" : "draft"

        return ToolSpec(
            id: toolID, title: title,
            short: isSafetyFirst ? "Safety First" : (section ?? title),
            blurb: subtitle ?? section ?? title, output: output,
            inputs: [
                ToolField(key: "task", label: "What do you need", type: .select,
                          placeholder: chooseFrom, options: dropdown),
                ToolField(key: "details", label: "Details / situation", type: .textarea,
                          placeholder: "Describe the situation, the person's needs and any facts / dates. Do not include names of vulnerable persons — use initials.",
                          big: true),
                ToolField(key: "language", label: "Language", type: .select,
                          options: ["English", "Hindi", "Regional (specify in details)"]),
                ToolField(key: "reading", label: "Reading level", type: .select,
                          options: ["Plain (simple, no jargon)", "Standard"]),
            ],
            build: { v, _ in
                """
                As a legal-aid / NGO assistant, prepare: "\(v.text("task", title))" (\(title)).

                \(note) Write in \(v.text("language", "English")) at a \(v.text("reading", "Plain (simple, no jargon)")) reading level. Anonymise any vulnerable-beneficiary personal data (use initials / [placeholders]).

                DETAILS / SITUATION:
                \(v.text("details", "(none provided)"))

                Produce a clear, accessible \(closing) and begin it with the label line "**Draft — for advocate / DLSA review**".
                """
            })
    }
}

// MARK: - Looking cards up

extension PractitionerRole {
    /// This role's cards, in the platform's order. Empty for Litigator, whose workspace is the
    /// drafting taxonomy instead — see `usesDraftingTaxonomy`.
    var cards: [RoleCard] { ROLE_CARDS.filter { $0.role == self } }

    /// Whether "Your workspace" is the drafting taxonomy rather than a card deck.
    ///
    /// Litigator alone: on the web it is the one role with `matters` and no `cardSet`
    /// (`roleConfig.js`), and its Home is a matter chooser over `litigatorDrafting.js`.
    var usesDraftingTaxonomy: Bool { self == .litigator }

    /// The filter this role's grid offers — modes, tags, levels or contexts. Empty where the
    /// grid is flat, which is Senior Counsel alone.
    var cardFilters: [RoleCardFilter] { ROLE_CARD_FILTERS[self] ?? [] }

    /// Section order for the grids that are grouped.
    var cardSections: [String] { ROLE_CARD_SECTIONS[self] ?? [] }

    /// The cards shown for a filter value.
    ///
    /// For Arbitrators & Judges this is **a compliance boundary, not a preference**: a judge is
    /// offered strictly assistive work and no award, order or judgment drafting, and an
    /// arbitrator is not offered judgment formatting. The platform's own comment says so, and
    /// `RoleCardGoldenTests` pins both lists.
    func cards(matching filterID: String?) -> [RoleCard] {
        guard let filterID, !cardFilters.isEmpty else { return cards }
        return cards.filter { $0.filters.contains(filterID) }
    }
}

/// A card by the id a route carries, which is the prefixed form.
func roleCard(_ toolID: String) -> RoleCard? {
    ROLE_CARDS.first { $0.toolID == toolID }
}

/// The tool a workspace route names — a role card's, or a Litigator document's or heading form's.
///
/// One lookup for every role's workspace, dispatching on the prefix the way `getTool` does
/// (`registry.js:853`): `ldoc-` and `lsec-` go to the drafting taxonomy, and everything else is
/// a card.
func roleTool(_ toolID: String) -> ToolSpec? {
    if let drafting = LitigatorDrafting.tool(toolID) { return drafting }
    return roleCard(toolID)?.toolSpec
}
