import Foundation

// The rules of the web's Matters list (`src/pages/Projects.jsx`), as plain functions over plain
// rows: what a status scope holds, which practice areas the menu offers, how a search matches,
// and the three orders. The web works on the whole list already fetched — a practice is a few
// hundred matters at most — and so does this.
//
// Matters absorbed Case Management, so the list also carries every tracked court case no matter
// links yet (`src/components/matters/trackedCases.js`), in the shape of a matter row so that
// search, filters, sort and counts treat both alike. Opening one makes its matter
// (`POST /project-from-case`).

/// The Status menu. The web's set, its labels, and its default (`active`).
enum MatterStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case active
    case onHold = "on_hold"
    case disposed
    case archived
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .active: return "Active"
        case .onHold: return "On hold"
        case .disposed: return "Disposed"
        case .archived: return "Archived"
        case .all: return "All statuses"
        }
    }

    /// How the summary names the scope: "3 matters on hold", not "3 on hold matters".
    func scopeWords(_ n: Int) -> String {
        let s = n == 1 ? "" : "s"
        switch self {
        case .active: return "\(n) active matter\(s)"
        case .onHold: return "\(n) matter\(s) on hold"
        case .disposed: return "\(n) disposed matter\(s)"
        case .archived: return "\(n) archived matter\(s)"
        case .all: return "\(n) matter\(s)"
        }
    }
}

/// The Sort menu. The web's three orders and its default (`recent`).
enum MatterSort: String, CaseIterable, Identifiable, Sendable {
    case recent, hearing, name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return "Recent activity"
        case .hearing: return "Next hearing"
        case .name: return "Name A–Z"
        }
    }
}

/// One row of the Matters list: a matter, or a tracked case that has none yet.
struct MatterListRow: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case project(Project)
        case trackedCase(LegalCase)
    }

    /// A matter's own id, or `case:` and the case's — two id spaces in one list.
    let id: String
    let source: Source
    let name: String
    /// The status the list files it under. A matter's own (blank reads as `active`); a tracked
    /// case's from the court's word for it.
    let status: String
    let practiceArea: String?
    let nextHearingRaw: String?
    /// The case reference shown under the name.
    let caseReference: String?
    let forumName: String?
    /// The team a tracked case is shared through, when it is shared at all.
    let sharedWith: String?
    /// When it last moved — see `MatterListing.activity`.
    let activity: Date
    /// The searchable text, lower-cased, and the same with everything but letters and digits
    /// taken out — so "WP(C) 4412 of 2025" finds "W.P.(C) 4412/2025".
    let haystack: String
    let bareHaystack: String

    var project: Project? {
        if case .project(let project) = source { return project }
        return nil
    }

    var trackedCaseID: String? {
        if case .trackedCase(let legalCase) = source { return legalCase.id }
        return nil
    }

    var isTrackedCase: Bool { trackedCaseID != nil }
}

/// A choice in the Status menu, with its count once the list is in.
struct MatterStatusOption: Equatable, Identifiable, Sendable {
    let filter: MatterStatusFilter
    let label: String
    var id: String { filter.rawValue }
}

/// A choice in the practice-area menu. `""` is every area; `MatterListing.noArea` is a matter
/// with none.
struct MatterAreaOption: Equatable, Identifiable, Sendable {
    let value: String
    let label: String
    var id: String { value }
}

enum MatterListing {
    static let trackedPrefix = "case:"
    /// The practice-area value for a row that has none. A tracked case has none until it is
    /// opened (the server guesses one then).
    static let noArea = "__none"

    /// The banner presets in the web's order (`BANNERS`), which `bannerForCase` indexes into.
    static let bannerOrder: [BannerPreset] = [.navy, .slate, .indigo, .teal, .forest, .wine, .gold, .sand]

    /// The court-type words a tracked case's forum falls back to (`CATEGORY_LABEL`).
    static let courtCategoryLabel: [String: String] = [
        "sc": "Supreme Court", "hc": "High Court", "nclt": "NCLT", "nclat": "NCLAT",
        "district": "District Court", "tribunal": "Tribunal", "forum": "Forum",
    ]

    // MARK: - Tracked cases as rows

