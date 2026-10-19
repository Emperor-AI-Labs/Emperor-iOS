import Foundation

/// The Bare Acts vocabulary — the web's `acts/actText.js` and `act/actFiles.js`: a presentable
/// title for an Act, its name and year apart for a cover, its jurisdiction and cloth, what it
/// holds ("9 rules · 25 amendments"), and how an Act page's tabs are shaped from the bundle.
enum LibraryActText {

    /// Tab keys in the contract's order (`/act`).
    static let tabOrder = [
        "act", "rules", "regulations", "notifications", "orders", "ordinances", "schemes",
        "bills", "circulars", "amendments", "editions", "related",
    ]

    static let tabNouns: [String: (one: String, many: String)] = [
        "rules": ("rule", "rules"), "regulations": ("regulation", "regulations"),
        "notifications": ("notification", "notifications"), "orders": ("order", "orders"),
        "ordinances": ("ordinance", "ordinances"), "schemes": ("scheme", "schemes"),
        "bills": ("bill", "bills"), "circulars": ("circular", "circulars"),
        "amendments": ("amendment", "amendments"), "editions": ("other edition", "other editions"),
        "related": ("related Act", "related Acts"),
    ]

    /// The "contains" filters the index offers (`has=`), most asked-for first.
    static let hasFilters: [(key: String, label: String)] = [
        ("rules", "Rules"), ("regulations", "Regulations"), ("notifications", "Notifications"),
        ("amendments", "Amendments"), ("orders", "Orders"), ("schemes", "Schemes"),
    ]

    static func hasLabel(_ key: String) -> String {
        hasFilters.first { $0.key == key }?.label ?? key
    }

    // MARK: - Titles

