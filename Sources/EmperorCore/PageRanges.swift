import Foundation

/// Page selections, as a person types them: `1-3, 5, 8-10`.
///
/// Pure string-to-numbers, so it lives here and is tested without a device or a PDF. The PDFKit
/// work itself sits in the app layer.
///
/// Every function is **1-based**, because that is what the page numbers on a document are and
/// what the user types. Converting to 0-based indices is the caller's job, done once, at the
/// boundary with PDFKit — doing it here would make every test read against the wrong numbering.
enum PageRanges {

    /// One contiguous run of pages, keeping the order it was typed in.
    ///
    /// `label` is what the output file is named after, so `1-3` stays `1-3` rather than becoming
    /// `1,2,3` — a filename should look like what the user asked for.
    struct Group: Equatable, Sendable {
        let pages: [Int]
        let label: String
    }

    /// Every page named, flattened, sorted and de-duplicated.
    ///
    /// Use for "extract these pages into one document", where `3-1, 2` and `1-3` mean the same
    /// thing and asking for page 2 twice cannot duplicate it.
    ///
    /// Out-of-range numbers are dropped rather than rejected: a bundle re-exported at a
    /// different length is the common case, and silently ignoring page 400 of a 380-page file is
    /// friendlier than refusing the whole selection. An entirely out-of-range selection returns
    /// empty, which the caller must treat as "nothing to do" rather than "all pages".
    static func parse(_ input: String?, pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        var pages = Set<Int>()
        for part in segments(of: input) {
            switch part {
            case .span(let from, let to):
                for page in min(from, to)...max(from, to) where (1...pageCount).contains(page) {
                    pages.insert(page)
                }
            case .single(let page):
                if (1...pageCount).contains(page) { pages.insert(page) }
            }
        }
        return pages.sorted()
    }

    /// The same syntax, but each comma-separated segment stays its **own** group, in the order
    /// typed.
    ///
    /// `1-3, 5, 8-10` becomes three documents, not one of seven pages. This is the difference
    /// between "extract" and "split", and it is why the two functions exist separately rather
    /// than one calling the other.
    ///
    /// Groups are neither sorted nor de-duplicated against each other: asking for `5, 1-3, 5`
    /// legitimately produces three files, one of which repeats page 5. Within a span the pages
    /// run low to high, so `3-1` yields `[1, 2, 3]` labelled `1-3`.
    static func parseGroups(_ input: String?, pageCount: Int) -> [Group] {
        guard pageCount > 0 else { return [] }
        var groups: [Group] = []
        for part in segments(of: input) {
            switch part {
            case .span(let from, let to):
                let pages = Array(min(from, to)...max(from, to))
                    .filter { (1...pageCount).contains($0) }
                guard let first = pages.first, let last = pages.last else { continue }
                // Labelled from what survived clamping, not from what was typed: a file named
                // 8-40 that holds pages 8-12 is a lie on the filesystem.
                groups.append(
                    Group(pages: pages, label: pages.count > 1 ? "\(first)-\(last)" : "\(first)"))
            case .single(let page):
                if (1...pageCount).contains(page) {
                    groups.append(Group(pages: [page], label: "\(page)"))
                }
            }
        }
        return groups
    }

    /// A filename-safe description of exactly which pages a file holds: `1-8_17-24`.
    ///
    /// Naming an extract after its first and last page is wrong the moment the selection has a
    /// gap in it — `pages_1-24` on a file holding 1-8 and 17-24 claims twenty-four pages and
    /// contains sixteen, which on a disk full of bundle parts is how the wrong document gets
    /// filed. So the label is built from the runs the selection actually contains.
    ///
    /// Past `maxRuns` runs it falls back to a plain count: `31_pages` is uninformative, but
    /// `1-2_5-6_9-10_…` repeated forty times is an unusable filename, and both are honest.
    static func label(_ pages: [Int], maxRuns: Int = 3) -> String {
        let ordered = Set(pages).sorted()
        guard let first = ordered.first else { return "none" }

        var runs: [ClosedRange<Int>] = []
        var start = first
        var previous = first
        for page in ordered.dropFirst() {
            if page != previous + 1 {
                runs.append(start...previous)
                start = page
            }
            previous = page
        }
        runs.append(start...previous)

        guard runs.count <= maxRuns else { return "\(ordered.count)_pages" }
        return runs
            .map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }
            .joined(separator: "_")
    }

    /// Describes a selection for the screen: `7 pages` or `nothing selected`.
    ///
    /// Deliberately counts the flattened selection, so `1-3, 2` reads as 3 pages rather than 4 —
    /// matching what `parse` would actually extract.
    static func describe(_ input: String?, pageCount: Int) -> String {
        switch parse(input, pageCount: pageCount).count {
        case 0: return "nothing selected"
        case 1: return "1 page"
        case let count: return "\(count) pages"
        }
    }

    /// Greedy packing of consecutive pages into parts no larger than `targetBytes`.
    ///
    /// Takes the measured size of each page rather than measuring anything itself, because
    /// getting a page's serialised size means writing it out — which needs PDFKit.
    ///
    /// A single page bigger than the target becomes its own oversized part rather than being
    /// dropped or split further: a page is the smallest thing a PDF can be cut into, and losing
    /// it to satisfy a size cap would silently remove evidence from a bundle. The caller is
    /// expected to say so on screen.
    static func packBySize(_ pageSizes: [Int], targetBytes: Int) -> [[Int]] {
        guard !pageSizes.isEmpty, targetBytes > 0 else { return [] }
        var parts: [[Int]] = []
        var current: [Int] = []
        var currentSize = 0
        for (index, size) in pageSizes.enumerated() {
            if !current.isEmpty, currentSize + size > targetBytes {
                parts.append(current)
                current = []
                currentSize = 0
            }
            current.append(index + 1)
            currentSize += size
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: - Parsing

    private enum Segment {
        case span(Int, Int)
        case single(Int)
    }

    /// Splits on commas and reads each part, ignoring anything that is not a number or a span.
    ///
    /// Deliberately hand-parsed rather than regex: `\d` means the whole Unicode `Nd` category
    /// under ICU but only ASCII under the JavaScript and Java engines this product's other
    /// clients use. A page number typed in Arabic-Indic digits would match here, then fail to
    /// convert, and the segment would vanish rather than being reported.
    private static func segments(of input: String?) -> [Segment] {
        (input ?? "").split(separator: ",", omittingEmptySubsequences: false).compactMap { raw in
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            if let dash = text.firstIndex(of: "-"), dash != text.startIndex {
                let left = text[text.startIndex..<dash].trimmingCharacters(in: .whitespaces)
                let right = text[text.index(after: dash)...].trimmingCharacters(in: .whitespaces)
                guard let from = asciiInt(left), let to = asciiInt(right) else { return nil }
                return .span(from, to)
            }
            guard let page = asciiInt(text) else { return nil }
            return .single(page)
        }
    }

    /// ASCII digits only, matching the other clients rather than ICU's idea of a digit.
    private static func asciiInt(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }
}