    /// The court's word for a case → the matter status the list filters on: disposed (decided,
    /// dismissed, closed) or active. The same reading `POST /project-from-case` gives it.
    static func caseStatusKey(_ status: String?) -> String {
        let lowered = (status ?? "").lowercased()
        let disposed = ["dispos", "decided", "dismiss", "closed"].contains { lowered.contains($0) }
        return disposed ? "disposed" : "active"
    }

    /// A banner preset per case, from its id (FNV-1a over its code points), so a tracked case
    /// wears the same one on every visit and keeps it once opened.
    static func banner(forCase caseID: String) -> BannerPreset {
        var hash: UInt32 = 2_166_136_261
        for scalar in caseID.unicodeScalars {
            hash = (hash ^ scalar.value) &* 16_777_619
        }
        return bannerOrder[Int(hash % UInt32(bannerOrder.count))]
    }

    /// Case id → the matter already made for it. When two matters link one case the oldest wins,
    /// compared as text as the server's `ORDER BY created_at` does.
    static func matterByCase(_ projects: [Project]) -> [String: Project] {
        var map: [String: Project] = [:]
        for project in projects {
            guard let key = project.linkedCaseID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else { continue }
            if let had = map[key], !((project.createdAtRaw ?? "") < (had.createdAtRaw ?? "")) { continue }
            map[key] = project
        }
        return map
    }

    /// "W.P.(C) 4412/2025", the way the registry prints it; the CNR when there is no number.
    static func caseRef(caseType: String?, caseNumber: String?, caseYear: String?, cnr: String?) -> String {
        if let number = nonEmpty(caseNumber) {
            let type = nonEmpty(caseType).map { "\($0) " } ?? ""
            let year = nonEmpty(caseYear).map { "/\($0)" } ?? ""
            return type + number + year
        }
        return nonEmpty(cnr) ?? ""
    }

