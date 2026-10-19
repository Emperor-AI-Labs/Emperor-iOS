import XCTest
@testable import EmperorCore

final class ChatListViewModelTests: XCTestCase {

    func testLoadPopulatesTheList() async {
        await withList { service, model in
            service.chats = [
                ChatSummary(id: "a", title: "Partition suit"),
                ChatSummary(id: "b", title: nil),
            ]
            await model.load()

            XCTAssertEqual(model.chats.count, 2)
            XCTAssertNil(model.failure?.message)
        }
    }

    func testLoadFailureIsSurfaced() async {
        await withList { service, model in
            service.error = APIError.server(status: 500, message: "Database is locked")
            await model.load()

            XCTAssertEqual(model.failure?.message, "Database is locked")
            XCTAssertTrue(model.chats.isEmpty)
        }
    }

    /// On a first launch, "No conversations yet" shown while the request is still in flight
    /// tells the user something false about their account. Only a load that has *returned*
    /// empty earns the empty state.
    func testEmptyStateWaitsForTheLoadToFinish() async {
        await withList { _, model in
            XCTAssertFalse(model.presentation.showsEmptyState)
            await model.load()
            XCTAssertTrue(model.presentation.showsEmptyState)
        }
    }

    /// A refresh over an existing list must not blank it out and show a spinner — the content
    /// stays put while the new copy is fetched.
    func testRefreshingKeepsTheExistingListVisible() async {
        await withList { service, model in
            service.chats = [ChatSummary(id: "a", title: "Partition suit")]
            await model.load()

            XCTAssertFalse(model.presentation.showsLoadingPlaceholder)
            XCTAssertFalse(model.presentation.showsEmptyState)
        }
    }

    /// Chats are created client-side; the row appears server-side only once the first turn is
    /// sent, which is why an abandoned new chat leaves nothing behind.
    func testNewChatIDsAreUnique() {
        XCTAssertNotEqual(ChatListViewModel.newChatID(), ChatListViewModel.newChatID())
    }

    // MARK: - Search

    private static let searchable = [
        ChatSummary(id: "a", title: "Partition suit", lastPreview: "Draft the plaint"),
        ChatSummary(id: "b", title: "Bail application", lastPreview: "Section 439 CrPC"),
        ChatSummary(id: "c", title: nil, lastPreview: "Limitation for a PARTITION claim"),
    ]

    func testEmptySearchShowsEveryConversation() async {
        await withList { service, model in
            service.chats = Self.searchable
            await model.load()
            model.searchText = "   "
            XCTAssertEqual(model.visibleChats.map(\.id), ["a", "b", "c"])
            XCTAssertNil(model.activeSearch)
            XCTAssertNil(model.noResultsMessage)
        }
    }

    func testSearchMatchesTitleAndLastLineIgnoringCase() async {
        await withList { service, model in
            service.chats = Self.searchable
            await model.load()
            model.searchText = "  partition "
            XCTAssertEqual(model.visibleChats.map(\.id), ["a", "c"])
            model.searchText = "439"
            XCTAssertEqual(model.visibleChats.map(\.id), ["b"])
            XCTAssertEqual(model.chats.count, 3, "the search narrows the view, never the list held")
        }
    }

    func testASearchThatMatchesNothingSaysSoInTheWebsWords() async {
        await withList { service, model in
            service.chats = Self.searchable
            await model.load()
            model.searchText = " arbitration "
            XCTAssertTrue(model.visibleChats.isEmpty)
            XCTAssertEqual(model.noResultsMessage, "We couldn't find any results for \"arbitration\"")
        }
    }

    /// An account with no conversations is the empty state, not a failed search.
    func testNoResultsIsNotClaimedForAnEmptyAccount() async {
        await withList { _, model in
            await model.load()
            model.searchText = "bail"
            XCTAssertNil(model.noResultsMessage)
        }
    }
}

@MainActor
private func withList(_ body: @MainActor (FakeChatList, ChatListViewModel) async -> Void) async {
    let service = FakeChatList()
    await body(service, ChatListViewModel(service: service))
}
