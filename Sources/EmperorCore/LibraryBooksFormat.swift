import Foundation

/// How Books & Law Reports and the other PDF collections caption a volume — the web's
/// `books/bookFormat.js`: the call-number label on a spine, the facts under a cover, how the
/// volumes of one series are ordered and grouped by decade, and the reference line a regulator's
/// order leads with.
enum LibraryBooksFormat {

    private static let volPrefix = TextPattern(#"^vol(ume)?[.\s-]*"#, options: [.caseInsensitive])
    private static let leadingDigits = TextPattern(#"^(\d{1,5})"#)
    private static let ordinal = TextPattern(#"(st|nd|rd|th)$"#, options: [.caseInsensitive])

    /// Roman or arabic volume → number (mirrors the server's `parseVolume` for old rows).
    static func volumeNumber(_ doc: CatalogueDocument) -> Int? {
        if let n = doc.volumeNo { return n }
        let s = volPrefix.replacing((doc.volume ?? "").trimmingCharacters(in: .whitespaces), with: "")
        return leadingDigits.groups(in: s)?[1].flatMap { Int($0) }
    }

    /// "Vol-02" → "2", "xxxiv" → "XXXIV", "Iiird" → "III" — how a spine label prints a volume.
    static func volumeText(_ doc: CatalogueDocument) -> String {
        let stripped = volPrefix.replacing((doc.volume ?? "").trimmingCharacters(in: .whitespaces), with: "")
        if let n = volumeNumber(doc), let first = stripped.first, first.isNumber { return String(n) }
        let raw = ordinal.replacing(stripped, with: "")
        return raw.isEmpty ? "" : String(raw.uppercased().prefix(7))
    }

    /// The cream call-number label: ("VOL. 12", "1987"), ("NO. 277", "2018") — nil when there is
    /// nothing to say.
    static func volumeLabel(_ doc: CatalogueDocument) -> (top: String, bottom: String)? {
        let year = doc.year.map(String.init) ?? ""
        if doc.category == LibraryCollection.lawCommission.rawValue, let n = doc.reportNo {
            return ("No. \(n)", year)
        }
        if doc.category == LibraryCollection.booksAndReports.rawValue {
            let v = volumeText(doc)
            if !v.isEmpty {
                let bottom = year.isEmpty ? (doc.issue?.nilIfEmpty.map { "No. \($0.prefix(6))" } ?? "") : year
                return ("Vol. \(v)", bottom)
            }
            if let issue = doc.issue?.nilIfEmpty { return ("No. \(issue.prefix(6))", year) }
        }
        return nil
    }

    /// `6.2 MB`, `412 KB`.
    static func size(_ bytes: Int?) -> String {
        guard let n = bytes, n > 0 else { return "" }
        let mb = Double(n) / (1024 * 1024)
        if n >= 1024 * 1024 * 1024 { return String(format: "%.1f GB", Double(n) / (1024 * 1024 * 1024)) }
        if n >= 1024 * 1024 { return n >= 100 * 1024 * 1024 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb) }
        return "\(max(1, Int((Double(n) / 1024).rounded()))) KB"
    }

    static func yearSpan(_ min: Int?, _ max: Int?) -> String {
        if min == nil && max == nil { return "" }
        guard let max, let min, min != max else { return String(max ?? min ?? 0) }
        return "\(min)–\(max)"
    }

    private static let seriesSmall = TextPattern(#"\s(Of|And|The|In|For|To|On|By)\b"#)

    /// Title-case a series name that shouts ("THE LAWS OF ENGLAND").
    static func seriesName(_ name: String?) -> String {
        let s = name ?? ""
        guard s.count >= 6, s == s.uppercased() else { return s }
        var out = ""
        var atWordStart = true
        for ch in s.lowercased() {
            if ch.isLetter {
                out += atWordStart ? ch.uppercased() : String(ch)
                atWordStart = false
            } else {
                out.append(ch)
                atWordStart = ch.isWhitespace
            }
        }
        return seriesSmall.replacing(out) { g in (g[0] ?? "").lowercased() }
    }

    /// The facts under a cover: when, the series, the size.
    static func captionMeta(_ doc: CatalogueDocument, withSeries: Bool = true, withSize: Bool = false) -> [String] {
        var out: [String] = []
        let when = doc.decidedOn.map(LibraryTitles.shortDay)
            ?? doc.dateFromTitle.map(LibraryTitles.shortDay)
            ?? doc.year.map(String.init) ?? ""
        if !when.isEmpty { out.append(when) }
        if withSeries, let series = doc.series?.nilIfEmpty { out.append(seriesName(series)) }
        if withSize, let size = doc.fileSize, size > 0 { out.append(self.size(size)) }
        return out
    }

    /// The volumes of one series in order: by volume number, then year, then title.
    static func volumeOrder(_ a: CatalogueDocument, _ b: CatalogueDocument) -> Bool {
        let va = volumeNumber(a), vb = volumeNumber(b)
        if let va, let vb, va != vb { return va < vb }
        if (va == nil) != (vb == nil) { return vb == nil }
        if (a.year ?? 0) != (b.year ?? 0) { return (a.year ?? 9999) < (b.year ?? 9999) }
        return LibraryTitles.tidyTitle(a).localizedStandardCompare(LibraryTitles.tidyTitle(b)) == .orderedAscending
    }

    struct DecadeGroup: Equatable, Identifiable, Sendable {
        var key: String
        var label: String
        var items: [CatalogueDocument]
        var id: String { key }
    }

    /// Volumes grouped by decade, oldest first; thin decades merge with their neighbours into one
    /// span ("1805–1819"), so a sparse run does not become a page of one-book sections; undated
    /// volumes come last in their own group.
    static func groupByDecade(_ docs: [CatalogueDocument], thisYear: Int) -> [DecadeGroup] {
        var groups: [Int: [CatalogueDocument]] = [:]
        var undated: [CatalogueDocument] = []
        for d in docs {
            if let y = d.year, y > 1500, y <= thisYear + 1 {
                groups[(y / 10) * 10, default: []].append(d)
            } else {
                undated.append(d)
            }
        }
        struct Run { var from: Int; var to: Int; var items: [CatalogueDocument] }
        var runs: [Run] = []
        for key in groups.keys.sorted() {
            let items = groups[key, default: []].sorted(by: volumeOrder)
            if var prev = runs.last, prev.items.count < 4 || items.count < 2 {
                prev.items = (prev.items + items).sorted(by: volumeOrder)
                prev.to = key
                runs[runs.count - 1] = prev
                continue
            }
            runs.append(Run(from: key, to: key, items: items))
        }
        var out: [DecadeGroup] = runs.map { run in
            if run.from == run.to { return DecadeGroup(key: String(run.from), label: "\(run.from)s", items: run.items) }
            let years = run.items.compactMap(\.year)
            let label = "\(years.min() ?? run.from)–\(years.max() ?? run.to)"
            return DecadeGroup(key: String(run.from), label: label, items: run.items)
        }
        if !undated.isEmpty {
            out.append(DecadeGroup(key: "undated", label: "Undated volumes", items: undated.sorted(by: volumeOrder)))
        }
        return out
    }

    /// One kind as a single document's label ("Adjudication order"), for meta lines.
    static let kindLabels: [String: String] = [
        "adjudication": "Adjudication order", "settlement": "Settlement order", "recovery": "Recovery proceedings",
        "order": "Order", "circular": "Circular / direction", "regulation": "Regulation / consultation",
        "speech": "Speech or notice", "fund": "Offer document", "appeal": "RTI appeal", "court": "Court matter",
        "case": "Antitrust case", "act": "Act or bill", "committee": "Committee report", "comparison": "Summary",
        "amendments": "Amendment notice",
    ]

    /// The reference line a regulator order or tribunal decision leads with.
    static func referenceLine(_ doc: CatalogueDocument) -> String {
        [doc.displayRef?.nilIfEmpty ?? doc.reference?.nilIfEmpty, doc.decidedOn.map(LibraryTitles.shortDay)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private static let leadingPunct = TextPattern(#"^[\s,.:;–—-]+"#)
    private static let volWord = TextPattern(#"\bvol(?:ume)?[.\s-]*0*([0-9]+|[ivxlcdm]+)\b"#, options: [.caseInsensitive])
    private static let issueWord = TextPattern(#"\bissue\s*no\.?[\s-]*0*(\w+)"#, options: [.caseInsensitive])
    private static let spaces = TextPattern(#"\s+"#)

    /// A volume's caption inside its own series: the title without the series name, the volume
    /// and issue made readable ("Calcutta Law Journal, Vol-01, Issue no.-615" → "Vol. 1, Issue 615").
    static func volumeTitle(_ doc: CatalogueDocument, series: String? = nil) -> String {
        let title = LibraryTitles.tidyTitle(doc)
        let s = series ?? doc.series ?? ""
        var rest = (!s.isEmpty && title.lowercased().hasPrefix(s.lowercased())) ? String(title.dropFirst(s.count)) : title
        if let year = doc.year {
            rest = TextPattern(#"\s*\(?\b\#(year)\b\)?\s*$"#).replacing(rest, with: "")
        }
        rest = leadingPunct.replacing(rest, with: "")
        rest = volWord.replacing(rest) { g in
            let v = g[1] ?? ""
            return "Vol. " + (v.first?.isNumber == true ? v : v.uppercased())
        }
        rest = issueWord.replacing(rest, with: "Issue $1")
        rest = spaces.replacing(rest, with: " ").trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { return rest }
        if let label = volumeLabel(doc) { return label.top }
        let named = seriesName(s)
        return named.isEmpty ? title : named
    }
}
