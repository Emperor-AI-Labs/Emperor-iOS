import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol NotificationProviding: Sendable {
    func notifications(limit: Int, unreadOnly: Bool) async throws -> [AppNotification]
    func unreadCount() async throws -> Int
    func markRead(id: String) async throws
    func markAllRead() async throws
}

extension NotificationProviding {
    func notifications() async throws -> [AppNotification] {
        try await notifications(limit: NotificationService.maximumLimit, unreadOnly: false)
    }
}

struct NotificationService: NotificationProviding {
    let client: APIClient

    /// The server clamps `limit` to 1...200 with **no indication of truncation** — no cursor,
    /// no offset, no total, no `hasMore` (`lib/notifications.js:95`). Asking for more silently
    /// yields 200. So the app asks for exactly the ceiling and treats a full page as "there may
    /// be older ones we cannot reach", which is the honest reading.
    static let maximumLimit = 200

    func notifications(
        limit: Int = maximumLimit, unreadOnly: Bool = false
    ) async throws -> [AppNotification] {
        var query = ["limit": String(min(max(limit, 1), Self.maximumLimit))]
        // Compared with strict equality to the string "1" (`sync-server.js:10412`). Sending
        // `true` silently returns the FULL list, read rows included.
        if unreadOnly { query["unreadOnly"] = "1" }

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
