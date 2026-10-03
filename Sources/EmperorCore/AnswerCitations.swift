import Foundation

// Numbered citations in a chat answer: `[2]` in the body, and a References section at the end
// that says what 2 is.
//
// The platform's system prompt makes this mandatory in chat (`src/lib/clerk_identity.js:7-15`):
// every cited statute or case carries a bracketed number, and the answer closes with one line per
// number — "[1] Sexual Harassment of Women at Workplace (POSH) Act, 2013 — Sections 2(a), 9." The
// web turns each number into a badge that leads to its reference (`src/lib/citations.js:78`,
// rendered by `src/tools/renderers/Markdown.jsx:95`). Here they arrived as the literal characters.
//
// This is a port of the web's rules, pinned to them by `CitationGoldenTests`, which replays
// fixtures captured by running `citations.js` itself under Node. Where this file departs from
// the web it says so at the site, and the fixtures carry the web's output for that case so the
// departure stays deliberate.
//
// Not to be confused with `AnnexureMention` — the `<@file.pdf:MARK:7>` tokens that name an
// attached document and page. Those are lifted out of the prose by `StreamContent` before any of
// this runs, and nothing here reads or writes them.

/// One numbered entry in an answer's References.
struct CitationReference: Equatable, Identifiable, Sendable {
    /// The number the body's markers use.
    var number: Int
    /// What follows the number on its line, as inline markdown — what the web shows after its
    /// pill (`citations.js:86`, `rest.trim()`).
    var text: String
    /// Where this entry sits among the answer's references, counting from zero.
    ///
    /// The identity, rather than the number, because a model occasionally lists one number twice
    /// and two rows must still be two rows.
    var ordinal: Int

    var id: Int { ordinal }
}

/// The references an answer lists, looked up by number.
struct CitationIndex: Equatable, Sendable {
    static let empty = CitationIndex(references: [])

    /// Every entry, in the order the answer lists them.
    let references: [CitationReference]
    private let firstByNumber: [Int: Int]

    init(references: [CitationReference]) {
        self.references = references
        var first: [Int: Int] = [:]
        for (position, reference) in references.enumerated() where first[reference.number] == nil {
            first[reference.number] = position
        }
        firstByNumber = first
    }

    /// The entry a marker with this number leads to.
    ///
    /// The first one listed, when a number is listed twice — the web's lookup takes the first
    /// element carrying that id in document order (`citations.js:224-243`).
    func reference(for number: Int) -> CitationReference? {
        firstByNumber[number].map { references[$0] }
    }

    var isEmpty: Bool { references.isEmpty }
}

/// A marker in the body that cites a numbered reference.
struct CitationMarker: Equatable, Sendable {
    /// The three spellings the web turns into badges (`citations.js:98-118`).
    enum Form: Equatable, Sendable {
        /// `[2]`, or a list: `[1, 3]`.
        case bracketed
        /// `【2】`, which some models use instead.
        case fullWidth
        /// `Citation 2`, `Ref. 2`, `ref 2` — the words are replaced by the badge, as on the web.
        case spoken
    }

    /// Where the marker sits, in Unicode scalars from the start of the text it was found in.
    ///
    /// Scalars rather than `Character`s on purpose: a combining mark after `]` would fuse with
    /// it into one grapheme and hide the bracket, while JavaScript — whose rules this ports —
    /// sees the bracket as its own code unit.
    var range: Range<Int>
    /// Each number it cites, in the order written. `[1, 3]` is two.
    var numbers: [Int]
    var form: Form
}

/// A block of an answer, as the renderer lays it out.
enum CitedBlock: Equatable, Sendable {
    case block(MarkdownBlock)
    case table(MarkdownTable)
    /// One or more consecutive reference entries, drawn as a list rather than as the raw lines.
    case references([CitationReference])
}

/// An answer's markdown with its references found and lifted into their own blocks.
struct CitedMarkdown: Equatable, Sendable {
    var index: CitationIndex
    var blocks: [CitedBlock]

