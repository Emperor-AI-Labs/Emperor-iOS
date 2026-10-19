import Foundation

/// In-place editing of a drafted document: the pure half.
///
/// The web edits the rendered page itself (`src/tools/useDocEditor.js`, `src/lib/editableDoc.js`)
/// and folds what the advocate typed back into the assistant message the draft came from
/// (`withEditedDraft` in `src/tools/ToolWorkspace.jsx`, over `replaceCanvasBody` in
/// `src/lib/output.js`). The message is the draft's only canonical home: every later turn carries
/// it, and the server re-derives the Drafts row from it on every write of the conversation. This
/// file ports those rules, so an edit made on the phone lands in exactly the place the web's would.
///
/// Everything here works on strings. The editing itself happens in a web view, where the DOM
/// does the real work; what comes back out of it is scrubbed (`scrub`) and folded (`withEditedDraft`).
enum DraftEdit {

    // MARK: - Regular-expression plumbing

    /// JavaScript's `$` without the `m` flag is the very end of the input; ICU's also matches
    /// before a final line break. `\z` is the JavaScript meaning, so every port uses it.
    fileprivate static func regex(
        _ pattern: String, _ options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    fileprivate static func whole(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    fileprivate static func replacingAll(
        _ text: String, _ pattern: NSRegularExpression, with literal: String
    ) -> String {
        pattern.stringByReplacingMatches(
            in: text, options: [], range: whole(text),
            withTemplate: NSRegularExpression.escapedTemplate(for: literal))
    }

    fileprivate static func replacingFirst(
        _ text: String, _ pattern: NSRegularExpression, with literal: String
    ) -> String {
        guard let match = pattern.firstMatch(in: text, options: [], range: whole(text))
        else { return text }
        return (text as NSString).replacingCharacters(in: match.range, with: literal)
    }

    fileprivate static func matches(_ text: String, _ pattern: NSRegularExpression) -> [String] {
        let ns = text as NSString
        return pattern.matches(in: text, options: [], range: whole(text))
            .map { ns.substring(with: $0.range) }
    }

    // MARK: - What the web strips before it renders (src/lib/output.js)

    /// Meta, reasoning and telemetry wrappers — `META_TAGS`.
    static let metaTags = [
        "usage", "status", "plan", "thinking", "think", "scratchpad", "reasoning", "internal",
        "reflection",
    ]

    private static let closedMeta: [NSRegularExpression] = metaTags.map {
        regex("<\($0)(?:\\s[^>]*)?>[\\s\\S]*?</\($0)>", .caseInsensitive)
    }
    private static let openMeta = regex(
        "<(?:\(metaTags.joined(separator: "|")))(?:\\s[^>]*)?>[\\s\\S]*\\z", .caseInsensitive)
    private static let truncateMarker = regex("<truncate:\\d+/>", .caseInsensitive)

    /// `stripMeta`: every closed meta block, then a still-open trailing one, then any rollback
    /// marker; trimmed.
    static func stripMeta(_ text: String) -> String {
        var out = text
        for pattern in closedMeta { out = replacingAll(out, pattern, with: "") }
        out = replacingFirst(out, openMeta, with: "")
        out = replacingAll(out, truncateMarker, with: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<@file.ext:P-3>` and its page forms — the annexure citation record (`MENTION_RE`).
    static let mentionPattern = regex("<@[^:>]+:[A-Za-z]+-\\d+(?::\\d+(?:-\\d+)?)?>")

    /// `stripMentions`. The tokens are the record, never something a reader sees; in a web view
    /// they would otherwise show as literal text, because `<@` does not open a tag.
    static func stripMentions(_ text: String) -> String {
        replacingAll(text, mentionPattern, with: "")
    }

    private static let leadingNarration = regex("^\\s*([^<]{1,400}?)\\s*\\n\\s*\\n\\s*(?=<)")
    private static let narrationOpening = regex(
        "^(now|let me|i will|i'll|i have|i understand)\\b", .caseInsensitive)

    /// `stripLeadingNarration`: a "Now I will draft…" sentence left as the first line of the
    /// document body is dropped. The server runs the identical function before it stores a draft.
    static func stripLeadingNarration(_ html: String) -> String {
        let ns = html as NSString
        guard let match = leadingNarration.firstMatch(in: html, options: [], range: whole(html))
        else { return html }
        let lead = ns.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard narrationOpening.firstMatch(in: lead, options: [], range: whole(lead)) != nil
        else { return html }
        return ns.substring(from: match.range.location + match.range.length)
    }

    private static let blockTag = regex(
        "<(?:p|div|table|tr|td|th|h[1-6]|ul|ol|li|center|section|article|blockquote)\\b[^>]*>",
        .caseInsensitive)
    private static let blockLead = regex(
        "^\\s*<(?:p|div|table|h[1-6]|ul|ol|center|section|article|blockquote)\\b",
        .caseInsensitive)

    /// `isBlockHtml`: the one test the web shares between rendering and putting an edit back.
    static func isBlockHTML(_ text: String) -> Bool {
        blockLead.firstMatch(in: text, options: [], range: whole(text)) != nil
            || blockTag.numberOfMatches(in: text, options: [], range: whole(text)) >= 3
    }

    // MARK: - Putting an edit back (replaceCanvasBody, withEditedDraft)

    private static let wrapper = regex(
        "(<(canvas_content|table_content)>)([\\s\\S]*?)(</\\2>|\\z)", .caseInsensitive)
    private static let triggerLine = regex(
        "\\[(?:CANVAS|TABLE)_TRIGGER:[^\\]\\n]*\\][ \\t]*\\r?\\n?", .caseInsensitive)

    /// `carryMentions`: every citation token the old body held and the edited one does not is
    /// appended, unseen, so the annexure registry keeps every mark the draft made.
    static func carryMentions(from oldBody: String, into html: String) -> String {
        let had = matches(oldBody, mentionPattern)
        guard !had.isEmpty else { return html }
        let kept = Set(matches(html, mentionPattern))
        var seen = Set<String>()
        let lost = had.filter { seen.insert($0).inserted && !kept.contains($0) }
        return lost.isEmpty ? html : "\(html)\n\(lost.joined())"
    }

    /// `replaceCanvasBody`: the edited body goes back exactly where `extractOutput` found the
    /// document. The trigger line, any narration before it and anything after the wrapper are left
    /// alone; the wrapper keeps its own tag, so an edited table stays filed as a table. A message
    /// with no wrapper, no trigger and no block HTML is returned untouched — an edit that cannot
    /// be placed loses the edit, never the turn.
    static func replaceCanvasBody(_ raw: String, html: String) -> String {
        guard !html.isEmpty else { return raw }
        let ns = raw as NSString
        if let match = wrapper.firstMatch(in: raw, options: [], range: whole(raw)) {
            let open = ns.substring(with: match.range(at: 1))
            let tag = ns.substring(with: match.range(at: 2))
            let body = carryMentions(from: ns.substring(with: match.range(at: 3)), into: html)
            let closeRange = match.range(at: 4)
            let close = closeRange.length > 0 ? ns.substring(with: closeRange) : "</\(tag)>"
            return ns.replacingCharacters(in: match.range, with: "\(open)\n\(body)\n\(close)")
        }
        if let trigger = triggerLine.firstMatch(in: raw, options: [], range: whole(raw)) {
            return ns.substring(with: trigger.range) + carryMentions(from: raw, into: html)
        }
        return isBlockHTML(stripMeta(raw)) ? carryMentions(from: raw, into: html) : raw
    }

    /// `lastAssistantIndex`.
    static func lastAssistantIndex(_ messages: [ChatMessage]) -> Int? {
        messages.lastIndex { $0.role == .assistant }
    }

    /// `withEditedDraft`: folds an edit into the assistant turn it was typed into.
    ///
    /// Position is identity here, as on the web: only the **last** assistant turn can take an
    /// edit, and only when it is still the turn the edit came from (`ownerIndex`). Nil when the
    /// conversation is untouched — the edit could not be placed, or it is already there.
    static func withEditedDraft(
        _ conversation: [ChatMessage], html: String, ownerIndex: Int
    ) -> [ChatMessage]? {
        guard !html.isEmpty, let index = lastAssistantIndex(conversation), index == ownerIndex
        else { return nil }
        let next = replaceCanvasBody(conversation[index].content, html: html)
        guard next != conversation[index].content else { return nil }
        var folded = conversation
        folded[index].content = next
        return folded
    }

    // MARK: - What the editor is given

    /// The body the editor opens over: what the web's `extractOutput` would render — citation
    /// tokens out, a stray opening sentence of narration out — as HTML. A Markdown table is laid
    /// out as an HTML table first, as the web's renderer does before its editor switches on; an
    /// edited table is then stored as that HTML, inside its own `<table_content>`, exactly as the
    /// web stores one.
    static func editableHTML(body: String, format: StreamArtifact.Format) -> String {
        let shown = stripLeadingNarration(stripMentions(body))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch format {
        case .html: return shown
        case .markdown: return MarkdownHTML.html(from: shown)
        }
    }

    // MARK: - The export funnel (editableDoc.js `scrub`)

    /// The attributes edit mode puts on the page — `EDIT_ATTRS`.
    static let editAttributes = [
        "contenteditable", "spellcheck", "data-ex-edit", "data-ex-edited", "role",
        "aria-multiline", "tabindex",
    ]

    private static let openingTag = regex("<[a-zA-Z][a-zA-Z0-9-]*\\b[^>]*>")
    private static let editMark = regex("\\sdata-ex-edit(?:ed)?\\b", .caseInsensitive)
    private static let editAttribute = regex(
        "\\s(?:\(editAttributes.joined(separator: "|")))(?:\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+))?(?=[\\s/>])",
        .caseInsensitive)
    private static let alignAttribute = regex(
        "\\salign\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", .caseInsensitive)
    private static let styleAttribute = regex(
        "\\sstyle\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", .caseInsensitive)
    private static let textAlignDeclaration = regex(
        "\\s*text-align\\s*:[^;]*;?", .caseInsensitive)
    private static let fontTag = regex("</?font\\b[^>]*>", .caseInsensitive)
    private static let pairedDrops = regex(
        "<(script|style)\\b[^>]*>[\\s\\S]*?</\\1\\s*>", .caseInsensitive)
    private static let voidDrops = regex("<(?:script|style|meta|link|base)\\b[^>]*>", .caseInsensitive)
    private static let interchangeBreak = regex(
        "<br\\b[^>]*\\bclass\\s*=\\s*[\"']?[^\"'>]*\\bApple-interchange-newline\\b[^>]*>",
        .caseInsensitive)

    /// The rules the web's `exportHtml` runs on an edited document, as a string pass. The web
    /// view runs the same rules on its own DOM before it hands the HTML over (`DraftEditScript`);
    /// this is the second line, so what is folded into the conversation is clean whatever the
    /// page did.
    ///
    /// 1. edit mode's own attributes, from the elements it marked;
    /// 2. a legacy `align` attribute becomes `text-align` — the Word converter reads only the style;
    /// 3. `<font>` is unwrapped, its text and nested emphasis kept;
    /// 4. nothing executable or page-level survives a paste: script, style, meta, link, base;
    /// 5. WebKit's paste marker, `br.Apple-interchange-newline`, goes.
    ///
    /// The web's sixth rule (page sheets) has nothing to act on here: this client does not
    /// paginate the screen.
    static func scrub(_ html: String) -> String {
        var out = rewritingOpeningTags(html) { tag in
            var tag = tag
            if editMark.firstMatch(in: tag, options: [], range: whole(tag)) != nil {
                tag = replacingAll(tag, editAttribute, with: "")
            }
            return movingAlignIntoStyle(tag)
        }
        out = replacingAll(out, pairedDrops, with: "")
        out = replacingAll(out, voidDrops, with: "")
        out = replacingAll(out, fontTag, with: "")
        out = replacingAll(out, interchangeBreak, with: "")
        return out
    }

    private static func rewritingOpeningTags(
        _ html: String, _ rewrite: (String) -> String
    ) -> String {
        let ns = html as NSString
        var out = ""
        var cursor = 0
        for match in openingTag.matches(in: html, options: [], range: whole(html)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += rewrite(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func movingAlignIntoStyle(_ tag: String) -> String {
        let ns = tag as NSString
        guard let align = alignAttribute.firstMatch(in: tag, options: [], range: whole(tag))
        else { return tag }
        let value = (1...3).lazy
            .map { align.range(at: $0) }
            .first { $0.location != NSNotFound }
            .map { ns.substring(with: $0) } ?? ""
        var rewritten = ns.replacingCharacters(in: align.range, with: "")
        guard !value.isEmpty else { return rewritten }
        let rns = rewritten as NSString
        if let style = styleAttribute.firstMatch(in: rewritten, options: [], range: whole(rewritten)) {
            let valueRange = style.range(at: 1).location != NSNotFound ? style.range(at: 1) : style.range(at: 2)
            var declarations = replacingAll(rns.substring(with: valueRange), textAlignDeclaration, with: "")
                .trimmingCharacters(in: .whitespaces)
            if !declarations.isEmpty, !declarations.hasSuffix(";") { declarations += ";" }
            let merged = (declarations.isEmpty ? "" : declarations + " ") + "text-align: \(value);"
            rewritten = rns.replacingCharacters(in: valueRange, with: merged)
        } else {
            let close = rewritten.hasSuffix("/>") ? 2 : 1
            let head = String(rewritten.dropLast(close))
            rewritten = head + " style=\"text-align: \(value);\"" + String(rewritten.suffix(close))
        }
        return rewritten
    }

    // MARK: - The outline (DocumentIndexRail)

    /// One heading of the document, for the outline that jumps to it.
    struct OutlineEntry: Equatable, Identifiable, Sendable {
        /// The element id the jump scrolls to.
        let id: String
        let text: String
        /// 1–4; a bold-only paragraph counts as 2, as on the web.
        let level: Int
    }

    private static let outlineCandidate = regex(
        "<(h[1-4]|p)\\b([^>]*)>([\\s\\S]*?)</\\1\\s*>", .caseInsensitive)
    private static let boldOnly = regex(
        "^\\s*<(strong|b)\\b[^>]*>([\\s\\S]*?)</\\1\\s*>\\s*\\z", .caseInsensitive)
    private static let idAttribute = regex(
        "\\sid\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", .caseInsensitive)
    private static let anyTag = regex("<[^>]*>")

    /// The document's headings, and the page with an anchor on each one that has none.
    ///
    /// The web's scan (`ToolWorkspace.jsx`, the outline effect beside `DocumentIndexRail`) reads
    /// `h1`–`h4`, and also a paragraph that is nothing but one short bold run — these drafts mark
    /// most of their sections that way, and keying on real headings alone found nothing in a
    /// typical filing. A heading keeps its own id; one without gets `doc-h-N`, N its place in the
    /// outline, as on the web.
    static func anchored(_ html: String) -> (html: String, outline: [OutlineEntry]) {
        let ns = html as NSString
        var outline: [OutlineEntry] = []
        var out = ""
        var cursor = 0
        for match in outlineCandidate.matches(in: html, options: [], range: whole(html)) {
            let tag = ns.substring(with: match.range(at: 1)).lowercased()
            let attributes = ns.substring(with: match.range(at: 2))
            let inner = ns.substring(with: match.range(at: 3))
            let text = visibleText(inner)
            guard !text.isEmpty else { continue }
            let level: Int
            if tag.hasPrefix("h") {
                level = Int(tag.dropFirst()) ?? 2
            } else {
                guard text.count <= 120,
                      let bold = boldOnly.firstMatch(in: inner, options: [], range: whole(inner))
                else { continue }
                let innerNS = inner as NSString
                let closing = "</" + innerNS.substring(with: bold.range(at: 1))
                guard !innerNS.substring(with: bold.range(at: 2)).lowercased()
                        .contains(closing.lowercased())
                else { continue }
                level = 2
            }
            let id: String
            if let existing = attributeValue(idAttribute, in: attributes), !existing.isEmpty {
                id = existing
            } else {
                id = "doc-h-\(outline.count)"
                // The opening tag ends where its attributes do.
                let insertAt = match.range(at: 2).location + match.range(at: 2).length
                out += ns.substring(with: NSRange(location: cursor, length: insertAt - cursor))
                out += " id=\"\(id)\""
                cursor = insertAt
            }
            outline.append(OutlineEntry(id: id, text: text, level: level))
        }
        out += ns.substring(from: cursor)
        return (out, outline)
    }

    static func outline(of html: String) -> [OutlineEntry] { anchored(html).outline }

    private static func attributeValue(_ pattern: NSRegularExpression, in attributes: String) -> String? {
        let ns = attributes as NSString
        guard let match = pattern.firstMatch(in: attributes, options: [], range: whole(attributes))
        else { return nil }
        return (1...3).lazy
            .map { match.range(at: $0) }
            .first { $0.location != NSNotFound }
            .map { ns.substring(with: $0) }
    }

    /// Markup out, the common entities decoded, white space collapsed.
    static func visibleText(_ html: String) -> String {
        var text = replacingAll(html, anyTag, with: " ")
        for (entity, character) in [
            ("&nbsp;", " "), ("&#160;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - The draft the server files (sync-server.js `setMessages`)

extension DraftEdit {

    /// A draft as the server stores it in the Drafts list, derived from one assistant message.
    struct StoredDraft: Equatable, Sendable {
        /// From the trigger line; `Untitled Document` or `Untitled Table` without one.
        let title: String
        /// The type the wrapper claims — `doc` or `table` — which is what a save names.
        let declaredType: String
        /// `doc` or `table` after the content has been read (`resolveCanvasType`).
        let resolvedType: String
        /// The body as stored: cleaned, and for a document its citation tokens taken out.
        let content: String
    }

    private static let reasoningBlock = regex("<think>[\\s\\S]*?</think>")
    private static let canvasTrigger = regex("\\[CANVAS_TRIGGER:\\s*(.*?)\\]")
    private static let tableTrigger = regex("\\[TABLE_TRIGGER:\\s*(.*?)\\]")
    private static let anyTrigger = regex("\\[(?:CANVAS|TABLE)_TRIGGER:")
    private static let canvasBody = regex("<canvas_content>([\\s\\S]*?)</canvas_content>")
    private static let tableBody = regex("<table_content>([\\s\\S]*?)</table_content>")
    private static let usageTail = regex("<usage>[\\s\\S]*\\z")

    /// What the server files when it stores this message — the derivation `setMessages` runs on
    /// every assistant message of every write, `/chat` and `/sync` alike. Nil when it files
    /// nothing. Ported so the app can find the row a draft was filed under, and give the server
    /// an edited body it will recognise as the same row (see `DraftEditService`).
    static func storedDraft(fromMessage content: String) -> StoredDraft? {
        let hasCanvas = content.contains("<canvas_content>")
        let hasTable = content.contains("<table_content>")
        let hasTrigger = anyTrigger.firstMatch(in: content, options: [], range: whole(content)) != nil
        guard hasCanvas || hasTable || hasTrigger else { return nil }

        let isTable = hasTable
            || (!hasCanvas
                && tableTrigger.firstMatch(in: content, options: [], range: whole(content)) != nil
                && canvasTrigger.firstMatch(in: content, options: [], range: whole(content)) == nil)
        let bodyPattern = isTable ? tableBody : canvasBody
        let triggerPattern = isTable ? tableTrigger : canvasTrigger

        let searchable = replacingAll(content, reasoningBlock, with: "")
        let ns = searchable as NSString
        let titleMatch = triggerPattern.firstMatch(in: searchable, options: [], range: whole(searchable))
        let searchFrom = titleMatch?.range.location ?? 0
        let tail = ns.substring(from: searchFrom)

        var body: String?
        if let match = bodyPattern.firstMatch(in: tail, options: [], range: whole(tail)) {
            body = (tail as NSString).substring(with: match.range(at: 1))
        } else if let titleMatch {
            let after = ns.substring(from: titleMatch.range.location + titleMatch.range.length)
            let close = isTable ? "</table_content>" : "</canvas_content>"
            let upTo = after.range(of: close).map { String(after[..<$0.lowerBound]) } ?? after
            let trimmed = replacingAll(upTo, usageTail, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Counted as the server counts, in UTF-16 units.
            if trimmed.utf16.count >= 200 { body = trimmed }
        }
        guard let body else { return nil }

        let title = titleMatch
            .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? (isTable ? "Untitled Table" : "Untitled Document")
        let declared = isTable ? "table" : "doc"
        var cleaned = cleanCanvasContent(body)
        let resolved = DraftShape.resolvedType(declared: declared, content: cleaned)
        if resolved != "table" { cleaned = stripMentions(cleaned) }
        return StoredDraft(title: title, declaredType: declared, resolvedType: resolved, content: cleaned)
    }

    private static let fences = regex("```html?\\s*", .caseInsensitive)
    private static let bareFences = regex("```\\s*")
    private static let bulletLead = regex("^[ \\t]*[•·◦‣⁃▪▸►—–]\\s+", .anchorsMatchLines)
    private static let ellipsisLead = regex("^[ \\t]*\\.{2,}\\s+", .anchorsMatchLines)
    private static let markdownBulletLead = regex("^[ \\t]*[-*+]\\s+", .anchorsMatchLines)
    private static let paddedDash = regex("\\s[—–]+\\s")

    /// The server's `cleanCanvasContent`, applied to every body it files.
    static func cleanCanvasContent(_ text: String) -> String {
        var out = replacingAll(text, fences, with: "")
        out = replacingAll(out, bareFences, with: "")
        out = replacingAll(out, bulletLead, with: "")
        out = replacingAll(out, ellipsisLead, with: "")
        out = replacingAll(out, markdownBulletLead, with: "")
        out = replacingAll(out, paddedDash, with: ", ")
        return stripLeadingNarration(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `normaliseForHash`: the form the server hashes to recognise the same draft saved twice.
    static func normalisedForMatch(_ content: String) -> String {
        content.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// What a filed draft actually is, read from its content — the platform's `src/lib/canvasShape.js`,
/// which the server applies at the storage boundary.
enum DraftShape: String, Equatable, Sendable {
    case empty, table, document

    private static let delimiterRow = DraftEdit.regex(
        "^[ \\t]{0,3}\\|?[ \\t]*:?-+:?[ \\t]*(?:\\|[ \\t]*:?-+:?[ \\t]*)+\\|?[ \\t]*\\z")
    private static let htmlTable = DraftEdit.regex("<table[\\s>]", .caseInsensitive)
    private static let wholeTable = DraftEdit.regex("<table[\\s\\S]*?</table>", .caseInsensitive)
    private static let anyTag = DraftEdit.regex("<[^>]*>")
    private static let spaceEntity = DraftEdit.regex("&nbsp;|&#160;|&#xa0;", .caseInsensitive)
    private static let otherEntity = DraftEdit.regex("&[a-z]+;|&#\\d+;", .caseInsensitive)
    private static let visibleMedia = DraftEdit.regex(
        "<(?:img|hr|br|table|input|svg|iframe)[\\s/>]", .caseInsensitive)

    static func hasMarkdownTable(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n").map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : $0
        }
        guard lines.count > 1 else { return false }
        for index in 1..<lines.count {
            let line = lines[index]
            guard delimiterRow.firstMatch(in: line, options: [], range: DraftEdit.whole(line)) != nil
            else { continue }
            let header = lines[index - 1]
            if header.contains("|"), !header.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        }
        return false
    }

    private static func visibleLength(_ text: String) -> Int {
        var out = DraftEdit.replacingAll(text, anyTag, with: " ")
        out = DraftEdit.replacingAll(out, spaceEntity, with: " ")
        return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").utf16.count
    }

    static func isHTMLTableDominant(_ text: String) -> Bool {
        guard htmlTable.firstMatch(in: text, options: [], range: DraftEdit.whole(text)) != nil
        else { return false }
        let outside = visibleLength(DraftEdit.replacingAll(text, wholeTable, with: " "))
        if outside <= 400 { return true }
        let inside = visibleLength(text) - outside
        return outside * 4 <= inside
    }

    static func hasVisibleContent(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if visibleMedia.firstMatch(in: text, options: [], range: DraftEdit.whole(text)) != nil {
            return true
        }
        var out = DraftEdit.replacingAll(text, anyTag, with: " ")
        out = DraftEdit.replacingAll(out, spaceEntity, with: " ")
        out = DraftEdit.replacingAll(out, otherEntity, with: "x")
        return out.contains { !$0.isWhitespace }
    }

    static func of(_ content: String) -> DraftShape {
        if !hasVisibleContent(content) { return .empty }
        if hasMarkdownTable(content) || isHTMLTableDominant(content) { return .table }
        return .document
    }

    /// `resolveCanvasType`: a table that holds no table is filed as a document; nothing else moves.
    static func resolvedType(declared: String, content: String) -> String {
        let declared = declared == "table" ? "table" : "doc"
        return declared == "table" && of(content) == .document ? "doc" : declared
    }
}
