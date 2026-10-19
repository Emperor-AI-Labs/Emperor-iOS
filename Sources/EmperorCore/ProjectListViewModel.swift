import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Hand-made matters, in the server's own order.
///
/// The sibling of `CaseListViewModel` and deliberately separate from it: a case belongs to a team
/// and is filled in by the court scrapers, a project belongs to one user and is typed in. The web
/// rail puts them next to each other for the same reason.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class ProjectListViewModel {

    /// Framing copy, kept in one place so the list and its empty state cannot drift apart about
    /// what this screen is.
    enum Copy {
        /// "Matters" is the tab; these are the workspaces behind them — the web's Matters page.
        static let title = "Matter workspaces"
        static let newMatter = "New matter"
        /// Said on the empty state because it is the only place a reader can learn where a
        /// workspace comes from: a tracked case opened here, the web, or the button above.
        static let openedOnTheWeb =
            "A workspace holds a matter's chronology, tasks, fees, people and documents. Open one from a case on your docket, or start one here."
    }

    private(set) var projects: [Project] = []
    private(set) var state: LoadState = .idle
    private(set) var isCreating = false
    var createError: String?

    var query = ""
    /// Whether archived matters were asked for. Changing this must be followed by a `load()`;
    /// `ProjectListView` binds it that way, and `setIncludeArchived` does it for callers that
    /// would rather not remember.
    private(set) var includeArchived = false

    private let service: any ProjectProviding

    init(service: any ProjectProviding) {
        self.service = service
    }

    // MARK: - Presentation

    /// Measured against the **filtered** list, so a search that matches nothing routes to the
    /// empty state rather than to an empty content view. `ProjectListView` relies on that.
    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: visible.isEmpty)
    }

    var showsNoSearchResults: Bool { !projects.isEmpty && visible.isEmpty }

    /// The list, in the server's order.
    ///
    /// Deliberately not re-sorted — see the note on `ProjectService`. Filtering is a different
    /// question from ordering and is safe: it removes rows without claiming a different one is
    /// more urgent.
    ///
    /// Matches on everything a practitioner might reach for, including the forum name, which is
    /// free text and is very often how a tribunal matter is remembered.
    var visible: [Project] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return projects }
        return projects.filter { project in
            [
                project.name, project.client, project.notes, project.caseReference,
                project.forumName, project.forumType, project.cnr, project.stage,
                project.status, project.priority,
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(trimmed)
        }
    }

    var emptyTitle: String {
        if showsNoSearchResults { return "No matters match" }
        return includeArchived ? "Nothing here" : "No matters yet"
    }

    /// The sentence under the empty state.
    ///
    /// The archived filter is named when it is *off*, because the commonest reason a matter a
    /// user remembers is missing is that they archived it — and a reader who is not told the
    /// filter exists concludes the matter is gone.
    var emptyDetail: String {
        if showsNoSearchResults {
            return includeArchived
                ? "Nothing matches that. Try a shorter search term."
                : """
                    Nothing matches that. Archived matters are not being shown — turn them on to \
                    search those too.
                    """
        }
        return Copy.openedOnTheWeb
    }

    // MARK: - Loading

    func load() async {
        state = .loading
        do {
            projects = try await service.projects(includeArchived: includeArchived)
            state = .loaded
        } catch {
            // The rows already on screen are kept. A dropped connection must not blank a list
            // someone is reading — `ListPresentation.showsStaleBanner` covers the caveat.
            state = .failed(LoadFailure(error))
        }
    }

    /// Starts a matter with a name and nothing else, as the web's New matter does, and returns
    /// its id so the screen can open it. The rest is filled in from the workspace.
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

    /// Switches the archived filter and re-fetches.
    ///
    /// Archived matters are a **different request**, not a filter over what is already held. The
    /// route excludes them in its `WHERE` clause (`sync-server.js:9925`), so the rows are not in
    /// hand — filtering locally would show an empty archive to someone who has one.
    func setIncludeArchived(_ include: Bool) async {
        guard include != includeArchived else { return }
        includeArchived = include
        await load()
    }
}
