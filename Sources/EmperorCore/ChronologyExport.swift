import Foundation

/// The matter's "List of Dates & Events" — the synopsis format of SLPs, writs and appeals: the
/// court, the case, the cause title, then a two-column table of DD.MM.YYYY dates and what
/// happened on them.
///
/// `html` is the web's `listOfDatesHtml` (`src/lib/projectRecord.js`), held to it byte for byte by
/// `scripts/generate-matter-record-fixtures.mjs`; it is a fragment, laid out by
/// `DocxDocument.make(fromHTML:)` for Word and by the app's PDF renderer, as the web lays it out
/// with `htmlToDocx` and `printHtml`. What goes in is the user's choice, by the web form's groups
/// (`ExportForm` in `ChronologySection.jsx`, restated in `Group` and pinned by this client's own
/// tests — it lives in a component, not in a function the generator can run).
enum ChronologyExport {

    /// The form's groups, in its order, with its defaults: the matter's events and the court's
    /// orders are in; every listing, and private notes and to-dos, are out.
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case mine, ai, orders, hearings, notes

        var id: String { rawValue }

        var label: String {
            switch self {
            case .mine: return "Your entries"
            case .ai: return "Entries found in the documents"
            case .orders: return "Court orders"
            case .hearings: return "Court hearings — every listing, adjournments included"
            case .notes: return "Notes and tasks"
            }
        }

        var isOnByDefault: Bool {
            switch self {
            case .mine, .ai, .orders: return true
            case .hearings, .notes: return false
            }
        }