    /// Splits `markdown` into renderable blocks, with each reference entry taken out of the
    /// prose and listed.
    ///
    /// ## What counts as a reference entry
    ///
    /// The web's two rules, line by line:
    ///
    /// 1. **Anywhere**, a line that is `[N]` and then text (`citations.js:85`) — optionally
    ///    after one `-`, `*`, `•` or `1.` in the first column, and with `[N]:`, `[N] -` and
    ///    `[N] text` all accepted. A line opening with `[1]` is an entry even outside any
    ///    References heading, which is how a model that drops the heading still gets a list.
    /// 2. **After the first References heading**, a numbered line `N. text` (`citations.js:90`)
    ///    is entry N. The heading is `References`, `References & Authorities`, `Authorities` or
    ///    `Sources`, optionally after up to four `#`, optionally with a colon, alone on its line —
    ///    so `**References**` is not one (rule 1 still finds its `[N]` lines), and neither is a
    ///    sentence that happens to start with the word.
    ///
    /// ## Where this is stricter than the web
    ///
    /// - Nothing inside a fenced code block is an entry or a heading. The web rewrites code too,
    ///   which corrupts the snippet it is showing.
    /// - `[N]: https://…` is a link reference definition, not an entry, when the answer also
    ///   uses `[text][N]` — the definition is what makes that link work. Without such a use it is
    ///   an entry whose text is a URL, as on the web.
    /// - An entry is one line. The web's pattern can reach across a line break (`[1]` alone on a
    ///   line takes the next line as its text, and a bare `-` line above an entry is swallowed);
    ///   no model writes references that way on purpose, and following it would make an entry's
    ///   extent depend on what streams in after it.
    /// - A numbered entry keeps its whole line. The web stops it at the first `<` and spills the
    ///   rest below the box — a rule for HTML that, here, would only cut "damages < 50,000" short.
    static func parse(_ markdown: String) -> CitedMarkdown {
        let lines = markdown.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Array($0) }
        let fenced = fencedLines(lines)
        let definitionLabels = referenceLinkLabels(in: lines, fenced: fenced)

        // The web's heading pattern ends in a line break (`[:\s]*\n`). Nothing needs to check
        // for one here: numbered entries are looked for on the lines *after* the heading, and a
        // heading still streaming in, with no break after it yet, has none.
        let heading = lines.indices.first { index in
            !fenced[index] && isReferencesHeading(lines[index])
        }

        var blocks: [CitedBlock] = []
        var references: [CitationReference] = []
        var pending: [String] = []
        var run: [CitationReference] = []
        var heldBlanks: [String] = []

        func flushMarkdown() {
            guard !pending.isEmpty else { return }
            blocks += markdownBlocks(pending.joined(separator: "\n"))
            pending = []
        }
        func flushRun() {
            guard !run.isEmpty else { return }
            blocks.append(.references(run))
            run = []
        }

        for (position, line) in lines.enumerated() {
            var entry: (number: Int, text: String)?
            if !fenced[position] {
                entry = listedEntry(line)
                if let found = entry, definitionLabels.contains(found.number),
                   isLinkDefinition(line) {
                    entry = nil
                }
                if entry == nil, let heading, position > heading {
                    entry = numberedEntry(line)
                }
            }

            if let entry {
                if run.isEmpty { flushMarkdown() }
                // A blank line between two entries is spacing, not a break in the list.
                heldBlanks = []
                let reference = CitationReference(
                    number: entry.number, text: entry.text, ordinal: references.count)
                references.append(reference)
                run.append(reference)
            } else if !run.isEmpty, line.allSatisfy(Self.isJSWhitespace) {
                heldBlanks.append(Self.string(line))
            } else {
                flushRun()
                pending += heldBlanks
                heldBlanks = []
                pending.append(Self.string(line))
            }
        }
        flushRun()
        pending += heldBlanks
        flushMarkdown()

