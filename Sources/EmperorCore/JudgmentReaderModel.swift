import Foundation

/// The pure half of the judgment reader — the web's `caselaw/readerModel.js` and
/// `lib/judgmentDoc.js`: reading comfort, the plain-text fallback, find-in-judgment, "go to
/// paragraph", the citation line, and the cause title as display rows.
enum JudgmentReaderModel {

    // MARK: - Reading comfort

    static let sizeSteps: [Double] = [0.88, 0.94, 1, 1.08, 1.17, 1.28, 1.4]

    /// What the reader remembers between judgments, per device.
    struct Preferences: Equatable, Sendable {
        enum Face: String, CaseIterable, Sendable { case serif, sans }
        enum Width: String, CaseIterable, Sendable { case narrow, normal, wide }
        enum Paper: String, CaseIterable, Sendable { case auto, light, sepia, dark }

        var size: Int = 2
        var face: Face = .serif
        var width: Width = .normal
        var paper: Paper = .auto

        static let `default` = Preferences()
        static let storageKey = "lib-reader-prefs"

        var scale: Double { JudgmentReaderModel.sizeSteps[min(max(size, 0), JudgmentReaderModel.sizeSteps.count - 1)] }
        var canShrink: Bool { size > 0 }
        var canGrow: Bool { size < JudgmentReaderModel.sizeSteps.count - 1 }
        var percent: Int { Int((scale * 100).rounded()) }

        /// The stored form: the web's JSON keys, so a value is readable either side.
        var encoded: String {
            "{\"size\":\(size),\"face\":\"\(face.rawValue)\",\"width\":\"\(width.rawValue)\",\"paper\":\"\(paper.rawValue)\"}"
        }

