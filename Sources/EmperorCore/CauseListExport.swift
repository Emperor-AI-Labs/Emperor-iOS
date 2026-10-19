import Foundation

/// The day's cause list as the web downloads it (`src/lib/causeList.js`): the listings grouped by
/// court in the judicial hierarchy, each court's rows ordered by court number then item, and one
/// column set — Court No., Item, Cause Title, CORAM, Advocate(s), SUPPL — written out as CSV
/// (with Time and Purpose / Stage appended) or as an HTML fragment that `AnswerPDF` lays out as a
/// PDF and `DocxDocument` packs as Word. The file names are the web's: `cause-list-<day>.<ext>`.
///
/// Every exported file carries the line saying these listings come from the user's own cases and
/// must be checked against the court's published list — the web defines that wording once, and
/// so does this.
///
/// Held to the platform's own answers by `CauseListExportGolden`
/// (`scripts/generate-cause-list-export-fixtures.mjs`).
enum CauseListExport {

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case pdf, docx, csv

        var id: String { rawValue }

        /// The web's menu labels.
        var label: String {
            switch self {
            case .pdf: return "PDF"
            case .docx: return "Word (.docx)"
            case .csv: return "CSV"
            }
        }
    }

    /// One court's listings for the day.
    struct Group: Equatable, Sendable {
        let courtName: String
        let rows: [Row]
    }

    /// One listing's cells. `—` where the web prints one.
    struct Row: Equatable, Sendable {
        let caseID: String
        let courtNo: String
        let item: String
        let parties: String
        let appealOrCaseNo: String
        let category: String
        let coram: String
        let advocates: String
        let suppl: String
        let time: String
        let note: String

        /// The cause title in one cell: "Parties [W.P.(C) No. 4412/2025 • Service matters]".
        var causeTitleLine: String {
            let details = [appealOrCaseNo, category].filter { !$0.isEmpty }.joined(separator: " • ")
            return details.isEmpty ? parties : "\(parties) [\(details)]"
        }
    }

    static let dash = "—"

    static let pdfDisclaimer =
        "Personalised cause list generated from your Emperor AI case dashboard. Verify listings against the official published court cause list."
    static let wordDisclaimer =
        "Personalised cause list generated from your Emperor AI case dashboard. Verify listings against the official court cause list."

    static func fileName(day: String, format: Format) -> String {
        "cause-list-\(day).\(format.rawValue)"
    }

    // MARK: - The table

    static func row(_ listing: CauseListing) -> Row {
        Row(
            caseID: listing.caseID,
            courtNo: CauseListText.courtRoom(listing) ?? dash,
            item: CauseListText.itemNumber(listing) ?? dash,
            parties: parties(listing),
            appealOrCaseNo: appealOrCaseNo(listing),
            category: category(listing.category),
            coram: CauseListText.coram(listing) ?? dash,
            advocates: advocates(listing),
            suppl: suppl(listing),
            time: CauseListText.time(listing) ?? "",
            note: CauseListText.listingNote(listing) ?? "")
    }

    /// `groupEntriesByCourtHierarchy`: courts in the hierarchy's order, and within each, court
    /// number (registrar courts after the benches, an unknown room last), then item (serial,
    /// then sub-serial — 301.1 after 301, not after 3010), then title.
    static func groups(_ listings: [CauseListing]) -> [Group] {
        var order: [String] = []
        var byKey: [String: (court: CourtClass, listings: [CauseListing])] = [:]
        for listing in listings {
            let court = classify(listing)
            if byKey[court.key] == nil {
                order.append(court.key)
                byKey[court.key] = (court, [])
            }
            byKey[court.key]?.listings.append(listing)
        }
        let sortedKeys = order.enumerated().sorted { a, b in
            let ka = byKey[a.element]!.court.sortKey, kb = byKey[b.element]!.court.sortKey
            let result = collate(ka, kb)
            return result != .orderedSame ? result == .orderedAscending : a.offset < b.offset
        }.map(\.element)

        return sortedKeys.map { key in
            let entry = byKey[key]!
            let rows = entry.listings.map { (listing: $0, row: row($0)) }
            let ordered = rows.enumerated().sorted { a, b in
                let ra = courtRank(a.element.row.courtNo), rb = courtRank(b.element.row.courtNo)
                if ra != rb { return ra < rb }
                let ia = itemRank(a.element.row.item), ib = itemRank(b.element.row.item)
                if ia != ib { return ia < ib }
                let ta = a.element.listing.title ?? "", tb = b.element.listing.title ?? ""
                let byTitle = collate(ta, tb)
                return byTitle != .orderedSame ? byTitle == .orderedAscending : a.offset < b.offset
            }
            return Group(courtName: entry.court.name, rows: ordered.map(\.element.row))
        }
    }

    private static func courtRank(_ courtNo: String) -> (Int, Int) {
        let tier: Int
        if courtNo == dash { tier = 2 } else if courtNo.lowercased().hasPrefix("registrar") { tier = 1 } else { tier = 0 }
        let digits = firstNumber(courtNo)
        return (tier, digits ?? Int.max)
    }

    private static func itemRank(_ item: String) -> (Int, Int) {
        guard let groups = Patterns.shared.itemSerial.groups(in: item), let serial = groups[1].flatMap({ Int($0) }) else {
            return (Int.max, 0)
        }
        return (serial, groups[2].flatMap { Int($0) } ?? 0)
    }

    private static func firstNumber(_ text: String) -> Int? {
        guard let match = Patterns.shared.digits.groups(in: text)?[0] else { return nil }
        return Int(match)
    }

    /// `localeCompare` with no locale: the default collation, not code-point order.
    static func collate(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [], range: nil, locale: Locale(identifier: "en"))
    }

    /// "Mon, 19 Oct 2026" — `fmtLong`.
    static func longDay(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return key }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return key
        }
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let weekday = weekdays[calendar.component(.weekday, from: date) - 1]
        return "\(weekday), \(parts[2]) \(months[parts[1] - 1]) \(parts[0])"
    }

    /// "Mon, 19 Oct 2026 — 4 matters across 2 courts".
    static func summary(day: String, listings: Int, courts: Int) -> String {
        "\(longDay(day)) — \(listings) matter\(listings == 1 ? "" : "s") across \(courts) court\(courts == 1 ? "" : "s")"
    }

    // MARK: - CSV

    static let csvHeader = [
        "Court", "Court No.", "Item", "Cause Title", "CORAM", "Advocate(s)", "SUPPL", "Time", "Purpose / Stage",
    ]

    /// Every cell quoted, quotes doubled, rows joined by a bare newline — as the web writes it.
    static func csv(_ listings: [CauseListing]) -> String {
        let cell = { (value: String) in "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = [csvHeader.map(cell).joined(separator: ",")]
        for group in groups(listings) {
            for row in group.rows {
                lines.append([
                    group.courtName, row.courtNo, row.item, row.causeTitleLine, row.coram,
                    row.advocates, row.suppl, row.time, row.note,
                ].map(cell).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - HTML, for the PDF and for Word

    /// The Word document's structure — a title, the date line, then each court as a heading and
    /// a six-column table — as one fragment both renderers read. `format` picks the closing line,
    /// which the web words slightly differently for each.
    static func html(day: String, listings: [CauseListing], format: Format = .pdf) -> String {
        let courts = groups(listings)
        var out = "<h1>Daily Cause List</h1>"
        out += "<p><em>\(escape(summary(day: day, listings: listings.count, courts: courts.count)))</em></p>"
        for group in courts {
            let n = group.rows.count
            out += "<h2>\(escape(group.courtName)) (\(n) matter\(n == 1 ? "" : "s"))</h2>"
            out += "<table><thead><tr>"
            out += ["Court No.", "Item", "Cause Title", "CORAM", "Advocate(s)", "SUPPL"].map { "<th>\(escape($0))</th>" }.joined()
            out += "</tr></thead><tbody>"
            for row in group.rows {
                out += "<tr>"
                out += "<td>\(escape(row.courtNo))\(row.time.isEmpty ? "" : "<br>\(escape(row.time))")</td>"
                out += "<td>\(escape(row.item))</td>"
                out += "<td>\(causeTitleCell(row))</td>"
                out += "<td>\(escape(row.coram))</td>"
                out += "<td>\(escape(row.advocates))</td>"
                out += "<td>\(escape(row.suppl))</td>"
                out += "</tr>"
            }
            out += "</tbody></table>"
        }
        out += "<p><em>\(escape(format == .docx ? wordDisclaimer : pdfDisclaimer))</em></p>"
        return out
    }

    private static func causeTitleCell(_ row: Row) -> String {
        var cell = "<strong>\(escape(row.parties))</strong>"
        let meta = [
            row.appealOrCaseNo.isEmpty ? nil : "<strong>\(escape(row.appealOrCaseNo))</strong>",
            row.category.isEmpty ? nil : "<em>\(escape(row.category))</em>",
        ].compactMap { $0 }
        if !meta.isEmpty { cell += "<br>" + meta.joined(separator: " • ") }
        if !row.note.isEmpty { cell += "<br><em>\(escape(row.note))</em>" }
        return cell
    }

    /// `esc`: the four characters HTML cares about.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Cells

    /// `extractParties`: the parties, else the title, without a trailing "[Court 4]" or
    /// "- Next hearing …".
    static func parties(_ listing: CauseListing) -> String {
        var text = listing.parties?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { text = listing.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        guard !text.isEmpty else { return "Untitled Matter" }
        text = CauseListText.Patterns.shared.whitespace.replaceAll(in: text, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = Patterns.shared.roomOrItemTag.replaceAll(in: text, with: "")
        text = Patterns.shared.nextHearingTail.replaceAll(in: text, with: "")
        return text
    }

    /// `cleanCaseType`: without a trailing internal code — "(CIVIL WRITS)-134", "-134".
    static func cleanCaseType(_ raw: String?) -> String {
        var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        text = Patterns.shared.bracketCode.replaceAll(in: text, with: "")
        text = Patterns.shared.dashCode.replaceAll(in: text, with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `extractAppealOrCaseNo`: "W.P.(C) No. 4412/2025", "Diary No. 12852/2024", "CNR: …".
    static func appealOrCaseNo(_ listing: CauseListing) -> String {
        let type = cleanCaseType(listing.caseType)
        let number = nonEmpty(listing.caseNumber)
        let year = nonEmpty(listing.caseYear)
        let diary = nonEmpty(listing.diaryNumber)

        if Patterns.shared.diaryLookup.matches(type), let shown = diary ?? number {
            return "Diary No. \(shown)"
        }
        if let number {
            let yearPart = year.map { number.hasSuffix("/\($0)") ? "" : "/\($0)" } ?? ""
            if !type.isEmpty {
                if Patterns.shared.endsInNo.matches(type) { return "\(type) \(number)\(yearPart)" }
                return "\(type) No. \(number)\(yearPart)"
            }
            return "Case No. \(number)\(yearPart)"
        }
        if !type.isEmpty { return type }
        if let diary { return "Diary No. \(diary)" }
        if let cnr = nonEmpty(listing.cnr) { return "CNR: \(cnr)" }
        return ""
    }

    /// `extractCategory`: a bare internal code is no category; a leading code and the "[other
    /// than …]" note are dropped; a very long statute is cut to its head and first clause.
    static func category(_ raw: String?) -> String {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return "" }
        if Patterns.shared.digitsOnly.matches(text) { return "" }
        text = Patterns.shared.leadingCode.replaceFirst(in: text, with: "")
        text = Patterns.shared.otherThan.replaceAll(in: text, with: "")
        if let colon = text.firstIndex(of: ":"), colon != text.startIndex, text.utf16.count > 80 {
            let parts = text.components(separatedBy: ":")
            let head = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = (parts.count > 1 ? parts[1] : "").components(separatedBy: ",")[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            text = rest.isEmpty ? head : "\(head) : \(rest)"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `extractAdvocates`: the advocates, else a stage that is not just "Pending" or "Disposed".
    static func advocates(_ listing: CauseListing) -> String {
        if let advocates = listing.advocates.flatMap(CauseListText.trimmed) { return advocates }
        if let stage = listing.stage.flatMap(CauseListText.trimmed), !Patterns.shared.pendingOrDisposed.matches(stage) {
            return stage
        }
        return dash
    }

    /// `extractSuppl`: the list the matter is on — Supplementary, Advance, Daily — from the list
    /// type, else from the purpose or the remarks.
    static func suppl(_ listing: CauseListing) -> String {
        if let listType = nonEmpty(listing.listType) {
            let lowered = listType.lowercased()
            if lowered.contains("supplementary") { return "Supplementary" }
            if lowered.contains("advance") { return "Advance" }
            if lowered.contains("daily") || lowered.contains("regular") { return "Daily" }
            return listing.listType ?? listType
        }
        for field in [listing.purpose, listing.remarks] {
            guard let field, !field.isEmpty else { continue }
            if Patterns.shared.supplWord.matches(field) { return "Supplementary" }
            if Patterns.shared.advanceWord.matches(field) { return "Advance" }
            if Patterns.shared.regularWord.matches(field) { return "Regular" }
            if Patterns.shared.dailyWord.matches(field) { return "Daily" }
        }
        return dash
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - The court hierarchy

    struct CourtClass: Equatable, Sendable {
        let key: String
        let name: String
        let sortKey: String
    }

    /// `classifyCourt`: the Supreme Court; the High Courts by place; the appellate tribunals
    /// (NCLAT first); the tribunals (NCLT first); district courts; consumer commissions; the rest.
    static func classify(_ listing: CauseListing) -> CourtClass {
        let rawName = listing.courtName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawType = (listing.courtType ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = "\(rawName) \(rawType)".lowercased()
        let lowerName = rawName.lowercased()
        let p = Patterns.shared

        func named(_ key: String, _ fallback: String, tier: String) -> CourtClass {
            CourtClass(key: key, name: rawName.isEmpty ? fallback : rawName, sortKey: "\(tier)_\(lowerName)")
        }

        if rawType == "sc" || combined.contains("supreme court") {
            return CourtClass(key: "sc", name: "Supreme Court of India", sortKey: "01_sc")
        }
        if rawType == "hc" || combined.contains("high court") {
            let place = (p.hcDash.groups(in: rawName)?[1] ?? p.hcOf.groups(in: rawName)?[1] ?? p.hcPrefix.groups(in: rawName)?[1])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var display = rawName.isEmpty ? "High Court" : rawName
            if !place.isEmpty {
                let words = CauseListText.Patterns.shared.whitespace.split(place).map { word -> String in
                    String(word.prefix(1)).uppercased() + word.dropFirst().lowercased()
                }
                display = "High Court — \(words.joined(separator: " "))"
            }
            return CourtClass(key: "hc_\(display.lowercased())", name: display, sortKey: "02_hc_\(display.lowercased())")
        }
        if rawType == "nclat" || p.nclat.matches(combined) {
            return CourtClass(key: "nclat", name: "National Company Law Appellate Tribunal (NCLAT)", sortKey: "03_nclat")
        }
        if p.drat.matches(combined) { return named("drat", "Debts Recovery Appellate Tribunal (DRAT)", tier: "03_drat") }
        if p.ncdrc.matches(combined) {
            return CourtClass(key: "ncdrc", name: "National Consumer Disputes Redressal Commission (NCDRC)", sortKey: "03_ncdrc")
        }
        if p.aptel.matches(combined) {
            return CourtClass(key: "aptel", name: "Appellate Tribunal for Electricity (APTEL)", sortKey: "03_aptel")
        }
        if p.tdsat.matches(combined) {
            return CourtClass(key: "tdsat", name: "Telecom Disputes Settlement and Appellate Tribunal (TDSAT)", sortKey: "03_tdsat")
        }
        if p.sat.matches(combined) {
            return CourtClass(key: "sat", name: "Securities Appellate Tribunal (SAT)", sortKey: "03_sat")
        }
        if rawType == "nclt" || p.nclt.matches(combined) {
            let name: String
            if rawName.contains("NCLT") {
                name = rawName
            } else if rawName.contains("National Company Law Tribunal") {
                name = "\(rawName) (NCLT)"
            } else {
                name = "National Company Law Tribunal (NCLT)"
            }
            return CourtClass(key: "nclt_\(lowerName)", name: name, sortKey: "04_nclt_\(lowerName)")
        }
        if p.drt.matches(combined) { return named("drt", "Debts Recovery Tribunal (DRT)", tier: "04_drt") }
        if p.itat.matches(combined) { return named("itat", "Income Tax Appellate Tribunal (ITAT)", tier: "04_itat") }
        if p.ngt.matches(combined) {
            return CourtClass(key: "ngt", name: "National Green Tribunal (NGT)", sortKey: "04_ngt")
        }
        if p.cat.matches(combined) {
            return CourtClass(key: "cat", name: "Central Administrative Tribunal (CAT)", sortKey: "04_cat")
        }
        if p.cestat.matches(combined) { return CourtClass(key: "cestat", name: "CESTAT", sortKey: "04_cestat") }
        if rawType == "tribunal" || combined.contains("tribunal") {
            return named("trib_\(lowerName)", "Tribunal", tier: "04_trib")
        }
        if rawType == "district" || p.district.matches(combined) {
            return named("dist_\(lowerName)", "District & Subordinate Courts", tier: "05_dist")
        }
        if rawType == "forum" || p.forum.matches(combined) {
            return named("forum_\(lowerName)", "Consumer Commission / Forum", tier: "06_forum")
        }
        return CourtClass(
            key: "other_\(lowerName)",
            name: rawName.isEmpty ? "Other Courts / Forums" : rawName,
            sortKey: "07_other_\(rawName.isEmpty ? "other" : lowerName)")
    }

    // MARK: - Patterns

    /// The platform's patterns, translated as `CauseListText.Pattern` translates them.
    struct Patterns: Sendable {
        static let shared = Patterns()
        typealias Pattern = CauseListText.Pattern

        let roomOrItemTag = Pattern(#"\s*\[(?:Court|Item)[^\]]*\]"#)
        let nextHearingTail = Pattern(#"\s*[-–—]\s*Next hearing.*$"#)
        let bracketCode = Pattern(#"\s*\([A-Z\s]+\)-\d+$"#)
        let dashCode = Pattern(#"-\d+$"#, caseInsensitive: false)
        let diaryLookup = Pattern(#"diary\s*lookup"#)
        let endsInNo = Pattern(#"\b(?:no\.?|number)$"#)
        let digitsOnly = Pattern(#"^\d+$"#, caseInsensitive: false)
        let leadingCode = Pattern(#"^\d+[\s\-:]+"#, caseInsensitive: false)
        let otherThan = Pattern(#"\s*\[other than[^\]]*\]"#)
        let pendingOrDisposed = Pattern(#"^(pending|disposed)$"#)
        let supplWord = Pattern(#"\b(?:suppl(?:ementary)?)\b"#)
        let advanceWord = Pattern(#"\badvance\b"#)
        let regularWord = Pattern(#"\bregular\b"#)
        let dailyWord = Pattern(#"\bdaily\b"#)
        let itemSerial = Pattern(#"^(\d+)(?:\.(\d+))?"#, caseInsensitive: false)
        let digits = Pattern(#"\d+"#, caseInsensitive: false)

        let hcDash = Pattern(#"high court\s*[-—–:]\s*([a-z\s&]+)"#)
        let hcOf = Pattern(#"high court of\s+([a-z\s&]+)"#)
        let hcPrefix = Pattern(#"^([a-z\s&]+)\s+high court"#)
        let nclat = Pattern(#"\bnclat\b|national company law appellate"#)
        let drat = Pattern(#"\bdrat\b|debts recovery appellate"#)
        let ncdrc = Pattern(#"\bncdrc\b|national consumer disputes redressal commission"#)
        let aptel = Pattern(#"\baptel\b|appellate tribunal for electricity"#)
        let tdsat = Pattern(#"\btdsat\b"#)
        let sat = Pattern(#"\bsat\b|securities appellate"#)
        let nclt = Pattern(#"\bnclt\b|national company law tribunal"#)
        let drt = Pattern(#"\bdrt\b|debts recovery tribunal"#)
        let itat = Pattern(#"\bitat\b|income tax appellate"#)
        let ngt = Pattern(#"\bngt\b|national green tribunal"#)
        let cat = Pattern(#"\bcat\b|central administrative tribunal"#)
        let cestat = Pattern(#"\bcestat\b"#)
        let district = Pattern(#"district|sessions|magistrate|civil judge|commercial court|mact|labour court|family court"#)
        let forum = Pattern(#"consumer|commission|scdrc|dcdrc"#)
    }
}
