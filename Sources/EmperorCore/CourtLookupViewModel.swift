import Foundation
#if canImport(Darwin)
import Observation
#endif

/// A case read from the court's own records (Fetch Orders), and the one button that keeps it.
///
/// Nothing here writes until "Add to Matters" is pressed: the record is fetched, read, copied or
/// asked about, and forgotten when the sheet closes. Adding it is the existing save (`/save-case`,
/// the personal team) followed by `/project-from-case` and — when the reader said which side they
/// are on — `/project-patch`, so the matter opens with the court case already linked and its
/// client named. A case already on the docket is recognised on load, and the offer becomes
/// "Open in Matters".
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class CourtLookupViewModel {

    let card: CourtSearchResult

    private(set) var record: CourtRecord?
    private(set) var state: LoadState = .idle
    /// The server answered from its ten-minute cache rather than the court.
    private(set) var fromCache = false

    private(set) var isAdding = false
    /// Set once the case is on the docket — by this screen, or already.
    private(set) var isTracked = false
    /// The tracked case's id, when known (found on load, or made by the save).
    private(set) var trackedCaseID: String?
    /// The matter made (or found) for the case, when adding got that far.
    private(set) var matterID: String?
    var addError: String?
    var notice: String?

    /// Which year's orders are shown; empty for all.
    var orderYear = ""

    private let lookup: any CourtLookupProviding
    private let tracker: any CourtSearching
    private let projects: (any ProjectProviding)?
    private let cases: (any CaseProviding)?
    private let recent: RecentLookups?
    private let todayKey: () -> String

    init(
        card: CourtSearchResult,
        lookup: any CourtLookupProviding,
        tracker: any CourtSearching,
        projects: (any ProjectProviding)? = nil,
        cases: (any CaseProviding)? = nil,
        recent: RecentLookups? = nil,
        todayKey: @escaping () -> String = { WireDate.todayKey() }
    ) {
        self.card = card
        self.lookup = lookup
        self.tracker = tracker
        self.projects = projects
        self.cases = cases
        self.recent = recent
        self.todayKey = todayKey
    }

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: record == nil)
    }

    var title: String { record?.displayTitle ?? card.displayTitle }

    /// The case's name as a court prints it, read quietly.
    var tidyTitle: String {
        record.map { LookupModel.title(of: $0.case) } ?? CourtNames.tidy(card.displayTitle, title: true)
    }

    // MARK: - The four tiles

    struct Tile: Equatable, Identifiable, Sendable {
        let label: String
        let value: String
        var detail: String?
        /// What the (?) beside the label explains.
        var hint: String?
        var id: String { label }
    }

    /// Next hearing · Where it stands · Latest order · What the court holds — the web's four,
    /// each with a plain answer even when the court has none.
    var tiles: [Tile] {
        guard let record else { return [] }
        var tiles: [Tile] = []

        if let next = record.nextHearingKey {
            let days = MatterStanding.days(from: todayKey(), to: next)
            let when = days == 0 ? "Today" : days == 1 ? "Tomorrow" : "In \(days) days"
            tiles.append(Tile(label: "Next hearing", value: when, detail: DisplayText.longDay(next), hint: Hints.nextHearing))
        } else if let last = record.lastHearing?.date {
            tiles.append(Tile(label: "Next hearing", value: isDisposed ? "Decided" : "Not listed yet",
                              detail: isDisposed ? "The case is over, so no further hearing is listed." : "Last heard \(DisplayText.longDay(last))",
                              hint: Hints.nextHearing))
        } else {
            tiles.append(Tile(label: "Next hearing", value: isDisposed ? "Decided" : "Not listed yet", hint: Hints.nextHearing))
        }

        tiles.append(Tile(label: "Where it stands", value: record.standingLine ?? "Not stated",
                          detail: record.case.bench?.nilIfEmpty.map { "Before \($0)" }, hint: Hints.stands))

        if let order = record.latestOrder {
            tiles.append(Tile(label: "Latest order",
                              value: order.date.map(DisplayText.longDay) ?? order.displayTitle,
                              detail: order.date == nil ? nil : order.displayTitle, hint: Hints.latestOrder))
        } else {
            tiles.append(Tile(label: "Latest order", value: "None on record", hint: Hints.latestOrder))
        }

        tiles.append(Tile(label: "What the court holds", value: record.holdingsLine, hint: Hints.holds))
        return tiles
    }

    /// The identifying line under the title: "ARB.P. 112/2025 · Delhi High Court".
    var subtitle: String? {
        guard let record else { return card.reference }
        return [record.reference, record.case.courtName?.nilIfEmpty]
            .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    /// The numbers worth copying, labelled.
    var identifiers: [(label: String, value: String)] {
        guard let record else { return [] }
        var out: [(String, String)] = []
        if let cnr = record.case.cnr?.nilIfEmpty { out.append(("CNR", cnr)) }
        if let diary = record.case.diaryNumber?.nilIfEmpty { out.append(("Diary no.", diary)) }
        if let filed = record.case.filingDate?.nilIfEmpty { out.append(("Filed", DisplayText.longDay(filed))) }
        if let category = record.case.category?.nilIfEmpty { out.append(("Category", category)) }
        return out
    }

    /// Why an order has no link: the court serves it only through a session.
    static let noCopyOnline = "No copy online — add the case to Matters and the order can be fetched there."

    // MARK: - Status, sides, timeline

    var isDisposed: Bool { record.map { LookupModel.isDisposed($0.case) } ?? false }

    /// "Still going", "Decided" — the court's status in a client's words.
    var statusWord: String { LookupModel.statusWord(record?.case.status) ?? "Status not given" }

    var sides: (first: LookupModel.Side, second: LookupModel.Side)? {
        record.map { LookupModel.sides(of: $0.parties) }
    }

    var timeline: [LookupModel.TimelineRow] {
        record.map { LookupModel.timeline(of: $0, today: todayKey()) } ?? []
    }

    /// "Filed 14 Feb 2025 · 1 year ago" / "First listed …".
    var sinceLine: String? {
        guard let record else { return nil }
        let first = record.hearings.last?.date
        guard let since = record.case.filingDate?.nilIfEmpty ?? first else { return nil }
        return "\(record.case.filingDate?.nilIfEmpty == nil ? "First listed" : "Filed") \(LibraryTitles.shortDay(since)) · \(LookupModel.ago(since, today: todayKey()))"
    }

    /// The years the orders span, newest first.
    var orderYears: [String] { record.map { LookupModel.years(of: $0.orders) } ?? [] }

    var filteredOrders: [CourtRecord.Order] {
        guard let record else { return [] }
        guard !orderYear.isEmpty else { return record.orders }
        return record.orders.filter { ($0.date ?? "").hasPrefix(orderYear) }
    }

    /// "4 Oct 2026 · 2 weeks ago".
    func orderLine(_ order: CourtRecord.Order) -> String? {
        guard let date = order.date?.nilIfEmpty else { return nil }
        return "\(LibraryTitles.shortDay(date)) · \(LookupModel.ago(date, today: todayKey()))"
    }

    func isUpcoming(_ hearing: CourtRecord.Hearing) -> Bool {
        (hearing.date ?? "") > todayKey()
    }

    /// "Court 12 · Item 34", else the bench, else "—".
    func hearingWhere(_ hearing: CourtRecord.Hearing) -> String {
        let room = [LookupModel.room(hearing.courtNo).nilIfEmpty, hearing.itemNo?.nilIfEmpty.map { "Item \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        return room.nilIfEmpty ?? LookupModel.plainCourtText(hearing.bench).nilIfEmpty ?? "—"
    }

    func hearingWhat(_ hearing: CourtRecord.Hearing) -> String {
        let purpose = LookupModel.plainCourtText(hearing.purpose).nilIfEmpty ?? "Listed before the court"
        if let stage = LookupModel.plainCourtText(hearing.stage).nilIfEmpty { return "\(purpose) · \(stage)" }
        return purpose
    }

    /// "Read from the court just now · not saved to your account".
    var provenanceLine: String {
        "Read from the court \(fromCache ? "a few minutes ago" : "just now") · not saved to your account"
    }

    // MARK: - Loading

    func load() async {
        state = .loading
        do {
            let fetched = try await lookup.lookup(card)
            record = fetched
            fromCache = false
            state = .loaded
            recent?.remember(card, title: fetched.case.title ?? fetched.displayTitle)
            await findExistingMatter()
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    /// Is this case already one of the user's matters? Then the offer becomes "Open in Matters".
    func findExistingMatter() async {
        guard let cases, record != nil else { return }
        guard let known = (try? await cases.cases()).flatMap({ TrackedCases.find(card, in: $0) }) else { return }
        isTracked = true
        trackedCaseID = known.id
        guard let projects, let mine = try? await projects.projects(includeArchived: true) else { return }
        matterID = mine.first { $0.linkedCaseID == known.id }?.id
    }

    // MARK: - Keeping it

    /// Adds the case to the docket, then opens (or makes) its matter. Returns the matter's id
    /// when it got that far. A case already on the docket is the outcome wanted, and is said so;
    /// a numberless card that collides is a refusal, and is said so too.
    @discardableResult
    func addToMatters() async -> String? {
        await addToMatters(draft: nil)
    }

    /// The same, with what the reader filled in: the matter's name and their side.
    @discardableResult
    func addToMatters(draft: AddToMattersDraft?) async -> String? {
        guard !isAdding else { return nil }
        isAdding = true
        addError = nil
        notice = nil
        defer { isAdding = false }

        do {
            var caseID = trackedCaseID
            if caseID == nil {
                switch try await tracker.save(card) {
                case .saved(let id):
                    caseID = id
                    isTracked = true
                    trackedCaseID = id
                case .alreadySaved(let message):
                    // Already there is what they wanted. Its id is not in the answer; the docket
                    // can name it, and the way to it otherwise is the Matters tab.
                    isTracked = true
                    if let cases, let known = (try? await cases.cases()).flatMap({ TrackedCases.find(card, in: $0) }) {
                        caseID = known.id
                        trackedCaseID = known.id
                    } else {
                        notice = "\(message) Open it from Matters."
                        return nil
                    }
                case .refusedAsIndistinguishable(let message):
                    addError = message
                    return nil
                }
            }
            guard let projects, let caseID else {
                notice = "\(title) is now on your docket."
                return nil
            }
            let made = try await projects.projectFromCase(caseID: caseID)
            matterID = made.project.id
            if let draft, !draft.patchFields.isEmpty {
                var fields = draft.patchFields
                if draft.trimmedName != made.project.name, !draft.trimmedName.isEmpty { fields["name"] = .string(draft.trimmedName) }
                _ = try? await projects.patch(projectID: made.project.id, fields: fields)
            } else if let draft, !draft.trimmedName.isEmpty, draft.trimmedName != made.project.name {
                _ = try? await projects.patch(projectID: made.project.id, fields: ["name": .string(draft.trimmedName)])
            }
            notice = made.existed
                ? "This case was already in your matters."
                : "\(title) is now in your matters."
        } catch {
            addError = DisplayText.message(for: error)
        }
        return matterID
    }

    /// The draft the "Add to Matters" sheet opens with.
    var addDraft: AddToMattersDraft? { record.map(AddToMattersDraft.init(record:)) }

    /// The one button's words: open the matter when there is one, else add.
    var keepLabel: String { matterID == nil ? "Add to Matters" : "Open in Matters" }

    var keepTitle: String {
        matterID == nil ? "Want to keep an eye on this case?" : "This case is already in your Matters."
    }

    static let keepPromises = [
        "Alerts when a new order or date appears",
        "Checked against the court every hour",
        "Files, tasks, fees and notes in one place",
    ]

    // MARK: - Taking it away

    /// The record as a plain-text note — what "Copy summary" puts on the clipboard.
    var summaryText: String {
        guard let record else { return title }
        var lines: [String] = [record.displayTitle]
        if let subtitle { lines.append(subtitle) }
        for (label, value) in identifiers { lines.append("\(label): \(value)") }
        if let standing = record.standingLine { lines.append("Status: \(standing)") }
        if let next = record.nextHearingKey { lines.append("Next hearing: \(DisplayText.longDay(next))") }
        if !record.parties.petitioners.isEmpty {
            lines.append("Petitioners: \(record.parties.petitioners.joined(separator: "; "))")
        }
        if !record.parties.respondents.isEmpty {
            lines.append("Respondents: \(record.parties.respondents.joined(separator: "; "))")
        }
        if !record.orders.isEmpty {
            lines.append("")
            lines.append("Orders")
            for order in record.orders {
                let day = order.date.map(DisplayText.longDay) ?? "Undated"
                lines.append("- \(day): \(order.displayTitle)\(order.url.map { " \($0)" } ?? "")")
            }
        }
        if !record.hearings.isEmpty {
            lines.append("")
            lines.append("Hearings")
            for hearing in record.hearings.prefix(20) {
                let day = hearing.date.map(DisplayText.longDay) ?? "Undated"
                let what = [hearing.purpose, hearing.remarks].compactMap { $0?.nilIfEmpty }.joined(separator: " — ")
                lines.append("- \(day)\(what.isEmpty ? "" : ": \(what)")")
            }
        }
        lines.append("")
        lines.append("Read from the court's records with Emperor. Confirm with the court before acting on it.")
        return lines.joined(separator: "\n")
    }

    /// The question "Ask about it" starts with: the case, where it stands, and what the reader
    /// is preparing for.
    var askPrompt: String {
        let name = title
        let reference = subtitle.map { " (\($0))" } ?? ""
        var facts: [String] = []
        if let standing = record?.standingLine { facts.append("the court shows it as \(standing)") }
        if let next = record?.nextHearingKey { facts.append("it is next listed on \(DisplayText.longDay(next))") }
        if let order = record?.latestOrder, let day = order.date {
            facts.append("the latest order is dated \(DisplayText.longDay(day))")
        }
        let because = facts.isEmpty ? "" : " — " + DisplayText.list(facts)
        return "I am looking at \(name)\(reference)\(because). What is this case about, where does it stand, and what should I prepare next?"
    }

    /// What each heading's (?) explains, in a line.
    enum Hints {
        static let nextHearing = "The next day this case is listed before a judge. It comes from the court’s own cause list."
        static let stands = "Whether the case is still being heard, and at what step. “Stage” is the court’s own word for the step."
        static let latestOrder = "What the judge decided or directed on the most recent hearing. Open it to read the court’s own copy."
        static let holds = "How much the court holds on this case, all of it on this page."
        static let orders = "Written decisions and directions of the court, newest first. “Read” opens the court’s own PDF."
        static let hearings = "Every day the case was (or will be) listed before a judge, with the courtroom and what the list said. Future dates are marked Upcoming."
        static let applications = "Smaller requests filed inside the case — for example, asking for an urgent hearing or for documents to be taken on record."
        static let parties = "Who is on each side of the case, and the lawyers appearing for them, as the court lists them."
        static let timeline = "Hearings and orders together, newest at the top."
        static let extras = "Earlier cases this one grew out of (for example, the lower court’s case), and the court fees paid."
    }
}
