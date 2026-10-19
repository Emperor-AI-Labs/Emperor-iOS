import Foundation

/// The Case Law vocabulary — the web's `caselaw/courts.js`: one entry per court (name, short
/// name, seal monogram, tier, colour per theme) and the pure helpers that turn a scraped case
/// title into a printable one.
enum CaseLawVocabulary {

    struct CourtInfo: Equatable, Sendable {
        var key: String
        var name: String
        var short: String
        /// The seal's letters — "SC", "Del".
        var monogram: String
        /// `sc` or `hc`.
        var tier: String
        /// The court's colour on a light surface and on a dark one (4.5:1 on both).
        var ink: String
        var inkDark: String
        /// The Supreme Court's daily orders, told apart from its judgments.
        var isOrders: Bool = false

        var isSupremeCourt: Bool { tier == "sc" }
    }

    private static let courts: [String: CourtInfo] = [
        "supremecourt": CourtInfo(key: "supremecourt", name: "Supreme Court of India", short: "Supreme Court", monogram: "SC", tier: "sc", ink: "#7A1F2B", inkDark: "#F2A7B0"),
        "scorders": CourtInfo(key: "scorders", name: "Supreme Court — daily orders", short: "SC orders", monogram: "SC", tier: "sc", ink: "#8A3A1C", inkDark: "#F2B593", isOrders: true),
        "allahabad": CourtInfo(key: "allahabad", name: "Allahabad High Court", short: "Allahabad HC", monogram: "All", tier: "hc", ink: "#2D5E3A", inkDark: "#9FD5AA"),
        "bombay": CourtInfo(key: "bombay", name: "Bombay High Court", short: "Bombay HC", monogram: "Bom", tier: "hc", ink: "#1E4C7A", inkDark: "#A3C6EC"),
        "kolkata": CourtInfo(key: "kolkata", name: "Calcutta High Court", short: "Calcutta HC", monogram: "Cal", tier: "hc", ink: "#653A7D", inkDark: "#D5B2E6"),
        "delhi": CourtInfo(key: "delhi", name: "Delhi High Court", short: "Delhi HC", monogram: "Del", tier: "hc", ink: "#17605F", inkDark: "#8FD6D3"),
        "karnataka": CourtInfo(key: "karnataka", name: "Karnataka High Court", short: "Karnataka HC", monogram: "Kar", tier: "hc", ink: "#7C5A0E", inkDark: "#E8C878"),
        "chennai": CourtInfo(key: "chennai", name: "Madras High Court", short: "Madras HC", monogram: "Mad", tier: "hc", ink: "#8A2C5C", inkDark: "#F0AACB"),
    ]

    /// Rail order: the Supreme Court first, then the High Courts A–Z.
    static let courtOrder = ["supremecourt", "scorders", "allahabad", "bombay", "kolkata", "delhi", "karnataka", "chennai"]

