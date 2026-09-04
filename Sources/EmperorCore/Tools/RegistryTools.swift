import Foundation

/*
 * The platform's drafting and research tools, ported from its registry.
 *
 * Generated from `emperor-ai/src/tools/registry.js`: the metadata by evaluating the module under
 * Node, the prompts by extracting the template literals. Neither was retyped. Every one is pinned
 * against the platform's own output by a fixture in `ToolGoldenTests`.
 */

/// Forum-specific formatting guidance, appended to a draft when a forum is chosen so the
/// cause-title, synopsis order, index and filing conventions match it.
let FORUM_FORMATS: [String: String] = [
    "Supreme Court of India":
        #"Format to the Supreme Court Rules, 2013: cause-title "IN THE SUPREME COURT OF INDIA", the correct jurisdiction (Civil/Criminal Appellate or Art. 32), a Synopsis & List of Dates before the petition, and the paperbook index and pagination."#,
    "High Court":
        #"Format to the relevant High Court rules (e.g. Delhi HC / Bombay HC Original or Appellate Side): the correct cause-title and bench, a synopsis & list of dates for writs, the index, and that Court's court-fee and e-filing conventions."#,
    "District Court":
        #"Format to the CPC and the local civil rules: cause-title with the court and district, valuation and court fee, and the standard index and verification."#,
    "NCLT":
        #"Format to the NCLT Rules, 2016 and the applicable form (e.g. NCLT-1 with the prescribed annexures), the correct Bench, and the statutory fee."#,
    "NCLAT":
        #"Format to the NCLAT Rules, 2016: the memorandum of appeal, the impugned order, limitation and the certificate / annexures."#,
    "NCDRC / Consumer":
        #"Format to the Consumer Protection Act, 2019 and the Commission rules: the correct pecuniary / territorial forum, the complaint format and the supporting affidavit."#,
    "Arbitral Tribunal":
        #"Format to the arbitration agreement and the applicable rules (ad-hoc under the A&C Act, 1996, or institutional — SIAC / ICC / MCIA / DIAC): headings, the seat, and the procedural-order framework."#,
    "Other Tribunal":
        #"Format to the constituting statute and that tribunal's rules and prescribed forms."#,
]

/// Research & Authorities — Precedents & statutes.
let ResearchTool = ToolSpec(
    id: "research",
    title: "Research & Authorities",
    short: "Precedents & statutes",
    blurb: "Find binding precedents, statutory provisions and their current status.",
    output: .research,
    inputs: [
        ToolField(
            key: "question",
            label: "Research question",
            type: .textarea,
            placeholder: "e.g. Limitation period for a suit for specific performance of an agreement to sell immovable property?"
        ),
        ToolField(
            key: "forum",
            label: "Court / forum",
            type: .select,
            options: FORUMS
        ),
        ToolField(
            key: "depth",
            label: "Depth",
            type: .select,
            options: [
                "Quick answer",
                "Standard",
                "Exhaustive with history",
            ]
        ),
    ],
    build: buildResearch
)

func buildResearch(_ v: ToolValues, _ today: Date) -> String {
    return """
Conduct focused Indian legal research and return a structured answer with citations.

RESEARCH QUESTION:
\(v.text("question", "(unspecified)"))

Forum context: \(v.text("forum", "General"))
Depth: \(v.text("depth", "Standard"))

Return:
1. A concise direct answer (≤200 words).
2. Governing statutory provisions (with section numbers).
3. Key precedents — case name, citation, court, year, and the ratio in one line. Mark each as [Settled], [Pending/appealed], or [Overruled].
4. Any conflicting High Court views or open questions.
Cite only real, verifiable authorities. Flag anything uncertain.
"""
}

