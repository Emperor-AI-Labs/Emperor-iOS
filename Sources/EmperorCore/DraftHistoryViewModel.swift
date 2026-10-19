import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Everything the assistant has drafted, across every conversation.
///
/// Worth its own screen because the alternative is remembering which chat a pleading came out
/// of. On a phone that is the difference between finding last week's draft in five seconds and
/// scrolling a conversation list.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class DraftHistoryViewModel {
    var kind: DraftKind = .document {
        didSet {
            guard kind != oldValue else { return }
            // Drafts and tables are separate routes with separate lists. Showing one while the
            // picker says the other is worse than a spinner.
            items = []
            state = .idle
        }
    }

    private(set) var items: [DraftedItem] = []
    private(set) var state: LoadState = .idle
    var query = ""

    /// The draft being read, once its content has arrived.
    var opened: OpenedDraft?
    private(set) var loadingID: String?
    var errorMessage: String?

    private let service: any DraftHistoryProviding

    /// Set for a matter's Drafts section: its documents **and** tables, in one list.
    let projectID: String?
    /// Said above a matter's list when one of its two halves could not be loaded.
    private(set) var partialNotice: String?

    struct OpenedDraft: Equatable, Identifiable {
        let item: DraftedItem
        let content: String
        var id: String { item.id }

        /// How to draw it — read from the content, never taken from the row's `type`.
        ///
        /// Drafts arrive as inline-styled HTML fragments: centred headings, underlined court
        /// names, bordered tables of contents. Rendering one as Markdown gives a wall of raw
        /// tags, which is exactly what this screen did — every draft went to the Markdown
        /// renderer whatever was in it.
        ///
        /// `detectFormat` is the sniff the streaming path already uses, and the platform's own
        /// `canvasShape.js` exists because a declared type is a claim rather than a fact. The
        /// declared kind is passed through as its tiebreak, but it settles only the case where
        /// the body holds neither block HTML nor a Markdown table: the content decides first.
        var format: StreamArtifact.Format {
            StreamArtifact.detectFormat(
                of: content, declared: item.type == DraftKind.table.rawValue ? .table : .canvas)
        }
    }

    init(service: any DraftHistoryProviding, projectID: String? = nil) {
        self.service = service
        let trimmed = projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.projectID = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    var isMatterScoped: Bool { projectID != nil }

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: visible.isEmpty)
    }

    /// Filtered by the search field, matching on the draft's own title and on the conversation
    /// it came from — someone looking for "the Bakshi petition" may remember either.
    var visible: [DraftedItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { item in
            item.displayTitle.localizedCaseInsensitiveContains(trimmed)
                || (item.chatTitle ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    var showsNoSearchResults: Bool {
        state == .loaded && !items.isEmpty && visible.isEmpty
    }

    /// Grouped by the day they were produced, in India.
    ///
    /// A draft written at 11pm IST is that day's work, not the next day's — which is what
    /// bucketing against the device's own zone would say to anyone travelling.
    var groups: [Group] {
        var order: [String] = []
        var byDay: [String: [DraftedItem]] = [:]
        for item in visible {
            let key = item.createdAt.map(WireDate.dayKey) ?? ""
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(item)
        }
        return order.map { key in
            Group(id: key, title: Self.dayTitle(key), items: byDay[key] ?? [])
        }
    }

    struct Group: Identifiable, Equatable {
        let id: String
        let title: String
        let items: [DraftedItem]
    }

    /// A row whose timestamp did not parse still has to appear somewhere. Burying it under a
    /// blank heading would read as a rendering fault.
    static func dayTitle(_ key: String) -> String {
        guard !key.isEmpty, let date = WireDate.parseDay(key) else { return "Undated" }
        return DisplayText.relative(date)
    }

    // MARK: - Loading

    func load() async {
        if let projectID { return await loadMatter(projectID) }
        state = .loading
        do {
            // A matter's drafts are the matter's, as its conversations are — see
            // `ChatListViewModel.ownConversations`.
            items = try await service.drafts(kind).filter { !$0.belongsToMatter }
            state = .loaded
        } catch is CancellationError {
            // Switching the Drafts/Tables control cancels the in-flight fetch, and a cancelled
            // `URLSession` request surfaces as a retryable transport error that `withRetry`
            // then converts into a `CancellationError`. Treated as a failure it renders as
            // "The operation couldn't be completed. (Swift.CancellationError error 1.)" with a
            // Try again button — for a request the user themselves replaced a moment ago.
            // The replacement task owns the state from here.
            return
        } catch {
            items = []
            state = .failed(LoadFailure(error))
        }
    }

    /// A matter's documents and tables, merged newest first.
    ///
    /// Only rows that name **this** matter are kept, as the web keeps them — a listing that held
    /// anything else would put a draft from another conversation inside the matter. One half
    /// failing still shows the other, with a line saying which is missing.
    private func loadMatter(_ projectID: String) async {
        state = .loading
        partialNotice = nil
        let service = self.service
        async let documents = Self.attempt { try await service.drafts(.document, projectID: projectID) }
        async let tables = Self.attempt { try await service.drafts(.table, projectID: projectID) }
        let (docs, tabs) = await (documents, tables)
        if Task.isCancelled { return }
        switch (docs, tabs) {
        case (.failure(let error), .failure):
            items = []
            state = .failed(LoadFailure(error))
            return
        case (.failure, .success):
            partialNotice = "Documents could not be loaded."
        case (.success, .failure):
            partialNotice = "Tables could not be loaded."
        case (.success, .success):
            break
        }
        let rows = ((try? docs.get()) ?? []).map { Self.typed($0, .document) }
            + ((try? tabs.get()) ?? []).map { Self.typed($0, .table) }
        items = Self.matterRows(rows, projectID: projectID)
        state = .loaded
    }

    /// The web's filter and order: this matter's rows only, each once, newest first.
    static func matterRows(_ rows: [DraftedItem], projectID: String) -> [DraftedItem] {
        var seen = Set<String>()
        let mine = rows.filter { row in
            let owner = row.projectID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard owner == projectID, !row.id.isEmpty, !seen.contains(row.id) else { return false }
            seen.insert(row.id)
            return true
        }
        return mine.enumerated().sorted { a, b in
            let ta = a.element.createdAt?.timeIntervalSince1970 ?? 0
            let tb = b.element.createdAt?.timeIntervalSince1970 ?? 0
            return ta == tb ? a.offset < b.offset : ta > tb
        }.map(\.element)
    }

    /// A row that does not say what it is takes the kind of the route that listed it.
    private static func typed(_ row: DraftedItem, _ kind: DraftKind) -> DraftedItem {
        var row = row
        if row.type?.isEmpty ?? true { row.type = kind.rawValue }
        return row
    }

    private static func attempt(
        _ body: @Sendable () async throws -> [DraftedItem]
    ) async -> Result<[DraftedItem], Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    // MARK: - Opening

    func open(_ item: DraftedItem) {
        Task { await runOpen(item) }
    }

    func runOpen(_ item: DraftedItem) async {
        guard loadingID == nil else { return }
        loadingID = item.id
        errorMessage = nil
        defer { loadingID = nil }

        do {
            opened = OpenedDraft(item: item, content: try await service.content(id: item.id))
        } catch {
            // An empty body is the server's answer for a row that is gone, so this is the
            // ordinary "you deleted the conversation" case, not an exceptional one.
            errorMessage = DisplayText.message(for: error)
        }
    }

    func close() { opened = nil }
}
