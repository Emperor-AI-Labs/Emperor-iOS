import Foundation

/// Markdown to the HTML the exporters read.
///
/// Both exports take HTML — the PDF renderer and `DocxDocument` alike — because that is what a
/// drafted artifact usually is. A markdown one still has to export, and this is the bridge: it
/// covers what these documents actually contain, which is headings, paragraphs, emphasis and
/// tables, rather than the whole of CommonMark.
///
/// Tables go through `MarkdownTable`, the same reader the on-screen renderer uses, so a
/// chronology cannot come out as a grid on screen and pipe characters in the file.
enum MarkdownHTML {
    /// A chat answer's prose, as the fragment the exporters read.
    ///
    /// An answer is markdown (`ToolWorkspace.jsx:542`: "The reply is Markdown"), so it is
    /// bridged like any markdown document — handed over raw, its line breaks collapse and a
    /// References list runs together into one line of `[1] … [2] … [3] …`. The rare answer the
    /// model wrote as block HTML is sniffed the way an artifact is, and passed through as it is.
    ///
    /// Citation markers stay the plain `[1]` they were written as, beside a References list
    /// with one entry per line: that is how a citation reads on paper, and a filed document has
    /// no use for links into an app.
    static func answerFragment(_ prose: String) -> String {
        StreamArtifact.detectFormat(of: prose, declared: .table) == .html
            ? prose
            : html(from: prose)
    }

    static func html(from markdown: String) -> String {
        var out = ""
        for segment in MarkdownTable.segments(in: markdown) {
            switch segment {
            case .prose(let text): out += prose(text)
            case .table(let table): out += self.table(table)
            }
        }
        return out
    }

    private static func prose(_ text: String) -> String {
        var out = ""
        // A blank line is a paragraph break; a single newline inside one is not.
        for block in text.components(separatedBy: "\n\n") {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // A heading is its own line, wherever in the block it falls, as it is on screen.
            // The lines around it are paragraphs — a References list written straight under its
            // heading, which is how the system prompt lays one out, is not more heading, and a
            // heading written straight under the last paragraph is not more paragraph.
            var paragraph: [String] = []
            func flushParagraph() {
                if paragraph.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    // A soft newline inside a paragraph is a line break, as it is on screen.
                    out += "<p>\(paragraph.map(inline).joined(separator: "<br>"))</p>"
                }
                paragraph = []
            }
            for line in trimmed.components(separatedBy: "\n") {
                if let heading = heading(line.trimmingCharacters(in: .whitespaces)) {
                    flushParagraph()
                    out += heading
                } else {
                    paragraph.append(line)
                }
            }
            flushParagraph()
        }
        return out
    }

    /// `## Title` as an HTML heading, capped at `h3`; nil for a line that is not one.
    ///
    /// The rule the screen uses (`MarkdownBlocks`): up to six hashes and then a space, so
    /// `#1 of 2026` opening a paragraph stays the paragraph it is.
    private static func heading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        let level = min(3, hashes)
        return "<h\(level)>\(inline(rest.trimmingCharacters(in: .whitespaces)))</h\(level)>"
    }

    private static func table(_ table: MarkdownTable) -> String {
        var out = "<table><thead><tr>"
        for header in table.headers { out += "<th>\(inline(header))</th>" }
        out += "</tr></thead><tbody>"
        for row in table.normalisedRows {
            out += "<tr>"
            for cell in row { out += "<td>\(inline(cell))</td>" }
            out += "</tr>"
        }
        return out + "</tbody></table>"
    }

    /// `**bold**` and `*italic*`, and nothing else.
    ///
    /// Escaped first, so a `<` in the prose becomes text rather than a tag the exporter would
    /// then try to read — and so a document about markup does not lose half of itself.
    static func inline(_ text: String) -> String {
        var out = DocxDocument.escape(text)
        out = replacePairs(in: out, marker: "**", tag: "b")
        out = replacePairs(in: out, marker: "*", tag: "i")
        return out
    }

    /// Replaces matched pairs of `marker`. An unmatched one is left as written — an asterisk in
    /// a citation is a character, not an unterminated instruction.
    private static func replacePairs(in text: String, marker: String, tag: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: marker) {
            let after = rest[open.upperBound...]
            guard let close = after.range(of: marker) else { break }
            let inner = after[after.startIndex..<close.lowerBound]
            guard !inner.isEmpty else { break }
            out += rest[rest.startIndex..<open.lowerBound]
            out += "<\(tag)>\(inner)</\(tag)>"
            rest = after[close.upperBound...]
        }
        return out + rest
    }
}
