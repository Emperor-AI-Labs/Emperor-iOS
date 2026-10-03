import XCTest
@testable import EmperorCore

/// Cross-tab navigation: the Calendar asking the Cases tab to open a matter.
final class AppNavigatorTests: XCTestCase {

    /// Asking for a case switches to Cases and leaves the request for that tab to take.
    func testOpeningACaseSwitchesToCasesAndLeavesTheRequest() async {
        await onMain {
            let navigator = AppNavigator(selectedTab: .calendar)
            navigator.openCase("case1")

            XCTAssertEqual(navigator.selectedTab, .cases)
            XCTAssertEqual(navigator.pendingCase?.caseID, "case1")
        }
    }

    /// The Cases tab's stack becomes just that case — replaced, not appended to — so Back from it
    /// lands on the docket rather than on whatever was open before.
    func testTheStackBecomesJustTheCase() async {
        await onMain {
            let navigator = AppNavigator()
            navigator.openCase("case1")

            let stack = navigator.takePendingCaseStack()
            XCTAssertEqual(stack?.count, 1)
            XCTAssertEqual(stack?.first?.caseID, "case1")
        }
    }

    /// Taken once. The Cases tab takes the request both when it appears and when the request
    /// changes; coming back to the tab later must not push the case a second time.
    func testTheRequestIsTakenOnce() async {
        await onMain {
            let navigator = AppNavigator()
            navigator.openCase("case1")

            XCTAssertNotNil(navigator.takePendingCaseStack())
            XCTAssertNil(navigator.pendingCase)
            XCTAssertNil(navigator.takePendingCaseStack(), "already applied")
        }
    }

    /// A second request before the first is taken replaces it: the user has since asked for
    /// something else.
    func testTheLatestRequestWins() async {
        await onMain {
            let navigator = AppNavigator()
            navigator.openCase("case1")
            navigator.openCase("case2")

            XCTAssertEqual(navigator.takePendingCaseStack()?.map(\.caseID), ["case2"])
        }
    }

    /// Asking again for the matter already open gives a route that differs from the last, so
    /// the stack changes and the screen is a fresh one showing the overview — not the old one,
    /// scrolled wherever it was left. Neither collides with a row tapped in the docket.
    func testEachRequestIsADistinctRoute() async {
        await onMain {
            let navigator = AppNavigator()
            navigator.openCase("case1")
            let first = navigator.takePendingCaseStack()?.first
            navigator.openCase("case1")
            let second = navigator.takePendingCaseStack()?.first

            XCTAssertNotNil(first)
            XCTAssertNotEqual(first, second)
            XCTAssertNotEqual(first, CaseRoute(caseID: "case1"))
            XCTAssertNotEqual(second, CaseRoute(caseID: "case1"))
        }
    }

    /// A row without a case cannot be opened, and asking does not move the user off the tab
    /// they are on.
    func testAnEmptyCaseIsIgnored() async {
        await onMain {
            let navigator = AppNavigator(selectedTab: .calendar)
            navigator.openCase("  ")

            XCTAssertEqual(navigator.selectedTab, .calendar)
            XCTAssertNil(navigator.pendingCase)
        }
    }
}

/// Linux XCTest cannot call a `@MainActor` test method, so each test hops here instead.
@MainActor
private func onMain(_ body: @MainActor () async -> Void) async {
    await body()
}