        return CitedMarkdown(index: CitationIndex(references: references), blocks: blocks)
    }

    /// The same two parsers the renderer always used, run over the prose between entries — so
    /// an answer with no references comes out exactly as it did before this existed.
    private static func markdownBlocks(_ text: String) -> [CitedBlock] {
        MarkdownTable.segments(in: text).flatMap { segment -> [CitedBlock] in
            switch segment {
            case .prose(let prose): return MarkdownBlocks.parse(prose).map(CitedBlock.block)
            case .table(let table): return [.table(table)]
            }
        }
    }

    // MARK: - Line rules

    /// Which lines sit inside a fenced block, fence lines included.
    ///
    /// The same rule `MarkdownBlocks` applies — three backticks or tildes after any indentation,
    /// closed by the next line opening with the same three, or by the end of the answer — so a
    /// line is never an entry here and code there.
    private static func fencedLines(_ lines: [[Unicode.Scalar]]) -> [Bool] {
        var fenced = Array(repeating: false, count: lines.count)
        var open: Unicode.Scalar?
        for (position, line) in lines.enumerated() {
            // Leading whitespace skipped and then three of the same fence character — what
            // `trimmingCharacters(in: .whitespaces).hasPrefix("```")` says, read off the scalars
            // because this runs over every line of every streamed update.
            let start = line.firstIndex { !CharacterSet.whitespaces.contains($0) } ?? line.count
            var fence: Unicode.Scalar?
            if start + 2 < line.count, line[start] == "`" || line[start] == "~",
               line[start + 1] == line[start], line[start + 2] == line[start] {
                fence = line[start]
            }
            if let current = open {
                fenced[position] = true
                if fence == current { open = nil }
            } else if let fence {
                fenced[position] = true
                open = fence
            }
        }
        return fenced
    }

    /// `(?:#{1,4}\s*)?(?:References(?:\s*&\s*Authorities)?|Authorities|Sources)[:\s]*` filling
    /// the line, case-insensitively — `citations.js:90`.
    static func isReferencesHeading(_ line: [Unicode.Scalar]) -> Bool {
        var index = 0
        while index < line.count, line[index] == "#" { index += 1 }
        let hashes = index
        // Five or more cannot match: `#{1,4}` leaves a `#` where the word must start.
        guard hashes <= 4 else { return false }
        if hashes > 0 { index = skipWhitespace(line, from: index) }

        if let end = matchWord("references", in: line, at: index) {
            index = end
            var probe = skipWhitespace(line, from: index)
            if probe < line.count, line[probe] == "&" {
                probe = skipWhitespace(line, from: probe + 1)
                if let end = matchWord("authorities", in: line, at: probe) { index = end }
            }
        } else if let end = matchWord("authorities", in: line, at: index) {
            index = end
        } else if let end = matchWord("sources", in: line, at: index) {
            index = end
        } else {
            return false
        }
        return line[index...].allSatisfy { $0 == ":" || isJSWhitespace($0) }
    }

    /// Rule 1: `(?:[-*•]|\d+\.)?\s*\[(\d+)\](?:\s*[:-]|\s+)([^\n]+)` from the start of a line —
    /// `citations.js:85`, including its backtracking, so `[1]  ` (two trailing spaces) is an
    /// entry with no text there and here alike.
    static func listedEntry(_ line: [Unicode.Scalar]) -> (number: Int, text: String)? {
        var index = 0
        if let first = line.first, first == "-" || first == "*" || first == "•" {
            index = 1
        } else {
            let digits = countDigits(line, from: 0)
            if digits > 0, digits < line.count, line[digits] == "." { index = digits + 1 }
        }
        index = skipWhitespace(line, from: index)

        guard index < line.count, line[index] == "[" else { return nil }
        let digits = countDigits(line, from: index + 1)
        guard digits > 0, index + 1 + digits < line.count, line[index + 1 + digits] == "]",
              let number = Int(string(line[(index + 1)..<(index + 1 + digits)]))
        else { return nil }
        let afterBracket = index + digits + 2

        // `\s*[:-]` and at least one character after it.
        let separator = skipWhitespace(line, from: afterBracket)
        if separator < line.count, line[separator] == ":" || line[separator] == "-",
           separator + 1 < line.count {
            return (number, jsTrimmed(line[(separator + 1)...]))
        }

        // `\s+` and at least one character after it. With nothing but spaces left, the pattern
        // hands one space back to `[^\n]+`, which is how two trailing spaces still match.
        let text = skipWhitespace(line, from: afterBracket)
        let spaces = text - afterBracket
        guard spaces >= 1 else { return nil }
        if text < line.count { return (number, jsTrimmed(line[text...])) }
        return spaces >= 2 ? (number, "") : nil
    }

    /// Rule 2: `(\d+)\.\s+` and text, from the start of a line under the heading —
    /// `citations.js:91`.
    static func numberedEntry(_ line: [Unicode.Scalar]) -> (number: Int, text: String)? {
        let digits = countDigits(line, from: 0)
        guard digits > 0, digits < line.count, line[digits] == ".",
              let number = Int(string(line[0..<digits]))
        else { return nil }
        let text = skipWhitespace(line, from: digits + 1)
        let spaces = text - (digits + 1)
        guard spaces >= 1 else { return nil }
        // `[^\n<]+`: the text may not open with `<` unless a space can be handed back to it.
        if text < line.count, line[text] != "<" { return (number, jsTrimmed(line[text...])) }
        return spaces >= 2 ? (number, jsTrimmed(line[text...])) : nil
    }

    /// `[N]: destination` with nothing after it but an optional quoted title — the CommonMark
    /// shape of a link reference definition.
    private static func isLinkDefinition(_ line: [Unicode.Scalar]) -> Bool {
        let text = string(line).trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("["), let colon = text.range(of: "]:") else { return false }
        let rest = text[colon.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let destination = rest.split(separator: " ", maxSplits: 1).first,
              destination.contains(":") || destination.hasPrefix("<") || destination.hasPrefix("/")
                || destination.hasPrefix("www.")
        else { return false }
        let title = rest.dropFirst(destination.count).trimmingCharacters(in: .whitespaces)
        return title.isEmpty
            || (title.hasPrefix("\"") && title.hasSuffix("\"") && title.count >= 2)
            || (title.hasPrefix("'") && title.hasSuffix("'") && title.count >= 2)
            || (title.hasPrefix("(") && title.hasSuffix(")"))
    }

    /// Every `N` the answer uses as the label of a reference-style link, `[text][N]`.
    private static func referenceLinkLabels(
        in lines: [[Unicode.Scalar]], fenced: [Bool]
    ) -> Set<Int> {
        var labels: Set<Int> = []
        for (position, line) in lines.enumerated() where !fenced[position] {
            // `][` is the only way a reference-style link can be written, so a line without
            // one is not worth scanning.
            guard zip(line, line.dropFirst()).contains(where: { $0 == "]" && $1 == "[" }) else {
                continue
            }
            labels.formUnion(CitationMarkers.referenceLinkLabels(in: line))
        }
        return labels
    }

    // MARK: - Scalars

    /// JavaScript's `\s`, which is what the web's patterns mean by whitespace: the Unicode space
    /// separators, the line terminators, and U+FEFF.
    static func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F,
             0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// JavaScript's `\d`: ASCII only. `Character.isNumber` would also accept `१`, which the web
    /// does not, and an entry the web would not show must not appear here.
    static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    static func countDigits(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var end = start
        while end < scalars.count, isASCIIDigit(scalars[end]) { end += 1 }
        return end - start
    }

    static func skipWhitespace(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var end = start
        while end < scalars.count, isJSWhitespace(scalars[end]) { end += 1 }
        return end
    }

    /// `String.prototype.trim`.
    static func jsTrimmed(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var slice = scalars
        while let first = slice.first, isJSWhitespace(first) { slice = slice.dropFirst() }
        while let last = slice.last, isJSWhitespace(last) { slice = slice.dropLast() }
        return string(slice)
    }

    /// The lowercase ASCII `word` at `start`, matched case-insensitively — the `i` flag on an
    /// ASCII pattern.
    static func matchWord(_ word: String, in scalars: [Unicode.Scalar], at start: Int) -> Int? {
        var index = start
        for expected in word.unicodeScalars {
            guard index < scalars.count else { return nil }
            let value = scalars[index].value
            let lowered = (0x41...0x5A).contains(value) ? value + 0x20 : value
            guard lowered == expected.value else { return nil }
            index += 1
        }
        return index
    }

    static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}

