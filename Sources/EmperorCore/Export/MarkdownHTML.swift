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

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let body = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                out += "<h\(min(3, hashes))>\(inline(body))</h\(min(3, hashes))>"
                continue
            }
            // A soft newline inside a paragraph is a line break, as it is on screen.
            let lines = trimmed.components(separatedBy: "\n").map(inline)
            out += "<p>\(lines.joined(separator: "<br>"))</p>"
        }
        return out
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
