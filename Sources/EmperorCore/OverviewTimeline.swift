import Foundation

/// The matter's timeline on the Overview: everything that has happened, newest first, the next
/// hearing on top — the web's vertical `Timeline` in `OverviewSection.jsx`.
///
/// It reads the merged record (`MatterRecord.entries`) up to today, leaves tasks out, puts a year
/// marker wherever the year changes, and alternates each row's side by the web's own index (year
/// markers counted), so the eye can run down either edge. Every row says where it came from —
/// the court, the user, or the documents — and that is what the view colours it by: the Chronology
/// and Court sections stay two sections, and a merged row here never passes for the court's own.
/// Held to the web by `scripts/generate-matter-record-fixtures.mjs`.
enum OverviewTimeline {

    /// Who put a row on the record, as the web words it (`SRC_WORD`).
    enum Origin: String, Equatable, Sendable {
        case court, manual, ai

        var label: String {
            switch self {
            case .court: return "From the court"
            case .manual: return "Added by you"
            case .ai: return "Found by AI"
            }
        }
    }

    struct Row: Equatable, Identifiable, Sendable {
        enum Kind: Equatable, Sendable {
            /// The next hearing, today or later.
            case next
            case year(String)
            case entry(kind: String, origin: Origin)
        }

        let id: String
        let kind: Kind
        /// "12 Aug" for an entry, "25 Oct 2026" for the next hearing, the year for a marker.
        let date: String
        let title: String
        /// The kind's label when the title is not already it; "in 6 days" for the next hearing.
        let subtitle: String
        /// The web's index for this row; the side flips on every odd one.
        let index: Int

        /// Drawn with the date on the right and the words on the left.
        var isFlipped: Bool { index % 2 == 1 }

        /// An order carries more weight on the line than a listing, as on the web.
        var isOrder: Bool {
            if case .entry(let kind, _) = kind { return kind == "order" }
            return false
        }

        var accessibilityText: String {
            switch kind {
            case .year(let year): return year
            case .next: return "Next hearing, \(date), \(subtitle)"
            case .entry(_, let origin):
                return "\(date): \(title)\(subtitle.isEmpty ? "" : ", \(subtitle)") (\(origin.label))"
            }
        }
    }

    /// What a row says: a listing reads "Listed in Court 71", not "Listed — LISTED IN COURT
    /// NO.71"; the kind is printed beside the date, so it is not repeated (`entryText`).
    static func entryText(_ entry: MatterRecordEntry) -> String {
        var title = entry.title
        if let range = title.range(of: #"^Listed\s+—\s+"#, options: .regularExpression) {
            title = String(title[range.upperBound...])
        }
        return MatterRecord.plainCourtText(title).nilIfEmpty ?? MatterRecord.kindLabel(entry.kind)
    }

    /// "Today", "Tomorrow", "in 6 days" (`awayText`).
    static func away(_ days: Int) -> String {
        days == 0 ? "Today" : days == 1 ? "Tomorrow" : "in \(days) days"
    }

    /// The rows, top to bottom.
    static func rows(entries: [MatterRecordEntry], next: MatterRecord.NextHearing?, today: String) -> [Row] {
        let list = MatterRecord.sorted(
            entries.filter { !$0.day.isEmpty && $0.kind != "task" && $0.day <= today }, newestFirst: true)
        let upcoming = next.flatMap { $0.days >= 0 ? $0 : nil }
        var rows: [Row] = []
        if let upcoming {
            rows.append(Row(id: "next", kind: .next, date: MatterRecord.shortDay(upcoming.day),
                            title: "Next hearing", subtitle: away(upcoming.days), index: 0))
        }
        let offset = upcoming == nil ? 0 : 1
        var year: String?
        var index = 0
        for entry in list {
            let y = String(entry.day.prefix(4))
            if y != year {
                rows.append(Row(id: "y\(y)", kind: .year(y), date: y, title: "", subtitle: "", index: index + offset))
                year = y
                index += 1
            }
            let title = entryText(entry)
            let label = MatterRecord.kindLabel(entry.kind)
            var date = MatterRecord.shortDay(entry.day)
            if let range = date.range(of: #" \d{4}$"#, options: .regularExpression) { date.removeSubrange(range) }
            rows.append(Row(
                id: entry.key, kind: .entry(kind: entry.kind, origin: Origin(rawValue: entry.source.rawValue) ?? .manual),
                date: date, title: title, subtitle: title == label ? "" : label, index: index + offset))
            index += 1
        }
        return rows
    }

    /// The empty state's words, when there is neither a past entry nor a hearing ahead.
    static let emptyText = "Hearings and orders appear once the court case is added. You can also add dates yourself."
}
