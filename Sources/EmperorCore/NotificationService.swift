import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol NotificationProviding: Sendable {
    func notifications(limit: Int) async throws -> [AppNotification]
    func unreadCount() async throws -> Int
    func markRead(id: String) async throws
    func markAllRead() async throws
}

extension NotificationProviding {
    func notifications() async throws -> [AppNotification] {
        try await notifications(limit: NotificationService.maximumLimit)
    }
}

struct NotificationService: NotificationProviding {
    let client: APIClient

    /// The server clamps `limit` to 1...200 with **no indication of truncation** — no cursor,
    /// no offset, no total, no `hasMore` (`lib/notifications.js:95`). Asking for more silently
    /// yields 200. So the app asks for exactly the ceiling and treats a full page as "there may
    /// be older ones we cannot reach", which is the honest reading.
    static let maximumLimit = 200

    /// The whole list, every time, and the unread ones are picked out locally.
    ///
    /// The route does take an `unreadOnly` filter, and this used to pass it. Nothing ever asked
    /// for it: the screen shows read and unread together and needs the full list anyway, and the
    /// badge counts unread rows from what it already holds. An unexercised parameter on a
    /// protocol is a claim that a mode works, so it is gone rather than sitting untested.
    ///
    /// If it is ever wanted back, the one thing worth knowing is that the server compares it
    /// with strict equality against the **string** `"1"` (`sync-server.js:10412`) — sending a
    /// JSON `true` silently returns the full list, read rows included, which reads as the filter
    /// being ignored rather than as a bad request.
    func notifications(limit: Int = maximumLimit) async throws -> [AppNotification] {
        let query = ["limit": String(min(max(limit, 1), Self.maximumLimit))]

        let response = try await withRetry {
            let request = try await client.makeRequest("GET", "/notifications", query: query)
            return try await client.send(request, as: NotificationListResponse.self)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        // Order is preserved exactly as received. The server disambiguates same-second rows
        // with `ORDER BY created_at DESC, rowid DESC` (`lib/notifications.js:98`) and `rowid` is
        // not in the projection — so re-sorting on `created_at` alone destroys an ordering that
        // cannot be reconstructed. A scraper run routinely writes several rows in one second.
        return response.notifications ?? []
    }

    func unreadCount() async throws -> Int {
        let request = try await client.makeRequest("GET", "/notifications/unread-count")
        let response = try await client.send(request, as: UnreadCountResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return response.count ?? 0
    }

    private struct ReadPayload: Encodable {
        let userId: String
        let id: String
    }

    /// - Important: `userId` must be a real value. The route does `'' + b.userId`
    ///   (`sync-server.js:10424`), so a missing key becomes the literal string `"undefined"`,
    ///   which defeats `markRead`'s own guard and returns
    ///   `200 {"success":true,"changed":0}` — the mark appears to work, the badge decrements
    ///   locally, and the next poll restores it. An infinite ping-pong with no error anywhere.
    func markRead(id: String) async throws {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        let request = try await client.makeRequest(
            "POST", "/notifications/read",
            body: ReadPayload(userId: credentials.userIDString, id: id))
        let response = try await client.send(request, as: ChangedResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }

    private struct ReadAllPayload: Encodable {
        let userId: String
    }

    func markAllRead() async throws {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        let request = try await client.makeRequest(
            "POST", "/notifications/read-all",
            body: ReadAllPayload(userId: credentials.userIDString))
        let response = try await client.send(request, as: ChangedResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }
}
