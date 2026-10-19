import Foundation

/// List of Dates: every dated rule, order and event in the papers, by side.
///
/// Shape: `repairListOfDates` in the platform's `lib/analysis/schemas.js`. It always sends the
/// matter and parties (each part possibly empty), at least one dated event, entries sorted by day
/// with undated ones last, and an "in sum" paragraph; `limitation` only when it could be worked
/// out. Every count and grouping here is derived, as the web's page derives them.
struct ListOfDatesResult: Decodable, Equatable, Sendable {

    enum Category: String, Decodable, Sendable, CaseIterable {
        /// A statute, rule, contract term or court order, as it came.
        case rules
        /// What our own client did.
        case ours
        /// Third parties: a bank, a registry, the court, an authority.
        case others
        /// What the other side did.
        case adverse
    }

    struct Entry: Decodable, Equatable, Sendable, Identifiable {
        var id: String
        /// `YYYY-MM-DD`, `YYYY-MM`, `YYYY`, or empty when undated.
        var day: String
        var cat: Category
        /// About six words, for a headline.
        var short: String
        /// The full line, with `**bold**` around key terms.
        var text: String
        /// The date as the chart should read it, when the model gave one ("Jan–Mar 2023").
        var label: String?
        /// A dated event after the day the result was made.
        var upcoming: Bool

        init(
            id: String, day: String, cat: Category, short: String = "", text: String,
            label: String? = nil, upcoming: Bool = false
        ) {
            self.id = id
            self.day = day
            self.cat = cat
            self.short = short
            self.text = text
            self.label = label
            self.upcoming = upcoming
        }

        enum CodingKeys: String, CodingKey { case id, day, cat, short, text, label, upcoming }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            day = try c.decode(String.self, forKey: .day)
            cat = try c.decode(Category.self, forKey: .cat)
            short = try c.decode(String.self, forKey: .short)
            text = try c.decode(String.self, forKey: .text)
            label = try c.decodeIfPresent(String.self, forKey: .label)
            upcoming = try c.decodeIfPresent(Bool.self, forKey: .upcoming) ?? false
        }

        var isEvent: Bool { cat != .rules }
        var year: String { day.count >= 4 ? String(day.prefix(4)) : "" }

        /// The chart's date: the model's label, else `06.03.2025`, `Mar 2025`, `2025` or
        /// `Undated` — the web's `labelOf`.
        var dateLabel: String {
            if let label, !label.isEmpty { return label }
            let (y, m, d) = ListOfDatesResult.parts(day)
            guard y > 0 else { return "Undated" }
            guard m > 0 else { return String(y) }
            guard d > 0 else { return "\(ListOfDatesResult.months[m - 1]) \(y)" }
            return String(format: "%02d.%02d.%d", d, m, y)
        }

        /// "6 Mar 2025", "Mar 2025", "2025" or "Undated" — the web's `fullDate`.
        var fullDate: String {
            let (y, m, d) = ListOfDatesResult.parts(day)
            guard y > 0 else { return "Undated" }
            var bits: [String] = []
            if d > 0 { bits.append(String(d)) }
            if m > 0 { bits.append(ListOfDatesResult.months[m - 1]) }
            bits.append(String(y))
            return bits.joined(separator: " ")
        }

