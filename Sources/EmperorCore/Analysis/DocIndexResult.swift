import Foundation

/// Doc Index: one table of every document, with columns the AI chose for this bundle.
///
/// The columns are not fixed — a pleadings bundle gets an annexure column, a data room gets a
/// folder column — so a row is a dictionary keyed by column, and every cell is drawn by its
/// column's `type`. Nothing here knows the name of any column.
///
/// Shape: `repairDocIndex` in the platform's `lib/analysis/schemas.js`. It always sends a label,
/// a rationale, at least two columns (each with key, label, type, width and description, exactly
/// one of them `strong`) and at least one row; a row carries `id` and one value — possibly
/// `null` — per column.
struct DocIndexResult: Decodable, Equatable, Sendable {

    enum ColumnType: String, Decodable, Sendable {
        case text, long, date, badge, number, amount, tags, pages, link
    }

    enum Tone: String, Decodable, Sendable {
        case danger, warn, ok, accent, info, neutral
    }

    struct Column: Decodable, Equatable, Sendable, Identifiable {
        var key: String
        var label: String
        var type: ColumnType
        var width: Int
        var pin: Bool
        var strong: Bool
        /// A badge column's colour per value.
        var tones: [String: Tone]?
        /// A badge column's order of values (High, Medium, Low).
        var order: [String]?
        /// Whether an amount or pages column is summed.
        var total: Bool
        var description: String

        var id: String { key }

        init(
            key: String, label: String, type: ColumnType, width: Int = 120, pin: Bool = false,
            strong: Bool = false, tones: [String: Tone]? = nil, order: [String]? = nil,
            total: Bool = false, description: String = ""
        ) {
            self.key = key
            self.label = label
            self.type = type
            self.width = width
            self.pin = pin
            self.strong = strong
            self.tones = tones
            self.order = order
            self.total = total
            self.description = description
        }

        enum CodingKeys: String, CodingKey {
            case key, label, type, width, pin, strong, tones, order, total, description
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            label = try c.decode(String.self, forKey: .label)
            type = try c.decode(ColumnType.self, forKey: .type)
            width = try c.decode(Int.self, forKey: .width)
            pin = try c.decodeIfPresent(Bool.self, forKey: .pin) ?? false
            strong = try c.decodeIfPresent(Bool.self, forKey: .strong) ?? false
            tones = try c.decodeIfPresent([String: Tone].self, forKey: .tones)
            order = try c.decodeIfPresent([String].self, forKey: .order)
            total = try c.decodeIfPresent(Bool.self, forKey: .total) ?? false
            description = try c.decode(String.self, forKey: .description)
        }
    }

    /// Which rows deserve a second look: those whose `key` cell is one of `in`, or — with
    /// `nonEmpty` — has anything in it.
    struct Flag: Decodable, Equatable, Sendable {
        var key: String
        var values: [String]?
        var nonEmpty: Bool
        var label: String

        init(key: String, values: [String]? = nil, nonEmpty: Bool = false, label: String) {
            self.key = key
            self.values = values
            self.nonEmpty = nonEmpty
            self.label = label
        }

