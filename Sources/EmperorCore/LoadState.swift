import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a load failed, and what the UI should offer in response.
struct LoadFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The request never left the device, or the network dropped it.
        case offline
        /// The server rejected our identity. The session is over.
        case unauthenticated
        /// A planned outage. Neither the user's fault nor a bug.
        case maintenance
        /// The server answered, unhappily.
        case server
    }

    var kind: Kind
    var message: String

    /// Whether offering "Try again" makes sense. It does not for an expired session — the only
    /// useful action there is to sign in again. It does for maintenance: the outage is finite,
    /// and the server sends `Retry-After`.
    var isRetryable: Bool { kind != .unauthenticated }

    init(_ error: Error) {
        message = DisplayText.message(for: error)
        if let apiError = error as? APIError {
            switch apiError {
            case .notAuthenticated, .invalidCredentials:
                kind = .unauthenticated
            case .maintenance:
                kind = .maintenance
            case .transport:
                kind = DisplayText.isOffline(error) ? .offline : .server
            case .server, .decoding:
                kind = .server
            }
        } else {
            kind = DisplayText.isOffline(error) ? .offline : .server
        }
    }
}

/// Where a fetched collection stands.
///
/// This exists to force one distinction: **"the server says you have nothing" is not the same
/// as "we could not ask."** The web client collapses them — `store.js:1051-1055` (cases),
/// `:1065-1070` (cause list) and `:1217-1219` (compliance) each catch the error and then set
/// `*Loaded: true`, so a failed request renders as an empty result. The consequence is that
/// `TodayCauseList.jsx:285` tells a litigator their court day is clear when the request merely
/// failed. That is the most dangerous thing this product can say, and it must not be ported.
///
/// `.idle` is separate from `.loading` because a view's `.task` runs *after* its first render.
/// Keying an empty state on "not currently loading" flashes it for a frame on every cold open.
enum LoadState: Equatable, Sendable {
    /// Nothing attempted yet — including the frame before `.task` fires.
    case idle
    case loading
    /// Returned successfully. An empty collection here genuinely means empty.
    case loaded
    case failed(LoadFailure)

    var isLoading: Bool { self == .loading }
    var hasLoaded: Bool { self == .loaded }

    var failure: LoadFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    /// Whether the session ended. The app should sign out and prompt rather than retry.
    var requiresReauthentication: Bool { failure?.kind == .unauthenticated }
}

/// Presentation rules shared by every list screen.
///
/// Kept as one type so the three states can never drift apart between screens — the failure
/// mode being designed against is a single list that quietly reverts to "empty means empty".
struct ListPresentation: Equatable, Sendable {
    var state: LoadState
    var isEmpty: Bool
    /// When the on-screen data was fetched, if it came from the cache rather than the network.
    /// `nil` means it is live.
    var cachedAt: Date?

    init(state: LoadState, isEmpty: Bool, cachedAt: Date? = nil) {
        self.state = state
        self.isEmpty = isEmpty
        self.cachedAt = cachedAt
    }

    /// Whether the content on screen predates this session and must say so.
    ///
    /// Cached data shown without a timestamp invites a practitioner to act on a list that
    /// predates the hearing they are walking into.
    var showsCachedStamp: Bool { !isEmpty && cachedAt != nil }

    /// Show a spinner: nothing to display and no answer yet.
    var showsLoadingPlaceholder: Bool {
        isEmpty && (state == .idle || state == .loading)
    }

    /// Show "you have nothing" — **only** after a load that actually returned.
    var showsEmptyState: Bool {
        isEmpty && state.hasLoaded
    }

    /// Show the failure as the primary content, because there is nothing else to show.
    var showsFailureState: Bool {
        isEmpty && state.failure != nil
    }

    /// Show what we have, with a banner saying it may be out of date. Refreshing over existing
    /// content must not blank the screen.
    var showsStaleBanner: Bool {
        !isEmpty && state.failure != nil
    }

    var failure: LoadFailure? { state.failure }
}