    private static let fallbackInk = ("#2B4373", "#A9BDEB")
    private static let courtWords = TextPattern(#"High Court|Court|of|the"#, options: [.caseInsensitive])
    private static let highCourt = TextPattern(#"High Court"#, options: [.caseInsensitive])

    /// The court for a catalogue key, with a plain fallback for one the vocabulary lacks.
    static func court(_ key: String?, label: String? = nil) -> CourtInfo {
        if let key, let known = courts[key] { return known }
        let name = label?.nilIfEmpty ?? "Court"
        let stripped = courtWords.replacing(name, with: "").trimmingCharacters(in: .whitespaces)
        let mono = stripped.isEmpty ? "§" : String(stripped.prefix(3))
        return CourtInfo(
            key: key ?? "", name: name, short: highCourt.replacing(name, with: "HC"), monogram: mono,
            tier: "hc", ink: fallbackInk.0, inkDark: fallbackInk.1)
    }

    /// `/facets` courts in rail order; unknown keys last, A–Z.
    static func orderCourts(_ options: [LibraryFacetOption]) -> [LibraryFacetOption] {
        func rank(_ v: String) -> Int { courtOrder.firstIndex(of: v) ?? 99 }
        return options.sorted { a, b in
            let ra = rank(a.value), rb = rank(b.value)
            if ra != rb { return ra < rb }
            return a.displayLabel.localizedCaseInsensitiveCompare(b.displayLabel) == .orderedAscending
        }
    }

    /// The rail's label for a court: the Supreme Court's two rows say what they hold.
    static func railName(_ option: LibraryFacetOption) -> String {
        let c = court(option.value, label: option.label)
        if c.isSupremeCourt { return c.isOrders ? "Daily orders" : "Judgments" }
        return TextPattern(#" High Court$"#).replacing(c.name, with: "")
    }

    // MARK: - Titles

    private static let smallWords = TextPattern(#"^(of|and|the|in|for|to|on|by|or|an|a|at|through|thr|vs|v)$"#, options: [.caseInsensitive])
    private static let spaces = TextPattern(#"\s+"#)
    private static let messrsSpace = TextPattern(#"^M/?S\.?\s+(?=\S)"#, options: [.caseInsensitive])
    private static let messrsGlued = TextPattern(#"^M/?S(?=[A-Z][a-z])"#)
    private static let messrsWord = TextPattern(#"\bM/S\b"#)
    private static let honorific = TextPattern(#"\b(Mr|Mrs|Dr|Smt|Sri|Shri|Ms)(?=[A-Z][a-z])"#)
    private static let relation = TextPattern(#"\b([SDW])O\s+(?=[A-Z])"#)
    private static let initials = TextPattern(#"(^|[\s(&])([A-Z]{1,3})(?=[A-Z][a-z]{2,})"#)
    private static let capsRun = TextPattern(#"[A-Z]{3}"#)
    private static let innerSmall = TextPattern(#"(\s)(Of|And|The|In|For|To|On|By|At)(?=\s)"#)
    private static let cutTail = TextPattern(#"(?:\s+(?:&|and|the|of|through|thr|by|rep|represented|vs\.?|v\.|versus))+\.?$"#, options: [.caseInsensitive])

    /// A party name as the file name left it → as a law report prints it. Conservative: only
    /// patterns that are unambiguous in Indian cause titles are touched.
    static func tidyParty(_ name: String?) -> String {
        var s = spaces.replacing(name ?? "", with: " ").trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "" }
        s = messrsSpace.replacing(s, with: "M/s ")
        s = messrsGlued.replacing(s, with: "M/s ")
        s = messrsWord.replacing(s, with: "M/s")
        s = honorific.replacing(s, with: "$1 ")
        s = relation.replacing(s) { g in "\((g[1] ?? "").lowercased())/o " }
        s = initials.replacing(s) { g in
            let pre = g[1] ?? "", ini = g[2] ?? ""
            return pre + ini.map(String.init).joined(separator: ".") + ". "
        }
        s = spaces.replacing(s, with: " ").trimmingCharacters(in: .whitespaces)
        // An all-caps name ("STATE OF KARNATAKA") reads as shouting in a title.
        if s.count > 6, s == s.uppercased(), capsRun.test(s) {
            var words: [String] = []
            for (i, word) in s.lowercased().split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                let w = String(word)
                if i > 0, smallWords.test(w) { words.append(w); continue }
                words.append(titleCaseWord(w))
            }
            s = words.joined(separator: " ")
        }
        s = innerSmall.replacing(s) { g in (g[1] ?? "") + (g[2] ?? "").lowercased() }
        // File names are cut at a length: "… Corporation &", "… Maharashtra Through The". Say so.
        let cut = cutTail.replacing(s, with: "")
        if cut != s, cut.count > 2 { s = cut + "…" }
        return s
    }

    /// Each run of letters in a word capitalised: "s/o" stays small, "state" → "State".
    private static func titleCaseWord(_ word: String) -> String {
        var out = ""
        var atStart = true
        for ch in word {
            if ch.isLetter || ch == "'" {
                out += atStart && ch.isLetter ? ch.uppercased() : String(ch)
                atStart = false
            } else {
                out.append(ch)
                atStart = true
            }
        }
        return out
    }

    private static let versus = TextPattern(#"\s+(?:vs\.?|v\.|v/s\.?|versus)\s+"#, options: [.caseInsensitive])
    private static let dateTail = TextPattern(#"\s+on\s+\d{1,2}\s+\w+,?\s+\d{4}\s*$"#, options: [.caseInsensitive])

    /// The two parties, tidied, from a row or a judgment header.
    static func parties(petitioner: String?, respondent: String?, title: String?) -> (String, String)? {
        if let p = petitioner?.nilIfEmpty, let r = respondent?.nilIfEmpty { return (tidyParty(p), tidyParty(r)) }
        let t = dateTail.replacing(title ?? "", with: "")
        let parts = versus.split(t)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (tidyParty(parts[0]), tidyParty(parts[1]))
    }

    static func parties(of doc: CatalogueDocument) -> (String, String)? {
        parties(petitioner: doc.petitioner, respondent: doc.respondent, title: doc.title)
    }

    static func parties(of header: JudgmentHeader) -> (String, String)? {
        parties(petitioner: header.petitioner, respondent: header.respondent, title: header.title)
    }

    /// "Seethamma v. State of Karnataka" — plain text, for copying and for VoiceOver.
    static func caseTitle(_ doc: CatalogueDocument?, header: JudgmentHeader? = nil) -> String {
        if let header, let p = parties(of: header) { return "\(p.0) v. \(p.1)" }
        if let doc, let p = parties(of: doc) { return "\(p.0) v. \(p.1)" }
        return tidyParty(header?.title ?? doc?.title ?? "Untitled judgment")
    }

    private static let arising = TextPattern(#"^arising"#, options: [.caseInsensitive])
    private static let arisingOrIn = TextPattern(#"arising|in\s*$"#, options: [.caseInsensitive])
    private static let noPrefix = TextPattern(#"^no\.?\s"#, options: [.caseInsensitive])

    /// "Civil Appeal No. 7710 of 2012" style line, or empty.
    static func caseNumberText(caseType: String?, caseNumber: String?) -> String {
        var type = spaces.replacing(caseType ?? "", with: " ").trimmingCharacters(in: .whitespaces)
        // The scraper sometimes files a sentence as the case type: a real one is short.
        if type.count > 34, !arising.test(type) { type = "" }
        let num = (caseNumber ?? "").trimmingCharacters(in: .whitespaces)
        if type.isEmpty && num.isEmpty { return "" }
        if num.isEmpty { return type }
        if type.isEmpty { return "No. \(num)" }
        if arisingOrIn.test(type) { return "\(type) No. \(num)" }
        return "\(type) \(noPrefix.test(num) ? num : "No. \(num)")"
    }

    static func caseNumberText(_ doc: CatalogueDocument) -> String {
        caseNumberText(caseType: doc.caseType, caseNumber: doc.caseNumber)
    }

    static func caseNumberText(_ header: JudgmentHeader) -> String {
        caseNumberText(caseType: header.caseType, caseNumber: header.caseNumber)
    }

    /// A judgment "decided" after today is a scraper error, never a fact.
    static func isFutureDate(_ iso: String?, today: String) -> Bool {
        guard let iso, iso.count >= 10, TextPattern(#"^\d{4}-\d{2}-\d{2}"#).test(iso) else { return false }
        return String(iso.prefix(10)) > today
    }

    /// Minutes at 230 words a minute, at least one.
    static func readingMinutes(_ words: Int?) -> Int {
        max(1, Int((Double(words ?? 0) / 230).rounded()))
    }

    /// On a "newest" list, rows dated in the future go to the end of the page.
    static func arrange(_ items: [CatalogueDocument], sort: String?, today: String) -> [CatalogueDocument] {
        guard sort == "date_desc" else { return items }
        let ok = items.filter { !isFutureDate($0.decidedOn, today: today) }
        guard ok.count != items.count else { return items }
        return ok + items.filter { isFutureDate($0.decidedOn, today: today) }
    }
}