// MARK: - Inline markers

/// Finds citation markers in one block of inline markdown.
enum CitationMarkers {

    /// Every citation-shaped marker in `text`, in order, whether or not the answer lists it.
    ///
    /// The web's three patterns (`citations.js:98-118`), with what it refuses kept refused:
    ///
    /// - `[2]` or `[1, 3]` — digits and commas only, so `[ ]`, `[x]`, `[^1]`, `[2–4]`, `[a]` and
    ///   `[Settled]` are never markers — and not followed by `(`, which would make it a link.
    /// - `【2】`, the full-width spelling.
    /// - `Citation 2`, `Ref. 2`, `ref 2`: the word, whitespace, digits, then a word boundary.
    ///   The web does not anchor the start of the word, so "Cross-ref 2" is a marker there and
    ///   here; the boundary at the end is ASCII-only, as in JavaScript.
    ///
    /// ## Where this is stricter than the web
    ///
    /// The web runs its patterns over the raw text. These are skipped here, because rewriting
    /// them breaks what they are:
    ///
    /// - inline code, `` `like [1] this` ``, and anything after a backslash;
    /// - a markdown link, text and destination both — `[see [1]](https://…)` keeps working as a
    ///   link — and the label of a reference-style link, `[the judgment][2]`;
    /// - an autolink, `<https://…>`, and an annexure token, `<@file.pdf:P-1>`, including one
    ///   still arriving — those are `StreamContent`'s, never this file's.
    static func find(in text: String) -> [CitationMarker] {
        find(in: Array(text.unicodeScalars))
    }

