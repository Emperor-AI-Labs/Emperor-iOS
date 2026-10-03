import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The "Subscribe in Calendar" sheet: fetch the private link, hand it out, reset it.
///
/// This client used to offer no subscription link at all, because the feed was keyed by
/// something a calendar link could not keep private. It is now a server-issued secret that the
/// user can reset (`/calendar/feed-url`), which is the condition the app was waiting for.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class CalendarSubscriptionViewModel {

    enum Copy {
        static let explanation =
            "Your hearings and diary entries appear in the iPhone Calendar app and stay up to date there."
        /// Said plainly, because it changes what the reader should do with the link: it is a
        /// password in the shape of a URL, not a page to share. The web says the same under its
        /// copy box (`MyCalendar.jsx`).
        static let privacy =
            "This link is private. Anyone who has it can see your hearings and diary entries — give it to a calendar app, not to people."
        static let resetTitle = "Reset your calendar link?"
        static let resetMessage =
            "The current link stops working straight away, on every device and calendar app that uses it. You will need to subscribe again with the new one."
        static let resetDone =
            "New link issued. Calendars subscribed to the old one have stopped updating — subscribe again to keep them current."
    }

    private(set) var link: CalendarFeedLink?
    private(set) var state: LoadState = .idle
    private(set) var isResetting = false
    /// Set after a reset succeeds, so the screen can say what just happened to old
    /// subscriptions. Cleared by the next load.
    private(set) var didReset = false
    /// A failed reset. Shown as an alert, because the link on screen is still the valid one and
    /// must not be replaced by a failure view.
    var resetError: String?

    private let service: any CalendarFeedProviding

    init(service: any CalendarFeedProviding) {
        self.service = service
    }

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: link == nil)
    }

    /// Whether the actions can be used. Not while a reset is in flight: the link on screen is
    /// about to stop working, and copying it then would hand out a dead credential.
    var canUseLink: Bool { link != nil && !isResetting }

    func load() async {
        state = .loading
        do {
            link = try await service.feedLink()
            didReset = false
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    /// Replaces the link. On failure the old link is kept on screen — it is still the one that
    /// works — and the reason is reported.
    func reset() async {
        guard !isResetting else { return }
        isResetting = true
        defer { isResetting = false }
        do {
            link = try await service.resetFeedLink()
            didReset = true
            state = .loaded
        } catch {
            resetError = DisplayText.message(for: error)
        }
    }
}
