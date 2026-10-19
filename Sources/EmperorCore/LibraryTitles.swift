import Foundation

// The Library's shared text vocabulary, ported from the web's `coverTheme.js`: a human title from
// a scraped one, what a cover prints, the facts under a card, Indian-grouped counts and short
// dates. Pure functions — every one is pinned by `LibraryTitleTests`.

/// One compiled regular expression and the ways this port uses it.
///
/// `NSRegularExpression` rather than Swift `Regex` because the web's patterns lean on
/// look-behind, which Swift `Regex` does not offer, and ICU's dialect is close enough to
/// JavaScript's that the patterns port with few changes.
struct TextPattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, options: NSRegularExpression.Options = []) {
        // A pattern here is a constant written by the developer: a failure is a programming
        // error, found by the first test that touches it.
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    private func range(_ text: String) -> NSRange { NSRange(text.startIndex..., in: text) }

    func test(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: range(text)) != nil
    }

    /// The first match's capture groups (`[0]` is the whole match), or nil.
    func groups(in text: String) -> [String?]? {
        guard let match = regex.firstMatch(in: text, range: range(text)) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) }
        }
    }

    /// The first match's location, as an offset into the string's UTF-16 view.
    func firstMatchRange(in text: String) -> Range<String.Index>? {
        guard let match = regex.firstMatch(in: text, range: range(text)) else { return nil }
        return Range(match.range, in: text)
    }

    func replacing(_ text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: range(text), withTemplate: template)
    }

    /// Replaces every match through a closure that sees the whole match and its groups.
    func replacing(_ text: String, _ transform: ([String?]) -> String) -> String {
        let matches = regex.matches(in: text, range: range(text))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = text.startIndex
        for match in matches {
            guard let whole = Range(match.range, in: text) else { continue }
            out += text[cursor..<whole.lowerBound]
            let groups = (0..<match.numberOfRanges).map { i in
                Range(match.range(at: i), in: text).map { String(text[$0]) }
            }
            out += transform(groups)
            cursor = whole.upperBound
        }
        out += text[cursor...]
        return out
    }

    func split(_ text: String) -> [String] {
        var out: [String] = []
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: range(text)) {
            guard let r = Range(match.range, in: text) else { continue }
            out.append(String(text[cursor..<r.lowerBound]))
            cursor = r.upperBound
        }
        out.append(String(text[cursor...]))
        return out
    }
}

enum LibraryTitles {

    // MARK: - Hashing

    /// FNV-1a over UTF-16 code units — the web's `hashOf`, so the same document gets the same
    /// cover cloth in the browser and on the phone.
    static func hashOf(_ value: String) -> UInt32 {
        var h: UInt32 = 0x811c9dc5
        for unit in value.utf16 {
            h ^= UInt32(unit)
            h = h &* 0x01000193
        }
        return h
    }

    static func hashOf(_ value: Int) -> UInt32 { hashOf(String(value)) }

    // MARK: - Titles

