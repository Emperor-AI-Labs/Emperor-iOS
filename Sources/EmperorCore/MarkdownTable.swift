import Foundation

/// A GitHub-flavoured markdown table, parsed into something renderable.
///
/// `AttributedString(markdown:)` silently does **not** support tables — it renders the pipe
/// syntax as literal text. Chronologies and lists of dates are a substantial fraction of what
/// this product produces, so a table artifact rendered as raw pipes is a visibly broken answer.
///
/// The parse rule matches the server's own (`src/lib/canvasShape.js:20-28`): a header row
/// containing `|`, **immediately** followed by a delimiter row. That pair, and only that pair,
/// makes something a table — which is what keeps a paragraph containing a stray `|` from being
/// mistaken for one.
struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable {
        case leading, center, trailing
    }

    var headers: [String]
    var alignments: [Alignment]
    var rows: [[String]]

    /// Rows padded or trimmed to the header width, so a renderer can assume a rectangle.
    /// Ragged rows are common in model output and must not drop cells or crash a grid.
    var normalisedRows: [[String]] {
        rows.map { row in
            if row.count == headers.count { return row }
            if row.count > headers.count { return Array(row.prefix(headers.count)) }
            return row + Array(repeating: "", count: headers.count - row.count)
        }
    }

    var columnCount: Int { headers.count }
}

/// A markdown document split into tables and the prose between them.
enum MarkdownSegment: Equatable, Sendable {
    case prose(String)
    case table(MarkdownTable)
}

extension MarkdownTable {

    /// Splits a document into tables and the prose around them, in document order.
    ///
    /// Segmenting rather than extracting: a chronology usually arrives with a sentence of
    /// framing before it and a note after, and dropping either loses the answer's meaning.
    static func segments(in markdown: String) -> [MarkdownSegment] {
        let lines = markdown.components(separatedBy: .newlines)
        var segments: [MarkdownSegment] = []
        var prose: [String] = []
        var index = 0

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(.prose(text)) }
            prose = []
        }

        while index < lines.count {
            if let (table, consumed) = parseTable(from: lines, at: index) {
                flushProse()
                segments.append(.table(table))
                index += consumed
            } else {
                prose.append(lines[index])
                index += 1
            }
        }
        flushProse()
        return segments
    }

    /// The first table in the document, if there is one.
    static func first(in markdown: String) -> MarkdownTable? {
        for segment in segments(in: markdown) {
            if case .table(let table) = segment { return table }
        }
        return nil
    }

    /// Whether the text contains at least one real table.
    static func containsTable(_ markdown: String) -> Bool { first(in: markdown) != nil }

    // MARK: - Parsing

    private static func parseTable(
        from lines: [String], at start: Int
    ) -> (MarkdownTable, Int)? {
        guard start + 1 < lines.count else { return nil }

        let headerLine = lines[start]
        let delimiterLine = lines[start + 1]
        guard headerLine.contains("|"), let alignments = parseDelimiter(delimiterLine) else {
            return nil
        }

        let headers = cells(in: headerLine)
        // A delimiter row that does not agree with the header on width is not a table header —
        // it is a coincidence of punctuation.
        guard !headers.isEmpty, alignments.count == headers.count else { return nil }

        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let line = lines[index]
            // A blank line, or a line with no pipe at all, ends the table.
            guard line.contains("|"),
                  !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            rows.append(cells(in: line))
            index += 1
        }

        let table = MarkdownTable(headers: headers, alignments: alignments, rows: rows)
        return (table, index - start)
    }

    /// Parses `|---|:--:|---:|` into per-column alignments, or nil if this is not a delimiter.
    private static func parseDelimiter(_ line: String) -> [Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return nil }

        let parts = cells(in: line)
        guard !parts.isEmpty else { return nil }

        var alignments: [Alignment] = []
        for part in parts {
            let spec = part.trimmingCharacters(in: .whitespaces)
            // Every cell must be dashes, optionally fenced by colons. Anything else and this
            // is an ordinary row that happens to contain a hyphen.
            let body = spec.hasPrefix(":") ? String(spec.dropFirst()) : spec
            let core = body.hasSuffix(":") ? String(body.dropLast()) : body
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }

            switch (spec.hasPrefix(":"), spec.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    /// Splits a row into cells on unescaped pipes.
    ///
    /// The outer pipes are optional in GFM, so a leading or trailing empty is dropped — but an
    /// empty cell *between* two pipes is real content and must survive.
    private static func cells(in line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false

        for character in line {
            if escaped {
                // Keep `\|` as a literal pipe; keep any other escape verbatim.
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)

        // Drop the empties produced by the optional outer pipes, and only those.
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty,
           line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            cells.removeFirst()
        }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty,
           line.trimmingCharacters(in: .whitespaces).hasSuffix("|") {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
