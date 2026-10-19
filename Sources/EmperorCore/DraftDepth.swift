import Foundation

/// How long a tool's draft should be: the web's Short / Detailed toggle.
///
/// ## Where it applies
///
/// To a **tool's** opening prompt and nothing else. The web puts the toggle on the live draft page
/// (`src/ui/DraftDepthToggle.jsx`, rendered by `ToolWorkspace.jsx`) and appends the matching
/// sentence inside that page's `generate()` — `tool.buildPrompt(values) + recordLine + lengthLine
/// + …`. A plain chat question never carries it, and a refinement ("make paragraph 4 shorter") is
/// sent as typed. So this is appended by `ToolSpec.draftPrompt`, at the one place a tool's form
/// starts its conversation, and never by `ChatViewModel`.
///
/// ## Its position in the prompt
///
/// Immediately after the tool's own prompt, and after the web's attached-record line when there
/// is one. A tool's form here has no attachments of its own (the conversation it opens does), so
/// the record line never exists on this side and the length line follows the tool's prompt
/// directly. The web's role guardrail lines come after it; this client sends none of them. The
/// order is pinned by `Resources/composer/draft-depth.json`, generated from the web's own file by
/// `scripts/generate-draft-depth-fixtures.mjs`.
///
/// Remembered for the account on this device, as the web remembers it in the browser (`store.js`
/// persists `draftDepth`). The server never sees the choice, only the sentence it produced.
enum DraftDepth: String, CaseIterable, Identifiable, Codable, Sendable {
    case short
    case detailed

    var id: String { rawValue }

    /// The web's default (`store.js`: `draftDepth: 'detailed'`).
    static let `default` = DraftDepth.detailed

    /// The toggle's own words (`DEPTHS` in `DraftDepthToggle.jsx`).
    var label: String {
        switch self {
        case .short: return "Short"
        case .detailed: return "Detailed"
        }
    }

    /// The hint under each choice — the web's button `title`.
    var hint: String {
        switch self {
        case .short: return "A tight, concise draft"
        case .detailed: return "A thorough, comprehensive draft"
        }
    }

    /// SF Symbols for the web's `AlignLeft` / `AlignJustify`.
    var systemImage: String {
        switch self {
        case .short: return "text.alignleft"
        case .detailed: return "text.justify"
        }
    }

    /// The sentence appended to a tool's prompt, word for word the web's `lengthLine`, including
    /// the blank line it opens with.
    var lengthLine: String {
        switch self {
        case .short:
            return "\n\nLENGTH — VERY CONCISE (HARD LIMIT): Keep the ENTIRE response to a MAXIMUM of 2–3 pages (roughly 900–1,300 words). Include only the essential components and the core reasoning, expressed crisply. Omit padding, repetition, background recital and over-elaboration. Keep every mandatory part of this document type, but state each point briefly. Do NOT exceed 3 pages under any circumstance."
        case .detailed:
            return "\n\nLENGTH — COMPREHENSIVE: Produce a thorough, exhaustive draft with NO length limit — use as many pages as the matter genuinely needs. Develop every issue fully, include all relevant components, clauses/paragraphs, reasoning and supporting detail, and leave nothing material unaddressed."
        }
    }

    // MARK: Storage

    static func key(forUser userID: Int?) -> String {
        "draft.depth.v1.\(userID.map(String.init) ?? "anonymous")"
    }

    /// The account's choice on this device, or Detailed — for nothing stored and for a value a
    /// later build no longer offers, as the web's `(st.draftDepth || 'detailed')` falls back.
    static func stored(in store: any PreferenceStore, userID: Int?) -> DraftDepth {
        store.string(for: key(forUser: userID)).flatMap(DraftDepth.init(rawValue:)) ?? .default
    }

    func save(to store: any PreferenceStore, userID: Int?) {
        store.setString(rawValue, for: Self.key(forUser: userID))
    }
}

extension ToolSpec {
    /// The opening message a tool's form sends: its prompt, then the length line — the web's
    /// `tool.buildPrompt(values2) + recordLine + lengthLine`, with no record line because the
    /// form carries no attachments of its own (see `DraftDepth`).
    func draftPrompt(_ values: ToolValues, depth: DraftDepth, today: Date = Date()) -> String {
        prompt(values, today: today) + depth.lengthLine
    }
}
