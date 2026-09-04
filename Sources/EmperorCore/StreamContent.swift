import Foundation

/// A document the model chose to render in a side panel rather than inline.
struct StreamArtifact: Equatable, Identifiable, Sendable {
    /// Which wrapper the model used. Decides the title and icon, not the rendering.
    enum Kind: Equatable, Sendable { case canvas, table }
    /// What the body actually *is*. Sniffed from the content, not taken from the wrapper.
    enum Format: Equatable, Sendable { case html, markdown }

    let id = UUID()
    var kind: Kind
    var format: Format
    var title: String
    var body: String

    static func == (a: StreamArtifact, b: StreamArtifact) -> Bool {
        a.kind == b.kind && a.format == b.format && a.title == b.title && a.body == b.body
    }

    /// Decides how to render a body.
    ///
    /// The wrapper is a claim, not a fact. The platform records a live incident
    /// (`src/lib/canvasShape.js:1-9`) where a pleading arrived as 81 HTML `<p>` paragraphs
    /// inside `<table_content>` — rendering that as Markdown produces a wall of raw tags. The
    /// server and web client both sniff for this reason, so the native client must too.
    static func detectFormat(of body: String, declared kind: Kind) -> Format {
        if blockTagRegex.firstMatch(
            in: body, options: [],
            range: NSRange(location: 0, length: (body as NSString).length)) != nil {
            return .html
        }
        if hasMarkdownTable(body) { return .markdown }
        return kind == .canvas ? .html : .markdown
    }

    /// Block-level HTML. `<br>` is deliberately excluded: Markdown table cells routinely
    /// contain one, and treating that as "this is HTML" would misroute real tables.
    private static let blockTagRegex = try! NSRegularExpression(
        pattern: "<(p|div|table|h[1-6]|ul|ol|li|blockquote)[\\s>]",
        options: [.caseInsensitive])

    /// A GFM table needs a header row followed by a delimiter row — that pair is precisely
    /// what "is a table" means, since a renderer produces nothing without it.
    private static let delimiterRowRegex = try! NSRegularExpression(
        pattern: "^[ \\t]{0,3}\\|?[ \\t]*:?-+:?[ \\t]*(?:\\|[ \\t]*:?-+:?[ \\t]*)+\\|?[ \\t]*$",
        options: [.anchorsMatchLines])

    private static func hasMarkdownTable(_ body: String) -> Bool {
        delimiterRowRegex.firstMatch(
            in: body, options: [],
            range: NSRange(location: 0, length: (body as NSString).length)) != nil
    }
}

/// A citation the model attached to a line of its answer.
///
/// The model emits these inline as `<@exact_file_name.ext:MARK>` or
/// `<@file.pdf:MARK:startPage-endPage>` (spec at `src/lib/clerk_identity.js:37`). They are the
/// product's central claim — every assertion names a document and page the reader can open —
/// so they are lifted out and surfaced rather than merely stripped.
///
/// They must also be preserved when writing an edited document back, or the paper trail is
/// destroyed (the web client calls this `carryMentions`, `src/lib/output.js:88`).
struct AnnexureMention: Equatable, Identifiable, Sendable {
    var fileName: String
    var mark: String
    var startPage: Int?
    var endPage: Int?

    var id: String { "\(fileName):\(mark):\(startPage ?? 0)-\(endPage ?? 0)" }

    var pageDescription: String? {
        guard let startPage else { return nil }
        guard let endPage, endPage != startPage else { return "p. \(startPage)" }
        return "pp. \(startPage)–\(endPage)"
    }
}

struct StreamPlan: Codable, Equatable, Sendable {
    struct Subtask: Codable, Equatable, Sendable {
        var label: String
        var tools: [String]?
        var description: String?
    }
    struct Task: Codable, Equatable, Sendable {
        var title: String
        var subtasks: [Subtask]?
    }
    var tasks: [Task]
}