        var runs: [RichRun] { RichRun.runs(text) }
        var plainText: String { RichRun.plain(text) }
    }

    struct Matter: Decodable, Equatable, Sendable {
        var title: String
        var number: String
        var forum: String
    }

    struct Parties: Decodable, Equatable, Sendable {
        var ours: String
        var other: String
    }

    struct Limitation: Decodable, Equatable, Sendable {
        var headline: String
        var note: String
    }

    var matter: Matter
    var parties: Parties
    var entries: [Entry]
    var inSum: String
    var limitation: Limitation?

    init(
        matter: Matter = Matter(title: "", number: "", forum: ""),
        parties: Parties = Parties(ours: "", other: ""),
        entries: [Entry], inSum: String, limitation: Limitation? = nil
    ) {
        self.matter = matter
        self.parties = parties
        self.entries = entries
        self.inSum = inSum
        self.limitation = limitation
    }

    enum CodingKeys: String, CodingKey { case matter, parties, entries, inSum, limitation }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matter = try c.decode(Matter.self, forKey: .matter)
        parties = try c.decode(Parties.self, forKey: .parties)
        entries = try c.decode([Entry].self, forKey: .entries)
        inSum = try c.decode(String.self, forKey: .inSum)
        limitation = try c.decodeIfPresent(Limitation.self, forKey: .limitation)
        guard entries.contains(where: { $0.isEvent && !$0.day.isEmpty }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .entries, in: c, debugDescription: "A list of dates needs a dated event.")
        }
    }

    // MARK: - Derived

    var rules: [Entry] { entries.filter { !$0.isEvent } }
    var events: [Entry] { entries.filter(\.isEvent) }

    struct YearGroup: Equatable, Sendable, Identifiable {
        /// "2023", or "Undated".
        var year: String
        var entries: [Entry]
        var id: String { year }
    }

    /// Events by year, oldest first, undated last — the web's `byYear`, events only.
    var eventsByYear: [YearGroup] { Self.byYear(events) }

    /// Rules by year, in the same shape.
    var rulesByYear: [YearGroup] { Self.byYear(rules) }

    static func byYear(_ entries: [Entry]) -> [YearGroup] {
        var groups: [YearGroup] = []
        // Undated entries go last whatever order they arrived in; the rest keep the server's.
        let ordered = entries.filter { !$0.year.isEmpty } + entries.filter { $0.year.isEmpty }
        for entry in ordered {
            let year = entry.year.isEmpty ? "Undated" : entry.year
            if groups.last?.year == year {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append(YearGroup(year: year, entries: [entry]))
            }
        }
        return groups
    }

    /// Dated events after today, for the head of the screen.
    var upcoming: [Entry] { entries.filter(\.upcoming) }

    /// Whose side an entry is on, in the words of the web's key — named for the parties when
    /// the result names them.
    func sideName(_ category: Category) -> String {
        let ours = parties.ours
        switch category {
        case .rules: return "Rules / orders"
        case .ours: return ours.isEmpty ? "Our side’s acts" : "\(ours)’s own acts"
        case .others: return "Third parties"
        case .adverse: return "Adverse action"
        }
    }

    /// The short tag beside one event — "Helios (ours)", "Northgrid (adverse)".
    func sideTag(_ category: Category) -> String {
        let ours = parties.ours
        let other = parties.other
        switch category {
        case .rules: return "Rules & orders"
        case .ours: return ours.isEmpty ? "Our side" : "\(ours) (ours)"
        case .others: return "Third parties"
        case .adverse: return other.isEmpty ? "Other side (adverse)" : "\(other) (adverse)"
        }
    }

    struct Summary: Equatable, Sendable {
        var events: Int
        var rules: Int
        var ours: Int
        var others: Int
        var adverse: Int
        /// The years the dated events span, or empty.
        var from: String
        var to: String

        /// "2021 → 2025", "2023", or empty.
        var span: String {
            guard !from.isEmpty else { return "" }
            return from == to ? from : "\(from) → \(to)"
        }
    }

    /// The web's `summarise`.
    var summary: Summary {
        func count(_ c: Category) -> Int { entries.filter { $0.cat == c }.count }
        let dated = entries.filter { $0.isEvent && !$0.day.isEmpty }
        return Summary(
            events: events.count, rules: count(.rules), ours: count(.ours),
            others: count(.others), adverse: count(.adverse),
            from: dated.first?.year ?? "", to: dated.last?.year ?? "")
    }

    /// "Title | Number, Forum", each part only when present.
    var matterLine: String {
        let tail = [matter.number, matter.forum].filter { !$0.isEmpty }.joined(separator: ", ")
        return [matter.title, tail].filter { !$0.isEmpty }.joined(separator: " | ")
    }

    var inSumRuns: [RichRun] { RichRun.runs(inSum) }

    // MARK: - Text

    /// The list as text, rules first and then the events year by year, with `**` stripped.
    var plainText: String {
        var lines = ["LIST OF DATES"]
        if !matterLine.isEmpty { lines.append(matterLine) }
        if let limitation {
            lines.append("Limitation watch: \(limitation.headline) (check with your advocate)")
        }
        if !rules.isEmpty {
            lines.append("")
            lines.append("RULES, CONTRACT TERMS & ORDERS (as they came)")
            for entry in rules { lines.append("\(entry.dateLabel): \(entry.plainText)") }
        }
        lines.append("")
        lines.append("EVENTS")
        for group in eventsByYear {
            lines.append("")
            lines.append(group.year)
            for entry in group.entries {
                lines.append("\(entry.dateLabel) [\(sideTag(entry.cat))]: \(entry.plainText)")
            }
        }
        lines.append("")
        lines.append("In sum: \(RichRun.plain(inSum))")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: -

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Year, month and day of a `YYYY[-MM[-DD]]` key, 0 where absent.
    static func parts(_ day: String) -> (Int, Int, Int) {
        let bits = day.split(separator: "-").map { Int($0) ?? 0 }
        let y = bits.count > 0 ? bits[0] : 0
        let m = bits.count > 1 && (1...12).contains(bits[1]) ? bits[1] : 0
        let d = bits.count > 2 && m > 0 ? bits[2] : 0
        return (y, m, d)
    }
}
