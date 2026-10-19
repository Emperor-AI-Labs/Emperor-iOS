import Foundation

// A matter's record read the web's way: the user's own chronology and the linked case's
// hearings and orders as one list of entries, the next hearing, and the wording a synopsis uses.
//
// A port of `src/lib/projectRecord.js` (`chronologyEntries`, `sortChronology`, `eventText`,
// `nextHearing`, `hearingFacts`, `plainCourtText`, `orderTitle`, `fmtDots`, `fmtDay`), held to
// the web's own output by `scripts/generate-matter-record-fixtures.mjs`. The Chronology and
// Court sections stay two sections on this client (see `ProjectDetailViewModel`); this merged
// reading feeds the two places the web merges them too — the List of Dates & Events export
// (`ChronologyExport`) and the Overview's timeline (`OverviewTimeline`) — where every row says
// whose it is.

/// One entry on the record (`chronologyEntries`).
struct MatterRecordEntry: Equatable, Identifiable, Sendable {
    enum Source: String, Sendable { case manual, court, ai }

    /// `u:<id>` for the user's own entry, `c:<id>` for a court row.
    let key: String
    let recordID: String
    let source: Source
    /// Typed in, accepted from the documents, or copied by the court sync into the chronology —
    /// as against a row of the court's own record.
    let isOwn: Bool
    /// `event`, `hearing`, `order`, `filing`, `milestone`, `task`, `note`, or whatever the row says.
    let kind: String
    /// `YYYY-MM-DD` in India, or empty for an undated entry.
    let day: String
    let title: String
    let body: String
    let sourceRef: String
    let created: String
    /// The court row this came from, for a court entry.
    let item: CaseItem?

    var id: String { key }

    /// The user's own notes and tasks.
    var isNoteOrTask: Bool { isOwn && (kind == "note" || kind == "task") }
    /// A row of the court's record, not a copy of one.
    var isCourtRecord: Bool { source == .court && !isOwn }
}

enum MatterRecord {

    // MARK: - Text