/// Custom Document — Draft anything.
let CustomDocumentTool = ToolSpec(
    id: "custom-document",
    title: "Custom Document",
    short: "Draft anything",
    blurb: "Draft any legal document from your own instructions.",
    output: .document,
    inputs: [
        ToolField(
            key: "docType",
            label: "Document type / title",
            type: .text,
            placeholder: "e.g. Legal Notice, MoU, Affidavit, Undertaking…"
        ),
        ToolField(
            key: "instructions",
            label: "Instructions & details",
            type: .textarea,
            placeholder: "Describe what the document should contain — parties, key terms, tone, clauses to include…",
            big: true
        ),
    ],
    build: buildCustomDocument
)

func buildCustomDocument(_ v: ToolValues, _ today: Date) -> String {
    return """
Draft a "\(v.text("docType", "legal document"))" based on the instructions below, following standard Indian legal drafting conventions and formatting. Use clearly marked [placeholders] for any specifics not provided.

INSTRUCTIONS:
\(v.text("instructions", "(none)"))
"""
}

/// Pleadings & Petitions — Court-ready drafts.
let DraftPleadingTool = ToolSpec(
    id: "draft-pleading",
    title: "Pleadings & Petitions",
    short: "Court-ready drafts",
    blurb: "Generate a court-ready pleading with caption, facts, grounds, prayer and verification.",
    output: .document,
    inputs: [
        ToolField(
            key: "docType",
            label: "Document type",
            type: .select,
            options: [
                "Writ Petition",
                "Civil Suit / Plaint",
                "Written Statement",
                "Bail Application",
                "Appeal",
                "Legal Notice",
                "Interim Application",
                "Petition (Other)",
            ]
        ),
        ToolField(
            key: "forum",
            label: "Court / forum",
            type: .select,
            options: FORUMS
        ),
        ToolField(
            key: "parties",
            label: "Parties",
            type: .text,
            placeholder: "Parties & their status"
        ),
        ToolField(
            key: "facts",
            label: "Facts & background",
            type: .textarea,
            placeholder: "Facts, dates, cause of action",
            big: true
        ),
        ToolField(
            key: "relief",
            label: "Relief sought",
            type: .textarea,
            placeholder: "Reliefs / orders sought"
        ),
    ],
    build: buildDraftPleading
)

func buildDraftPleading(_ v: ToolValues, _ today: Date) -> String {
    let forumBlock = v.raw("forum").flatMap { FORUM_FORMATS[$0] }.map { " \($0)" } ?? ""

    return """
Draft a court-ready \(v.text("docType", "pleading")) for filing before the \(v.text("forum", "appropriate court")) in India.

PARTIES: \(v.text("parties", "(to be completed)"))

FACTS & BACKGROUND:
\(v.text("facts", "(none provided)"))

RELIEF SOUGHT:
\(v.text("relief", "(frame appropriate reliefs)"))

Produce a complete, properly structured draft in the format best suited to this document and forum. Use your own judgment on the exact structure; for a filing of this kind that will typically include a cause title/caption, jurisdiction paragraph, party details, chronological statement of facts with dates, grounds, limitation compliance, non-filing declaration, prayer for relief, and verification/affidavit blocks — but add, merge, reorder or omit parts as the matter genuinely requires rather than forcing every item.\(forumBlock) Use correct Indian court formatting and leave clearly marked [placeholders] where specific data is missing.
"""
}

/// Settle a Draft — Errors, gaps, fixes.
let DraftReviewTool = ToolSpec(
    id: "draft-review",
    title: "Settle a Draft",
    short: "Errors, gaps, fixes",
    blurb: "Mark up a draft as a senior would — errors, missing components, sharper language.",
    output: .research,
    inputs: [
        ToolField(
            key: "draft",
            label: "Paste the draft to review",
            type: .textarea,
            placeholder: "Paste the pleading/contract text here…",
            big: true
        ),
        ToolField(
            key: "focus",
            label: "Review focus",
            type: .select,
            options: [
                "Full review",
                "Legal soundness",
                "Formatting & compliance",
                "Persuasiveness",
            ]
        ),
    ],
    build: buildDraftReview
)

