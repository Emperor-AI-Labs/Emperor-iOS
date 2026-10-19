import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the Corporate Calendar reads, and the one thing it writes.
protocol ComplianceCalendarProviding: Sendable {
    /// Every obligation the compliance pipeline tracks, dated or not.
    func deadlines() async throws -> [StatutoryDeadline]
    /// The rows that record a statutory deadline as done, for every team the user is in.
    func statutoryMarkers() async throws -> [ComplianceEvent]
    /// Records a statutory deadline as done, or as open again.
    func saveMarker(_ marker: StatutoryMarker) async throws
}

/// The row that records a statutory deadline's state — the body the web's `toggleDone` sends.
///
/// Its id is the deadline's own: `stat:<obligation>:<YYYY-MM-DD>`, where the obligation is the
/// generator's id for a deadline from a company profile (`stat:aoc4:2026-10-30`) and the
/// pipeline's code for one from the feed (`stat:GSTR1:2026-10-11`). `POST /compliance-event`
/// upserts on that id, so ticking and unticking rewrite one row rather than adding rows.
struct StatutoryMarker: Equatable, Sendable {
    let id: String
    let title: String
    /// The deadline's category (`mca`, `gst`, …), or `filing` when it has none — the web's
    /// `ev.category || 'filing'`.
    let type: String
    let dueDate: String
    let isDone: Bool
    /// Whatever the existing marker carried, sent back so the upsert does not clear it.
    let notes: String?

    init(deadline: StatutoryDeadline, done: Bool, notes: String?) {
        id = deadline.id
        title = deadline.displayTitle
        type = deadline.uiCategory?.nilIfEmpty ?? "filing"
        dueDate = deadline.dueDay ?? ""
        isDone = done
        self.notes = notes?.nilIfEmpty
    }
}

struct ComplianceCalendarService: ComplianceCalendarProviding {
    let client: APIClient

    /// The pipeline's statutory calendar.
    ///
    /// `GET /compliance-calendar` (`sync-server.js`, the branch commented "Statutory compliance
    /// calendar feed") answers with a **bare array** — the one route on this screen without the
    /// `{success, …}` envelope — so it decodes straight into `[StatutoryDeadline]`. The list is
    /// the platform's register of obligations, the same for every account, which is why it is
    /// cached and shown whole rather than filtered to a company.
    ///
    /// A failure is a failure. The web page swallows one and shows its calendar without these
    /// rows; here they are the whole screen, and an empty calendar after a failed request would
    /// tell a company secretary they have nothing due.
    func deadlines() async throws -> [StatutoryDeadline] {
        try await withRetry {
            let request = try await client.makeRequest("GET", "/compliance-calendar")
            return try await client.send(request, as: [StatutoryDeadline].self)
        }
    }

    /// The done-markers, read so a deadline the team ticked off on the web does not show here
    /// as overdue.
    ///
    /// The web records "done" for a statutory deadline as an ordinary `compliance_events` row
    /// whose id is the deadline's own `stat:<code>:<date>` (`ComplianceCalendar.jsx`,
    /// `toggleDone`). `CalendarService.events()` filters exactly those rows out, because on the
    /// diary they are noise; here they are the only thing wanted, so this asks `/compliance`
    /// itself and keeps the other half.
    ///
    func statutoryMarkers() async throws -> [ComplianceEvent] {
        let response = try await withRetry {
            let request = try await client.makeRequest("GET", "/compliance")
            return try await client.send(request, as: ComplianceListResponse.self)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return (response.events ?? []).filter(\.isStatutoryMarker)
    }

    private struct MarkerPayload: Encodable {
        let userId: String
        let marker: StatutoryMarker

        enum CodingKeys: String, CodingKey {
            case userId, id, title, type, dueDate, status, notes, remindDays
        }

        /// Every key the web sends, `null`s included. No `teamId`: the web sends its chosen team,
        /// and with none chosen — this client has no such choice — the server files the row
        /// under the user's own personal team. An existing row keeps the team it was filed in.
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(userId, forKey: .userId)
            try c.encode(marker.id, forKey: .id)
            try c.encode(marker.title, forKey: .title)
            try c.encode(marker.type, forKey: .type)
            try c.encode(marker.dueDate, forKey: .dueDate)
            try c.encode(marker.isDone ? "done" : "open", forKey: .status)
            if let notes = marker.notes { try c.encode(notes, forKey: .notes) } else { try c.encodeNil(forKey: .notes) }
            try c.encodeNil(forKey: .remindDays)
        }
    }

    /// `POST /compliance-event` with the deadline's own id — the web's `toggleDone`.
    ///
    /// Answers `{success: true, id}`; a refusal is `403 {success: false, error}` and a failure
    /// `500 {error}`, both of which `APIClient` raises. Not retried: a write is not repeated
    /// behind the user's back.
    func saveMarker(_ marker: StatutoryMarker) async throws {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        let request = try await client.makeRequest(
            "POST", "/compliance-event",
            body: MarkerPayload(userId: credentials.userIDString, marker: marker))
        let response = try await client.send(request, as: WriteResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }
}
