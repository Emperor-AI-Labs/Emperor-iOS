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
    /// What the search field holds. The web's History filters its conversations as you type
    /// (`src/pages/ChatHistory.jsx`); this is the same filter, run locally over the list held.
    var searchText = ""

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

    /// The conversations the list draws: every one while the search is empty, else those whose
    /// title or last line contains what was typed — trimmed, ignoring case. The web matches the
    /// title alone; the last line is matched too because a phone's row shows it, and a search
    /// that ignores text on the screen reads as broken.
    var visibleChats: [ChatSummary] { Self.filter(chats, by: searchText) }

    /// The trimmed search, or `nil` when nothing narrows the list.
    var activeSearch: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What to say when a search matches nothing — the web's own wording. `nil` while the search
    /// is empty or something matches.
    var noResultsMessage: String? {
        guard let search = activeSearch, visibleChats.isEmpty, !chats.isEmpty else { return nil }
        return Self.noResultsMessage(for: search)
    }

    static func noResultsMessage(for search: String) -> String {
        "We couldn't find any results for \"\(search)\""
    }

    static func filter(_ chats: [ChatSummary], by search: String) -> [ChatSummary] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return chats }
        return chats.filter { chat in
            [chat.title, chat.lastPreview].contains { field in
                field?.range(of: needle, options: [.caseInsensitive]) != nil
            }
        }
    }

    var isLoading: Bool { state.isLoading }
    var failure: LoadFailure? { state.failure }

    func load() async {
        // Show the last known list immediately, so a cold launch on a bad connection opens on
        // content rather than a spinner. It is replaced the moment the network answers, and
        // carries a visible "as of" stamp until then.
        if state == .idle, chats.isEmpty,
           let cached = cache?.load([ChatSummary].self, for: .chatList) {
            chats = Self.ownConversations(cached.value)
            cachedAt = cached.storedAt
        }

        state = .loading
        do {
            chats = Self.ownConversations(try await service.chats())
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

    /// The conversations this list shows: the ones started here or in the web's Ask, not the
    /// ones started inside a matter.
    ///
    /// A matter's conversation searches only that matter's documents and carries its context.
    /// Opened from here it would be continued as an ordinary conversation — the server drops a
    /// matter's attachments from a turn that does not name the matter — so the person would see
    /// an answer that had silently stopped reading their file. The web keeps them out of History
    /// and the home rail for the same reason; this client does not yet open a matter's
    /// conversations at all, so until it does they are not listed.
    static func ownConversations(_ chats: [ChatSummary]) -> [ChatSummary] {
        chats.filter { !$0.belongsToMatter }
    }

    /// The id for a conversation the user is starting now.
    ///
    /// Chats are created client-side: the id is minted here and the row appears server-side
    /// only once the first turn is sent, which is why an unused new chat leaves nothing behind.
    nonisolated static func newChatID() -> String { ChatViewModel.newChatID() }
}