/// The renderable decomposition of an accumulated answer.
///
/// The server stores and streams the answer with every control tag left in — stripping is
/// entirely the client's job (the web client does it at `ChatWindow.jsx:466,755`). The same
/// decomposition therefore has to run over both live stream buffers and history loaded from
/// `GET /messages`.
struct StreamContent: Equatable, Sendable {
    /// The answer as the user should read it: every control tag removed.
    var prose: String = ""
    /// Sentence-by-sentence upstream reasoning. Only reasoning-capable models emit these.
    var reasoning: [String] = []
    var artifacts: [StreamArtifact] = []
    var plan: StreamPlan?
    var followUps: [String] = []
    /// In-band failures the server writes as prose rather than as an HTTP error.
    var errors: [String] = []
    /// Citations the model attached to this answer, in the order they appeared.
    var mentions: [AnnexureMention] = []
    /// True when the stored copy carries the server's interrupted-response marker.
    var wasInterrupted = false

    /// True when a document block was opened and never closed.
    ///
    /// Meaningless while a turn is streaming — a block is legitimately open until its body
    /// finishes arriving — so callers must consult `looksTruncated` instead, and only once the
    /// answer is final.
    var hasUnclosedDocumentBlock = false

    /// Whether a **finished** answer shows any sign of having been cut short.
    ///
    /// The marker alone is not enough. `/chat`'s `onDone` (`sync-server.js:7797`) destructures
    /// only `{content, usage}` and throws away the provider's `status`/`incomplete` verdict, so
    /// a run that ended `status:'length'` — token budget exhausted, or the draft stranded inside
    /// an unclosed block (`OpenRouterProvider.js:1255,1260`) — is persisted with
    /// `incomplete:false`, carries no marker, and ends the response cleanly. `/stream-status`
    /// then reports `done:true, incomplete:false`. Re-deriving the provider's own `unclosedBlock`
    /// test (`OpenRouterProvider.js:170-178`) is the only way a client can catch that case.
    var looksTruncated: Bool { wasInterrupted || hasUnclosedDocumentBlock }

    /// What to send back to the server as this turn's content.
    ///
    /// **Not `prose`.** `POST /chat` replaces the chat's stored messages with exactly what it
    /// receives — `setMessages` runs `DELETE FROM messages WHERE chat_id = ?` and re-inserts
    /// (`sync-server.js:4250`) — so whatever goes back here is what survives, for the web
    /// client too. `prose` has had the artifacts and the `<@file:MARK>` citation tokens
    /// stripped out of it, so posting that back would permanently delete the drafted pleading
    /// and every citation from the history on the next follow-up question.
    ///
    /// This matches the server's own persisted copy: `fullContent`, which keeps the artifacts
    /// and citations but never the `<think>` blocks the provider writes alongside them.
    var persistableContent: String = ""

    /// The marker the server appends to the *persisted* copy of an interrupted run
    /// (sync-server.js:2062). It is never written to the live stream, so it only shows up
    /// on history loaded from `GET /messages`.
    private static let interruptedMarker = "This response was interrupted and is incomplete."

    static func parse(_ raw: String) -> StreamContent {
        var content = StreamContent()
        var text = raw

        content.wasInterrupted = text.contains(interruptedMarker)
        content.hasUnclosedDocumentBlock = Self.hasUnclosedDocumentBlock(text)
        // Everything except the model's private reasoning — see `persistableContent`.
        content.persistableContent = Self.strippingReasoning(from: raw)

        // Order matters: pull structured blocks out before the generic tag sweep, so their
        // bodies are captured rather than flattened into prose.
        content.plan = Self.takePlan(&text)
        content.reasoning = Self.takeReasoning(&text)
        content.artifacts = Self.takeArtifacts(&text)
        content.followUps = Self.takeFollowUps(&text)
        content.errors = Self.takeErrors(&text)
        // After artifacts, so citations inside a drafted document are captured too.
        content.mentions = Self.takeMentions(&text)

        // Defensive: <status> and <usage> are lifted by ChatStreamParser, but history rows
        // written before that logic existed can still carry them.
        _ = Self.takeAll(&text, pattern: "<status>([\\s\\S]*?)</status>")
        _ = Self.takeAll(&text, pattern: "<usage>([\\s\\S]*?)</usage>")

        text = Self.stripDanglingTag(text)
        content.prose = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return content
    }

