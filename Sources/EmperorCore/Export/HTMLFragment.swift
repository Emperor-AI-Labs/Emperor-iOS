import Foundation

/// Just enough HTML to turn a drafted fragment into a document.
///
/// Foundation ships no HTML parser, and these fragments are model-authored: inline-styled
/// paragraphs, headings, lists and tables, with no doctype and no guarantee of tidiness. This
/// reads that subset and is deliberately forgiving — an unknown tag is descended into rather than
/// dropped, because the text inside it is the pleading and the tag is only a wrapper.
///
/// Not a general parser and not a sanitiser. It is a reader for markup that is already displayed,
/// used to re-express it in another format.
enum HTMLNode: Equatable, Sendable {
    case text(String)
    indirect case element(tag: String, attributes: [String: String], children: [HTMLNode])

    /// All the text under this node, with runs of whitespace collapsed as HTML would.
    var plainText: String {
        switch self {
        case .text(let value): return value
        case .element(_, _, let children): return children.map(\.plainText).joined()
        }
    }
}

enum HTMLFragment {
    /// Tags that never have a closing tag.
    private static let voidTags: Set<String> = [
        "br", "hr", "img", "input", "meta", "link", "col", "area", "base", "source", "wbr",
    ]

    /// Tags whose contents are not document text.
    private static let droppedTags: Set<String> = ["script", "style", "head", "figcaption"]

    static func parse(_ html: String) -> [HTMLNode] {
        var scanner = Scanner(html)
        return scanner.nodes(until: nil)
    }

    // MARK: - Scanning

    private struct Scanner {
        private let chars: [Character]
        private var index = 0

        init(_ html: String) { chars = Array(html) }

        private var atEnd: Bool { index >= chars.count }

        /// Reads nodes until the matching close tag for `parent`, or the end of input.
        ///
        /// An unmatched close tag is skipped rather than treated as fatal. Model-authored markup
        /// carries stray `</p>` often enough that failing on one would mean refusing to export a
        /// document the user can see on screen.
        mutating func nodes(until parent: String?) -> [HTMLNode] {
            var out: [HTMLNode] = []
            while !atEnd {
                if chars[index] == "<" {
                    if peekIsClosing() {
                        let name = readClosingTag()
                        if let parent, name == parent { return out }
                        continue                      // stray close tag: ignore it
                    }
                    if peekIsComment() { skipComment(); continue }
                    guard let (tag, attributes, selfClosing) = readOpenTag() else {
                        // A bare '<' that is not markup — keep it as text.
                        out.append(.text("<"))
                        index += 1
                        continue
                    }
                    if droppedTags.contains(tag) {
                        if !selfClosing { _ = nodes(until: tag) }
                        continue
                    }
                    if selfClosing || voidTags.contains(tag) {
                        out.append(.element(tag: tag, attributes: attributes, children: []))
                        continue
                    }
                    let children = nodes(until: tag)
                    out.append(.element(tag: tag, attributes: attributes, children: children))
                } else {
                    let text = readText()
                    if !text.isEmpty { out.append(.text(text)) }
                }
            }
            return out
        }

        private func peekIsClosing() -> Bool {
            index + 1 < chars.count && chars[index + 1] == "/"
        }

        private func peekIsComment() -> Bool {
            index + 3 < chars.count
                && chars[index + 1] == "!" && chars[index + 2] == "-" && chars[index + 3] == "-"
        }

        private mutating func skipComment() {
            index += 4
            while index + 2 < chars.count {
                if chars[index] == "-" && chars[index + 1] == "-" && chars[index + 2] == ">" {
                    index += 3
                    return
                }
                index += 1
            }
            index = chars.count
        }

        private mutating func readClosingTag() -> String {
            index += 2                                    // past "</"
            var name = ""
            while !atEnd, chars[index] != ">" {
                name.append(chars[index])
                index += 1
            }
            if !atEnd { index += 1 }                      // past ">"
            return name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        private mutating func readOpenTag() -> (String, [String: String], Bool)? {
            let start = index
            index += 1                                    // past "<"
            var name = ""
            while !atEnd, !chars[index].isWhitespace, chars[index] != ">", chars[index] != "/" {
                name.append(chars[index])
                index += 1
            }
            guard !name.isEmpty, name.first?.isLetter == true else {
                index = start
                return nil
            }

            var attributes: [String: String] = [:]
            var selfClosing = false
            while !atEnd, chars[index] != ">" {
                if chars[index] == "/" { selfClosing = true; index += 1; continue }
                if chars[index].isWhitespace { index += 1; continue }

                var key = ""
                while !atEnd, !chars[index].isWhitespace, chars[index] != "=",
                      chars[index] != ">", chars[index] != "/" {
                    key.append(chars[index])
                    index += 1
                }
                var value = ""
                while !atEnd, chars[index].isWhitespace { index += 1 }
                if !atEnd, chars[index] == "=" {
                    index += 1
                    while !atEnd, chars[index].isWhitespace { index += 1 }
                    if !atEnd, chars[index] == "\"" || chars[index] == "'" {
                        let quote = chars[index]
                        index += 1
                        while !atEnd, chars[index] != quote {
                            value.append(chars[index])
                            index += 1
                        }
                        if !atEnd { index += 1 }
                    } else {
                        while !atEnd, !chars[index].isWhitespace, chars[index] != ">" {
                            value.append(chars[index])
                            index += 1
                        }
                    }
                }
                if !key.isEmpty { attributes[key.lowercased()] = decodeEntities(value) }
            }
            if !atEnd { index += 1 }                      // past ">"
            return (name.lowercased(), attributes, selfClosing)
        }

        private mutating func readText() -> String {
            var raw = ""
            while !atEnd, chars[index] != "<" {
                raw.append(chars[index])
                index += 1
            }
            // Collapsed as a browser would: the fragment's newlines are formatting, not content.
            let collapsed = raw.replacingOccurrences(
                of: "\\s+", with: " ", options: .regularExpression)
            return decodeEntities(collapsed)
        }
    }

    // MARK: - Entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "hellip": "…", "bull": "•", "middot": "·", "sect": "§", "para": "¶", "copy": "©",
        "reg": "®", "trade": "™", "deg": "°", "times": "×", "rupee": "₹",
    ]

    /// Decodes the entities a drafted document actually carries.
    ///
    /// `&nbsp;` matters most: the platform's editor emits it constantly, and left undecoded it
    /// would print as the literal six characters in the middle of a cause title.
    static func decodeEntities(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        var out = ""
        var rest = Substring(raw)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<amp]
            let after = rest.index(after: amp)
            guard let semi = rest[after...].firstIndex(of: ";"),
                  rest.distance(from: after, to: semi) <= 8
            else {
                out.append("&")
                rest = rest[after...]
                continue
            }
            let body = String(rest[after..<semi])
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let value: UInt32?
                if digits.first == "x" || digits.first == "X" {
                    value = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    value = UInt32(digits)
                }
                if let value, let scalar = Unicode.Scalar(value) {
                    out.append(Character(scalar))
                } else {
                    out += "&\(body);"
                }
            } else if let mapped = namedEntities[body.lowercased()] {
                out += mapped
            } else {
                out += "&\(body);"
            }
            rest = rest[rest.index(after: semi)...]
        }
        out += rest
        return out
    }
}
