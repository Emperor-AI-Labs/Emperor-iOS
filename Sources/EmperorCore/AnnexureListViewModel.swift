import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The List of Annexures under a finished draft, and what each row shows when it is opened.
///
/// The web shows this card once a drafted document finishes streaming
/// (`AnnexuresCard` in `src/tools/ToolWorkspace.jsx`): one row per annexure the draft cites,
/// each opening the original document or its true typed copy, fetched only when it is opened.
/// Nothing is shown at all when the draft cites nothing.
///
/// `@Observable` on Apple platforms only — see `ChatViewModel` for the Linux link failure.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class AnnexureListViewModel {

    /// The web's sentence above the rows, word for word.
    nonisolated static let notice =
        "Attached annexures below will download along with the entire petition."

    enum ListState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
        /// Filing is outside this account's plan. The card stays hidden, as on the web, but the
        /// reason is kept rather than mistaken for "nothing cited".
        case refused(Refusal)
    }

    /// What an opened row is showing.
    enum RowState: Equatable {
        case loading
        /// The original document's bytes — PDF, or an image for a photograph.
        case original(Data, AnnexureFileKind)
        /// The typed copy, as an HTML fragment.
        case typedCopy(String)
        /// No typed copy, and the platform's reason why.
        case skipped(String)
        case failed(String)
        case refused(Refusal)
    }

    let chatID: String
    private let service: any FilingAnnexureProviding

    private(set) var rows: [FilingAnnexure] = []
    private(set) var listState: ListState = .idle
    private var opened: [String: RowState] = [:]

    init(chatID: String, service: any FilingAnnexureProviding) {
        self.chatID = chatID
        self.service = service
    }

    /// Whether the card is drawn: only once the list is in, and only when it holds something.
    var isVisible: Bool { listState == .loaded && !rows.isEmpty }

    var refusal: Refusal? {
        if case .refused(let refusal) = listState { return refusal }
        return nil
    }

    /// Reads the list. Called when a draft turn has finished, and again on pull — a draft
    /// re-answered may cite a different set.
    func load() async {
        if listState != .loaded { listState = .loading }
        do {
            rows = FilingAnnexure.sorted(try await service.annexures(chatID: chatID))
            listState = .loaded
        } catch {
            let failure = FilingAnnexureError.from(error, mark: nil)
            if let refusal = failure.refusal {
                rows = []
                listState = .refused(refusal)
            } else if listState != .loaded {
                // A failed refresh keeps the list already on screen.
                listState = .failed(failure.errorDescription ?? "The list of annexures could not be read.")
            }
        }
    }

    /// What `annexure`'s sheet shows, or nil before it has been opened.
    func state(for annexure: FilingAnnexure) -> RowState? {
        opened[annexure.mark]
    }

    /// Fetches what `annexure` opens to: its typed copy, or its original document.
    ///
    /// A row already showing its content is not fetched again; one that failed is.
    func open(_ annexure: FilingAnnexure) async {
        switch opened[annexure.mark] {
        case .loading, .original, .typedCopy, .skipped: return
        default: break
        }
        opened[annexure.mark] = .loading
        opened[annexure.mark] = await fetch(annexure)
    }

    /// Forgets a row's content so that opening it again reads it afresh.
    func close(_ annexure: FilingAnnexure) {
        if case .loading = opened[annexure.mark] { return }
        opened[annexure.mark] = nil
    }

    private func fetch(_ annexure: FilingAnnexure) async -> RowState {
        do {
            if annexure.isTypedCopy {
                switch try await service.typedCopy(chatID: chatID, mark: annexure.mark) {
                case .html(let html): return .typedCopy(html)
                case .skipped(let reason): return .skipped(reason)
                }
            }
            let data = try await service.original(chatID: chatID, mark: annexure.mark)
            let kind = AnnexureFileKind.of(data)
            guard kind != .unknown else {
                return .failed(FilingAnnexureError.unsupportedFile(mark: annexure.mark).errorDescription ?? "")
            }
            return .original(data, kind)
        } catch {
            let failure = FilingAnnexureError.from(error, mark: annexure.mark)
            if let refusal = failure.refusal { return .refused(refusal) }
            return .failed(failure.errorDescription ?? "Annexure \(annexure.mark) could not be opened.")
        }
    }

    // MARK: - Where the card goes

    /// The answer the List of Annexures is drawn under: the last finished answer in the
    /// conversation that carries a drafted document. Nil while an answer is still arriving —
    /// the registry is written as the turn is stored, so a list read mid-stream is stale.
    ///
    /// One card per conversation, not one per draft: the registry is kept per chat, so every
    /// draft in it would show the same list.
    nonisolated static func draftAnswerID(in messages: [ChatMessage], isStreaming: Bool) -> String? {
        guard !isStreaming else { return nil }
        return messages.last { message in
            message.role == .assistant
                && StreamContent.parse(message.content).artifacts.contains { $0.kind == .canvas }
        }?.stableID
    }
}