func buildDraftReview(_ v: ToolValues, _ today: Date) -> String {
    return """
Review the following legal draft (\(v.text("focus", "Full review"))). Identify errors, missing mandatory components, weak arguments, formatting/compliance issues, and concrete improvements. Organise findings by severity (Critical / Important / Minor) with specific fixes.

DRAFT:
\(v.text("draft", "(none)"))
"""
}

/// Brief Analysis — Summarise pleadings.
let CaseGistTool = ToolSpec(
    id: "case-gist",
    title: "Brief Analysis",
    short: "Summarise pleadings",
    blurb: "Turn pleadings into a structured brief: facts, issues, both sides, chronology.",
    output: .document,
    inputs: [
        ToolField(
            key: "material",
            label: "Pleadings / case material",
            type: .textarea,
            placeholder: "Paste the pleadings or case documents…",
            big: true
        ),
        ToolField(
            key: "title",
            label: "Case title",
            type: .text,
            placeholder: "e.g. Sterling Infra Pvt. Ltd. v. NHAI"
        ),
    ],
    build: buildCaseGist
)

func buildCaseGist(_ v: ToolValues, _ today: Date) -> String {
    let titleBlock: String
    if v.has("title") {
        titleBlock = " for \(v.text("title", ""))"
    } else {
        titleBlock = ""
    }

    return """
Prepare a structured case gist\(titleBlock) from the material below. Cover: (1) parties, (2) material facts in chronology, (3) each side's positions, (4) issues framed, (5) reliefs claimed, (6) current status. Keep it neutral and precise.

MATERIAL:
\(v.text("material", "(none)"))
"""
}

/// Written Submissions — Argument notes.
let ArgumentsTool = ToolSpec(
    id: "arguments",
    title: "Written Submissions",
    short: "Argument notes",
    blurb: "Draft written submissions — propositions, authorities and pre-empted rebuttals.",
    output: .document,
    inputs: [
        ToolField(
            key: "side",
            label: "Arguing for",
            type: .text,
            placeholder: "e.g. the Petitioner"
        ),
        ToolField(
            key: "issues",
            label: "Issues / propositions",
            type: .textarea,
            placeholder: "List the legal issues or propositions to argue…"
        ),
        ToolField(
            key: "facts",
            label: "Relevant facts",
            type: .textarea,
            placeholder: "Key facts the arguments rest on…"
        ),
    ],
    build: buildArguments
)

func buildArguments(_ v: ToolValues, _ today: Date) -> String {
    return """
Draft a structured argument note on behalf of \(v.text("side", "the client")). For each issue: state the proposition, the supporting legal reasoning, and the strongest precedent (case name, citation, ratio). Anticipate and pre-empt the opponent's likely counter-arguments.

ISSUES / PROPOSITIONS:
\(v.text("issues", "(none)"))

RELEVANT FACTS:
\(v.text("facts", "(none)"))
"""
}

/// Clause & Risk Extraction — Key contract clauses.
let ClauseExtractTool = ToolSpec(
    id: "clause-extract",
    title: "Clause & Risk Extraction",
    short: "Key contract clauses",
    blurb: "Identify and analyse important clauses in a contract.",
    output: .research,
    inputs: [
        ToolField(
            key: "contract",
            label: "Contract text",
            type: .textarea,
            placeholder: "Paste the contract…",
            big: true
        ),
    ],
    build: buildClauseExtract
)

func buildClauseExtract(_ v: ToolValues, _ today: Date) -> String {
    return """
Extract and analyse the key clauses in the contract below — indemnity, limitation of liability, termination, force majeure, dispute resolution, confidentiality, non-compete, governing law. For each: quote the clause, explain its effect, and flag any risk or ambiguity.

CONTRACT:
\(v.text("contract", "(none)"))
"""
}

