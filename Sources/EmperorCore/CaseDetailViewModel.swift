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

    /// Sections beyond the four the app surfaces directly, so nothing the server returned is
    /// silently dropped — `section` is an open string and a new one can appear at any time.
    var otherSections: [(section: String, items: [CaseItem])] {
        guard let detail else { return [] }
        let surfaced: Set<String> = CaseSection.causeListSections
            .union([CaseSection.orders.rawValue, CaseSection.tasks.rawValue])
        let remaining = Dictionary(grouping: detail.items.filter { !surfaced.contains($0.section) }) {
            $0.section
        }
        return remaining
            .map { (section: $0.key, items: $0.value) }
            .sorted { $0.section < $1.section }
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
