import Foundation

/// A draft's citation numbers — `[1]`, `[2, 3]`, `<sup>4</sup>` — shown or hidden.
///
/// A drafted document arrives with numbered markers that point at the references the answer
/// lists. The Record draft view lets the reader hide them on the page, and every download asks
/// whether to carry them. Hiding is a **display** choice: the stored draft is never rewritten, so
/// these functions return a new string and leave the original alone.
enum DraftCitations {

    /// Whether the draft carries any citation markers at all — when it does not, there is nothing
    /// to show or hide and the toggle is not offered.
    static func hasMarkers(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return marker.firstMatch(in: text, options: [], range: range) != nil
            || superscript.firstMatch(in: text, options: [], range: range) != nil
    }

    /// The draft without its markers, and without the space a marker left before punctuation.
    static func withoutMarkers(_ text: String) -> String {
        var result = text
        for pattern in [superscript, marker] {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        let range = NSRange(result.startIndex..., in: result)
        return spaceBeforePunctuation.stringByReplacingMatches(
            in: result, options: [], range: range, withTemplate: "$1")
    }

    /// `[1]`, `[1, 2]`, `[3–5]`, with any space before it.
    nonisolated(unsafe) private static let marker = try! NSRegularExpression(
        pattern: "[ \\u00A0]?\\[[0-9]{1,3}(?:\\s*[,–-]\\s*[0-9]{1,3})*\\]", options: [])
    /// `<sup>4</sup>`, `<sup class="dc">[4]</sup>` — a superscript holding only a citation number.
    nonisolated(unsafe) private static let superscript = try! NSRegularExpression(
        pattern: "<sup[^>]*>\\s*\\[?[0-9]{1,3}(?:\\s*[,–-]\\s*[0-9]{1,3})*\\]?\\s*</sup>",
        options: [.caseInsensitive])
    nonisolated(unsafe) private static let spaceBeforePunctuation = try! NSRegularExpression(
        pattern: "[ \\u00A0]+([.,;:])", options: [])
}