        static func of(_ entry: MatterRecordEntry) -> Group {
            if entry.isNoteOrTask { return .notes }
            if entry.source == .court { return entry.kind == "hearing" ? .hearings : .orders }
            if entry.source == .ai { return .ai }
            return .mine
        }
    }

    static let defaultGroups: Set<Group> = Set(Group.allCases.filter(\.isOnByDefault))

    /// The dated entries in each group.
    static func grouped(_ entries: [MatterRecordEntry]) -> [Group: [MatterRecordEntry]] {
        var out: [Group: [MatterRecordEntry]] = [:]
        for entry in entries where !entry.day.isEmpty {
            out[Group.of(entry), default: []].append(entry)
        }
        return out
    }

    /// What the chosen groups put on the list, group by group as the web collects them.
    static func picked(_ entries: [MatterRecordEntry], groups: Set<Group>) -> [MatterRecordEntry] {
        let byGroup = grouped(entries)
        return Group.allCases.flatMap { groups.contains($0) ? byGroup[$0] ?? [] : [] }
    }

    /// "12 entries on 9 dates, oldest first", or "Nothing selected".
    static func summary(_ picked: [MatterRecordEntry]) -> String {
        guard !picked.isEmpty else { return "Nothing selected" }
        let dates = Set(picked.map(\.day)).count
        return "\(picked.count) \(picked.count == 1 ? "entry" : "entries") on \(dates) \(dates == 1 ? "date" : "dates"), oldest first"
    }

    /// `List_of_Dates_<matter>`, the matter's name cut at a word when long (`base` in the form).
    static func baseName(matterName: String?) -> String {
        var slug = ""
        var gap = false
        for scalar in (matterName ?? "").unicodeScalars {
            if ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
                gap = false
            } else if !gap {
                slug += "_"
                gap = true
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if slug.count > 60 {
            let cut = String(slug.prefix(60))
            if let range = cut.range(of: "_[^_]*$", options: .regularExpression) {
                slug = String(cut[..<range.lowerBound])
            } else {
                slug = cut
            }
        }
        return "List_of_Dates_\(slug.isEmpty ? "matter" : slug)"
    }

    // MARK: - The document

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// "W.P.(C) No. 1234 of 2026" (`caseNoFormal`).
    static func formalCaseNumber(type rawType: String?, number rawNumber: String?, year rawYear: String?) -> String {
        let number = MatterRecord.clean(rawNumber)
        guard !number.isEmpty else { return "" }
        let type = MatterRecord.clean(rawType)
        let year = MatterRecord.clean(rawYear)
        var lead = ""
        var body = number
        if let regex = try? NSRegularExpression(pattern: #"^(.*?)\s*([0-9][A-Za-z0-9_/-]*)$"#),
           let match = regex.firstMatch(in: number, range: NSRange(number.startIndex..., in: number)),
           let prefix = Range(match.range(at: 1), in: number), let digits = Range(match.range(at: 2), in: number) {
            lead = String(number[prefix])
            body = "No. \(number[digits])"
        }
        let typePart = !type.isEmpty && !number.lowercased().hasPrefix(type.lowercased()) ? type : ""
        let leadText = [typePart, lead].filter { !$0.isEmpty }.joined(separator: " ")
        return "\(leadText.isEmpty ? "" : "\(leadText) ")\(body)\(year.isEmpty ? "" : " of \(year)")"
    }

    private static let opposite: [String: String] = [
        "petitioner": "Respondent", "plaintiff": "Defendant", "appellant": "Respondent", "complainant": "Accused",
        "applicant": "Respondent", "respondent": "Petitioner", "defendant": "Plaintiff", "accused": "Complainant",
    ]
    private static let firstNamed: Set<String> = ["petitioner", "plaintiff", "appellant", "complainant", "applicant"]
    private static let sideLabels: [String: String] = [
        "petitioner": "Petitioner", "respondent": "Respondent", "plaintiff": "Plaintiff", "defendant": "Defendant",
        "appellant": "Appellant", "complainant": "Complainant", "accused": "Accused", "applicant": "Applicant",
    ]

    /// The side that brought the matter first, whichever side the user acts for — only when both
    /// parties and a known side are recorded; a guessed cause title is worse than none.
    static func causeTitle(_ project: Project) -> [(name: String, role: String)]? {
        let client = MatterRecord.clean(project.client)
        let other = MatterRecord.clean(project.oppositeParty)
        let side = (project.ourSide ?? "").lowercased()
        guard !client.isEmpty, !other.isEmpty, let theirRole = opposite[side], let ourRole = sideLabels[side] else {
            return nil
        }
        let ours = (name: client, role: ourRole)
        let theirs = (name: other, role: theirRole)
        return firstNamed.contains(side) ? [ours, theirs] : [theirs, ours]
    }

    /// The List of Dates as an HTML fragment — the web's `listOfDatesHtml`.
    static func html(project: Project, linkedCase: LinkedCaseSummary?, entries: [MatterRecordEntry]) -> String {
        let court = MatterRecord.clean(project.forumName?.nilIfEmpty ?? linkedCase?.courtName)
        let caseNo = formalCaseNumber(type: project.caseType, number: project.caseNumber, year: project.caseYear).nilIfEmpty
            ?? formalCaseNumber(type: linkedCase?.caseType, number: linkedCase?.caseNumber, year: linkedCase?.caseYear)
        var out: [String] = []
        if !court.isEmpty { out.append("<p style=\"text-align:center\"><strong>IN THE \(esc(court.uppercased()))</strong></p>") }
        if !caseNo.isEmpty { out.append("<p style=\"text-align:center\"><strong>\(esc(caseNo.uppercased()))</strong></p>") }
        out.append("<p style=\"text-align:center\">IN THE MATTER OF:</p>")
        if let parties = causeTitle(project) {
            out.append("<p style=\"text-align:center\"><strong>\(esc(parties[0].name))</strong> … \(esc(parties[0].role))</p>")
            out.append("<p style=\"text-align:center\">VERSUS</p>")
            out.append("<p style=\"text-align:center\"><strong>\(esc(parties[1].name))</strong> … \(esc(parties[1].role))</p>")
        } else {
            out.append("<p style=\"text-align:center\"><strong>\(esc(project.name?.nilIfEmpty ?? "Untitled matter"))</strong></p>")
        }
        out.append("<h1>LIST OF DATES AND EVENTS</h1>")
        // One row per date: two things on one day are one date, each its own paragraph.
        var rows: [(day: String, events: [String])] = []
        for entry in MatterRecord.sorted(entries.filter { !$0.day.isEmpty }) {
            if let last = rows.last, last.day == entry.day {
                rows[rows.count - 1].events.append(MatterRecord.eventText(entry))
            } else {
                rows.append((entry.day, [MatterRecord.eventText(entry)]))
            }
        }
        out.append("<table><thead><tr><th>Date</th><th>Event</th></tr></thead><tbody>")
        for row in rows {
            out.append("<tr><td>\(esc(MatterRecord.dots(row.day)))</td><td>\(row.events.map { "<p>\(esc($0))</p>" }.joined())</td></tr>")
        }
        out.append("</tbody></table>")
        return out.joined(separator: "\n")
    }
}
