import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The user's private calendar-subscription link, in the two forms the app hands out.
///
/// The feed is `GET /calendar/my.ics?feed=<secret>` — hearings on the user's matters plus their
/// diary entries, as ICS. Calendar apps poll it on their own schedule and cannot sign in, so the
/// secret in the URL *is* the credential: anyone holding the link can read the feed. That is why
/// it is issued by the server to a signed-in caller and can be reset, and why this client shows
/// where it points without ever printing the secret on screen.
struct CalendarFeedLink: Equatable, Sendable {
    /// The `https` feed. What "Copy link" copies, and what Google or Outlook take "from URL".
    let feedURL: URL
    /// The same feed as `webcal://`, the scheme iOS routes to the Calendar app's own
    /// "Subscribe" sheet.
    let subscribeURL: URL

    /// Where the link points, without its secret — for a caption under the actions.
    var host: String { feedURL.host ?? "" }
}

/// Turning the route's answer into links, and refusing anything that would not work.
///
/// Separate from the service so every rule can be tested without a server: the route answers a
/// **path**, not a URL, and the shape of what it answers is the whole difference between a
/// subscription that works and one that silently fetches nothing every few hours for ever.
enum CalendarFeedURL {
    /// The server issues 32 hex characters and refuses anything shorter as "no such feed"
    /// (`sync-server.js`, the `/calendar/my.ics` branch). A link carrying less would subscribe
    /// the user to a feed that can only ever answer 404 — and a calendar app reports that as
    /// an empty calendar, not as an error.
    static let minimumSecretLength = 32

    enum Failure: LocalizedError, Equatable {
        case unusable

        var errorDescription: String? {
            "Emperor did not return a usable calendar link. Please try again."
        }
    }

    /// Resolves what `/calendar/feed-url` answered into the absolute `https` feed.
    ///
    /// The route answers `path: "/api/calendar/my.ics?feed=…"` — rooted, and already carrying
    /// `/api`. The web prefixes the page's origin (`MyCalendar.jsx`, `GoogleSyncModal`). Here the
    /// API base already ends in `/api`, so the path is resolved against the base's **origin**,
    /// never appended to the base, which would give `/api/api/…`.
    ///
    /// An absolute `https` URL is accepted as it is, in case the route ever answers one. Anything
    /// else — plain `http`, another scheme, a path that is not rooted, or a link without a full
    /// secret — is refused rather than handed to a calendar app.
    static func feedURL(fromPath path: String, base: URL) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.unusable }

        let resolved: URL?
        if trimmed.hasPrefix("/"), !trimmed.hasPrefix("//") {
            var origin = URLComponents()
            origin.scheme = base.scheme
            origin.host = base.host
            origin.port = base.port
            resolved = origin.url.flatMap { URL(string: trimmed, relativeTo: $0)?.absoluteURL }
        } else {
            resolved = URL(string: trimmed)
        }

        guard let url = resolved,
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              let secret = secret(in: url), secret.count >= minimumSecretLength
        else { throw Failure.unusable }
        return url
    }

    /// The `feed` query value, if there is exactly one.
    static func secret(in url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let feeds = items.filter { $0.name == "feed" }
        guard feeds.count == 1, let value = feeds[0].value?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// The `webcal://` form of an `https` feed: the same host, port, path and query.
    ///
    /// `webcal` is not a transport of its own — it is the scheme iOS recognises as "subscribe to
    /// this calendar", and the Calendar app fetches the feed over the web from there. Only the
    /// scheme changes.
    static func subscribeURL(for feed: URL) -> URL? {
        guard feed.scheme?.lowercased() == "https",
              var components = URLComponents(url: feed, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "webcal"
        return components.url
    }

    static func link(fromPath path: String, base: URL) throws -> CalendarFeedLink {
        let feed = try feedURL(fromPath: path, base: base)
        guard let subscribe = subscribeURL(for: feed) else { throw Failure.unusable }
        return CalendarFeedLink(feedURL: feed, subscribeURL: subscribe)
    }
}

protocol CalendarFeedProviding: Sendable {
    /// The user's link, issuing one if they have never had one.
    func feedLink() async throws -> CalendarFeedLink
    /// Replaces the link. Every calendar subscribed to the old one stops updating at once.
    func resetFeedLink() async throws -> CalendarFeedLink
}

struct CalendarFeedResponse: Codable, Sendable {
    var success: Bool?
    var path: String?
    var rotated: Bool?
    var error: String?
}

struct CalendarFeedService: CalendarFeedProviding {
    let client: APIClient
    /// The API base the client was configured with, which the route's answer is resolved
    /// against. Passed in because the client does not expose its configuration.
    let baseURL: URL

    /// `GET /calendar/feed-url`. Identified from the bearer token alone; the server creates the
    /// secret on first ask, so this is safe to call every time the screen opens.
    func feedLink() async throws -> CalendarFeedLink {
        let response = try await withRetry {
            let request = try await client.makeRequest("GET", "/calendar/feed-url")
            return try await client.send(request, as: CalendarFeedResponse.self)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return try CalendarFeedURL.link(fromPath: response.path ?? "", base: baseURL)
    }

    private struct ResetPayload: Encodable {
        let userId: String
        let rotate: Bool
    }

    /// `POST /calendar/feed-url` with `{ rotate: true }`.
    ///
    /// Not retried: a reset is a write, and RetryPolicy's rule for writes holds even where a
    /// repeat would be harmless.
    ///
    /// - Important: the answer must say `rotated: true`. The route issues a new secret only when
    ///   it can read `rotate` from the body, and otherwise answers 200 with the **existing**
    ///   link and `rotated: false`. Taking that as success would tell someone who reset their
    ///   link because it leaked that the old one is dead while it still works — so it is
    ///   reported as a failure, and the message says the old link still works.
    func resetFeedLink() async throws -> CalendarFeedLink {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        let request = try await client.makeRequest(
            "POST", "/calendar/feed-url",
            body: ResetPayload(userId: credentials.userIDString, rotate: true))
        let response = try await client.send(request, as: CalendarFeedResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        guard response.rotated == true else {
            throw APIError.server(
                status: 200,
                message: "Your calendar link could not be reset. The current link still works.")
        }
        return try CalendarFeedURL.link(fromPath: response.path ?? "", base: baseURL)
    }
}
