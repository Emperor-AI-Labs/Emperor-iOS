import XCTest
@testable import EmperorCore

final class NotificationTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Decoding traps

    /// `read` is the **number** 0 or 1, not a JSON boolean (`sync-server.js:3574`). Decoding it
    /// as `Bool` throws `typeMismatch` and takes the whole feed down.
    func testReadIsANumberNotABoolean() throws {
        let unread = try decode(AppNotification.self, #"{"id":"n1","read":0}"#)
        let read = try decode(AppNotification.self, #"{"id":"n2","read":1}"#)

        XCTAssertFalse(unread.isRead)
        XCTAssertTrue(read.isRead)
    }

    /// A 500 body is `{"error": "..."}` and nothing else — no `success` key. A non-optional
    /// `success` would lose the real message behind a decoding failure.
    func testAnErrorBodyWithNoSuccessKeyDecodes() throws {
        let response = try decode(NotificationListResponse.self, #"{"error":"Missing userId"}"#)

        XCTAssertNil(response.success)
        XCTAssertEqual(response.error, "Missing userId")
    }

    /// `created_at` is zoneless SQLite `CURRENT_TIMESTAMP` — `ISO8601DateFormatter` cannot
    /// read it, and it is UTC despite carrying no marker.
    func testCreatedAtParsesTheZonelessSQLiteForm() throws {
        let notification = try decode(
            AppNotification.self, #"{"id":"n1","created_at":"2026-08-26 09:47:22"}"#)

        let date = try XCTUnwrap(notification.createdAt)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.hour, from: date), 9, "read as UTC, not local")
        XCTAssertEqual(utc.component(.minute, from: date), 47)
    }

    // MARK: - Link routing

    /// **The auction link is an API path, not a UI route.** The producer emits
    /// `/auction-notices/<id>` (`court-scraper/ibbi-auctions-ingest.js:97`); the web router has
    /// no such route and falls through to NotFound. Routing on `link` verbatim reproduces a
    /// bug that currently sends every auction notification to a dead end.
    func testTheAuctionLinkIsInterceptedRatherThanFollowed() throws {
        let notification = try decode(
            AppNotification.self,
            #"{"id":"n1","type":"auction","link":"/auction-notices/abc123"}"#)

        XCTAssertEqual(notification.destination, .auction(id: "abc123"))
    }

    func testACaseLinkResolvesToTheCase() throws {
        let notification = try decode(
            AppNotification.self,
            #"{"id":"n1","type":"hearing","link":"/cases/case_42","case_id":"case_42"}"#)

        XCTAssertEqual(notification.destination, .caseDetail(id: "case_42"))
    }

    /// `case_id` is NULL on the team-invite notification even though its link is `/cases`
    /// (`sync-server.js:8791`). Inferring a case from the link prefix would open a detail
    /// screen with no id.
    func testTheTeamInviteLinkResolvesToTheListNotADetailScreen() throws {
        let notification = try decode(
            AppNotification.self,
            #"{"id":"n1","type":"team","link":"/cases","case_id":null}"#)

        XCTAssertEqual(notification.destination, .caseList)
        XCTAssertNil(notification.caseID)
    }

    func testAMissingOrEmptyLinkGoesNowhere() throws {
        XCTAssertEqual(try decode(AppNotification.self, #"{"id":"n"}"#).destination, .none)
        XCTAssertEqual(
            try decode(AppNotification.self, #"{"id":"n","link":""}"#).destination, .none)
        XCTAssertEqual(
            try decode(AppNotification.self, #"{"id":"n","link":"/cases/"}"#).destination,
            .caseList, "a trailing slash with no id is the list, not a detail with an empty id")
    }

    // MARK: - Types

    /// Seven types are whitelisted but only five have a producer. `reminder` has none — there
    /// is no scheduler reading `remind_days` — and `system` is a coercion fallback that never
    /// fires. Shipping UI for them would imply this product sends reminders. It does not.
    func testOnlyProducedTypesAreModelled() {
        XCTAssertEqual(
            NotificationKind.produced.map(\.rawValue),
            ["hearing", "order", "status", "team", "auction"])
        XCTAssertEqual(NotificationKind(wire: "reminder"), .other)
        XCTAssertEqual(NotificationKind(wire: "system"), .other)
        XCTAssertEqual(NotificationKind(wire: "hearing"), .hearing)
        XCTAssertEqual(NotificationKind(wire: nil), .other)
    }

    // MARK: - View model

    /// Marking an already-read row still reports `changed: 1`, so a client that decremented on
    /// every success would drive its badge negative. The count is recomputed, never decremented.
    func testTheBadgeCannotGoNegativeOnADoubleTap() async {
        await withNotifications { service, model in
            service.notifications = [
                Self.notification("n1", read: 0), Self.notification("n2", read: 0),
            ]
            service.unreadCount = 2
            await model.load()
            XCTAssertEqual(model.unreadCount, 2)

            let first = model.notifications[0]
            service.unreadCount = 1
            await model.markRead(first)
            XCTAssertEqual(model.unreadCount, 1)

            // Same row again — the server would report changed:1 a second time.
            await model.markRead(model.notifications[0])
            XCTAssertGreaterThanOrEqual(model.unreadCount, 0)
            XCTAssertEqual(model.unreadCount, 1, "no double decrement")
        }
    }

    /// A failed mark-read must not leave the UI claiming something that did not happen.
    func testAFailedMarkReadIsRolledBack() async {
        await withNotifications { service, model in
            service.notifications = [Self.notification("n1", read: 0)]
            service.unreadCount = 1
            await model.load()

            service.error = APIError.transport("offline")
            await model.markRead(model.notifications[0])

            XCTAssertFalse(model.notifications[0].isRead, "rolled back")
        }
    }

    /// The server disambiguates same-second rows with `rowid`, which is not in the response.
    /// Re-sorting on `created_at` alone destroys an ordering that cannot be reconstructed —
    /// and a scraper run routinely writes several rows inside one second.
    func testFeedOrderIsPreservedExactlyAsReceived() async {
        await withNotifications { service, model in
            let sameSecond = "2026-08-26 09:47:22"
            service.notifications = [
                Self.notification("newest", createdAt: sameSecond),
                Self.notification("middle", createdAt: sameSecond),
                Self.notification("oldest", createdAt: sameSecond),
            ]
            await model.load()

            XCTAssertEqual(model.notifications.map(\.id), ["newest", "middle", "oldest"])
        }
    }

    /// There is no cursor and no truncation signal, so a full page is the only evidence older
    /// rows exist — and they are unreachable through this API.
    func testAFullPageIsFlaggedAsPossiblyIncomplete() async {
        await withNotifications { service, model in
            service.notifications = (0..<NotificationService.maximumLimit).map {
                Self.notification("n\($0)")
            }
            await model.load()

            XCTAssertTrue(model.mayHaveOlderUnreachable)
        }
    }

    func testAShortPageIsNotFlagged() async {
        await withNotifications { service, model in
            service.notifications = [Self.notification("n1")]
            await model.load()

            XCTAssertFalse(model.mayHaveOlderUnreachable)
        }
    }

    /// An unknown or malformed userId returns 200 with an empty array — indistinguishable from
    /// "you have no notifications". A genuine failure must still read as a failure.
    func testAFailedLoadIsNotAnEmptyFeed() async {
        await withNotifications { service, model in
            service.error = APIError.server(status: 500, message: "Missing userId")
            await model.load()

            XCTAssertTrue(model.presentation.showsFailureState)
            XCTAssertFalse(model.presentation.showsEmptyState)
        }
    }

    func testMarkAllReadClearsTheBadge() async {
        await withNotifications { service, model in
            service.notifications = [
                Self.notification("n1", read: 0), Self.notification("n2", read: 0),
            ]
            service.unreadCount = 2
            await model.load()

            service.unreadCount = 0
            await model.markAllRead()

            XCTAssertEqual(model.unreadCount, 0)
            XCTAssertTrue(model.notifications.allSatisfy(\.isRead))
        }
    }

    // MARK: - Fixtures

    private static func notification(
        _ id: String, read: Int = 0, type: String = "hearing",
        createdAt: String = "2026-08-26 09:47:22"
    ) -> AppNotification {
        AppNotification(
            id: id, userID: "42", teamID: "team_1", type: type,
            title: "Next hearing listed", body: "14 September 2026",
            link: "/cases/case_1", caseID: "case_1", read: read, createdAtRaw: createdAt)
    }
}

@MainActor
private func withNotifications(
    _ body: @MainActor (FakeNotifications, NotificationsViewModel) async -> Void
) async {
    let service = FakeNotifications()
    await body(service, NotificationsViewModel(service: service))
}
