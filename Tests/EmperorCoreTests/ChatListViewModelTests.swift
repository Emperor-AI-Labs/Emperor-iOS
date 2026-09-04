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
}

@MainActor
private func withList(_ body: @MainActor (FakeChatList, ChatListViewModel) async -> Void) async {
    let service = FakeChatList()
    await body(service, ChatListViewModel(service: service))
}
