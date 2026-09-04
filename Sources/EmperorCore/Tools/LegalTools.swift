import Foundation

/// The tools this client has built, in the order the list shows them.
///
/// All twenty-nine are the platform's own, ported with their prompts pinned against fixtures
/// generated from its JavaScript. None of them needs anything from the server that this app does
/// not already send: a tool is a form, a prompt, and a rendering hint, and the prompt goes out as
/// an ordinary chat message.
///
/// The ids match the platform's, so a route that works on the web works here.

/// The five document-analysis tools.
///
/// These are the ones the web's own sidebar links — the rest are reachable there only by typing
/// `/w/<id>`.
let ANALYSIS_TOOLS: [ToolSpec] = [
    BlindSpotsTool,
    HighlighterTool,
    DocIndexTool,
    ListOfDatesTool,
    CaseflowTool,
]

/// Everything else the platform's registry holds — drafting, research and review.
///
/// Ported wholesale rather than picked over: they are the same three pieces of data as the five
/// above, and choosing a subset would have meant deciding for an advocate which of their own
/// platform's tools were worth having on a phone.
let REGISTRY_TOOLS: [ToolSpec] = [
    ResearchTool,
    CustomDocumentTool,
    DraftPleadingTool,
    DraftReviewTool,
    CaseGistTool,
    ArgumentsTool,
    ClauseExtractTool,
    BriefWorkupTool,
    ContractAnalysisTool,
    DueDiligenceTool,
    DraftContractTool,
    BoardResolutionTool,
    ComplianceCalendarTool,
    CaseComparisonTool,
    DraftJudgmentTool,
    BenchNoteTool,
    LawTimelineTool,
    CaseBriefTool,
    IracTool,
    SimplifyTool,
    CitationCheckTool,
    DocAssemblyTool,
    KnowYourRightsTool,
    PilTemplateTool,
]

let LEGAL_TOOLS: [ToolSpec] = ANALYSIS_TOOLS + REGISTRY_TOOLS

/// The tool with this id, or `nil`.
///
/// Ids come off a navigation route, so they are not trusted.
func legalTool(_ id: String?) -> ToolSpec? {
    guard let id else { return nil }
    return LEGAL_TOOLS.first { $0.id == id }
}