    static func find(in scalars: [Unicode.Scalar]) -> [CitationMarker] {
        Scanner(scalars).markers()
    }

    /// The labels of `[text][N]` reference-style links on one line.
    static func referenceLinkLabels(in line: [Unicode.Scalar]) -> Set<Int> {
        Scanner(line).referenceLabels()
    }

    private struct Scanner {
        let s: [Unicode.Scalar]
        init(_ scalars: [Unicode.Scalar]) { s = scalars }

        func markers() -> [CitationMarker] {
            var found: [CitationMarker] = []
            var index = 0
            while index < s.count {
                // Only these characters can start anything this scanner cares about; every other
                // one is stepped over without a look, since this runs on every streamed update.
                switch s[index] {
                case "\\", "`", "<":
                    if let skip = skippedSpan(at: index) {
                        index = skip
                        continue
                    }
                case "[":
                    if let marker = bracketed(at: index) {
                        found.append(marker)
                        index = marker.range.upperBound
                        continue
                    }
                    if let end = linkEnd(at: index) {
                        index = end
                        continue
                    }
                case "【":
                    if let marker = fullWidth(at: index) {
                        found.append(marker)
                        index = marker.range.upperBound
                        continue
                    }
                case "c", "C", "r", "R":
                    if let marker = spoken(at: index) {
                        found.append(marker)
                        index = marker.range.upperBound
                        continue
                    }
                default:
                    break
                }
                index += 1
            }
            return found
        }

        func referenceLabels() -> Set<Int> {
            var labels: Set<Int> = []
            var index = 0
            while index < s.count {
                if s[index] == "\\" || s[index] == "`" || s[index] == "<",
                   let skip = skippedSpan(at: index) {
                    index = skip
                    continue
                }
                if s[index] == "[", bracketed(at: index) == nil,
                   let close = matchingBracket(from: index), close + 1 < s.count,
                   s[close + 1] == "[", let labelEnd = matchingBracket(from: close + 1) {
                    let label = CitedMarkdown.string(s[(close + 2)..<labelEnd])
                    if let number = Int(label), label.unicodeScalars.allSatisfy(
                        CitedMarkdown.isASCIIDigit) {
                        labels.insert(number)
                    }
                    index = labelEnd + 1
                    continue
                }
                index += 1
            }
            return labels
        }

        // MARK: Spans that are never read

        /// The end of an escape, a code span, an autolink or an annexure token starting here.
        private func skippedSpan(at index: Int) -> Int? {
            switch s[index] {
            case "\\":
                // A backslash escapes ASCII punctuation; `\[1]` is the author asking for brackets.
                if index + 1 < s.count, isASCIIPunctuation(s[index + 1]) { return index + 2 }
                return nil
            case "`":
                let run = backtickRun(at: index)
                // An unclosed run is literal backticks, and the text after it is still prose.
                return codeSpanEnd(openingAt: index, length: run) ?? index + run
            case "<":
                return annexureTokenEnd(at: index) ?? autolinkEnd(at: index)
            default:
                return nil
            }
        }