    /// Whitespace runs to one space, trimmed (`clean`).
    static func clean(_ value: String?) -> String {
        (value ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A JSON value as the web's `String(v)` reads it — a number printed without a trailing
    /// `.0` — or nil for null, false or an empty string (what `||` and `filter(Boolean)` skip).
    static func text(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s): return s.isEmpty ? nil : s
        case .number(let n):
            if n == 0 { return nil }
            return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(true): return "true"
        default: return nil
        }
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Any stored date shape → its day in India, or empty (`dayKey`). A bare `YYYY-MM-DD` is
    /// already a day and passes through untouched; a timestamp is placed on India's calendar.
    static func dayKey(_ raw: String?) -> String {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if isDayShape(s) { return s }
        return WireDate.parse(s).map(WireDate.dayKey) ?? ""
    }

    private static func isDayShape(_ s: String) -> Bool {
        let chars = Array(s)
        return chars.count == 10 && chars.enumerated().allSatisfy { index, c in
            index == 4 || index == 7 ? c == "-" : (c.isASCII && c.isNumber)
        }
    }

    /// "12 Aug 2026" (`fmtDay`).
    static func shortDay(_ raw: String?) -> String {
        let key = dayKey(raw)
        guard isDayShape(key) else { return "" }
        let parts = key.split(separator: "-")
        guard let month = Int(parts[1]), (1...12).contains(month) else { return "" }
        return "\(parts[2]) \(months[month - 1]) \(parts[0])"
    }

    /// "12.08.2026", the date column of a List of Dates (`fmtDots`).
    static func dots(_ raw: String?) -> String {
        let key = dayKey(raw)
        guard isDayShape(key) else { return "" }
        let parts = key.split(separator: "-")
        return "\(parts[2]).\(parts[1]).\(parts[0])"
    }

    /// The chronology's kinds and their labels (`CHRONO_KINDS`); an unknown kind reads as Event.
    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "hearing": return "Hearing"
        case "order": return "Order"
        case "filing": return "Filing"
        case "milestone": return "Milestone"
        case "task": return "Task"
        case "note": return "Note"
        default: return "Event"
        }
    }

    /// An order's title as people read it: a court's one-letter code spelled out (`orderTitle`).
    static func orderTitle(_ raw: String?) -> String {
        let t = clean(raw)
        switch t.uppercased() {
        case "O": return "Order"
        case "J": return "Judgment"
        case "OJ": return "Order / Judgment"
        default: return t
        }
    }

    /// A court's capitals as a sentence: "TO BE LISTED IN COURT NO.42" → "To be listed in Court
    /// 42" (`plainCourtText`).
    static func plainCourtText(_ raw: String?) -> String {
        var t = clean(raw)
        if t.hasSuffix(")") && !t.contains("(") {
            while t.hasSuffix(")") { t.removeLast() }
        }
        if !t.isEmpty, t == t.uppercased(), t.range(of: "[A-Z]{3}", options: .regularExpression) != nil {
            t = String(t.prefix(1)) + t.dropFirst().lowercased()
        }
        let courtNo = try? NSRegularExpression(pattern: #"\bcourt\s*no\.?\s*"#, options: [.caseInsensitive])
        if let courtNo {
            t = courtNo.stringByReplacingMatches(
                in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "Court ")
        }
        return clean(t)
    }

    // MARK: - Court rows

    /// One hearing in the words a lawyer reads a cause list in (`hearingFacts`).
    struct HearingFacts: Equatable, Sendable {
        var purpose: String
        var place: String
        var coram: String
        var remarks: String
    }

    static func hearingFacts(_ item: CaseItem) -> HearingFacts {
        let d = item.data
        let raw = clean(item.title?.nilIfEmpty ?? text(d["purpose"]))
        let purpose = raw.caseInsensitiveCompare("listing") == .orderedSame ? "" : raw
        let room = CauseListText.courtLabel(text(d["courtNo"])) ?? ""
        let itemNo = text(d["itemNo"]).map { "Item \(clean($0))" } ?? ""
        let place = [room, itemNo, clean(text(d["time"]))].filter { !$0.isEmpty }.joined(separator: " · ")
        let coram = clean(text(d["coram"]) ?? item.subtitle?.nilIfEmpty ?? text(d["bench"]))
        return HearingFacts(purpose: purpose, place: place, coram: coram, remarks: clean(text(d["remarks"])))
    }

    private static func normTitle(_ s: String) -> String {
        let lowered = clean(s).lowercased()
        var out = ""
        var lastWasGap = false
        for scalar in lowered.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasGap = false
            } else if !lastWasGap {
                out += " "
                lastWasGap = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - The merge

    /// The user's entries, then the court's hearings and orders, with a court fact the server
    /// copied into the chronology shown once (`chronologyEntries`).
    static func entries(updates: [ProjectUpdate], courtHistory: [CaseItem]) -> [MatterRecordEntry] {
        let own = updates.map { u -> MatterRecordEntry in
            let source: MatterRecordEntry.Source = u.source == "ai" ? .ai : u.source == "court" ? .court : .manual
            return MatterRecordEntry(
                key: "u:\(u.id)", recordID: u.id, source: source, isOwn: true,
                kind: u.kind?.nilIfEmpty ?? "note",
                day: dayKey(u.eventDateRaw?.nilIfEmpty ?? u.createdAtRaw),
                title: clean(u.title),
                body: (u.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                sourceRef: clean(u.sourceRef), created: u.createdAtRaw ?? "", item: nil)
        }
        let copied = Set(own.filter { $0.source == .court }.map { "\($0.day)|\(normTitle($0.title))" })
        var court: [MatterRecordEntry] = []
        for item in courtHistory where item.section == "hearings" || item.section == "orders" {
            let day = dayKey(item.itemDateRaw)
            guard !day.isEmpty else { continue }
            let title: String
            let body: String
            if item.section == "hearings" {
                let h = hearingFacts(item)
                title = h.purpose.isEmpty ? "Listed before the court" : "Listed — \(h.purpose)"
                body = [h.coram, h.place, h.remarks].filter { !$0.isEmpty }.joined(separator: " · ")
            } else {
                let d = item.data
                title = orderTitle(item.title?.nilIfEmpty ?? text(d["title"])).nilIfEmpty ?? "Order passed"
                let type = text(d["type"]) ?? ""
                body = clean(!type.isEmpty && type.caseInsensitiveCompare("order") != .orderedSame ? type : "")
            }
            if copied.contains("\(day)|\(normTitle(title))") { continue }
            court.append(MatterRecordEntry(
                key: "c:\(item.id)", recordID: item.id, source: .court, isOwn: false,
                kind: item.section == "hearings" ? "hearing" : "order",
                day: day, title: title, body: body, sourceRef: "", created: "", item: item))
        }
        return own + court
    }

    /// Oldest first; on one day the court's listing, then the order passed at it, then what the
    /// user wrote; undated last (`sortChronology`).
    static func sorted(_ entries: [MatterRecordEntry], newestFirst: Bool = false) -> [MatterRecordEntry] {
        func rank(_ e: MatterRecordEntry) -> Int { e.isCourtRecord ? (e.kind == "hearing" ? 0 : 1) : 2 }
        let dated = entries.enumerated().filter { !$0.element.day.isEmpty }
            .sorted { a, b in
                let l = a.element, r = b.element
                if l.day != r.day { return l.day < r.day }
                if rank(l) != rank(r) { return rank(l) < rank(r) }
                if l.created != r.created { return l.created < r.created }
                return a.offset < b.offset
            }
            .map(\.element)
        let undated = entries.filter { $0.day.isEmpty }
        return (newestFirst ? dated.reversed() : dated) + undated
    }

    /// The words of one entry in a List of Dates' Event column (`eventText`). The user's own read
    /// as written; a court row as the sentence a synopsis carries.
    static func eventText(_ e: MatterRecordEntry) -> String {
        if e.isCourtRecord, let item = e.item {
            if e.kind == "hearing" {
                let h = hearingFacts(item)
                return "The matter was listed\(h.purpose.isEmpty ? "" : " for \(h.purpose)")\(h.coram.isEmpty ? "" : " before \(h.coram)")."
            }
            let isOrderDated = e.title.range(of: #"^order dated\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            return isOrderDated || e.title.isEmpty ? "Order passed by the Court." : e.title
        }
        let title = clean(e.title)
        let body = clean(e.body)
        if body.isEmpty { return title.nilIfEmpty ?? kindLabel(e.kind) }
        if title.isEmpty { return body }
        let endsInStop = title.last.map { ".!?:;".contains($0) } ?? false
        return endsInStop ? "\(title) \(body)" : "\(title). \(body)"
    }

    // MARK: - The next hearing

    struct NextHearing: Equatable, Sendable {
        /// `YYYY-MM-DD`.
        let day: String
        /// `project` when only the matter's own date says so, `court` when the linked case does.
        let from: String
        /// From today; negative once it has passed.
        let days: Int
    }

    /// The earliest date still ahead of the matter's and the linked case's; failing that, the
    /// latest, shown as passed rather than as nothing (`nextHearing`).
    static func nextHearing(projectDate: String?, courtDate: String?, today: String) -> NextHearing? {
        let candidates = [(dayKey(projectDate), "project"), (dayKey(courtDate), "court")].filter { !$0.0.isEmpty }
        guard !candidates.isEmpty else { return nil }
        let ahead = candidates.filter { $0.0 >= today }.sorted { $0.0 < $1.0 }
        let pick = ahead.first ?? candidates.sorted { $0.0 > $1.0 }[0]
        let from = candidates.contains { $0.0 == pick.0 && $0.1 == "court" } ? "court" : pick.1
        return NextHearing(day: pick.0, from: from, days: CourtCalendar.days(from: today, to: pick.0) ?? 0)
    }
}