    /// Removes only the reasoning wrappers, leaving artifacts and citations intact.
    private static func strippingReasoning(from raw: String) -> String {
        var text = raw
        _ = takeReasoning(&text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Truncation

    /// Whether any document wrapper is left open.
    ///
    /// Counting is safe against the closing form: `</canvas_content>` puts a `/` immediately
    /// after the `<`, so it can never match the opening literal.
    private static func hasUnclosedDocumentBlock(_ text: String) -> Bool {
        ["canvas_content", "table_content"].contains { tag in
            occurrences(of: "<\(tag)>", in: text) > occurrences(of: "</\(tag)>", in: text)
        }
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var index = haystack.startIndex
        while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }

    // MARK: - Extractors

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    /// Removes every match of `pattern` from `text`, returning capture group 1 of each.
    private static func takeAll(_ text: inout String, pattern: String) -> [String] {
        let re = regex(pattern)
        let ns = text as NSString
        let matches = re.matches(in: text, options: [],
                                 range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        let captured = matches.map { ns.substring(with: $0.range(at: 1)) }
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            mutable.deleteCharacters(in: match.range)
        }
        text = mutable as String
        return captured
    }

    /// Model-internal deliberation, under any of the wrappers this platform strips.
    ///
    /// The server's own sweep (`src/lib/output.js:11-22`) covers all of these, not just
    /// `<think>` — different upstream models wrap reasoning differently, and an unstripped
    /// one would put the model's private working straight in front of a client.
    private static let reasoningTags = [
        "think", "thinking", "scratchpad", "reasoning", "internal", "reflection",
    ]

    private static func takeReasoning(_ text: inout String) -> [String] {
        var found: [String] = []
        for tag in reasoningTags {
            found += takeAll(&text, pattern: "<\(tag)>([\\s\\S]*?)</\(tag)>")
        }
        return found
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Lifts inline citation tokens out of the prose.
    ///
    /// Form is `<@file.ext:MARK>` or `<@file.ext:MARK:start-end>`. They are removed from the
    /// displayed text — they are markup, not prose — but retained on the parsed result so the
    /// UI can show which document and page each answer rests on.
    /// Three forms are valid per `src/lib/clerk_identity.js:37`: no page, a single page
    /// (`:7`), or a range (`:4-9`). The single-page form is easy to miss — and because the
    /// server's stripper only removes *well-formed* tokens, a client regex that fails to
    /// match one leaves it rendering verbatim in the middle of a pleading.
    private static let mentionRegex = try! NSRegularExpression(
        pattern: "<@([^:>]+):([^:>]+?)(?::(\\d+)(?:\\s*[-–]\\s*(\\d+))?)?>", options: [])

    private static func takeMentions(_ text: inout String) -> [AnnexureMention] {
        let ns = text as NSString
        let matches = mentionRegex.matches(
            in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        func capture(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }

        let mentions = matches.map { match in
            AnnexureMention(
                fileName: capture(match, 1)?.trimmingCharacters(in: .whitespaces) ?? "",
                mark: capture(match, 2)?.trimmingCharacters(in: .whitespaces) ?? "",
                startPage: capture(match, 3).flatMap(Int.init),
                endPage: capture(match, 4).flatMap(Int.init))
        }

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            mutable.deleteCharacters(in: match.range)
        }
        text = mutable as String
        return mentions
    }

    private static func takePlan(_ text: inout String) -> StreamPlan? {
        let blocks = takeAll(&text, pattern: "<plan>([\\s\\S]*?)</plan>")
        guard let json = blocks.first, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StreamPlan.self, from: data)
    }

    /// Pulls `[CANVAS_TRIGGER: Title]` + `<canvas_content>…</canvas_content>` pairs, and the
    /// table equivalent. The trigger line carries the title and sits immediately before the
    /// body; we match them together so a title can never attach to the wrong body.
    private static func takeArtifacts(_ text: inout String) -> [StreamArtifact] {
        var found: [StreamArtifact] = []

        for (kind, trigger, tag) in [
            (StreamArtifact.Kind.canvas, "CANVAS_TRIGGER", "canvas_content"),
            (StreamArtifact.Kind.table, "TABLE_TRIGGER", "table_content"),
        ] {
            // Title is optional: the model occasionally emits the body without its trigger.
            let pattern = "(?:\\[\(trigger):\\s*([^\\]]*)\\]\\s*)?<\(tag)>([\\s\\S]*?)</\(tag)>"
            let re = regex(pattern)
            let ns = text as NSString
            let matches = re.matches(in: text, options: [],
                                     range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }

            for match in matches {
                let titleRange = match.range(at: 1)
                let title = titleRange.location == NSNotFound
                    ? (kind == .canvas ? "Document" : "Table")
                    : ns.substring(with: titleRange).trimmingCharacters(in: .whitespaces)
                let body = Self.cleanArtifactBody(ns.substring(with: match.range(at: 2)))
                found.append(StreamArtifact(
                    kind: kind,
                    format: StreamArtifact.detectFormat(of: body, declared: kind),
                    title: title,
                    body: body))
            }

            let mutable = NSMutableString(string: text)
            for match in matches.reversed() {
                mutable.deleteCharacters(in: match.range)
            }
            text = mutable as String
        }

        // A trigger whose body has not streamed in yet would otherwise render as prose.
        _ = takeAll(&text, pattern: "\\[(?:CANVAS|TABLE)_TRIGGER:\\s*([^\\]]*)\\]")
        return found
    }

    /// Tidies an artifact body the way the web client does before rendering.
    ///
    /// Models intermittently wrap the document in a fenced code block, which would otherwise
    /// render the whole pleading as source rather than as a document.
    private static func cleanArtifactBody(_ body: String) -> String {
        var cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
        for fence in ["```html", "```HTML", "```markdown", "```"] {
            if cleaned.hasPrefix(fence) {
                cleaned = String(cleaned.dropFirst(fence.count))
                break
            }
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func takeFollowUps(_ text: inout String) -> [String] {
        let blocks = takeAll(&text, pattern: "<follow-up-queries>([\\s\\S]*?)</follow-up-queries>")
        guard let json = blocks.first, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// The provider and route write failures as bracketed prose rather than as an HTTP error,
    /// because by then the response is already streaming and the status line is long gone
    /// (OpenRouterProvider.js:920,1224; sync-server.js:7971).
    private static func takeErrors(_ text: inout String) -> [String] {
        takeAll(&text, pattern: "\\[((?:Server )?Error: [^\\]]*)\\]")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Drops a trailing tag that has not finished streaming, so it never flashes as prose.
    ///
    /// Only a genuinely tag-shaped tail qualifies: `<` followed solely by characters that can
    /// appear in a tag name, running to the end of the buffer. Legal prose is full of literal
    /// comparisons — "damages < 50,000" — and those must survive, which they do here because
    /// the space after `<` breaks the pattern.
    private static let danglingTagRegex = try! NSRegularExpression(
        pattern: "<[a-zA-Z0-9_:/-]{0,32}$", options: [])

    private static func stripDanglingTag(_ text: String) -> String {
        let ns = text as NSString
        guard let match = danglingTagRegex.firstMatch(
            in: text, options: [], range: NSRange(location: 0, length: ns.length))
        else { return text }
        return ns.substring(to: match.range.location)
    }
}