        private func backtickRun(at index: Int) -> Int {
            var end = index
            while end < s.count, s[end] == "`" { end += 1 }
            return end - index
        }

        /// CommonMark: a code span closes at the next run of exactly as many backticks.
        private func codeSpanEnd(openingAt index: Int, length: Int) -> Int? {
            var probe = index + length
            while probe < s.count {
                if s[probe] == "`" {
                    let run = backtickRun(at: probe)
                    if run == length { return probe + run }
                    probe += run
                } else {
                    probe += 1
                }
            }
            return nil
        }

        /// `<@…>`, or `<@…` running to the end of the line while it is still streaming in.
        private func annexureTokenEnd(at index: Int) -> Int? {
            guard index + 1 < s.count, s[index + 1] == "@" else { return nil }
            var probe = index + 2
            while probe < s.count, s[probe] != "\n" {
                if s[probe] == ">" { return probe + 1 }
                probe += 1
            }
            return probe
        }

        /// `<scheme:…>` — CommonMark's URI autolink.
        private func autolinkEnd(at index: Int) -> Int? {
            var probe = index + 1
            guard probe < s.count, isASCIILetter(s[probe]) else { return nil }
            probe += 1
            while probe < s.count,
                  isASCIILetter(s[probe]) || CitedMarkdown.isASCIIDigit(s[probe])
                    || s[probe] == "+" || s[probe] == "." || s[probe] == "-" {
                probe += 1
            }
            let schemeLength = probe - index - 1
            guard (2...32).contains(schemeLength), probe < s.count, s[probe] == ":" else {
                return nil
            }
            probe += 1
            while probe < s.count {
                let scalar = s[probe]
                if scalar == ">" { return probe + 1 }
                if scalar == "<" || scalar.value <= 0x20 { return nil }
                probe += 1
            }
            return nil
        }

        /// The end of an inline link `[text](destination)` or a reference-style link
        /// `[text][label]` opening here; nil for brackets that are only brackets.
        private func linkEnd(at index: Int) -> Int? {
            guard let close = matchingBracket(from: index), close + 1 < s.count else {
                return nil
            }
            switch s[close + 1] {
            case "(":
                return matchingParenthesis(from: close + 1).map { $0 + 1 }
            case "[":
                return matchingBracket(from: close + 1).map { $0 + 1 }
            default:
                return nil
            }
        }

        private func matchingBracket(from index: Int) -> Int? {
            var depth = 0
            var probe = index
            while probe < s.count {
                switch s[probe] {
                case "\\" where probe + 1 < s.count && isASCIIPunctuation(s[probe + 1]):
                    probe += 2
                    continue
                case "`":
                    // A code span binds tighter than a bracket: `[a `]` b]` is one bracket pair.
                    let run = backtickRun(at: probe)
                    probe = codeSpanEnd(openingAt: probe, length: run) ?? probe + run
                    continue
                case "[":
                    depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 { return probe }
                default:
                    break
                }
                probe += 1
            }
            return nil
        }

        private func matchingParenthesis(from index: Int) -> Int? {
            var depth = 0
            var probe = index
            while probe < s.count {
                switch s[probe] {
                case "\\" where probe + 1 < s.count && isASCIIPunctuation(s[probe + 1]):
                    probe += 2
                    continue
                case "(":
                    depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 { return probe }
                default:
                    break
                }
                probe += 1
            }
            return nil
        }

        // MARK: The three marker forms

        /// `\[(\d+(?:\s*,\s*\d+)*)\](?!\()` — `citations.js:98`.
        private func bracketed(at index: Int) -> CitationMarker? {
            guard s[index] == "[",
                  let (numbers, close) = numberList(from: index + 1, closer: "]")
            else { return nil }
            if close + 1 < s.count, s[close + 1] == "(" { return nil }
            return CitationMarker(range: index..<(close + 1), numbers: numbers, form: .bracketed)
        }