/// Work from my Brief — Grounded in your record.
let BriefWorkupTool = ToolSpec(
    id: "brief-workup",
    title: "Work from my Brief",
    short: "Grounded in your record",
    blurb: "Drop your brief or paperbook — get a synopsis, list of dates, chronology, issues and more, grounded in your own record.",
    output: .document,
    inputs: [
        ToolField(
            key: "deliverable",
            label: "What do you need",
            type: .select,
            options: [
                "Synopsis & List of Dates",
                "Chronology / List of Events",
                "Issues / Points for Determination",
                "Contradictions in the Evidence",
                "Cross-examination Points",
                "Merits & Strategy Note",
                "Full Work-up (all of the above)",
            ]
        ),
        ToolField(
            key: "matter",
            label: "Matter title",
            type: .text,
            placeholder: "e.g. Sterling Infra Pvt. Ltd. v. NHAI (optional)"
        ),
        ToolField(
            key: "focus",
            label: "Focus / instructions",
            type: .textarea,
            placeholder: "Any specific issue, party, witness or period to focus on… (optional)"
        ),
    ],
    build: buildBriefWorkup
)

func buildBriefWorkup(_ v: ToolValues, _ today: Date) -> String {
    let focusBlock: String
    if v.has("focus") {
        focusBlock = """
Focus / instructions: \(v.text("focus", ""))

"""
    } else {
        focusBlock = ""
    }

    return """
You are working from the ADVOCATE'S OWN BRIEF — the documents attached to this request (the paperbook / record: pleadings, orders, depositions, exhibits, correspondence). Base everything STRICTLY on that attached record. Do not invent facts, dates, witnesses or documents. Wherever you state a fact, pin-cite it to its source in the record (page / paragraph / exhibit / document name). If a document you need does not appear to be attached, say so plainly and ask for it rather than guessing.

Matter: \(v.text("matter", "[as per the attached record]")).
\(focusBlock)Produce: \(v.text("deliverable", "Full Work-up (all of the above)")).

Use the correct format for the chosen deliverable:
- "Synopsis & List of Dates": a concise narrative SYNOPSIS of the matter, then a two-column LIST OF DATES (Date | Event) in chronological order, each event pin-cited to the record.
- "Chronology / List of Events": a dated chronology of every material event, pin-cited.
- "Issues / Points for Determination": the precise questions of fact and law arising on the record, numbered, noting the party on whom the onus lies.
- "Contradictions in the Evidence": witness-wise and document-wise contradictions, omissions and improvements, each cross-referenced to the specific deposition / exhibit.
- "Cross-examination Points": lines of cross for each key witness — short, single-fact leading questions grouped by theme, tied to the prior statements / documents to confront the witness with.
- "Merits & Strategy Note": a candid assessment — prospects, correct forum, reliefs and their likelihood, limitation, interim strategy (prima facie case / balance of convenience / irreparable injury), key risks, and settlement leverage — grounded in the record.
- "Full Work-up (all of the above)": produce each of the above in turn, under clear headings.

Work only from what is attached; where the record is incomplete, flag the gaps rather than filling them.
"""
}

/// Contract Risk & Position — Risk scoring.
let ContractAnalysisTool = ToolSpec(
    id: "contract-analysis",
    title: "Contract Risk & Position",
    short: "Risk scoring",
    blurb: "Flag each clause’s risk and your negotiating position, with recommended language.",
    output: .riskReport,
    inputs: [
        ToolField(
            key: "contract",
            label: "Contract text",
            type: .textarea,
            placeholder: "Paste the contract to analyse…",
            big: true
        ),
        ToolField(
            key: "party",
            label: "Reviewing on behalf of",
            type: .text,
            placeholder: "e.g. the Buyer"
        ),
    ],
    build: buildContractAnalysis
)

func buildContractAnalysis(_ v: ToolValues, _ today: Date) -> String {
    return """
Analyse the contract below on behalf of \(v.text("party", "our client")). For each material clause return: clause name, a risk score from 1 (safe) to 10 (severe), the specific vulnerability, and suggested protective language. End with an overall risk rating and the top 3 priorities. Present the per-clause findings as a Markdown table with columns: Clause | Risk (1-10) | Issue | Suggested fix.

CONTRACT:
\(v.text("contract", "(none)"))
"""
}

