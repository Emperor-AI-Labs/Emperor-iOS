import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The Matters list, as the web's Matters page draws it (`src/pages/Projects.jsx`): every matter,
/// archived ones included, with every tracked court case that has no matter yet listed alongside
/// — then a status scope (Active by default), a practice area, a search and one of three orders.
/// The rules live in `MatterListing`; this holds the choices and the loading.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class ProjectListViewModel {

    /// Framing copy, kept in one place so the list and its empty states cannot drift apart.
    enum Copy {
        static let title = "Matters"
        static let newMatter = "New matter"
        static let searchPrompt = "Name, client, party, case no., CNR…"
        static let firstMatterTitle = "Open a file for your first matter"
        /// Said on the empty state because it is the only place a reader learns what a matter
        /// holds and where its hearings come from.
        static let openedOnTheWeb =
            "A matter holds its papers, Ask Emperor chats and drafts, its dates, tasks and fees — together, and apart from everything else in your account. Find its case in the court records and the hearings keep themselves up to date."
        static let filteringDetail =
            "Try a client, a party, a case number or a CNR — or clear the search and filters."
        static let otherStatusesDetail = "Matters with other statuses are under the Status menu."
        static let clearFilters = "Clear search and filters"
        static let showAllStatuses = "Show all statuses"
        static let couldNotOpen = "Could not reach the server — check the connection and try again."
    }

    private(set) var projects: [Project] = []
    private(set) var trackedCases: [LegalCase] = []
    private(set) var teams: [Team] = []
    private(set) var state: LoadState = .idle
    private(set) var isCreating = false
    var createError: String?

    var query = ""
    var statusFilter: MatterStatusFilter = .active
    /// `""` is every practice area; `MatterListing.noArea` is a matter with none.
    var practiceArea = ""
    var sort: MatterSort = .recent

    /// The tracked case being opened as its matter, and why the last attempt failed.
    private(set) var openingCaseID: String?
    var openError: String?

    private let service: any ProjectProviding
    private let cases: (any CaseProviding)?
    private let teamService: (any TeamProviding)?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - cases: the tracked cases to list beside the matters. Without it, matters only.
    ///   - teams: names the team a shared case is tracked through. Optional.
    init(
        service: any ProjectProviding,
        cases: (any CaseProviding)? = nil,
        teams: (any TeamProviding)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.cases = cases
        self.teamService = teams
        self.now = now
    }

    // MARK: - Rows

    private var todayKey: String { WireDate.todayKey(now: now()) }

    /// Every row: the matters, then the tracked cases no matter links.
    var rows: [MatterListRow] {
        MatterListing.rows(projects: projects, cases: trackedCases, teams: teams, now: now())
    }

    /// What is shown, in the chosen order.
    var visible: [MatterListRow] {
        MatterListing.shown(
            rows, status: statusFilter, area: practiceArea, query: query, sort: sort, todayKey: todayKey)
    }

    /// Measured against the **filtered** list, so a search that matches nothing routes to the
    /// empty state rather than to an empty content view. `ProjectListView` relies on that.
    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: visible.isEmpty)
    }

    var hasLoaded: Bool { state.hasLoaded || !projects.isEmpty }

    var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !practiceArea.isEmpty
    }

    /// There are matters, just none in view.
    var showsNoSearchResults: Bool { !rows.isEmpty && visible.isEmpty }

    // MARK: - Menus

    /// The Status menu, each with its count once the list is in — no numbers before, rather
    /// than a row of confident zeros.
    var statusOptions: [MatterStatusOption] {
        let counts = MatterListing.counts(rows)
        return MatterStatusFilter.allCases.map { filter in
            guard hasLoaded else { return MatterStatusOption(filter: filter, label: filter.label) }
            return MatterStatusOption(filter: filter, label: "\(filter.label) · \(counts[filter] ?? 0)")
        }
    }

    var areaOptions: [MatterAreaOption] {
        MatterListing.areaOptions(rows, selected: practiceArea)
    }

    var areaLabel: String {
        areaOptions.first { $0.value == practiceArea }?.label ?? "All practice areas"
    }

    /// "12 active matters", or "3 of 12 active matters" while searching or filtering by area.
    var summary: String {
        guard hasLoaded else { return "" }
        let scopeCount = MatterListing.scoped(rows, status: statusFilter).count
        let words = statusFilter.scopeWords(scopeCount)
        return isFiltering ? "\(visible.count) of \(words)" : words
    }

    /// Hearings in the next seven days, within the status scope.
    var hearingsSoon: Int {
        MatterListing.hearingsSoon(MatterListing.scoped(rows, status: statusFilter), todayKey: todayKey)
    }

    // MARK: - Empty states

    var emptyTitle: String {
        guard showsNoSearchResults else { return Copy.firstMatterTitle }
        let scope = statusFilter == .all ? "" : statusFilter.label.lowercased()
        let scoped = scope.isEmpty ? "" : "\(scope) "
        guard isFiltering else { return "No \(scope) matters" }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty
            ? "No \(scoped)matter in that practice area"
            : "No \(scoped)matter matches “\(term)”"
    }

    var emptyDetail: String {
        guard showsNoSearchResults else { return Copy.openedOnTheWeb }
        return isFiltering ? Copy.filteringDetail : Copy.otherStatusesDetail
    }

    var offersShowAllStatuses: Bool { showsNoSearchResults && statusFilter != .all }

    func clearFilters() {
        query = ""
        practiceArea = ""
    }

    func showAllStatuses() { statusFilter = .all }

    // MARK: - Loading

    /// Every matter, archived ones included, always — see `ProjectService`. The tracked cases and
    /// the teams come alongside; a failure of either keeps what was last held, as the web keeps
    /// listing the matters when the cases could not be read.
    func load() async {
        state = .loading
        do {
            let fetched = try await service.projects(includeArchived: true)
            if let cases, let tracked = try? await cases.cases() { trackedCases = tracked }
            if let teamService, let list = try? await teamService.teams() { teams = list }
            projects = fetched
            state = .loaded
        } catch {
            // The rows already on screen are kept. A dropped connection must not blank a list
            // someone is reading — `ListPresentation.showsStaleBanner` covers the caveat.
            state = .failed(LoadFailure(error))
        }
    }

    /// Starts a matter with a name alone, and returns its id so the screen can open it. New
    /// matter's full sheet goes through `NewMatterViewModel`.
    func create(named name: String, practiceArea: String? = nil) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            createError = "Give the matter a name."
            return nil
        }
        guard !isCreating else { return nil }
        isCreating = true
        createError = nil
        defer { isCreating = false }
        do {
            let project = try await service.create(MatterDraft(name: trimmed, practiceArea: practiceArea))
            await load()
            return project.id
        } catch {
            createError = DisplayText.message(for: error)
            return nil
        }
    }

    // MARK: - Opening a tracked case

    /// The matter for a tracked case: the one already linked, else the one `POST
    /// /project-from-case` makes (or finds) — wearing the banner the row wore, so the matter looks
    /// like the row that was tapped. `nil` with `openError` set when it could not be opened.
    func openTrackedCase(_ caseID: String) async -> String? {
        if let known = MatterListing.matterByCase(projects)[caseID] { return known.id }
        guard openingCaseID == nil else { return nil }
        openingCaseID = caseID
        openError = nil
        defer { openingCaseID = nil }
        do {
            let banner = MatterListing.banner(forCase: caseID).rawValue
            let made = try await service.projectFromCase(caseID: caseID, seed: MatterSeed(banner: banner))
            await load()
            return made.project.id
        } catch let error as APIError {
            openError = Self.openFailure(error)
            return nil
        } catch {
            openError = Copy.couldNotOpen
            return nil
        }
    }

    /// The server's own words when it said anything ("You are not a member of the team that
    /// tracks that case"); a request that never reached it says so.
    private static func openFailure(_ error: APIError) -> String {
        switch error {
        case .transport: return Copy.couldNotOpen
        default: return DisplayText.message(for: error)
        }
    }
}