        /// `【(\d+(?:\s*,\s*\d+)*)】` — `citations.js:108`.
        private func fullWidth(at index: Int) -> CitationMarker? {
            guard s[index] == "【",
                  let (numbers, close) = numberList(from: index + 1, closer: "】")
            else { return nil }
            return CitationMarker(range: index..<(close + 1), numbers: numbers, form: .fullWidth)
        }

        /// `(?:Citation|Ref\.?)\s+(\d+)\b`, case-insensitive — `citations.js:118`.
        private func spoken(at index: Int) -> CitationMarker? {
            let first = s[index].value | 0x20
            guard first == 0x63 || first == 0x72 else { return nil }  // c, r
            var probe: Int
            if let end = CitedMarkdown.matchWord("citation", in: s, at: index) {
                probe = end
            } else if let end = CitedMarkdown.matchWord("ref", in: s, at: index) {
                probe = end
                if probe < s.count, s[probe] == "." { probe += 1 }
            } else {
                return nil
            }
            let digitsStart = CitedMarkdown.skipWhitespace(s, from: probe)
            guard digitsStart > probe else { return nil }
            let digits = CitedMarkdown.countDigits(s, from: digitsStart)
            guard digits > 0 else { return nil }
            let end = digitsStart + digits
            // `\b`, in JavaScript's ASCII sense: the digits may not run on into a word character.
            if end < s.count, isASCIIWordCharacter(s[end]) { return nil }
            guard let number = Int(CitedMarkdown.string(s[digitsStart..<end])) else { return nil }
            return CitationMarker(range: index..<end, numbers: [number], form: .spoken)
        }

        /// `\d+(?:\s*,\s*\d+)*` followed by `closer`; the numbers and the closer's position.
        private func numberList(from start: Int, closer: Unicode.Scalar) -> ([Int], Int)? {
            var numbers: [Int] = []
            var probe = start
            while true {
                let digits = CitedMarkdown.countDigits(s, from: probe)
                // An overflowing number is still citation-shaped to the web, but no reference
                // can carry it, so it is left as the text it is.
                guard digits > 0,
                      let number = Int(CitedMarkdown.string(s[probe..<(probe + digits)]))
                else { return nil }
                numbers.append(number)
                probe += digits
                let afterSpace = CitedMarkdown.skipWhitespace(s, from: probe)
                if afterSpace < s.count, s[afterSpace] == "," {
                    probe = CitedMarkdown.skipWhitespace(s, from: afterSpace + 1)
                    continue
                }
                guard probe < s.count, s[probe] == closer else { return nil }
                return (numbers, probe)
            }
        }

        // MARK: Character classes

        private func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
            (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
        }

        private func isASCIIWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
            isASCIILetter(scalar) || CitedMarkdown.isASCIIDigit(scalar) || scalar == "_"
        }

        private func isASCIIPunctuation(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: return true
            default: return false
            }
        }
    }
}

// MARK: - Links the renderer can intercept

/// The private URL a citation badge carries, so a tap on it can be told apart from a real link.
///
/// `emperor-citation:2#5` — the number, then which occurrence in its block this is. The
/// occurrence is not read back; it is there so that `[1][1]` produces two links rather than one
/// run, since `AttributedString` merges adjacent runs whose attributes are equal.
enum CitationLink {
    static let scheme = "emperor-citation"

    static func url(for number: Int, occurrence: Int = 0) -> URL? {
        URL(string: string(for: number, occurrence: occurrence))
    }

    static func string(for number: Int, occurrence: Int = 0) -> String {
        "\(scheme):\(number)#\(occurrence)"
    }

    /// The number a citation link carries, or nil for any other URL — which is then opened as
    /// the link it is.
    static func number(from url: URL) -> Int? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let absolute = url.absoluteString
        guard let colon = absolute.firstIndex(of: ":") else { return nil }
        var rest = absolute[absolute.index(after: colon)...]
        while rest.hasPrefix("/") { rest = rest.dropFirst() }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }
}

/// An inline text with its resolvable markers rewritten as citation links.
struct CitationLinkedText: Equatable, Sendable {
    /// Inline markdown for `AttributedString`, each badge a link to `CitationLink`.
    var markdown: String
    /// The references this text cites, in the order first cited, each once.
    var references: [CitationReference]
}

