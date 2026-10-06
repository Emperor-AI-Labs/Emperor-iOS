import XCTest
@testable import EmperorCore

/// The list beside its detail on an iPad: which item the detail column shows, and what a tap in
/// the list does to the path both layouts share.
final class ListDetailPathTests: XCTestCase {

    private func caseID(_ route: CaseRoute) -> String { route.caseID }
    private func route(_ id: String) -> CaseRoute { CaseRoute(caseID: id) }

    // MARK: - Selection

    /// Nothing open, nothing selected — the detail column shows its placeholder.
    func testAnEmptyPathSelectsNothing() {
        XCTAssertNil(ListDetailPath.selection(in: [CaseRoute](), id: caseID))
        XCTAssertNil(ListDetailPath.selection(in: [String]()))
    }

    /// The detail shows what a phone would have on top — including a path a phone built two
    /// deep before the screen widened.
    func testTheSelectionIsTheTopOfThePath() {
        XCTAssertEqual(ListDetailPath.selection(in: [route("a")], id: caseID), "a")
        XCTAssertEqual(ListDetailPath.selection(in: [route("a"), route("b")], id: caseID), "b")
        XCTAssertEqual(ListDetailPath.selection(in: ["c1", "c2"]), "c2")
    }

    /// Choosing a row opens it: the path becomes that one item.
    func testChoosingARowFromNothingOpensIt() {
        let path = ListDetailPath.selecting("a", in: [CaseRoute](), id: caseID, route: route)
        XCTAssertEqual(path, [CaseRoute(caseID: "a")])
    }

    /// Choosing another row **replaces** the detail — the path is that one item, not the old
    /// one with the new pushed on top, so nothing builds up behind the detail column.
    func testChoosingAnotherRowReplacesThePath() {
        let path = ListDetailPath.selecting(
            "b", in: [route("a")], id: caseID, route: route)
        XCTAssertEqual(path, [CaseRoute(caseID: "b")])

        XCTAssertEqual(ListDetailPath.selecting("c2", in: ["c1"]), ["c2"])
    }

    /// A path a phone pushed two deep collapses to the one chosen.
    func testChoosingFromADeepPathReplacesAllOfIt() {
        let path = ListDetailPath.selecting(
            "c", in: [route("a"), route("b")], id: caseID, route: route)
        XCTAssertEqual(path, [CaseRoute(caseID: "c")])
    }

    /// The row already showing leaves the path exactly as it was — the same route, so the
    /// detail is not rebuilt and keeps the reader's place.
    func testChoosingTheRowAlreadyShowingChangesNothing() {
        let open = [route("a")]
        XCTAssertEqual(ListDetailPath.selecting("a", in: open, id: caseID, route: route), open)
        XCTAssertEqual(ListDetailPath.selecting("c1", in: ["c1"]), ["c1"])
    }

    /// A case the Calendar opened carries its request number. Tapping its row must not swap it
    /// for a row-tap route (request 0) — that would be a different value, and a fresh screen
    /// that reloads the matter the reader is already looking at.
    func testTheRowOfARequestedCaseKeepsTheRequestedRoute() {
        let requested = [CaseRoute(caseID: "a", request: 3)]
        let path = ListDetailPath.selecting("a", in: requested, id: caseID, route: route)
        XCTAssertEqual(path, requested)
        XCTAssertEqual(path.first?.request, 3)
    }

    /// The list reporting no selection — a search hiding the chosen row — closes nothing.
    func testChoosingNothingKeepsWhatIsOpen() {
        let open = [route("a")]
        XCTAssertEqual(ListDetailPath.selecting(nil, in: open, id: caseID, route: route), open)
        XCTAssertEqual(ListDetailPath.selecting(nil, in: ["c1"]), ["c1"])
        XCTAssertEqual(ListDetailPath.selecting(nil, in: [String]()), [])
    }

    /// The deeper elements of a phone's path survive choosing the top one again: the screen
    /// widened, and the reader tapped the row of what was already showing.
    func testChoosingTheTopOfADeepPathChangesNothing() {
        let deep = [route("a"), route("b")]
        XCTAssertEqual(ListDetailPath.selecting("b", in: deep, id: caseID, route: route), deep)
    }

    /// A new conversation is not in the list yet. Choosing a listed one replaces it.
    func testAListedConversationReplacesANewOne() {
        let new = ["9F3C-NEW"]
        XCTAssertEqual(ListDetailPath.selection(in: new), "9F3C-NEW", "a new conversation is in no row")
        XCTAssertEqual(ListDetailPath.selecting("c1", in: new), ["c1"])
    }

    // MARK: - Placeholder

    /// "Choose a case" only where there is a case to choose.
    func testThePlaceholderShowsBesideAListWithRows() {
        let list = ListPresentation(state: .loaded, isEmpty: false)
        XCTAssertEqual(
            ListDetailPath.placeholder(ListDetailPath.chooseCase, beside: list),
            ListDetailPath.chooseCase)
    }

    /// Rows shown from the cache while the refresh is out are rows to choose.
    func testThePlaceholderShowsBesideCachedRows() {
        let list = ListPresentation(state: .loading, isEmpty: false, cachedAt: Date())
        XCTAssertNotNil(ListDetailPath.placeholder(ListDetailPath.chooseConversation, beside: list))
    }

    /// Beside "No matters yet", a spinner or a failure, the column stays empty — anything it
    /// said would point at rows that are not there.
    func testThePlaceholderIsWithheldWhileTheListHasNothing() {
        let states: [LoadState] = [
            .idle, .loading, .loaded, .failed(LoadFailure(APIError.transport("offline"))),
        ]
        for state in states {
            let list = ListPresentation(state: state, isEmpty: true)
            XCTAssertNil(
                ListDetailPath.placeholder(ListDetailPath.chooseCase, beside: list),
                "a placeholder beside an empty list in state \(state)")
        }
    }

    /// Before the list's model exists there is nothing to point at.
    func testThePlaceholderIsWithheldBeforeTheListExists() {
        XCTAssertNil(ListDetailPath.placeholder(ListDetailPath.chooseCase, beside: nil))
    }

    /// Each placeholder wears its own tab's mark and says what opens there.
    func testEachPlaceholderNamesWhatItIsFor() {
        XCTAssertEqual(ListDetailPath.chooseCase.title, "Choose a case")
        XCTAssertEqual(ListDetailPath.chooseCase.systemImage, "briefcase")
        XCTAssertEqual(ListDetailPath.chooseConversation.title, "Choose a conversation")
        XCTAssertEqual(ListDetailPath.chooseConversation.systemImage, "bubble.left.and.bubble.right")
    }
}