/// Due Diligence — DD lists & reports.
let DueDiligenceTool = ToolSpec(
    id: "due-diligence",
    title: "Due Diligence",
    short: "DD lists & reports",
    blurb: "DD request lists, checklists, red-flag reports and DD summaries.",
    output: .research,
    inputs: [
        ToolField(
            key: "target",
            label: "Target / transaction",
            type: .text,
            placeholder: "e.g. Acquisition of 100% equity in Helios Renewables Pvt. Ltd."
        ),
        ToolField(
            key: "deliverable",
            label: "Deliverable",
            type: .select,
            options: [
                "DD request list",
                "Legal DD checklist",
                "Red-flag report",
                "DD summary report",
            ]
        ),
        ToolField(
            key: "scope",
            label: "Scope / focus areas",
            type: .textarea,
            placeholder: "Corporate, material contracts, litigation, IP, employment, tax, regulatory, property…"
        ),
    ],
    build: buildDueDiligence
)

func buildDueDiligence(_ v: ToolValues, _ today: Date) -> String {
    return """
Prepare the requested legal due-diligence deliverable (\(v.text("deliverable", "Legal DD checklist"))) for: \(v.text("target", "(target/transaction)")).

SCOPE / FOCUS AREAS:
\(v.text("scope", "Corporate & constitutional, material contracts, litigation & disputes, IP, employment & HR, tax, regulatory & licences, property, financing & security."))

Present a clear, structured checklist/report organised by area, and flag high-risk / red-flag items with the reason and suggested action.
"""
}

/// Draft Contract — Commercial agreements.
let DraftContractTool = ToolSpec(
    id: "draft-contract",
    title: "Draft Contract",
    short: "Commercial agreements",
    blurb: "Draft NDAs, MSAs, service and commercial agreements.",
    output: .document,
    inputs: [
        ToolField(
            key: "ctype",
            label: "Agreement type",
            type: .select,
            options: [
                "NDA",
                "Master Services Agreement",
                "Service Agreement",
                "Supply Agreement",
                "Licensing Agreement",
                "Employment Agreement",
                "Shareholders Agreement",
                "Other",
            ]
        ),
        ToolField(
            key: "parties",
            label: "Parties",
            type: .text,
            placeholder: "e.g. Helios Renewables Pvt. Ltd. and Meridian Capital LLP"
        ),
        ToolField(
            key: "terms",
            label: "Key commercial terms",
            type: .textarea,
            placeholder: "Scope, consideration, term, special conditions…"
        ),
    ],
    build: buildDraftContract
)

func buildDraftContract(_ v: ToolValues, _ today: Date) -> String {
    return """
Draft a \(v.text("ctype", "commercial agreement")) between \(v.text("parties", "[Party A] and [Party B]")) governed by Indian law. Incorporate the commercial terms below plus standard protective clauses (indemnity, limitation of liability, confidentiality, termination, dispute resolution, governing law). Produce a complete, well-structured draft with clear [placeholders] for missing specifics.

KEY TERMS:
\(v.text("terms", "(none)"))
"""
}

/// Board & Secretarial — Resolutions & notices.
let BoardResolutionTool = ToolSpec(
    id: "board-resolution",
    title: "Board & Secretarial",
    short: "Resolutions & notices",
    blurb: "Board resolutions, meeting packs, AGM/EGM notices.",
    output: .document,
    inputs: [
        ToolField(
            key: "action",
            label: "Corporate action",
            type: .textarea,
            placeholder: "e.g. Approve appointment of Mr. X as Additional Director w.e.f. 01.08.2026"
        ),
        ToolField(
            key: "company",
            label: "Company name",
            type: .text,
            placeholder: "e.g. Helios Renewables Private Limited"
        ),
    ],
    build: buildBoardResolution
)

func buildBoardResolution(_ v: ToolValues, _ today: Date) -> String {
    return """
Draft the board/secretarial document(s) required for the following corporate action for \(v.text("company", "[Company]")), compliant with the Companies Act, 2013. Include the resolution text, relevant recitals, and any required explanatory statement.

ACTION:
\(v.text("action", "(none)"))
"""
}

