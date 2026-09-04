import XCTest
@testable import EmperorCore

final class ResponseCacheTests: XCTestCase {

    private static let epoch = Date(timeIntervalSince1970: 1_787_000_000)

    private func makeCache(
        _ store: any CacheStore = InMemoryCacheStore(),
        at date: Date = ResponseCacheTests.epoch
    ) -> ResponseCache {
        ResponseCache(store: store, now: { date })
    }

    // MARK: - Round trip

    func testValuesRoundTripWithTheirTimestamp() {
        let cache = makeCache()
        cache.save([ChatSummary(id: "a", title: "Partition suit")], for: .chatList)

        let loaded = cache.load([ChatSummary].self, for: .chatList)

        XCTAssertEqual(loaded?.value.first?.id, "a")
        XCTAssertEqual(loaded?.storedAt, Self.epoch, "the stamp is recorded, never inferred")
    }

    func testAMissingKeyReturnsNil() {
        XCTAssertNil(makeCache().load([ChatSummary].self, for: .caseList))
    }

    func testKeysDoNotCollide() {
        let cache = makeCache()
        cache.save([ChatSummary(id: "chat", title: "A")], for: .chatList)
        cache.save([ChatSummary(id: "cause", title: "B")], for: .causeList)

        XCTAssertEqual(cache.load([ChatSummary].self, for: .chatList)?.value.first?.id, "chat")
        XCTAssertEqual(cache.load([ChatSummary].self, for: .causeList)?.value.first?.id, "cause")
    }

    /// A payload written by an older build will not decode. Dropping it is right: it is
    /// re-fetchable, and carrying a broken entry forward means it fails on every launch.
    func testAnUndecodablePayloadIsDiscardedRatherThanCarriedForward() {
        let store = InMemoryCacheStore()
        store.write(Data(#"{"value":"not an array","storedAt":"nope"}"#.utf8),
                    for: ResponseCache.Key.chatList.rawValue)
        let cache = makeCache(store)

        XCTAssertNil(cache.load([ChatSummary].self, for: .chatList))
        XCTAssertNil(store.read(ResponseCache.Key.chatList.rawValue), "and it is evicted")
    }

    /// Cached matters must not outlive the session that fetched them — signing out is the only
    /// protection the next person to hold the phone gets, since the token cannot be revoked.
    func testClearRemovesEverything() {
        let cache = makeCache()
        for key in ResponseCache.Key.allCases {
            cache.save([ChatSummary(id: key.rawValue, title: nil)], for: key)
        }

        cache.clear()

        for key in ResponseCache.Key.allCases {
            XCTAssertNil(cache.load([ChatSummary].self, for: key), "\(key) survived a clear")
        }
    }

    // MARK: - On disk

    /// The disk implementation is what actually ships, so exercise it rather than only the
    /// in-memory stand-in.
    func testFileStoreRoundTripsAndCleansUp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmperorCacheTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(FileCacheStore(directory: directory))
        cache.save([ChatSummary(id: "a", title: "On disk")], for: .caseList)

        XCTAssertEqual(cache.load([ChatSummary].self, for: .caseList)?.value.first?.title,
                       "On disk")

        cache.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// Keys are internal constants, but a separator in one must never let a write escape the
    /// cache directory.
    func testFileStoreKeysCannotEscapeTheDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmperorCacheEscape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileCacheStore(directory: directory)
        store.write(Data("x".utf8), for: "../../escaped")

        let parent = directory.deletingLastPathComponent()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: parent.appendingPathComponent("escaped.json").path))
        XCTAssertEqual(store.read("../../escaped"), Data("x".utf8), "still readable by its key")
    }

    // MARK: - Through a view model

    /// A cold launch on a bad connection should open on content, not a spinner.
    func testAColdLaunchShowsCachedContentBeforeTheNetworkAnswers() async {
        let cache = makeCache()
        cache.save([ChatSummary(id: "a", title: "Yesterday's matter")], for: .chatList)

        await withCachedList(cache) { service, model in
            service.error = APIError.transport("offline")
            await model.load()

            XCTAssertEqual(model.chats.count, 1, "the cached list is shown")
            XCTAssertEqual(model.cachedAt, Self.epoch)
            XCTAssertTrue(model.presentation.showsCachedStamp, "and it says how old it is")
            XCTAssertTrue(model.presentation.showsStaleBanner)
            XCTAssertFalse(
                model.presentation.showsFailureState,
                "there is content to show, so the failure is a banner not a page")
        }
    }

    /// A successful load replaces the cache and drops the stamp — the data is live again.
    func testASuccessfulLoadClearsTheCachedStamp() async {
        let cache = makeCache()
        cache.save([ChatSummary(id: "old", title: "Stale")], for: .chatList)

        await withCachedList(cache) { service, model in
            service.chats = [ChatSummary(id: "new", title: "Fresh")]
            await model.load()

            XCTAssertEqual(model.chats.first?.id, "new")
            XCTAssertNil(model.cachedAt)
            XCTAssertFalse(model.presentation.showsCachedStamp)
            XCTAssertEqual(
                cache.load([ChatSummary].self, for: .chatList)?.value.first?.id, "new",
                "and the cache is refreshed for next launch")
        }
    }

    /// With no cache and no network there is genuinely nothing to show — that is the failure
    /// page, and it must not be mistaken for an empty account.
    func testNoCacheAndNoNetworkIsAFailureNotAnEmptyState() async {
        await withCachedList(makeCache()) { service, model in
            service.error = APIError.transport("offline")
            await model.load()

            XCTAssertTrue(model.presentation.showsFailureState)
            XCTAssertFalse(model.presentation.showsEmptyState)
        }
    }
}

@MainActor
private func withCachedList(
    _ cache: ResponseCache,
    _ body: @MainActor (FakeChatList, ChatListViewModel) async -> Void
) async {
    let service = FakeChatList()
    await body(service, ChatListViewModel(service: service, cache: cache))
}
