import Foundation
#if canImport(Darwin)
import Observation
#endif

/// A matter pushed onto the Cases tab's navigation stack.
struct CaseRoute: Hashable, Sendable {
    let caseID: String
    /// Which request pushed it: `0` for a row tapped in the docket itself, otherwise the
    /// `AppNavigator` request that asked for it.
    ///
    /// Part of the value so that asking for the matter already on screen still gives a fresh
    /// screen. A stack whose only element is unchanged is left exactly as it was — scrolled to
    /// whichever section the reader left it on — and the request was to see the matter's
    /// overview.
    var request: Int = 0
}

/// Navigation that crosses tabs: which tab is showing, and a case some other tab has asked the
/// Cases tab to open.
///
/// One per signed-in app, made by `MainTabView` and handed down the environment. A tab that wants
/// another tab to show something says so here rather than reaching into it, so neither has to
/// know how the other is built.
///
/// ## Opening a case from another tab
///
/// `openCase(_:)` records the request and switches to Cases. The Cases tab takes it with
/// `takePendingCaseStack()` — when it appears, or when the request changes while it is already
/// on screen — and replaces its stack with what that returns. Taking clears the request, so it is
/// applied once: coming back to the tab later must not push the case a second time.
///
/// The stack is **replaced, not appended to**. Whatever the Cases tab was last showing is not
/// what the user asked for, and Back from the case should land on the docket — the place the
/// case lives — rather than on a matter opened an hour ago.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class AppNavigator {

    /// The tab bar, in order. The order is the product owner's choice; see `MainTabView`.
    enum Tab: Hashable, Sendable {
        case home, cases, chat, calendar, more
    }

    var selectedTab: Tab

    /// A case another tab has asked to open, not yet taken by the Cases tab.
    private(set) var pendingCase: CaseRoute?

    /// Requests so far. Starts above zero, which is reserved for a row tapped in the docket.
    private var requestCount = 0

    init(selectedTab: Tab = .home) {
        self.selectedTab = selectedTab
    }

    /// Shows a case on the Cases tab, opened on its overview.
    ///
    /// The latest request wins: a second one before the first is taken replaces it, because the
    /// user has since asked for something else.
    func openCase(_ caseID: String) {
        guard !caseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        requestCount += 1
        pendingCase = CaseRoute(caseID: caseID, request: requestCount)
        selectedTab = .cases
    }

    /// The Cases tab's new stack, or `nil` when nothing is waiting. Taking the request clears it.
    func takePendingCaseStack() -> [CaseRoute]? {
        guard let route = pendingCase else { return nil }
        pendingCase = nil
        return [route]
    }
}