/// Corporate Calendar — Filing deadlines.
let ComplianceCalendarTool = ToolSpec(
    id: "compliance-calendar",
    title: "Corporate Calendar",
    short: "Filing deadlines",
    blurb: "Year-round MCA/SEBI/Companies Act compliance calendar.",
    output: .document,
    inputs: [
        ToolField(
            key: "entity",
            label: "Entity type",
            type: .select,
            options: [
                "Private Limited",
                "Public Limited",
                "Listed Company",
                "LLP",
                "One Person Company",
            ]
        ),
        ToolField(
            key: "year",
            label: "Financial year",
            type: .text,
            placeholder: "e.g. FY 2026-27"
        ),
    ],
    build: buildComplianceCalendar
)

func buildComplianceCalendar(_ v: ToolValues, _ today: Date) -> String {
    return """
Generate an annual statutory compliance calendar for a \(v.text("entity", "Private Limited company")) in India for \(v.text("year", "the current financial year")). Present as a Markdown table: Due date | Compliance | Form/Filing | Authority | Consequence of default. Cover MCA/ROC, Companies Act, and (if listed) SEBI LODR obligations.
"""
}

/// Case Comparison — Side-by-side.
let CaseComparisonTool = ToolSpec(
    id: "case-comparison",
    title: "Case Comparison",
    short: "Side-by-side",
    blurb: "Compare two or more judgments side by side.",
    output: .comparison,
    inputs: [
        ToolField(
            key: "cases",
            label: "Cases to compare",
            type: .textarea,
            placeholder: "Name the judgments (or paste them) to compare…",
            big: true
        ),
        ToolField(
            key: "question",
            label: "Point of comparison",
            type: .text,
            placeholder: "e.g. Test for grant of interim injunction"
        ),
    ],
    build: buildCaseComparison
)

func buildCaseComparison(_ v: ToolValues, _ today: Date) -> String {
    let questionBlock: String
    if v.has("question") {
        questionBlock = " on: \(v.text("question", ""))"
    } else {
        questionBlock = ""
    }

    return """
Compare the following judgments side by side\(questionBlock). Return a Markdown table with rows for: Case name, Citation, Court, Year, Key facts, Legal issue, Ratio decidendi, Disposition, Subsequent treatment. Then note the key similarities, divergences, and which is binding.

CASES:
\(v.text("cases", "(none)"))
"""
}

/// Draft Judgment / Award — Structured judgment.
let DraftJudgmentTool = ToolSpec(
    id: "draft-judgment",
    title: "Draft Judgment / Award",
    short: "Structured judgment",
    blurb: "Draft a structured judgment or arbitral award.",
    output: .document,
    inputs: [
        ToolField(
            key: "record",
            label: "Case record / submissions",
            type: .textarea,
            placeholder: "Paste the case record, pleadings and submissions…",
            big: true
        ),
        ToolField(
            key: "kind",
            label: "Type",
            type: .select,
            options: [
                "Judgment",
                "Arbitral Award",
                "Order",
            ]
        ),
    ],
    build: buildDraftJudgment
)

func buildDraftJudgment(_ v: ToolValues, _ today: Date) -> String {
    return """
Draft a structured \(v.text("kind", "judgment")) from the record below, with sections: (1) Introduction & parties, (2) Facts, (3) Issues, (4) Submissions of each side, (5) Analysis & reasoning with authorities, (6) Findings issue-wise, (7) Operative order/relief. Maintain a neutral, judicial tone and correct formatting.

RECORD:
\(v.text("record", "(none)"))
"""
}

/// Order / Bench Memo — Procedural order.
let BenchNoteTool = ToolSpec(
    id: "bench-note",
    title: "Order / Bench Memo",
    short: "Procedural order",
    blurb: "Draft the next procedural or substantive order.",
    output: .document,
    inputs: [
        ToolField(
            key: "context",
            label: "Last order & submissions",
            type: .textarea,
            placeholder: "Paste the last order and what happened since…",
            big: true
        ),
    ],
    build: buildBenchNote
)