    private static let uuidish = TextPattern(#"^[0-9a-f]{6,}(-[0-9a-f]{3,}){2,}$"#, options: [.caseInsensitive])
    private static let junkTitle = TextPattern(
        #"^(view|download|pdf|accessible|click here|link|file|document)?[\s_-]*(\(?\s*(pdf)?\s*[\d.]*\s*[km]b\s*\)?)?$"#,
        options: [.caseInsensitive])
    private static let markdown = TextPattern(#"[#*_`]+"#)
    private static let listNumber = TextPattern(#"^\s*\(\s*\d+\s*\)\s*"#)
    private static let pdfTail = TextPattern(#"[\s_-]*\(\s*pdf[^)]*\)\s*$"#, options: [.caseInsensitive])
    private static let leadingDebris = TextPattern(#"^[^\p{L}\p{N}(]+"#)
    private static let unbalancedBracket = TextPattern(#"^\(([^)]*)$"#)
    private static let spaces = TextPattern(#"\s+"#)
    private static let smallWords = TextPattern(#"\b(Of|And|The|In|For|To|On|By|Or|An|A)\b"#)
    private static let wordStart = TextPattern(#"\b([a-z])"#)

    /// The title as the row has it, debris removed — empty when nothing usable is left.
    static func cleanTitle(_ raw: String?) -> String {
        var t = raw ?? ""
        t = markdown.replacing(t, with: " ")
        t = listNumber.replacing(t, with: "")
        t = pdfTail.replacing(t, with: "")
        t = leadingDebris.replacing(t, with: "")
        t = unbalancedBracket.replacing(t, with: "$1")
        t = spaces.replacing(t, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || junkTitle.test(t) || uuidish.test(t) { return "" }
        // An all-caps statute title reads as shouting at cover sizes; title-case it.
        if t.count > 12, t == t.uppercased(), t.rangeOfCharacter(from: .uppercaseLetters) != nil {
            t = wordStart.replacing(t.lowercased()) { groups in (groups[1] ?? "").uppercased() }
            t = smallWords.replacing(t) { groups in
                // The regex has no notion of "first word"; the leading one is re-capitalised below.
                (groups[1] ?? "").lowercased()
            }
        }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    /// True when the row has no usable title and `tidyTitle` had to name it.
    static func isUntitled(_ doc: CatalogueDocument) -> Bool {
        cleanTitle(doc.title).isEmpty
    }

    /// A human title, never empty: the server's read-time title when it sent one, else the
    /// cleaned title, else the reference or series, else a plain name for the kind of document.
    static func tidyTitle(_ doc: CatalogueDocument) -> String {
        if let display = doc.displayTitle?.nilIfEmpty {
            let cleaned = cleanTitle(display)
            return cleaned.isEmpty ? display : cleaned
        }
        let cleaned = cleanTitle(doc.title)
        if !cleaned.isEmpty { return cleaned }
        if let reference = doc.reference?.nilIfEmpty { return reference }
        if let series = doc.series?.nilIfEmpty {
            return doc.volume.map { "\(series), vol. \($0)" } ?? series
        }
        let name = doc.theme.untitled
        return doc.year.map { "\(name), \($0)" } ?? name
    }

    // MARK: - Dates and counts

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let isoDay = TextPattern(#"^(\d{4})-(\d{2})-(\d{2})"#)

    /// `1979-05-04` → `4 May 1979`. Anything unparsable comes back as given.
    static func shortDay(_ iso: String?) -> String {
        guard let iso, let g = isoDay.groups(in: iso), let y = g[1], let m = g[2].flatMap({ Int($0) }),
              let d = g[3].flatMap({ Int($0) }), (1...12).contains(m)
        else { return iso ?? "" }
        return "\(d) \(months[m - 1]) \(y)"
    }

    /// `2,71,480` — Indian grouping, as the platform prints counts.
    static func count(_ n: Int) -> String { DisplayText.grouped(n) }

    // MARK: - Covers and cards

    private static let versus = TextPattern(#"^(.+?)\s+(?:vs\.?|v\.|versus)\s+(.+)$"#, options: [.caseInsensitive])

    /// The case's two parties, from the row or from the "X vs Y" in its title.
    static func parties(of doc: CatalogueDocument) -> (String, String)? {
        if let p = doc.petitioner?.nilIfEmpty, let r = doc.respondent?.nilIfEmpty { return (p, r) }
        guard let g = versus.groups(in: tidyTitle(doc)), let a = g[1], let b = g[2] else { return nil }
        return (a, b)
    }

    /// What a typographic cover prints.
    struct CoverFields: Equatable, Sendable {
        var kicker: String
        var title: String?
        var parties: (String, String)?
        var foot: [String]

        static func == (lhs: CoverFields, rhs: CoverFields) -> Bool {
            lhs.kicker == rhs.kicker && lhs.title == rhs.title && lhs.foot == rhs.foot
                && lhs.parties?.0 == rhs.parties?.0 && lhs.parties?.1 == rhs.parties?.1
        }
    }

    static func coverFields(_ doc: CatalogueDocument) -> CoverFields {
        let theme = doc.theme
        let year = doc.coverYear
        if doc.category == LibraryCollection.caseLaw.rawValue || doc.category == LibraryCollection.tribunals.rawValue {
            let parties = parties(of: doc)
            let day = doc.decidedOn.map(shortDay) ?? year
            return CoverFields(
                kicker: doc.courtLabel?.nilIfEmpty ?? theme.cap,
                title: parties == nil ? tidyTitle(doc) : nil,
                parties: parties,
                foot: [day, doc.neutralCitation ?? ""].filter { !$0.isEmpty })
        }
        let volume = doc.volume?.nilIfEmpty.map { "Vol. \($0)" } ?? ""
        let kicker: String
        if doc.category == LibraryCollection.bareActs.rawValue {
            kicker = doc.jurisdiction?.nilIfEmpty ?? "Central"
        } else {
            kicker = doc.series?.nilIfEmpty ?? theme.cap
        }
        return CoverFields(kicker: kicker, title: tidyTitle(doc), parties: nil,
                           foot: [volume, year].filter { !$0.isEmpty })
    }

    /// The facts a card prints under its title, most useful first. Empty facts are left out.
    static func meta(_ doc: CatalogueDocument) -> [String] {
        if doc.category == LibraryCollection.caseLaw.rawValue || doc.category == LibraryCollection.tribunals.rawValue {
            let number: String? = doc.neutralCitation?.nilIfEmpty
                ?? doc.caseNumber?.nilIfEmpty.map { n in
                    (doc.caseType?.nilIfEmpty.map { "\($0) " } ?? "") + n
                }
            return [
                doc.courtLabel?.nilIfEmpty,
                doc.decidedOn.map(shortDay) ?? doc.year.map(String.init),
                number,
            ].compactMap { $0 }
        }
        return [
            doc.category == LibraryCollection.bareActs.rawValue ? (doc.jurisdiction?.nilIfEmpty ?? "Central") : doc.jurisdiction?.nilIfEmpty,
            doc.series?.nilIfEmpty.map { s in doc.volume.map { "\(s), vol. \($0)" } ?? s },
            doc.year.map(String.init),
            (doc.hasChildren ?? 0) > 0 ? "\(doc.hasChildren ?? 0) related" : nil,
        ].compactMap { $0 }
    }

    /// Which of the collection's cloth shades a document is bound in: volumes of one series
    /// share a cloth (a run of law reports is bound alike); others vary by id.
    static func clothIndex(_ doc: CatalogueDocument) -> Int {
        let theme = doc.theme
        guard !theme.cloth.isEmpty else { return 0 }
        let seed = doc.series?.nilIfEmpty.map { $0.lowercased() } ?? String(doc.id)
        return Int(hashOf(seed) % UInt32(theme.cloth.count))
    }

    static func cloth(_ doc: CatalogueDocument) -> String {
        let theme = doc.theme
        return theme.cloth.isEmpty ? LibraryCollectionTheme.fallback.cloth[0] : theme.cloth[clothIndex(doc)]
    }

    /// Rows worth putting on a home shelf when the server has no `/shelf`: a title that is a
    /// scraper's leftovers, a date in the future or an anomaly flag keeps a row off it.
    static func isShelfWorthy(_ doc: CatalogueDocument, thisYear: Int) -> Bool {
        guard !isUntitled(doc) else { return false }
        guard let first = (doc.title ?? "").unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        if let anomalies = doc.anomalies, !anomalies.isEmpty { return false }
        if let year = doc.year, year > thisYear { return false }
        return true
    }
}
