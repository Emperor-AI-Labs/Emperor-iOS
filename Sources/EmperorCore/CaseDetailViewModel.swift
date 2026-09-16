import Foundation
#if canImport(Darwin)
import Observation
#endif

/// One matter: its overview, hearings, orders and timeline.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class CaseDetailViewModel {

    private(set) var detail: CaseDetail?
    private(set) var state: LoadState = .idle
    private(set) var isWriting = false
    var writeError: String?
    /// A fetched order PDF, ready to present.
    var openDocument: OpenDocument?

    struct OpenDocument: Identifiable, Sendable {
        let id = UUID()
        let data: Data
        let title: String
    }

    let caseID: String
    private let service: any CaseProviding

    init(caseID: String, service: any CaseProviding) {
        self.caseID = caseID
        self.service = service
    }

    var legalCase: LegalCase? { detail?.legalCase }
    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: detail == nil)
    }

    // MARK: - Reading

    /// Hearings, newest first. Read from both sections the cause list uses, because a row can
    /// legitimately be filed under either.
    var hearings: [CaseItem] {
        guard let detail else { return [] }
        return detail.items
            .filter { CaseSection.causeListSections.contains($0.section) }
            .sorted { ($0.itemDateRaw ?? "") > ($1.itemDateRaw ?? "") }
    }

    var orders: [CaseItem] {
        detail?.items(in: .orders)
            .sorted { ($0.itemDateRaw ?? "") > ($1.itemDateRaw ?? "") } ?? []
    }

    var tasks: [CaseItem] {
        detail?.items(in: .tasks)
            .sorted { ($0.itemDateRaw ?? "") < ($1.itemDateRaw ?? "") } ?? []
    }

    var timeline: [CaseEvent] {
        detail?.events.sorted { ($0.eventDate ?? .distantPast) > ($1.eventDate ?? .distantPast) }
            ?? []
    }

    // MARK: - Tabs

    /// One tab below the overview.
    ///
    /// Everything but the overview is a tab because a matter is read one section at a time: you
    /// open a case to check the next date, or to find an order — not to scroll past four
    /// sections to reach the fifth.
    struct CaseTab: Identifiable, Equatable, Sendable {
        enum Content: Equatable, Sendable {
            case items([CaseItem])
            case notes([CaseEvent])
        }

        /// The section's wire value, so a tab keeps its identity across a reload while its
        /// contents change underneath it.
        let id: String
        let label: String
        let content: Content

        var count: Int {
            switch content {
            case .items(let items): return items.count
            case .notes(let events): return events.count
            }
        }
    }

    /// The timeline's tab id. Deliberately not `notes`: `section` is an open string, so a row
    /// filed under `notes` could arrive, and two tabs must never share an id.
    static let timelineTabID = "timeline"

    /// The tabs below the overview — only the ones with something in them.
    ///
    /// An empty tab is worse than an absent one: it costs a tap to discover there was nothing
    /// there, and on a matter just pulled from a court portal most of these are empty.
    ///
    /// The order is `CaseDetail.populatedSections`, which is `CaseSection.allCases` filtered, so
    /// reading order is declared once in the taxonomy rather than a second time here.
    var tabs: [CaseTab] {
        guard let detail else { return [] }
        var built: [CaseTab] = []
        var hasHearings = false

        for section in detail.populatedSections {
            // `hearings` and `causelist` are one tab. A row can be filed under either, and which
            // one is the court's bookkeeping rather than anything the reader came here for.
            if CaseSection.causeListSections.contains(section.rawValue) {
                guard !hasHearings else { continue }
                hasHearings = true
                built.append(CaseTab(
                    id: CaseSection.hearings.rawValue,
                    label: CaseSection.hearings.label,
                    content: .items(hearings)))
                continue
            }

            let rows: [CaseItem]
            switch section {
            case .orders: rows = orders
            case .tasks: rows = tasks
            default: rows = Self.newestFirst(detail.items(in: section))
            }
            built.append(CaseTab(id: section.rawValue, label: section.label, content: .items(rows)))
        }

        // Sections this build has no name for. Surfaced rather than dropped, for the same reason
        // the server's own list cannot be trusted to be closed.
        for section in detail.unknownSections {
            built.append(CaseTab(
                id: section,
                label: DisplayText.fileName(section).capitalized,
                content: .items(
                    Self.newestFirst(detail.items.filter { $0.section == section }))))
        }

        if !timeline.isEmpty {
            built.append(CaseTab(
                id: Self.timelineTabID,
                label: CaseSection.notes.label,
                content: .notes(timeline)))
        }
        return built
    }

    /// Which tab the user chose. Stored because it is a choice, but never trusted alone — read
    /// it through `selectedTab`.
    var selectedTabID: String?

    /// The tab to show: the chosen one while it exists, otherwise the first.
    ///
    /// A reload can empty the section being read — a task ticked off on the web, the only note
    /// deleted — and `tabs` then no longer holds it. Falling back on the way out, rather than
    /// correcting `selectedTabID`, means the choice survives the gap: if the section comes back
    /// so does the selection, and nothing mutates while the screen is drawing.
    var selectedTab: CaseTab? {
        let available = tabs
        guard let selectedTabID,
              let chosen = available.first(where: { $0.id == selectedTabID })
        else { return available.first }
        return chosen
    }

    private static func newestFirst(_ items: [CaseItem]) -> [CaseItem] {
        items.sorted { ($0.itemDateRaw ?? "") > ($1.itemDateRaw ?? "") }
    }

    /// How to describe the sync state honestly.
    ///
    /// `null` means never synced — not "synced long ago". Saying "Not synced from the court"
    /// is the difference between a practitioner trusting a stale hearing date and checking it.
    var syncDescription: String {
        guard let legalCase else { return "" }
        guard let synced = legalCase.lastSyncedAt else {
            return "Not synced from the court. Dates here were entered by hand."
        }
        return "Last synced from the court \(DisplayText.relative(synced))."
    }

    var isCourtSynced: Bool { legalCase?.isCourtSynced == true }

    // MARK: - Loading

    func load() async {
        state = .loading
        do {
            detail = try await service.caseDetail(id: caseID)
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    // MARK: - Writing

    /// Adds a note to the timeline. One of only two writes this app offers on a matter — the
    /// two that make sense standing up outside a courtroom.
    func addNote(title: String?, body: String) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        do {
            try await service.addNote(
                caseID: caseID,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                body: trimmed)
            // Re-read rather than appending optimistically: the server mints the id and the
            // timestamp, and `updated_at` on the case moves too.
            await load()
        } catch {
            writeError = DisplayText.message(for: error)
        }
    }

    func addTask(title: String, dueDate: Date?) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        do {
            try await service.addTask(caseID: caseID, title: trimmed, dueDate: dueDate)
            await load()
        } catch {
            writeError = DisplayText.message(for: error)
        }
    }

    /// Whether this row can be edited in the app.
    ///
    /// Scraped rows cannot: they are deleted and re-inserted wholesale on every refresh
    /// (`court-scraper/materialize.js:59-69`), so an edit survives until the next sync and is
    /// then removed with no error and no notification. Offering the edit would be a lie.
    func isEditable(_ item: CaseItem) -> Bool { !item.isCourtOwned }

    // MARK: - Order documents

    func openOrder(_ item: CaseItem) async {
        guard let legalCase else { return }
        isWriting = true
        defer { isWriting = false }
        do {
            let data = try await service.orderDocument(for: item, in: legalCase)
            openDocument = OpenDocument(
                data: data,
                title: item.title ?? "Order")
        } catch {
            writeError = DisplayText.message(for: error)
        }
    }
}