        enum CodingKeys: String, CodingKey { case key, values = "in", nonEmpty, label }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            values = try c.decodeIfPresent([String].self, forKey: .values)
            nonEmpty = try c.decodeIfPresent(Bool.self, forKey: .nonEmpty) ?? false
            label = try c.decode(String.self, forKey: .label)
            guard nonEmpty || values != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .values, in: c, debugDescription: "A flag needs `in` or `nonEmpty`.")
            }
        }
    }

    typealias Row = [String: JSONValue]

    var label: String
    var rationale: String
    var filterKey: String?
    var filterLabel: String?
    var flag: Flag?
    var columns: [Column]
    var rows: [Row]

    init(
        label: String, rationale: String = "", filterKey: String? = nil, filterLabel: String? = nil,
        flag: Flag? = nil, columns: [Column], rows: [Row]
    ) {
        self.label = label
        self.rationale = rationale
        self.filterKey = filterKey
        self.filterLabel = filterLabel
        self.flag = flag
        self.columns = columns
        self.rows = rows
    }

    enum CodingKeys: String, CodingKey { case label, rationale, filterKey, filterLabel, flag, columns, rows }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        rationale = try c.decode(String.self, forKey: .rationale)
        filterKey = try c.decodeIfPresent(String.self, forKey: .filterKey)
        filterLabel = try c.decodeIfPresent(String.self, forKey: .filterLabel)
        flag = try c.decodeIfPresent(Flag.self, forKey: .flag)
        columns = try c.decode([Column].self, forKey: .columns)
        rows = try c.decode([Row].self, forKey: .rows)
        guard columns.count >= 2, !rows.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .rows, in: c, debugDescription: "An index needs two columns and a row.")
        }
    }

    // MARK: - Columns

    /// The column that names each document — the card's title.
    var strongColumn: Column {
        columns.first(where: \.strong) ?? columns.first(where: { $0.type == .text }) ?? columns[0]
    }

    /// Every column but the title, in the server's order.
    var detailColumns: [Column] {
        let strong = strongColumn.key
        return columns.filter { $0.key != strong }
    }

    var filterColumn: Column? {
        guard let filterKey else { return nil }
        return columns.first { $0.key == filterKey }
    }

    // MARK: - Cells

    /// One cell as a person reads it, or `nil` when it is empty.
    ///
    /// Dates the server could read come as `YYYY-MM-DD` and are written out as a day in India;
    /// anything else is shown as the document wrote it.
    func cell(_ row: Row, _ column: Column) -> String? {
        Self.text(row[column.key], type: column.type)
    }

    static func text(_ value: JSONValue?, type: ColumnType) -> String? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if type == .date, isDayKey(trimmed) { return DisplayText.longDay(trimmed) }
            return trimmed
        case .number(let n):
            switch type {
            case .amount: return MatterMoney.inr(n)
            case .pages:
                let count = Int(n.rounded())
                return "\(DisplayText.grouped(count)) page\(count == 1 ? "" : "s")"
            default: return number(n)
            }
        case .array(let items):
            let parts = items.compactMap { item -> String? in
                switch item {
                case .string(let s): return s.isEmpty ? nil : s
                case .number(let n): return number(n)
                default: return nil
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        case .bool(let b):
            return b ? "Yes" : "No"
        case .object:
            return nil
        }
    }

    /// The tags of a tags cell, one per chip.
    func tags(_ row: Row, _ column: Column) -> [String] {
        guard case .array(let items)? = row[column.key] else { return [] }
        return items.compactMap { $0.stringValue }.filter { !$0.isEmpty }
    }

    /// A badge's colour — the server's, else the web's guess from the word.
    func tone(for value: String, in column: Column) -> Tone {
        if let given = column.tones?[value] { return given }
        let lower = value.lowercased()
        if lower.hasPrefix("high") || lower.hasPrefix("critical") || lower.hasPrefix("urgent") {
            return .danger
        }
        return lower.hasPrefix("medium") ? .warn : .neutral
    }

    func title(of row: Row) -> String {
        cell(row, strongColumn) ?? "Untitled document"
    }

    /// The row's own id, for list identity. The server numbers rows `r1…rn`.
    static func id(of row: Row, at index: Int) -> String {
        row["id"]?.stringValue ?? "r\(index + 1)"
    }

    // MARK: - Summary

    /// Rows the flag picks out.
    func isFlagged(_ row: Row) -> Bool {
        guard let flag else { return false }
        let value = row[flag.key]
        if flag.nonEmpty {
            switch value {
            case nil, .null?: return false
            case .string(let s)?: return !s.isEmpty
            case .array(let a)?: return !a.isEmpty
            default: return true
            }
        }
        guard let text = value?.stringValue else { return false }
        return flag.values?.contains(text) ?? false
    }

    var flaggedCount: Int? {
        flag == nil ? nil : rows.filter(isFlagged).count
    }

    /// Every page of every document, when there is a pages column.
    var totalPages: Int? {
        guard let column = columns.first(where: { $0.type == .pages }) else { return nil }
        return rows.reduce(0) { $0 + Int(($1[column.key]?.doubleValue ?? 0).rounded()) }
    }

    /// "3 documents · 214 pages in all · 2 with an issue to watch" — the web's summary strip.
    var summaryLine: String {
        var parts = ["\(rows.count) document\(rows.count == 1 ? "" : "s")"]
        if let pages = totalPages { parts.append("\(DisplayText.grouped(pages)) pages in all") }
        if let flagged = flaggedCount, let flag { parts.append("\(flagged) \(flag.label)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Filtering

    struct FilterOption: Equatable, Sendable, Identifiable {
        var value: String
        var count: Int
        var id: String { value }
    }

    /// The filter column's values with their counts, in the order they first appear.
    var filterOptions: [FilterOption] {
        guard let column = filterColumn else { return [] }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for row in rows {
            guard let value = row[column.key]?.stringValue, !value.isEmpty else { continue }
            if counts[value] == nil { order.append(value) }
            counts[value, default: 0] += 1
        }
        return order.map { FilterOption(value: $0, count: counts[$0] ?? 0) }
    }

    /// The rows with `filter` as their filter-column value, or every row for `nil`.
    func rows(matching filter: String?) -> [Row] {
        guard let filter, let column = filterColumn else { return rows }
        return rows.filter { $0[column.key]?.stringValue == filter }
    }

    // MARK: - Text

    /// The index as text: a heading, then one block per document with each filled column.
    var plainText: String {
        var lines = ["DOC INDEX: \(label)", summaryLine]
        if !rationale.isEmpty { lines.append(rationale) }
        for (index, row) in rows.enumerated() {
            lines.append("")
            lines.append("\(index + 1). \(title(of: row))")
            for column in detailColumns {
                guard let value = cell(row, column) else { continue }
                lines.append("   \(column.label): \(value)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: -

    private static func isDayKey(_ s: String) -> Bool {
        s.utf8.count == 10 && s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private static func number(_ n: Double) -> String {
        if n.rounded() == n, abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
    }
}
