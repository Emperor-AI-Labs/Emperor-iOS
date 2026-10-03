import Foundation

/// The block structure of a markdown answer: headings, list items, quotes, code, paragraphs.
///
/// `AttributedString(markdown:)` cannot supply this. Its `.full` option encodes block structure
/// as `presentationIntent` runs that SwiftUI's `Text` ignores — which is why the renderers here
/// use `.inlineOnlyPreservingWhitespace`, and why `## Grounds` and `- First` were coming out as
/// literal characters: inline-only parses emphasis and leaves every block marker alone.
///
/// So the blocks are found here and the inline markup inside each one is still left to
/// `AttributedString`. Splitting it this way keeps the part with the edge cases — what counts as
/// a list, how deep it is, where a fence ends — testable without a device.
enum MarkdownBlock: Equatable, Sendable {
    /// 1...6 as written, so a renderer can decide how far to honour it.
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(depth: Int, text: String)
    case numbered(depth: Int, number: Int, text: String)
    case quote(String)
    /// A fenced block, kept verbatim — indentation and all.
    case code(String)

    /// The inline markdown inside this block, for the renderer to hand to `AttributedString`.
    var text: String {
        switch self {
        case .heading(_, let text), .paragraph(let text), .bullet(_, let text),
             .numbered(_, _, let text), .quote(let text), .code(let text):
            return text
        }
    }
}

enum MarkdownBlocks {
    /// Four spaces, or a tab, is one level of nesting — the common convention, and what the
    /// models emit.
    private static let indentWidth = 2

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        var lines = markdown.components(separatedBy: .newlines)[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A fence runs to its closing partner, or to the end if the answer was cut off
            // mid-block — which happens, and must not swallow the rest as code silently.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var body: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    body.append(next)
                }
                blocks.append(.code(body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty { flushParagraph(); continue }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(trimmed == ">" ? 1 : 2))))
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
                continue
            }

            // A horizontal rule is a paragraph break and nothing else here.
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), trimmed.count >= 3 {
                flushParagraph()
                continue
            }

            paragraph.append(line)
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard hashes <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes)
        // `#tag` is not a heading — a hash has to be followed by a space to open one.
        guard rest.first == " " || rest.isEmpty else { return nil }
        return .heading(
            level: hashes,
            text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        // A tab counts as a full level; spaces count in twos, so both 2- and 4-space nesting read
        // as nesting rather than as one flat list.
        let depth = leading.reduce(0) { total, character in
            total + (character == "\t" ? indentWidth : 1)
        } / indentWidth
        let rest = line.dropFirst(leading.count)

        if let marker = rest.first, marker == "-" || marker == "*" || marker == "+" {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            return .bullet(
                depth: depth, text: after.trimmingCharacters(in: .whitespaces))
        }

        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard afterDigits.first == "." || afterDigits.first == ")" else { return nil }
        let body = afterDigits.dropFirst()
        guard body.first == " " else { return nil }
        return .numbered(
            depth: depth, number: Int(digits) ?? 1,
            text: body.trimmingCharacters(in: .whitespaces))
    }
}