func buildBenchNote(_ v: ToolValues, _ today: Date) -> String {
    return """
Based on the last order and submissions below, draft the next order for the court, with proper cause title, the recording of appearances/submissions, the court's reasoning, and clear directions with timelines.

CONTEXT:
\(v.text("context", "(none)"))
"""
}

/// Law Evolution Timeline — How a law evolved.
let LawTimelineTool = ToolSpec(
    id: "law-timeline",
    title: "Law Evolution Timeline",
    short: "How a law evolved",
    blurb: "Trace a law from origin through amendments and landmark cases.",
    output: .timeline,
    inputs: [
        ToolField(
            key: "topic",
            label: "Statute / provision / doctrine",
            type: .text,
            placeholder: "e.g. Article 21 — right to life and personal liberty"
        ),
    ],
    build: buildLawTimeline
)

func buildLawTimeline(_ v: ToolValues, _ today: Date) -> String {
    return """
Build a chronological evolution timeline for: \(v.text("topic", "(unspecified)")). Return the timeline as a Markdown ordered list where each entry is "YEAR — event: description". Cover enactment/origin, key amendments (with the amending instrument), landmark judgments that shaped it, and current status / pending reform. Add the socio-political context briefly where relevant.
"""
}

/// Case Brief — IRAC brief.
let CaseBriefTool = ToolSpec(
    id: "case-brief",
    title: "Case Brief",
    short: "IRAC brief",
    blurb: "Generate a case brief: facts, issue, holding, reasoning, significance.",
    output: .document,
    inputs: [
        ToolField(
            key: "case",
            label: "Case (name or text)",
            type: .textarea,
            placeholder: "Name or paste the judgment…",
            big: true
        ),
    ],
    build: buildCaseBrief
)

func buildCaseBrief(_ v: ToolValues, _ today: Date) -> String {
    return """
Prepare a structured case brief for the judgment below with clearly labelled sections: Facts, Issue(s), Rule/Law, Holding, Reasoning (ratio), Obiter, and Significance. Keep it concise and student-friendly.

CASE:
\(v.text("case", "(none)"))
"""
}

/// IRAC Solver — Problem analysis.
let IracTool = ToolSpec(
    id: "irac",
    title: "IRAC Solver",
    short: "Problem analysis",
    blurb: "Full IRAC analysis of a problem or moot proposition.",
    output: .document,
    inputs: [
        ToolField(
            key: "problem",
            label: "Problem / proposition",
            type: .textarea,
            placeholder: "Paste the problem question or moot proposition…",
            big: true
        ),
    ],
    build: buildIrac
)

func buildIrac(_ v: ToolValues, _ today: Date) -> String {
    return """
Solve the following legal problem using the IRAC method. Clearly label Issue, Rule (with authorities), Application (apply the rule to these facts, both sides), and Conclusion.

PROBLEM:
\(v.text("problem", "(none)"))
"""
}

/// Simplify a Judgment — Plain language.
let SimplifyTool = ToolSpec(
    id: "simplify",
    title: "Simplify a Judgment",
    short: "Plain language",
    blurb: "Break a judgment into plain-language facts, ratio, decision, takeaway.",
    output: .document,
    inputs: [
        ToolField(
            key: "judgment",
            label: "Judgment text",
            type: .textarea,
            placeholder: "Paste the judgment…",
            big: true
        ),
    ],
    build: buildSimplify
)

func buildSimplify(_ v: ToolValues, _ today: Date) -> String {
    return """
Explain the judgment below in plain English for a law student. Give: (1) what the case was about, (2) the key facts, (3) what the court decided, (4) the ratio in simple terms, (5) the one-line takeaway. Avoid jargon; where a legal term is unavoidable, define it briefly.

JUDGMENT:
\(v.text("judgment", "(none)"))
"""
}

