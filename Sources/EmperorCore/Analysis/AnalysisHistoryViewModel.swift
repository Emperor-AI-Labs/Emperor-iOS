import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The saved runs of one analysis tool, or of every tool.
///
/// Each finished run is kept on the server automatically, at most 50 per tool, newest first.
/// The web lists them per tool, from each tool's page; the hub here also lists every tool's
/// together (`tool: nil`), which the same route answers.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class AnalysisHistoryViewModel {

    let tool: AnalysisJobTool?

    private(set) var runs: [AnalysisRunSummary] = []
    private(set) var state: LoadState = .idle
    /// Narrows the list by title or file name — offered once there are more than a few.
    var query = ""
    /// Why the last delete failed. Cleared by the next action.
    var actionError: String?

    private let service: any AnalysisProviding
    private var ticket = 0

    /// The web offers a search once the list is longer than this.
    static let searchThreshold = 8

    init(tool: AnalysisJobTool?, service: any AnalysisProviding) {
        self.tool = tool
        self.service = service
    }

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: runs.isEmpty)
    }

    var offersSearch: Bool { runs.count > Self.searchThreshold }

    var visible: [AnalysisRunSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return runs }
        return runs.filter {
            ([$0.displayTitle] + $0.fileNames).joined(separator: " ").lowercased().contains(q)
        }
    }

    /// The empty list's line — the web's.
    static let emptyMessage = "Nothing yet — your finished runs appear here."

    var subtitle: String {
        "Your past runs of \(tool?.title ?? "the analysis tools"). Only you can see them."
    }

    func load() async {
        ticket += 1
        let mine = ticket
        if runs.isEmpty { state = .loading }
        do {
            let list = try await service.history(tool: tool)
            guard mine == ticket else { return }
            runs = list
            state = .loaded
        } catch {
            guard mine == ticket else { return }
            state = .failed(LoadFailure(error))
        }
    }

    func delete(_ id: String) async {
        actionError = nil
        do {
            try await service.deleteRun(id: id)
            runs.removeAll { $0.id == id }
        } catch {
            actionError = DisplayText.message(for: error)
        }
    }
}
