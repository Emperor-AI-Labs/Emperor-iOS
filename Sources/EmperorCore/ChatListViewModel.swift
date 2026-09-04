import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The conversation list.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class ChatListViewModel {
    private(set) var chats: [ChatSummary] = []
    private(set) var state: LoadState = .idle
    /// Set while the list on screen came from disk rather than the network.
    private(set) var cachedAt: Date?

    private let service: any ChatListProviding
    private let cache: ResponseCache?

    init(service: any ChatListProviding, cache: ResponseCache? = nil) {
        self.service = service
        self.cache = cache
    }

    /// The three-way distinction every list screen owes the user. See `LoadState`.
    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: chats.isEmpty, cachedAt: cachedAt)
    }

    var isLoading: Bool { state.isLoading }
    var failure: LoadFailure? { state.failure }

    func load() async {
        // Show the last known list immediately, so a cold launch on a bad connection opens on
        // content rather than a spinner. It is replaced the moment the network answers, and
        // carries a visible "as of" stamp until then.
        if state == .idle, chats.isEmpty,
           let cached = cache?.load([ChatSummary].self, for: .chatList) {
            chats = cached.value
            cachedAt = cached.storedAt
        }

        state = .loading
        do {
            chats = try await service.chats()
            cachedAt = nil
            cache?.save(chats, for: .chatList)
            state = .loaded
        } catch {
            // The list is deliberately left standing — whether it came from a previous fetch
            // or from disk. A refresh that fails over existing content shows that content with
            // a staleness banner rather than blanking it.
            state = .failed(LoadFailure(error))
        }
    }

    /// The id for a conversation the user is starting now.
    ///
    /// Chats are created client-side: the id is minted here and the row appears server-side
    /// only once the first turn is sent, which is why an unused new chat leaves nothing behind.
    nonisolated static func newChatID() -> String { ChatViewModel.newChatID() }
}