/// Citation Checker — Verify & format.
let CitationCheckTool = ToolSpec(
    id: "citation-check",
    title: "Citation Checker",
    short: "Verify & format",
    blurb: "Validate citations for accuracy and format; flag treatment.",
    output: .research,
    inputs: [
        ToolField(
            key: "citations",
            label: "Citations to check",
            type: .textarea,
            placeholder: "Paste the citations…",
            big: true
        ),
    ],
    build: buildCitationCheck
)

func buildCitationCheck(_ v: ToolValues, _ today: Date) -> String {
    return """
Check each citation below: verify the case name/year/court/reporter looks correct, flag if the format is wrong (and give the corrected form), and note if a cited case is known to be overruled/doubted. Present as a table: Citation | Status | Corrected form | Notes.

CITATIONS:
\(v.text("citations", "(none)"))
"""
}

/// Document Assembly — Routine drafts.
let DocAssemblyTool = ToolSpec(
    id: "doc-assembly",
    title: "Document Assembly",
    short: "Routine drafts",
    blurb: "Assemble routine documents — vakalatnama, affidavits, applications.",
    output: .document,
    inputs: [
        ToolField(
            key: "doc",
            label: "Document needed",
            type: .select,
            options: [
                "Vakalatnama",
                "Affidavit",
                "Application",
                "Memo of Parties",
                "Index",
                "Legal Notice",
            ]
        ),
        ToolField(
            key: "details",
            label: "Details",
            type: .textarea,
            placeholder: "Party names, matter, particulars…"
        ),
    ],
    build: buildDocAssembly
)

func buildDocAssembly(_ v: ToolValues, _ today: Date) -> String {
    return """
Draft a \(v.text("doc", "document")) for an Indian court/matter using the details below. Follow standard format and leave [placeholders] for anything not provided.

DETAILS:
\(v.text("details", "(none)"))
"""
}

/// Know Your Rights — Plain-language guide.
let KnowYourRightsTool = ToolSpec(
    id: "know-your-rights",
    title: "Know Your Rights",
    short: "Plain-language guide",
    blurb: "Plain-language rights guide for common issues.",
    output: .document,
    inputs: [
        ToolField(
            key: "topic",
            label: "Issue",
            type: .text,
            placeholder: "e.g. Rights of a worker denied wages"
        ),
        ToolField(
            key: "lang",
            label: "Language",
            type: .select,
            options: [
                "English",
                "Hindi",
                "Both",
            ]
        ),
    ],
    build: buildKnowYourRights
)

func buildKnowYourRights(_ v: ToolValues, _ today: Date) -> String {
    let langBlock = v.raw("lang").flatMap { $0 != "English" ? " (in \($0))" : nil } ?? ""

    return """
Create a simple, plain-language "know your rights" guide on: \(v.text("topic", "(unspecified)"))\(langBlock). Explain the person's legal rights, the relevant law in simple terms, and the practical steps/remedies available in India. Avoid jargon.
"""
}

/// PIL / Public Interest — PIL templates.
let PilTemplateTool = ToolSpec(
    id: "pil-template",
    title: "PIL / Public Interest",
    short: "PIL templates",
    blurb: "Draft PILs and public interest interventions.",
    output: .document,
    inputs: [
        ToolField(
            key: "cause",
            label: "Public cause",
            type: .textarea,
            placeholder: "Describe the public interest issue and the relief sought…"
        ),
        ToolField(
            key: "forum",
            label: "Forum",
            type: .select,
            options: [
                "Supreme Court (Art 32)",
                "High Court (Art 226)",
                "NGT",
            ]
        ),
    ],
    build: buildPilTemplate
)

func buildPilTemplate(_ v: ToolValues, _ today: Date) -> String {
    return """
Draft a Public Interest Litigation for the \(v.text("forum", "High Court")) on the cause below, with caption, locus/maintainability, facts, grounds, and prayer. Emphasise the public interest and cite relevant constitutional provisions and precedents.

CAUSE:
\(v.text("cause", "(none)"))
"""
}