enum CitationMarkup {

    /// Rewrites every marker the answer lists into a markdown link the renderer draws as a badge.
    ///
    /// A marker is left exactly as written — `[7]` stays `[7]` — unless **every** number in it
    /// has an entry. The web makes a badge of any bracketed number, but one with no entry leads
    /// nowhere: its preview says "Authority Reference [7]" and its click finds nothing to jump to.
    /// On a phone that is a control that does nothing. Leaving it as text also covers an answer
    /// still streaming, whose markers arrive long before its References: they read as `[1]` until
    /// entry 1 lands, then become badges, and never pass through anything broken on the way.
    ///
    /// `holdingTrailingMarker` is for the last block of an answer that is still arriving: a
    /// marker that ends exactly where the text does may not be finished — `Ref 1` may become
    /// `Ref 12`, `[1]` may become `[1](https://…)` — so it waits for the next character.
    static func linked(
        _ text: String, citations: CitationIndex, holdingTrailingMarker: Bool = false
    ) -> CitationLinkedText {
        guard !citations.isEmpty else { return CitationLinkedText(markdown: text, references: []) }
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var cited: [CitationReference] = []
        var cursor = 0
        var occurrence = 0

        for marker in CitationMarkers.find(in: scalars) {
            if holdingTrailingMarker, marker.range.upperBound == scalars.count { continue }
            let references = marker.numbers.compactMap { citations.reference(for: $0) }
            guard references.count == marker.numbers.count else { continue }

            let start = marker.range.lowerBound
            // `![1](…)` would be an image. A literal `!` just before a marker is escaped so it
            // stays the character the model wrote.
            if start > cursor, scalars[start - 1] == "!", !isEscaped(scalars, at: start - 1) {
                output.append(contentsOf: scalars[cursor..<(start - 1)])
                output.append(contentsOf: "\\!".unicodeScalars)
            } else {
                output.append(contentsOf: scalars[cursor..<start])
            }

            let links = marker.numbers.map { number -> String in
                occurrence += 1
                return "[\(number)](\(CitationLink.string(for: number, occurrence: occurrence)))"
            }
            // Separated by a space, as the web separates `[1, 2]` into two badges.
            output.append(contentsOf: links.joined(separator: " ").unicodeScalars)
            cursor = marker.range.upperBound

            for reference in references where !cited.contains(where: { $0.number == reference.number }) {
                cited.append(reference)
            }
        }
        guard !cited.isEmpty else { return CitationLinkedText(markdown: text, references: []) }
        output.append(contentsOf: scalars[cursor...])
        return CitationLinkedText(markdown: String(output), references: cited)
    }

    /// Rewrites every marker, listed or not, with `replacement` — for comparing against the
    /// web's own output, where each marker becomes one `[N](#cite-N)` per number.
    static func rewritingMarkers(
        in text: String, with replacement: (CitationMarker) -> String
    ) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var cursor = 0
        for marker in CitationMarkers.find(in: scalars) {
            output.append(contentsOf: scalars[cursor..<marker.range.lowerBound])
            output.append(contentsOf: replacement(marker).unicodeScalars)
            cursor = marker.range.upperBound
        }
        output.append(contentsOf: scalars[cursor...])
        return String(output)
    }

    private static func isEscaped(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var backslashes = 0
        var probe = index - 1
        while probe >= 0, scalars[probe] == "\\" {
            backslashes += 1
            probe -= 1
        }
        return backslashes % 2 == 1
    }
}

// MARK: - Colour

extension Palette {
    /// The wash behind a citation number, inline and in the References list.
    ///
    /// The accent at 8%. The web's badge uses 16% (`src/ui/theme.css:1489`), but the number is
    /// drawn in `accentText` at caption size, and at 16% that falls under 4.5:1 on the light
    /// canvas. 8% is the strongest wash that keeps the number at AA on the canvas and on a card
    /// in both appearances; `CitationTests` measures it.
    var citationFill: PaletteColor {
        PaletteColor(accent.red, accent.green, accent.blue, opacity: 0.08)
    }
}
