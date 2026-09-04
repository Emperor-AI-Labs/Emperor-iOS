import SwiftUI

/// What to show when a list has nothing to show *because the request failed*.
///
/// A separate surface from the empty state on purpose. The two say opposite things — "you have
/// no matters" versus "we could not find out" — and the web client conflates them
/// (`store.js:1051-1055`), which is how `TodayCauseList.jsx:285` comes to tell a litigator
/// their court day is clear when the request merely failed.
struct LoadFailureView: View {
    @Environment(\.theme) private var theme
    let failure: LoadFailure
    /// Absent for an expired session, where retrying achieves nothing.
    var retry: (() async -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(failure.message)
        } actions: {
            if failure.isRetryable, let retry {
                Button("Try again") {
                    Task { await retry() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var title: String {
        switch failure.kind {
        case .offline: return "No connection"
        case .unauthenticated: return "Session expired"
        case .maintenance: return "Emperor is down for maintenance"
        case .server: return "Could not load"
        }
    }

    private var icon: String {
        switch failure.kind {
        case .offline: return "wifi.slash"
        case .unauthenticated: return "person.crop.circle.badge.exclamationmark"
        case .maintenance: return "wrench.and.screwdriver"
        case .server: return "exclamationmark.triangle"
        }
    }
}

/// Shown above content that is on screen but may be out of date, because the last refresh
/// failed. The content stays — blanking a screen someone is reading is worse than a caveat.
///
/// When the content came off disk, the banner carries **when** it was fetched. Cached data
/// shown without a timestamp invites a practitioner to act on a list that predates the hearing
/// they are walking into.
struct StaleBanner: View {
    @Environment(\.theme) private var theme
    let failure: LoadFailure
    var cachedAt: Date?
    var retry: (() async -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: failure.kind == .offline ? "wifi.slash" : "exclamationmark.triangle")
            VStack(alignment: .leading, spacing: 1) {
                Text(failure.kind == .offline
                     ? "Offline — showing what was last loaded."
                     : "Could not refresh. Showing what was last loaded.")
                    .lineLimit(2)
                if let cachedAt {
                    Text("As of \(cachedAt, format: .relative(presentation: .named))")
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            if failure.isRetryable, let retry {
                Button("Retry") { Task { await retry() } }
                    .font(.brand(.caption, weight: .semibold))
            }
        }
        .font(.brand(.caption))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warning.opacity(0.12))
    }
}

/// Shown above cached content when the refresh has not failed — it simply has not answered yet.
struct CachedStamp: View {
    @Environment(\.theme) private var theme
    let cachedAt: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
            Text("As of \(cachedAt, format: .relative(presentation: .named))")
            Spacer(minLength: 0)
        }
        .font(.brand(.caption))
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceElevated)
    }
}

/// Renders the correct one of spinner / empty / failure / content for a list screen.
///
/// Routing through one view is what keeps the distinction from drifting: a new screen cannot
/// accidentally reintroduce "empty means empty" without deleting this.
struct ListStateView<Content: View, Empty: View>: View {
    @Environment(\.theme) private var theme
    let presentation: ListPresentation
    var retry: (() async -> Void)?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var empty: () -> Empty

    var body: some View {
        if presentation.showsLoadingPlaceholder {
            ProgressView()
        } else if presentation.showsFailureState, let failure = presentation.failure {
            LoadFailureView(failure: failure, retry: retry)
        } else if presentation.showsEmptyState {
            empty()
        } else {
            VStack(spacing: 0) {
                if presentation.showsStaleBanner, let failure = presentation.failure {
                    StaleBanner(failure: failure, cachedAt: presentation.cachedAt, retry: retry)
                } else if presentation.showsCachedStamp, let cachedAt = presentation.cachedAt {
                    // Cached, but the refresh has not failed — it is simply still in flight.
                    CachedStamp(cachedAt: cachedAt)
                }
                content()
            }
        }
    }
}