    private static let portalPrefix = TextPattern(#"^\W*indian bare acts\s+"#, options: [.caseInsensitive])
    private static let lostLetter = TextPattern(#"^\W*NDIAN\b"#)
    private static let scanDigit = TextPattern(#"^\d(?=(?:the|THE|The|Dr)\b|[A-Z]{2})"#)
    private static let ocrL = TextPattern(#"(?<=[A-Z])l(?=[A-Z])"#)
    private static let singleDocument = TextPattern(#"\s*\(\s*single document\s*\)"#, options: [.caseInsensitive])
    private static let centralAct = TextPattern(#"\s*\(\s*central act\s*\)"#, options: [.caseInsensitive])
    private static let dots = TextPattern(#"\s*[·•]\s*"#)
    private static let quoteGap = TextPattern(#"\s+'\s+"#)
    private static let instrumentPunctYear = TextPattern(
        #"\b(Act|Code|Rules|Regulations?|Ordinance|Order|Scheme|Sanhita|Adhiniyam)\s*[.,-]\s*((?:1[789]|20)\d{2})\b"#)
    private static let instrumentSpaceYear = TextPattern(
        #"\b(Act|Code|Rules|Regulations?|Ordinance|Sanhita|Adhiniyam)\s+((?:1[789]|20)\d{2})\b"#)
    private static let spaceComma = TextPattern(#"\s+,"#)
    private static let doubleSpace = TextPattern(#"\s{2,}"#)
    private static let smallWordsInside = TextPattern(#"(?<=\s)(Of|And|The|In|For|To|On|By|Or|An|A)(?=\s)"#)

    /// A title fit to print: scrape and scan debris removed, the year set off by a comma.
    static func actTitle(_ doc: CatalogueDocument) -> String {
        var raw = doc.title ?? ""
        raw = portalPrefix.replacing(raw, with: "")
        raw = lostLetter.replacing(raw, with: "INDIAN")
        raw = scanDigit.replacing(raw, with: "")
        raw = ocrL.replacing(raw, with: "I")
        // Mostly capitals ("CHHATTISGARH APPROPRIATION (No. 2) ACT, 2006") reads as shouting.
        let letters = raw.filter { $0.isLetter }
        let upper = letters.filter { $0.isUppercase }.count
        let shouting = letters.count > 12 && Double(upper) / Double(letters.count) > 0.8 && raw != raw.uppercased()
        var seed = doc
        seed.title = shouting ? raw.uppercased() : raw
        var t = LibraryTitles.tidyTitle(seed)
        t = singleDocument.replacing(t, with: "")
        t = centralAct.replacing(t, with: "")
        t = dots.replacing(t, with: " ")
        t = t.replacingOccurrences(of: "_", with: " ")
        t = quoteGap.replacing(t, with: " ")
        t = instrumentPunctYear.replacing(t, with: "$1, $2")
        t = instrumentSpaceYear.replacing(t, with: "$1, $2")
        t = spaceComma.replacing(t, with: ",")
        t = doubleSpace.replacing(t, with: " ").trimmingCharacters(in: .whitespaces)
        t = smallWordsInside.replacing(t) { g in (g[1] ?? "").lowercased() }
        return t
    }

    private static let yearAfterWord = TextPattern(
        #"^(.*?\b(?:Act|Code|Rules|Regulations?|Ordinance|Order|Scheme|Sanhita|Adhiniyam))\s*,?\s*(?:\(?\s*(?:Act\s+)?No\.?\s*\d+\s+of\s+)?((?:1[789]|20)\d{2})\b"#,
        options: [.caseInsensitive])
    private static let yearAtEnd = TextPattern(#"^(.*?[^\d.\s,])(?:\s*,\s*|\s+)((?:1[789]|20)\d{2})\s*$"#)
    private static let trailingCommaSpace = TextPattern(#"[\s,]+$"#)

    /// The name and the year apart — the year is printed large on a cover.
    static func splitTitle(_ doc: CatalogueDocument) -> (name: String, year: String) {
        let t = actTitle(doc)
        if let g = yearAfterWord.groups(in: t), let name = g[1], name.count > 3, let year = g[2] {
            return (name, year)
        }
        if let g = yearAtEnd.groups(in: t), let name = g[1], name.count > 3, let year = g[2] {
            return (trailingCommaSpace.replacing(name, with: ""), year)
        }
        return (t, doc.year.map(String.init) ?? "")
    }

    private static let repealedPattern = TextPattern(#"\(\s*rep\.|\brepealed\b|\bomitted\b"#, options: [.caseInsensitive])

    static func isRepealed(_ doc: CatalogueDocument) -> Bool {
        if doc.repealed == true { return true }
        return repealedPattern.test(doc.title ?? "")
    }

    static func isRepealed(title: String) -> Bool { repealedPattern.test(title) }

    // MARK: - Jurisdiction and cloth

    struct Jurisdiction: Equatable, Sendable {
        /// Matches the index's `jurisdiction=` facet; `none` when unknown.
        var value: String
        var label: String
        var short: String
        var isCentral: Bool
    }

    private static let shortNames: [String: String] = [
        "Dadra and Nagar Haveli and Daman and Diu": "DNH & Daman and Diu",
        "Andaman and Nicobar Islands": "Andaman & Nicobar",
        "Jammu and Kashmir": "Jammu & Kashmir",
    ]

    static func jurisdiction(of doc: CatalogueDocument) -> Jurisdiction {
        guard let v = doc.jurisdiction?.nilIfEmpty, v != "none" else {
            return Jurisdiction(value: "none", label: "Unspecified", short: "", isCentral: false)
        }
        return Jurisdiction(value: v, label: v, short: shortNames[v] ?? v, isCentral: v == "Central")
    }

    /// One cloth per State, the same on every cover — a reader learns "Assam is the teal one".
    static let stateCloths = [
        "#1F3A5F", "#1E4D3B", "#1D4B55", "#4A2747", "#5A3A1E", "#2F3A4A", "#3B3570", "#5B2E1F", "#2F5D50", "#3F2F5A",
    ]

    /// Oxblood for a Central Act, one colour per State, slate for an unknown jurisdiction.
    static func cloth(_ doc: CatalogueDocument) -> String {
        let j = jurisdiction(of: doc)
        if j.isCentral {
            let c = LibraryCollectionTheme.theme(for: LibraryCollection.bareActs.rawValue).cloth
            return c[Int(LibraryTitles.hashOf(doc.id) % UInt32(c.count))]
        }
        if j.value == "none" { return "#3A3F5C" }
        return stateCloths[Int(LibraryTitles.hashOf(j.value) % UInt32(stateCloths.count))]
    }

    // MARK: - Counts

    private static func plural(_ n: Int, _ noun: (one: String, many: String)) -> String {
        "\(DisplayText.grouped(n)) \(n == 1 ? noun.one : noun.many)"
    }

    /// `["9 rules", "25 amendments"]` — instruments only, in the contract's tab order, with
    /// `first` leading when the index's "Contains" filter names one.
    static func countParts(_ tabCounts: [String: Int]?, withEditions: Bool = false, first: String? = nil) -> [String] {
        guard let tabCounts else { return [] }
        var order = tabOrder
        if let first, tabOrder.contains(first) { order = [first] + tabOrder.filter { $0 != first } }
        return order.compactMap { key in
            guard key != "act", withEditions || (key != "editions" && key != "related"),
                  let n = tabCounts[key], n > 0, let noun = tabNouns[key] else { return nil }
            return plural(n, noun)
        }
    }

    /// `1.4 MB` — the Act page's size, as `actText.fmtSize` prints it.
    static func size(_ bytes: Int?) -> String {
        guard let n = bytes, n > 0 else { return "" }
        if n < 1024 * 1024 { return "\(max(1, Int((Double(n) / 1024).rounded()))) KB" }
        let mb = Double(n) / (1024 * 1024)
        return n < 10 * 1024 * 1024 ? String(format: "%.1f MB", mb) : String(format: "%.0f MB", mb)
    }

    /// Where a copy of an Act came from, to tell ten "Industrial Disputes Act, 1947" rows apart.
    static func copySource(_ doc: CatalogueDocument) -> String {
        if let j = doc.jurisdiction?.nilIfEmpty, doc.jurisdictionInferred != true {
            return j == "Central" ? "India Code" : "\(j) copy"
        }
        return "India Code, 2026 scrape"
    }

    /// What the first tab is called, from what the principal instrument is.
    static func actTabLabel(_ doc: CatalogueDocument?, kind: String) -> String {
        if kind == "amendments" { return "Amending Acts" }
        let t = (doc?.title ?? "").lowercased()
        if t.contains("constitution of india") { return "The Constitution" }
        if TextPattern(#"\bsanhita\b"#).test(t) { return "The Sanhita" }
        if TextPattern(#"\badhiniyam\b"#).test(t) { return "The Adhiniyam" }
        if TextPattern(#"\bcode\b"#).test(t), !TextPattern(#"\bact\b"#).test(t) { return "The Code" }
        if kind == "orphan", let type = doc?.docType, type != "act" { return "The document" }
        if TextPattern(#"\bregulation\b"#).test(t), !TextPattern(#"\bact\b"#).test(t) { return "The Regulation" }
        return "The Act"
    }

    private static let instrumentKickers: [String: String] = [
        "rules": "Rules", "regulation": "Regulations", "notification": "Notification", "order": "Order",
        "ordinance": "Ordinance", "scheme": "Scheme", "circular": "Circular", "bill": "Bill",
    ]

    /// The kind of volume, for a cover's top line.
    static func kicker(_ doc: CatalogueDocument, kind: String? = nil) -> String {
        if (kind ?? doc.kind) == "amendments" { return "Amending Acts" }
        if let alias = doc.aliases?.first?.nilIfEmpty { return alias }
        if let type = doc.docType, type != "act" { return instrumentKickers[type] ?? "Instrument" }
        let j = jurisdiction(of: doc)
        if j.isCentral { return "Bare Act" }
        return j.value == "none" ? "Act" : "State Act"
    }

    /// The title a card shows: an amendment group is named for the Act it amends.
    static func cardTitle(_ doc: CatalogueDocument) -> String {
        if let group = doc.groupTitle?.nilIfEmpty { return "\(group) — amending Acts" }
        return actTitle(doc)
    }

    /// The facts under a card: jurisdiction, year, the first alias.
    static func facts(_ doc: CatalogueDocument) -> [String] {
        let j = jurisdiction(of: doc)
        return [
            j.value == "none" ? nil : j.label,
            doc.year.map(String.init),
            doc.aliases?.first?.nilIfEmpty,
        ].compactMap { $0 }
    }

    // MARK: - The Act page's tabs

    private static func byYear(_ a: CatalogueDocument, _ b: CatalogueDocument) -> Bool {
        let ya = a.year ?? 9999, yb = b.year ?? 9999
        if ya != yb { return ya < yb }
        return (a.title ?? "") < (b.title ?? "")
    }

    /// The bundle's tabs as the page shows them: the first tab named for what it holds, and an
    /// Act known only by the Acts that amended it as one chronological list.
    static func tabsForView(_ bundle: ActBundle) -> [ActBundle.Tab] {
        let kind = bundle.resolvedKind
        if kind == "amendments" {
            let amend = bundle.tabs.first { $0.key == "amendments" }
            let docs = ((bundle.tabs.first?.docs ?? []) + (amend?.docs ?? [])).sorted(by: byYear)
            let rest = bundle.tabs.filter { $0.key != "act" && $0.key != "amendments" }
            return [ActBundle.Tab(key: "amendments", label: "Amending Acts", count: docs.count, docs: docs)] + rest
        }
        return bundle.tabs.map { tab in
            guard tab.key == "act" else { return tab }
            var renamed = tab
            renamed.label = actTabLabel(bundle.act, kind: kind)
            return renamed
        }
    }

    /// What the reading pane can show for a tab: the Act tab also offers its other editions.
    static func choices(for tab: ActBundle.Tab, in tabs: [ActBundle.Tab]) -> [CatalogueDocument] {
        guard tab.key == "act" else { return tab.docs }
        return tab.docs + (tabs.first { $0.key == "editions" }?.docs ?? [])
    }

    /// The instrument a tab opens on: the one the link asked for when it sits in this tab, else
    /// the first.
    static func defaultDocument(for tab: ActBundle.Tab, in tabs: [ActBundle.Tab], bundle: ActBundle) -> CatalogueDocument? {
        let pool = choices(for: tab, in: tabs)
        let mine = bundle.selectedTab == tab.key
            || (tab.key == "amendments" && bundle.resolvedKind == "amendments")
            || (tab.key == "act" && bundle.selectedTab == "editions")
        if mine, let hit = pool.first(where: { $0.id == bundle.selectedId }) { return hit }
        return tab.docs.first
    }

    /// The most recent instrument of a list — nil when there is one, or when the latest year is
    /// shared.
    static func latestID(in docs: [CatalogueDocument]) -> Int? {
        guard docs.count >= 2 else { return nil }
        guard let best = docs.compactMap({ d in d.year.map { ($0, d) } }).max(by: { $0.0 < $1.0 }) else { return nil }
        return docs.filter { $0.year == best.0 }.count == 1 ? best.1.id : nil
    }

    /// A row's short title inside its Act's list: the Act's name dropped when the title repeats
    /// it ("Assam Amusements and Betting Tax (Amendment) Act, 1940" → "… (Amendment) Act, 1940").
    static func shortTitle(_ title: String, actName: String) -> String? {
        let lead = TextPattern(#"\s+(Act|Code|Sanhita|Adhiniyam)$"#, options: [.caseInsensitive]).replacing(actName, with: "")
        guard lead.count > 8, title.lowercased().hasPrefix(lead.lowercased()), title.count - lead.count > 4 else { return nil }
        return "… " + title.dropFirst(lead.count).trimmingCharacters(in: .whitespaces)
    }
}
