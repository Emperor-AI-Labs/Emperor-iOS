import Foundation

/// The picture on a tool's tile — the web's own icon for the tool, read across into SF Symbols.
///
/// Every tool in `src/tools/registry.js` and `src/tools/definitions/` carries a lucide icon, and
/// the web draws it on the tool's tile wherever the tool is offered. The app draws the same tile
/// (`TileHue.forTool` gives the colour), so it needs the same picture. Two tables, deliberately:
///
/// - `forLucide` says what each lucide icon the tools use looks like as an SF Symbol. That is a
///   judgement, made once per icon, and the reason it is a table rather than a guess per tool.
/// - `symbol(for:)` says which icon each tool carries — the platform's data, read off the
///   registry.
///
/// `TileTests` holds the second to the first through the platform: for every tool the registry
/// exports, the symbol here must be the one `forLucide` gives for the icon the web draws. So a
/// tool whose icon changes on the web, or a typo here, fails a test rather than quietly drawing
/// the wrong picture — and a symbol name that does not exist draws *nothing*, silently, which is
/// why every name below is a long-standing one.
enum ToolSymbol {

    /// Lucide icon names, as the SF Symbol that reads the same.
    static let forLucide: [String: String] = [
        "BookOpen": "book",
        "Brain": "brain",
        "CalendarClock": "calendar.badge.clock",
        "ClipboardCheck": "checklist",
        "FileSearch": "doc.text.magnifyingglass",
        "FileSignature": "signature",
        "FilePlus2": "doc.badge.plus",
        "FileText": "doc.text",
        "Files": "doc.on.doc",
        "FolderOpen": "folder",
        "Gavel": "hammer",
        // Two hands meeting, on the web; the heart-and-text square is the Legal Aid role's own.
        "HeartHandshake": "heart.text.square",
        "Highlighter": "highlighter",
        "Landmark": "building.columns",
        "Layers": "square.stack.3d.up",
        "Megaphone": "megaphone",
        "MessagesSquare": "bubble.left.and.bubble.right",
        "Quote": "text.quote",
        // A winding path, on the web: where a matter is in its journey.
        "Route": "arrow.triangle.turn.up.right.diamond",
        "Scissors": "scissors",
        "ScrollText": "scroll",
        "Search": "magnifyingglass",
        "ShieldAlert": "exclamationmark.shield",
        "Sparkles": "sparkles",
        "StickyNote": "note.text",
        // Crossed swords, on the web — an argument. SF Symbols has no swords; a speech bubble
        // with text says "submissions" without borrowing the gavel the judgment tools wear.
        "Swords": "text.bubble",
        "GitCompareArrows": "arrow.left.arrow.right",
    ]

    /// The symbol for a tool, by its platform id. An id the web gives no icon of its own — a
    /// role's card, a Litigator document — gets the document the web draws for those.
    static func symbol(for id: String) -> String {
        switch id {
        case "assistant": return "bubble.left.and.bubble.right"      // MessagesSquare
        case "research": return "magnifyingglass"                     // Search
        case "custom-document": return "doc.badge.plus"               // FilePlus2
        case "draft-pleading": return "doc.text"                      // FileText
        case "draft-review": return "checklist"                       // ClipboardCheck
        case "case-gist": return "scroll"                             // ScrollText
        case "arguments": return "text.bubble"                        // Swords
        case "clause-extract": return "scissors"                      // Scissors
        case "brief-workup": return "folder"                          // FolderOpen
        case "contract-analysis": return "exclamationmark.shield"     // ShieldAlert
        case "due-diligence": return "checklist"                      // ClipboardCheck
        case "draft-contract": return "signature"                     // FileSignature
        case "board-resolution": return "building.columns"            // Landmark
        case "compliance-calendar": return "calendar.badge.clock"     // CalendarClock
        case "case-comparison": return "arrow.left.arrow.right"       // GitCompareArrows
        case "draft-judgment": return "hammer"                        // Gavel
        case "bench-note": return "note.text"                         // StickyNote
        case "law-timeline": return "square.stack.3d.up"              // Layers
        case "case-brief": return "book"                              // BookOpen
        case "irac": return "brain"                                   // Brain
        case "simplify": return "sparkles"                            // Sparkles
        case "citation-check": return "text.quote"                    // Quote
        case "doc-assembly": return "doc.on.doc"                      // Files
        case "know-your-rights": return "heart.text.square"           // HeartHandshake
        case "pil-template": return "megaphone"                       // Megaphone
        case "blind-spots": return "exclamationmark.shield"           // ShieldAlert
        case "highlighter": return "highlighter"                      // Highlighter
        case "doc-index": return "doc.text.magnifyingglass"           // FileSearch
        case "list-of-dates": return "calendar.badge.clock"           // CalendarClock
        case "caseflow": return "arrow.triangle.turn.up.right.diamond" // Route
        default: return "doc.text"                                    // FileText
        }
    }
}