    /// Every tracked case no matter of the user's links — archived matters count, so a matter the
    /// user archived does not come back as a tracked case.
    static func trackedCaseRows(
        _ cases: [LegalCase], linked: [String: Project], teams: [Team]
    ) -> [MatterListRow] {
        let teamsByID = Dictionary(teams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return cases
            .filter { !$0.id.isEmpty && linked[$0.id] == nil }
            .map { trackedCaseRow($0, teamsByID: teamsByID) }
    }

    static func trackedCaseRow(_ kase: LegalCase, teamsByID: [String: Team]) -> MatterListRow {
        let numbered = caseRef(caseType: kase.caseType, caseNumber: kase.caseNumber, caseYear: kase.caseYear, cnr: kase.cnr)
        let ref = numbered.isEmpty ? (nonEmpty(kase.diaryNumber).map { "Diary No. \($0)" } ?? "") : numbered
        // `parties` can hold the literal "[]" for a case saved without any (see `LegalCase`),
        // which is no name at all.
        let parties = nonEmpty(kase.parties).flatMap { $0 == "[]" ? nil : $0 }
        let name: String
        if let title = nonEmpty(kase.title) {
            name = CourtNames.tidy(title, title: true)
        } else {
            name = parties ?? nonEmpty(ref) ?? "Untitled case"
        }
        let forum = nonEmpty(kase.courtName) ?? kase.courtType.flatMap { courtCategoryLabel[$0] } ?? ""
        // Named only when it is shared: every user's own cases sit in a team of one.
        let team = kase.teamID.flatMap { teamsByID[$0] }
        let shared = (team?.isShared ?? false) ? (nonEmpty(team?.name) ?? nonEmpty(kase.teamName) ?? "") : ""
        let text = [name, parties, ref, kase.caseNumber, kase.cnr, kase.diaryNumber, forum, shared]
            .compactMap(nonEmpty)
            .joined(separator: " • ")
        return MatterListRow(
            id: trackedPrefix + kase.id,
            source: .trackedCase(kase),
            name: name,
            status: caseStatusKey(kase.status),
            practiceArea: nil,
            nextHearingRaw: nonEmpty(kase.nextHearingDateRaw),
            caseReference: nonEmpty(ref),
            forumName: nonEmpty(forum),
            sharedWith: nonEmpty(shared),
            // Its activity is when it was added, not `updated_at`, which the hourly court
            // refresh rewrites on every case.
            activity: activityDate(kase.createdAtRaw) ?? .distantPast,
            haystack: text.lowercased(),
            bareHaystack: squash(text))
    }

    static func projectRow(_ project: Project, now: Date = Date()) -> MatterListRow {
        let ref = caseRef(caseType: project.caseType, caseNumber: project.caseNumber, caseYear: project.caseYear, cnr: project.cnr)
        let text = [project.name, project.client, project.oppositeParty, ref, project.caseNumber, project.cnr, project.forumName]
            .compactMap(nonEmpty)
            .joined(separator: " • ")
        return MatterListRow(
            id: project.id,
            source: .project(project),
            name: project.displayName,
            status: nonEmpty(project.status) ?? "active",
            practiceArea: nonEmpty(project.practiceArea),
            nextHearingRaw: nonEmpty(project.nextHearingDateRaw),
            caseReference: project.caseReference,
            forumName: project.forumLabel,
            sharedWith: nil,
            activity: activity(of: project, now: now),
            haystack: text.lowercased(),
            bareHaystack: squash(text))
    }

    /// Every row: the matters, then the tracked cases without one.
    static func rows(projects: [Project], cases: [LegalCase], teams: [Team], now: Date = Date()) -> [MatterListRow] {
        projects.map { projectRow($0, now: now) }
            + trackedCaseRows(cases, linked: matterByCase(projects), teams: teams)
    }

    // MARK: - Activity

    /// When the matter last moved: the latest of `updated_at`, `created_at` and `last_activity`
    /// — except that `last_activity` is the newest chronology entry's *event* day, which can be a
    /// hearing listed for next month. A date that has not happened yet is not activity.
    static func activity(of project: Project, now: Date) -> Date {
        let last = activityDate(project.lastActivityRaw)
        let candidates = [
            activityDate(project.updatedAtRaw),
            activityDate(project.createdAtRaw),
            last.flatMap { $0 > now ? nil : $0 },
        ]
        return candidates.compactMap { $0 }.max() ?? .distantPast
    }

    /// A stored instant, read as the web's `toDate` reads it: a zoneless timestamp is UTC, and a
    /// bare day is midnight UTC.
    static func activityDate(_ raw: String?) -> Date? {
        guard let raw = nonEmpty(raw) else { return nil }
        if raw.count == 10, let day = utcDay.date(from: raw) { return day }
        return WireDate.parse(raw)
    }

    nonisolated(unsafe) private static let utcDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Hearing days

    /// Whole days from today to the hearing, both counted as days in India. Negative when it
    /// has passed; `nil` when there is no date.
    static func hearingDays(_ raw: String?, todayKey: String) -> Int? {
        guard let raw = nonEmpty(raw) else { return nil }
        let instant: Date?
        if raw.count == 10 {
            instant = WireDate.parseDay(raw)
        } else {
            instant = WireDate.parse(raw) ?? WireDate.parseDay(raw)
        }
        guard let instant, let hearing = WireDate.parseDay(WireDate.dayKey(instant)),
              let today = WireDate.parseDay(todayKey) else { return nil }
        return Int((hearing.timeIntervalSince(today) / 86_400).rounded())
    }

    // MARK: - Filters

    /// The rows in a status scope. A matter with no status is active.
    static func scoped(_ rows: [MatterListRow], status: MatterStatusFilter) -> [MatterListRow] {
        guard status != .all else { return rows }
        return rows.filter { $0.status == status.rawValue }
    }

    /// How many rows each status holds. A status the menu does not list counts as active.
    static func counts(_ rows: [MatterListRow]) -> [MatterStatusFilter: Int] {
        var counts: [MatterStatusFilter: Int] = [.active: 0, .onHold: 0, .disposed: 0, .archived: 0]
        for row in rows {
            let key = MatterStatusFilter(rawValue: row.status).flatMap { $0 == .all ? nil : $0 } ?? .active
            counts[key, default: 0] += 1
        }
        counts[.all] = rows.count
        return counts
    }

    /// Only the practice areas the matters actually have, in the vocabulary's order; then any
    /// area the vocabulary does not know; then "No practice area" when some have none and there
    /// is anything else to choose. A choice the data no longer has stays visible, so the menu
    /// never shows a selection it does not hold.
    static func areaOptions(_ rows: [MatterListRow], selected: String) -> [MatterAreaOption] {
        var present: [String] = []
        for row in rows {
            let key = row.practiceArea ?? noArea
            if !present.contains(key) { present.append(key) }
        }
        var options = [MatterAreaOption(value: "", label: "All practice areas")]
        for (key, label) in MatterVocabulary.practiceAreas where present.contains(key) {
            options.append(MatterAreaOption(value: key, label: label))
        }
        for key in present where key != noArea && !MatterVocabulary.practiceAreas.contains(where: { $0.key == key }) {
            options.append(MatterAreaOption(value: key, label: key))
        }
        if present.contains(noArea), options.count > 1 {
            options.append(MatterAreaOption(value: noArea, label: "No practice area"))
        }
        if !selected.isEmpty, !options.contains(where: { $0.value == selected }) {
            let label = selected == noArea
                ? "No practice area"
                : (MatterVocabulary.practiceAreas.first { $0.key == selected }?.label ?? selected)
            options.append(MatterAreaOption(value: selected, label: label))
        }
        return options
    }

    /// The rows shown: the scope, the area, the search, then the order.
    static func shown(
        _ rows: [MatterListRow], status: MatterStatusFilter, area: String, query: String,
        sort: MatterSort, todayKey: String
    ) -> [MatterListRow] {
        let term = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = squash(query)
        let list = scoped(rows, status: status).filter { row in
            if !area.isEmpty, (row.practiceArea ?? noArea) != area { return false }
            guard !term.isEmpty else { return true }
            return row.haystack.contains(term) || (bare.count >= 2 && row.bareHaystack.contains(bare))
        }
        return sorted(list, by: sort, todayKey: todayKey)
    }

    static func sorted(_ list: [MatterListRow], by sort: MatterSort, todayKey: String) -> [MatterListRow] {
        let indexed = Array(list.enumerated())
        let ordered: [(offset: Int, element: MatterListRow)]
        switch sort {
        case .name:
            ordered = indexed.sorted { a, b in
                let byName = compareNames(a.element.name, b.element.name)
                return byName != .orderedSame ? byName == .orderedAscending : a.offset < b.offset
            }
        case .hearing:
            // Upcoming first, soonest first; then hearings already past, the most recent first —
            // the ones most likely to need a new date entered; then matters with no date at all.
            let keys = Dictionary(uniqueKeysWithValues: list.map { row -> (String, (Int, Int)) in
                guard let days = hearingDays(row.nextHearingRaw, todayKey: todayKey) else { return (row.id, (2, 0)) }
                return (row.id, days >= 0 ? (0, days) : (1, -days))
            })
            ordered = indexed.sorted { a, b in
                let ka = keys[a.element.id] ?? (2, 0), kb = keys[b.element.id] ?? (2, 0)
                if ka.0 != kb.0 { return ka.0 < kb.0 }
                if ka.1 != kb.1 { return ka.1 < kb.1 }
                let byName = compareNames(a.element.name, b.element.name)
                return byName != .orderedSame ? byName == .orderedAscending : a.offset < b.offset
            }
        case .recent:
            ordered = indexed.sorted { a, b in
                if a.element.activity != b.element.activity { return a.element.activity > b.element.activity }
                let byName = compareNames(a.element.name, b.element.name)
                return byName != .orderedSame ? byName == .orderedAscending : a.offset < b.offset
            }
        }
        return ordered.map(\.element)
    }

    /// Hearings in the next seven days, today included — the web's "N hearings in the next 7 days".
    static func hearingsSoon(_ rows: [MatterListRow], todayKey: String) -> Int {
        rows.filter { row in
            guard let days = hearingDays(row.nextHearingRaw, todayKey: todayKey) else { return false }
            return days >= 0 && days <= 7
        }.count
    }

    /// `localeCompare(…, 'en-IN', { numeric: true, sensitivity: 'base' })`: case and accents
    /// ignored, digits compared as numbers.
    static func compareNames(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .numeric], range: nil, locale: Locale(identifier: "en_IN"))
    }

    // MARK: - Text

    /// Lower-cased, with everything but ASCII letters and digits removed.
    static func squash(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map(Character.init))
    }

    static func nonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
