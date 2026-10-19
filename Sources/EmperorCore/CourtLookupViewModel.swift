import Foundation
#if canImport(Darwin)
import Observation
#endif

/// A case read from the court's own records (Fetch Orders), and the one button that keeps it.
///
/// Nothing here writes until "Add to Matters" is pressed: the record is fetched, read, copied or
/// asked about, and forgotten when the sheet closes. Adding it is the existing save (`/save-case`,
/// the personal team) followed by `/project-from-case`, so the matter opens with the court case
/// already linked.
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

    private(set) var isAdding = false
    /// Set once the case is on the docket — by this screen, or already.
    private(set) var isTracked = false
    /// The matter made (or found) for the case, when adding got that far.
    private(set) var matterID: String?
    var addError: String?
    var notice: String?

    private let lookup: any CourtLookupProviding
    private let tracker: any CourtSearching
    private let projects: (any ProjectProviding)?
    private let todayKey: () -> String

    init(
        card: CourtSearchResult,
        lookup: any CourtLookupProviding,
        tracker: any CourtSearching,
        projects: (any ProjectProviding)? = nil,
        todayKey: @escaping () -> String = { WireDate.todayKey() }
    ) {
        self.card = card
        self.lookup = lookup
        self.tracker = tracker
        self.projects = projects
        self.todayKey = todayKey
    }

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: record == nil)
    }

    var title: String { record?.displayTitle ?? card.displayTitle }

    // MARK: - The four tiles

    struct Tile: Equatable, Identifiable, Sendable {
        let label: String
        let value: String
        var detail: String?
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
            tiles.append(Tile(label: "Next hearing", value: when, detail: DisplayText.longDay(next)))
        } else if let last = record.lastHearing?.date {
            tiles.append(Tile(label: "Next hearing", value: "Not listed yet",
                              detail: "Last heard \(DisplayText.longDay(last))"))
        } else {
            tiles.append(Tile(label: "Next hearing", value: "Not listed yet"))
        }

        tiles.append(Tile(label: "Where it stands", value: record.standingLine ?? "Not stated",
                          detail: record.case.bench?.nilIfEmpty.map { "Before \($0)" }))

        if let order = record.latestOrder {
            tiles.append(Tile(label: "Latest order",
                              value: order.date.map(DisplayText.longDay) ?? order.displayTitle,
                              detail: order.date == nil ? nil : order.displayTitle))
        } else {
            tiles.append(Tile(label: "Latest order", value: "None on record"))
        }

        tiles.append(Tile(label: "What the court holds", value: record.holdingsLine))
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

    // MARK: - Loading

    func load() async {
        state = .loading
        do {
            record = try await lookup.lookup(card)
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    // MARK: - Keeping it

    /// Adds the case to the docket, then opens (or makes) its matter. Returns the matter's id
    /// when it got that far. A case already on the docket is the outcome wanted, and is said so;
    /// a numberless card that collides is a refusal, and is said so too.
    @discardableResult
    func addToMatters() async -> String? {
        guard !isAdding else { return nil }
        isAdding = true
        addError = nil
        notice = nil
        defer { isAdding = false }

        do {
            switch try await tracker.save(card) {
            case .saved(let caseID):
                isTracked = true
                if let projects {
                    let made = try await projects.projectFromCase(caseID: caseID)
                    matterID = made.project.id
                    notice = made.existed
                        ? "This case was already in your matters."
                        : "\(title) is now in your matters."
                } else {
                    notice = "\(title) is now on your docket."
                }
            case .alreadySaved(let message):
                // Already there is what they wanted; there is no id in the answer to open it
                // by, so the way to it is the Matters tab.
                isTracked = true
                notice = "\(message) Open it from Matters."
            case .refusedAsIndistinguishable(let message):
                addError = message
            }
        } catch {
            addError = DisplayText.message(for: error)
        }
        return matterID
    }

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
}