        /// Anything malformed falls back to the default, field by field.
        static func decode(_ raw: String?) -> Preferences {
            var out = Preferences()
            guard let raw, let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return out }
            if let size = object["size"] as? Int, (0..<sizeSteps.count).contains(size) { out.size = size }
            if let face = (object["face"] as? String).flatMap(Face.init(rawValue:)) { out.face = face }
            if let width = (object["width"] as? String).flatMap(Width.init(rawValue:)) { out.width = width }
            if let paper = (object["paper"] as? String).flatMap(Paper.init(rawValue:)) { out.paper = paper }
            return out
        }
    }

    // MARK: - The plain-text fallback

    private static let paraNumber = TextPattern(#"^\s*(\d{1,3}(?:\.\d{1,2})?)\s*[.)]\s+(?=\S)"#)
    private static let citesWidget = TextPattern(#"^\s*\[Cites[\s\S]{0,80}?\]\s*"#, options: [.caseInsensitive])
    private static let blankLines = TextPattern(#"\n\s*\n+"#)
    private static let doubleSpace = TextPattern(#"\s{2,}"#)
    private static let titleLine = TextPattern(#"^Title:\s*(.+)$"#, options: [.anchorsMatchLines])

    /// Split the raw `.txt` into paragraphs. The scraper's header block (Title / Court / Year /
    /// Source and a rule of `=`) is dropped; court documents are hard-wrapped, so a single
    /// newline is a line break inside a paragraph, not a paragraph boundary.
    static func paragraphs(fromPlainText raw: String) -> (title: String?, paragraphs: [String]) {
        var src = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var title: String?
        if let headerEnd = src.range(of: "\n==="), src.distance(from: src.startIndex, to: headerEnd.lowerBound) < 800 {
            let header = String(src[..<headerEnd.lowerBound])
            title = titleLine.groups(in: header)?[1]?.trimmingCharacters(in: .whitespaces)
            if let ruleEnd = src[headerEnd.upperBound...].firstIndex(of: "\n") {
                src = String(src[src.index(after: ruleEnd)...])
            } else {
                src = ""
            }
        }
        src = citesWidget.replacing(src, with: "")
        return (title, splitPlainText(src))
    }

    static func splitPlainText(_ text: String) -> [String] {
        blankLines.split(text).compactMap { block in
            let joined = block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            let squeezed = doubleSpace.replacing(joined, with: " ").trimmingCharacters(in: .whitespaces)
            return squeezed.isEmpty ? nil : squeezed
        }
    }

    /// The text-mirror fallback → the `/judgment` block shape, numbered paragraphs recognised.
    static func blocks(fromParagraphs paragraphs: [String]) -> [JudgmentBlock] {
        var seen = Set<String>()
        return paragraphs.enumerated().map { i, p in
            if let g = paraNumber.groups(in: p), let n = g[1], !seen.contains(n), let whole = g[0] {
                seen.insert(n)
                return JudgmentBlock(id: "para-\(n)", type: "para", text: String(p.dropFirst(whole.count)), n: n)
            }
            return JudgmentBlock(id: "b-\(i)", type: "para", text: p)
        }
    }

    // MARK: - Find in this judgment

    /// Text the reader shows for a block (what search runs over).
    static func blockText(_ b: JudgmentBlock) -> String {
        if b.type == "cause" || b.type == "table" || (b.type == "meta" && b.lines != nil) {
            return (b.lines ?? [b.text]).joined(separator: "\n")
        }
        return b.text
    }

    /// One match: which block, and where in its text (UTF-16 offsets, as `NSRange` counts).
    struct Hit: Equatable, Hashable, Sendable {
        var block: Int
        var start: Int
        var end: Int
        var index: Int
    }

    struct Search: Equatable, Sendable {
        var hits: [Hit] = []
        var byBlock: [Int: [Hit]] = [:]
        var capped = false

        static let empty = Search()
        var total: Int { hits.count }
    }

    /// The phrase as typed, case-insensitive, every occurrence — what "find in page" means.
    /// Counts every match, including in parts not drawn yet. Stops at `limit`.
    static func search(_ blocks: [JudgmentBlock], for query: String, limit: Int = 3000) -> Search {
        let q = query.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, !blocks.isEmpty else { return .empty }
        var out = Search()
        let needle = q.lowercased() as NSString
        blockLoop: for (bi, block) in blocks.enumerated() {
            let hay = blockText(block).lowercased() as NSString
            var from = 0
            var local: [Hit] = []
            while from < hay.length {
                let r = hay.range(of: needle as String, options: [], range: NSRange(location: from, length: hay.length - from))
                guard r.location != NSNotFound else { break }
                let hit = Hit(block: bi, start: r.location, end: r.location + r.length, index: out.hits.count)
                out.hits.append(hit)
                local.append(hit)
                from = r.location + max(r.length, 1)
                if out.hits.count >= limit { out.capped = true; break }
            }
            if !local.isEmpty { out.byBlock[bi] = local }
            if out.capped { break blockLoop }
        }
        return out
    }

    /// The next hit from `current` in `direction` (+1 / −1), wrapping; nil when there are none.
    static func step(from current: Int, by direction: Int, in search: Search) -> Int? {
        let n = search.hits.count
        guard n > 0 else { return nil }
        if current < 0 { return direction > 0 ? 0 : n - 1 }
        return ((current + direction) % n + n) % n
    }

    // MARK: - Going to a paragraph

    /// Index of the block numbered `n` — exact, else the first numbered at or past it; -1 if none.
    static func findParagraph(_ blocks: [JudgmentBlock], numbered n: String) -> Int {
        let want = n.trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty else { return -1 }
        if let exact = blocks.firstIndex(where: { $0.n == want }) { return exact }
        guard let num = Double(want) else { return -1 }
        return blocks.firstIndex { b in
            guard let s = b.n, let v = Double(s) else { return false }
            return v >= num
        } ?? -1
    }

    static func index(of id: String, in blocks: [JudgmentBlock]) -> Int {
        blocks.firstIndex { $0.id == id } ?? -1
    }

    /// The highest paragraph number (a later opinion may restart at 1).
    static func lastParagraphNumber(_ blocks: [JudgmentBlock]) -> String? {
        var best: (Double, String)?
        for b in blocks {
            guard let s = b.n, let v = Double(s) else { continue }
            if best == nil || v > best!.0 { best = (v, s) }
        }
        return best?.1
    }

    /// About 16 evenly spaced paragraph numbers for jumping through a long judgment; several
    /// opinions in one judgment each restart at 1, and the first paragraph of a number wins.
    static func paragraphMarks(_ blocks: [JudgmentBlock]) -> [(id: String, n: Int)] {
        let nums: [(id: String, n: Int)] = blocks.compactMap { b in
            guard let s = b.n, let n = Int(s) else { return nil }
            return (b.id, n)
        }
        guard nums.count >= 15, let last = nums.last?.n else { return [] }
        let steps = [5, 10, 20, 25, 50, 100, 200, 250, 500]
        let step = steps.first { Double(last) / Double($0) <= 18 } ?? 1000
        var seen = Set<Int>()
        return nums.filter { p in
            guard p.n == 1 || p.n % step == 0, !seen.contains(p.n) else { return false }
            seen.insert(p.n)
            return true
        }
    }

    /// The headings (levels 1 and 2) of the contents rail.
    static func headings(_ toc: [JudgmentTOCEntry]) -> [JudgmentTOCEntry] {
        toc.filter { $0.level <= 2 }
    }

    // MARK: - Citations

    /// "A v. B, (2012) 10 SCC 409 (Supreme Court, 31 Oct 2012)".
    static func citationLine(_ doc: CatalogueDocument?, header: JudgmentHeader?) -> String {
        let title = CaseLawVocabulary.caseTitle(doc, header: header)
        let cite = header?.neutralCitation?.nilIfEmpty
            ?? doc?.neutralCitation?.nilIfEmpty
            ?? header?.citations.first?.nilIfEmpty
            ?? header.map(CaseLawVocabulary.caseNumberText)?.nilIfEmpty
            ?? doc.map(CaseLawVocabulary.caseNumberText)?.nilIfEmpty
        let court = CaseLawVocabulary.court(header?.court ?? doc?.court, label: header?.courtLabel ?? doc?.courtLabel).short
        let day = header?.decidedOn?.nilIfEmpty ?? doc?.decidedOn?.nilIfEmpty
        let year = (header?.year ?? doc?.year).map(String.init)
        let tail = [court, day.map(LibraryTitles.shortDay) ?? year].compactMap { $0?.nilIfEmpty }.joined(separator: ", ")
        return title + (cite.map { ", \($0)" } ?? "") + (tail.isEmpty ? "" : " (\(tail))")
    }

    /// Every citation worth offering: the neutral one first, then the rest, no repeats.
    static func citations(_ doc: CatalogueDocument?, header: JudgmentHeader?) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for c in [header?.neutralCitation ?? doc?.neutralCitation].compactMap({ $0 }) + (header?.citations ?? []) {
            guard !c.isEmpty, !seen.contains(c) else { continue }
            seen.insert(c)
            out.append(c)
        }
        return out
    }

    /// The Indian Kanoon page a judgment came from, and nothing else — the only source worth a
    /// link, and the only host this will open.
    static func sourceURL(_ header: JudgmentHeader?) -> URL? {
        guard let source = header?.source,
              TextPattern(#"^https://(www\.)?indiankanoon\.org/"#).test(source) else { return nil }
        return URL(string: source)
    }

    // MARK: - The cause title

    enum CauseRowKind: Equatable, Sendable { case tag, versus, party, caps, text, gap, prayer }

    /// The cause title as display rows: a party and its role, "Versus", the court's tags, the
    /// upper-case lines, prose (a Madras prayer runs on into one paragraph).
    struct CauseRow: Equatable, Identifiable, Sendable {
        var kind: CauseRowKind
        var text: String
        var role: String?
        var id: Int
    }

    private static let rolePattern = TextPattern(
        #"^(.*?\S)\s*(?:…+|\.{2,}|-{2,}|—|:)\s*((?:the\s+)?(?:\d{1,2}(?:st|nd|rd|th)\s+|(?:sole|all)\s+)?(?:appellants?|respondents?|petitioners?|applicants?|accused|complainants?|plaintiffs?|defendants?|revisionists?|opposite\s+part(?:y|ies)|contemnors?|caveators?|claimants?|objectors?|decree[- ]holders?|judgment[- ]debtors?|landlords?|tenants?|state)(?:\s*(?:no\.?\s*)?\d+(?:\s*(?:to|-|&|and)\s*\d+)?)?(?:\s*/\s*[\w ]*)?[.)]*)\s*$"#,
        options: [.caseInsensitive])
    private static let roleBare = TextPattern(#"^([^a-z]{3,}?)\s+((?:Appellant|Respondent|Petitioner|Applicant|Accused)s?\s?\(s\)\.?)$"#)
    private static let tagPattern = TextPattern(
        #"^(?:\$?~?\s*)?(?:R|non[- ]?reportable|reportable|afr|a\.f\.r\.?|not reportable|court no\.?\s*\d+|item no\.?\s*\d+|\*|#|%)\.?$"#,
        options: [.caseInsensitive])
    private static let versusLine = TextPattern(#"^(?:-\s*)?(?:versus|vs\.?|v/s\.?|v\.)(?:\s*-)?$"#, options: [.caseInsensitive])
    private static let nameTail = TextPattern(#"[\s.,]+$"#)
    private static let roleHead = TextPattern(#"^\W+"#)
    private static let capsNoise = TextPattern(#"\d|\b(?:COURT|JURISDICTION|BENCH|BEFORE|CORAM|PRESENT|IN THE|AND|WITH|BETWEEN)\b|[:.]$"#)
    private static let appearance = TextPattern(#"^(?:For\s|Counsel|Mr\.|Ms\.|Mrs\.|M/s\b|Through\b|Present\b|Coram\b)"#, options: [.caseInsensitive])
    private static let prayerStart = TextPattern(#"^PRAYER\b"#, options: [.caseInsensitive])

    static func splitCauseLine(_ line: String) -> (kind: CauseRowKind, text: String, role: String?) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return (.gap, "", nil) }
        if tagPattern.test(t) { return (.tag, t, nil) }
        if versusLine.test(t) { return (.versus, "Versus", nil) }
        if let g = rolePattern.groups(in: t) ?? roleBare.groups(in: t), let name = g[1], name.count > 1, let role = g[2] {
            return (.party, nameTail.replacing(name, with: ""), roleHead.replacing(role, with: ""))
        }
        let letters = t.filter { $0.isLetter }
        if letters.count >= 4, letters == letters.uppercased() { return (.caps, t, nil) }
        return (.text, t, nil)
    }

    static func causeRows(_ lines: [String]) -> [CauseRow] {
        var rows: [CauseRow] = []
        var prayerOpen = false
        for line in lines {
            let p = splitCauseLine(line)
            if p.kind == .party {
                var text = p.text
                // Join the line above when it is a bare upper-case fragment of the same name.
                if let prev = rows.last, prev.kind == .caps, !capsNoise.test(prev.text), prev.text.count < 70 {
                    rows.removeLast()
                    text = prev.text + " " + text
                }
                rows.append(CauseRow(kind: .party, text: text, role: p.role, id: rows.count))
                prayerOpen = false
                continue
            }
            // "5.C.Jeya ... Petitioners/" + "Accused Nos.1 to 5": the role continues on the next line.
            if p.kind == .text, let last = rows.last, last.kind == .party, let role = last.role, role.hasSuffix("/"), line.count < 40 {
                rows[rows.count - 1].role = role + " " + p.text
                continue
            }
            if p.kind == .text, prayerOpen, !appearance.test(p.text) {
                rows[rows.count - 1].text += " " + p.text
                continue
            }
            let isPrayer = prayerStart.test(p.text)
            rows.append(CauseRow(kind: isPrayer ? .prayer : p.kind, text: p.text, role: nil, id: rows.count))
            prayerOpen = isPrayer
        }
        return rows
    }

    /// How many rows of a long cause title to show before "Show the full title": 26 rows or
    /// about 1,400 characters, and only when more than four would be hidden.
    static func causeFold(_ rows: [CauseRow]) -> Int? {
        var chars = 0
        var cut = rows.count
        for (i, row) in rows.enumerated() {
            chars += row.text.count + (row.role?.count ?? 0)
            if i >= 26 || chars > 1400 { cut = i; break }
        }
        return rows.count - cut > 4 ? cut : nil
    }

    private static let elision = TextPattern(#"^(?:\*\s*){3,}$|^(?:x{3,}\s*){2,}$"#, options: [.caseInsensitive])

    /// "*   *   *" / "xxx xxx" — an elision mark, set on its own line.
    static func isElision(_ text: String) -> Bool { elision.test(text) }

    /// A signature block's "Copy to:" lines are set apart from the names.
    static func isCopyLine(_ line: String) -> Bool {
        TextPattern(#"^(copy|to\s*[:,]|\d+\.\s*the\b)"#, options: [.caseInsensitive]).test(line.trimmingCharacters(in: .whitespaces))
    }

    /// A cause-title line that is prose rather than a name: long, with lower-case words.
    static func isProse(_ text: String) -> Bool {
        text.count > 70 && TextPattern(#"\b[a-z]{3,}\s+[a-z]{2,}\s+[a-z]{2,}\b"#).test(text)
    }
}
