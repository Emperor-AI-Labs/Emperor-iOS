import Foundation

/// One notification row.
struct AppNotification: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var userID: String?
    var teamID: String?
    /// One of `hearing`, `order`, `status`, `team`, `auction` in practice. See
    /// `NotificationKind` for why `reminder` and `system` are not in that list.
    var type: String?
    var title: String?
    var body: String?
    /// An app-internal path, never an absolute URL. **Not routable verbatim** — see
    /// `destination`.
    var link: String?
    var caseID: String?
    /// **The number 0 or 1, not a JSON boolean** (`sync-server.js:3574`). Decoding this as
    /// `Bool` throws `typeMismatch` and takes the whole feed down.
    var read: Int?
    /// Zoneless SQLite `CURRENT_TIMESTAMP` — `createNotification`'s INSERT omits the column so
    /// the DDL default always fires (`lib/notifications.js:61`). `ISO8601DateFormatter` cannot
    /// read it.
    var createdAtRaw: String?

    var isRead: Bool { (read ?? 0) != 0 }
    var createdAt: Date? { WireDate.parse(createdAtRaw) }

    var kind: NotificationKind { NotificationKind(wire: type) }

    /// Where tapping this should actually go.
    ///
    /// The `link` field cannot be routed verbatim. The auction producer emits
    /// `/auction-notices/<id>` (`court-scraper/ibbi-auctions-ingest.js:97`), which is an **API**
    /// path — the web router has no such route and falls through to NotFound
    /// (`src/App.jsx:186`); the real auction UI is at `/liquidations`. So the link is parsed
    /// into an intent rather than followed.
    var destination: NotificationDestination {
        guard let link, !link.isEmpty else { return .none }
        if link.hasPrefix("/auction-notices/") {
            let id = String(link.dropFirst("/auction-notices/".count))
            return id.isEmpty ? .none : .auction(id: id)
        }
        if link.hasPrefix("/cases/") {
            let id = String(link.dropFirst("/cases/".count))
            return id.isEmpty ? .caseList : .caseDetail(id: id)
        }
        if link == "/cases" {
            // `case_id` is NULL on the team-invite notification even though its link is
            // "/cases" (`sync-server.js:8791`), so this deliberately resolves to the list.
            return .caseList
        }
        return .none
    }

    enum CodingKeys: String, CodingKey {
        case id, type, title, body, link, read
        case userID = "user_id"
        case teamID = "team_id"
        case caseID = "case_id"
        case createdAtRaw = "created_at"
    }
}

/// Where a notification tap leads.
enum NotificationDestination: Equatable, Sendable {
    case caseDetail(id: String)
    case caseList
    /// A liquidation auction notice, routed to `AuctionDetailView`.
    ///
    /// The id is parsed out of the server's `link` rather than followed: that link is the API
    /// path `/auction-notices/<id>`, which has no screen even on the web.
    case auction(id: String)
    case none
}

/// The notification types that actually exist.
///
/// The server whitelists seven (`lib/notifications.js:16`) but only **five** have a producer
/// anywhere in the repository. `reminder` has none — there is no scheduler reading
/// `compliance_events.remind_days` — and `system` is reachable only as a coercion fallback that
/// never fires, because every real caller passes a valid type.
///
/// Building UI for the other two would ship code paths that can never execute and, worse,
/// imply to the reader that a "reminder" notification is something this product sends.
enum NotificationKind: String, CaseIterable, Sendable {
    case hearing, order, status, team, auction
    /// Anything unrecognised, including the two whitelisted-but-unproduced types. Kept so a
    /// future server-side producer degrades to a readable row rather than being dropped.
    case other

    init(wire: String?) {
        self = NotificationKind(rawValue: wire ?? "") ?? .other
    }

    /// The types this app has a producer for and can honestly render.
    static let produced: [NotificationKind] = [.hearing, .order, .status, .team, .auction]

    var label: String {
        switch self {
        case .hearing: return "Hearing"
        case .order: return "Order"
        case .status: return "Status"
        case .team: return "Team"
        case .auction: return "Auction"
        case .other: return "Update"
        }
    }

    var systemImage: String {
        switch self {
        case .hearing: return "calendar"
        case .order: return "doc.text"
        case .status: return "arrow.triangle.2.circlepath"
        case .team: return "person.2"
        case .auction: return "hammer"
        case .other: return "bell"
        }
    }
}

// MARK: - Envelopes

struct NotificationListResponse: Codable, Sendable {
    var success: Bool?
    var notifications: [AppNotification]?
    var error: String?
}

struct UnreadCountResponse: Codable, Sendable {
    var success: Bool?
    var count: Int?
    var error: String?
}

struct ChangedResponse: Codable, Sendable {
    var success: Bool?
    /// `better-sqlite3`'s `.changes`. **Not** a signal that anything meaningful happened:
    /// marking an already-read row read again still reports 1, because `markRead`'s WHERE has
    /// no `AND read = 0` predicate (`lib/notifications.js:119`).
    var changed: Int?
    var error: String?
}
