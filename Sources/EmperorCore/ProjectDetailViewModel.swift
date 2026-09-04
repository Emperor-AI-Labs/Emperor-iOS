import Foundation
#if canImport(Darwin)
import Observation
#endif

/// One matter: its facts, its own timeline, and — when it is linked to a scraped case — that
/// case's hearing and order history.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class ProjectDetailViewModel {

    let projectID: String

    private(set) var detail: ProjectDetail?
    private(set) var state: LoadState = .idle

    private let service: any ProjectProviding

    init(projectID: String, service: any ProjectProviding) {
        self.projectID = projectID
        self.service = service
    }

    var project: Project? { detail?.project }

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: detail == nil)
    }

    var title: String { project?.displayName ?? "Matter" }

    // MARK: - The two records

    // These are kept as **two sections, not one interleaved chronology**, and that is the single
    // decision on this screen worth arguing about.
    //
    // The server merges both into one response precisely so a client *can* interleave, and the
    // web does — `courtHistory` and `updates` are concatenated and sorted by date into a single
    // timeline. Android split them, and this follows Android.
    //
    // The reason is that the merged view reads as one chronology when it is two. A project update
    // is something the user typed: it can be wrong, backdated, or a note-to-self. A court-history
    // row was scraped from a registry and is a fact about the record. Interleaved, they share a
    // rule and a spine and a date column, and the eye stops distinguishing them within about
    // three rows — at which point "order received, uploaded to counsel" and "Order dated
    // 12.08.2026" carry the same weight. They do not. One is evidence of what the court did; the
    // other is evidence of what the user believed.
    //
    // Two headings cost one extra scroll and make the provenance unmissable, and provenance is
    // the thing this screen is read for.

    /// The matter's own timeline, newest first — already sorted and filtered by the server and
    /// `ProjectService` respectively.
    var updates: [ProjectUpdate] { detail?.updates ?? [] }

    /// The linked case's scraped rows. Empty when nothing is linked.
    var courtHistory: [CaseItem] { detail?.courtHistory ?? [] }

    /// Whether this matter is joined to a case the court scrapers maintain.
    ///
    /// Not the same question as `courtHistory.isEmpty`: a link can be set to a case that has no
    /// items yet, or to one the sync has since deleted. Saying "linked, nothing on the record
    /// yet" is honest where showing nothing at all invites the reader to conclude the link
    /// failed.
    var isLinkedToCase: Bool {
        project?.linkedCaseID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// The line under the court-record heading, when there is a link but no rows behind it.
    var courtRecordCaveat: String? {
        guard isLinkedToCase, courtHistory.isEmpty else { return nil }
        return """
            This matter is linked to a case on your docket, but nothing has been synced from the \
            court for it yet.
            """
    }

    /// The facts panel, as label/value pairs, skipping everything the matter does not state.
    ///
    /// Assembled here rather than in the view so the "which fields, in which order, and which is
    /// emphasised" decision is testable — it is the part of this screen most likely to be edited
    /// by someone who cannot run it.
    var facts: [Fact] {
        guard let project else { return [] }
        var facts: [Fact] = []
        func add(_ label: String, _ value: String?, emphasised: Bool = false) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }
            facts.append(Fact(label: label, value: trimmed, isEmphasised: emphasised))
        }
        add("Client", project.client)
        add("Case", project.caseReference)
        add("Forum", project.forumLabel)
        add("Stage", project.stage)
        if let hearing = project.nextHearingDate {
            add("Next hearing", DisplayText.longDay(WireDate.dayKey(hearing)), emphasised: true)
        }
        if let filed = project.filingDate {
            add("Filed", DisplayText.longDay(WireDate.dayKey(filed)))
        }
        // Only when archived. "Status: active" is the default and says nothing; "Archived" is
        // the reason a matter is not on the default list and must be visible from inside it.
        if project.isArchived { add("Status", "Archived") }
        add("Notes", project.notes)
        return facts
    }

    struct Fact: Identifiable, Equatable, Sendable {
        let label: String
        let value: String
        var isEmphasised = false
        var id: String { label }
    }

    // MARK: - Loading

    func load() async {
        state = .loading
        do {
            detail = try await service.project(id: projectID)
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }
}
