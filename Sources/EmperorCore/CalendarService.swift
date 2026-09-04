import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol CalendarProviding: Sendable {
    func events() async throws -> [ComplianceEvent]
    func save(_ draft: ComplianceDraft) async throws
    func delete(id: String) async throws
}

/// A new or edited obligation.
///
/// - Note: `remindDays` is carried but never *offered* — see `CalendarService.remindersAreInert`
///   for why there is no picker. It is here because the upsert's `ON CONFLICT` clause sets
///   `remind_days=@remind` (`sync-server.js:10267`), so omitting it NULLs whatever the user set
///   on the web. Destroying a value this app declines to expose would be worse than ignoring it.
struct ComplianceDraft: Equatable, Sendable {
    var id: String?
    var title: String
    var kind: ComplianceKind = .task
    var dueDate: Date
    var notes: String?
    var caseID: String?
    var isDone: Bool = false
    /// Opaque passthrough. Never read, never shown, never edited — only preserved.
    var remindDays: Int?
}

struct CalendarService: CalendarProviding {

    /// **Reminders do not exist on this platform, and the app must not imply they do.**
    ///
    /// `compliance_events.remind_days` is written by `POST /compliance-event`
    /// (`sync-server.js:10264`) and rendered back as a "3d before" chip by the web client
    /// (`MyCalendar.jsx:409`) — and read by nothing else anywhere in the repository. There is
    /// no scheduler that scans `compliance_events` by due date; the only cron-style process
    /// reads a different database entirely. The `reminder` notification type has no producer.
    /// The ICS feed emits no `VALARM`, so even a subscribing calendar gets nothing.
    ///
    /// A reminder picker would therefore be a promise the product cannot keep, on a screen
    /// whose entire purpose is not missing a limitation date. It is omitted until a server-side
    /// job exists.
    static let remindersAreInert = true

    /// **The ICS subscription URL is not offered in-app either.**
    ///
    /// A calendar subscription URL is a standing credential for every hearing and limitation
    /// date the user has, and a share sheet invites it into an email. It stays out until it can
    /// be issued as a rotatable, revocable token.
    static let icsFeedIsUnsafeToShare = true

    let client: APIClient

    /// Every obligation for every team the user belongs to.
    ///
    /// Statutory markers are filtered here rather than in the view. They are bookkeeping rows
    /// written by the Corporate Calendar to record that an obligation was met — not to-dos —
    /// and the web client filters them for the same reason (`MyCalendar.jsx:97`).
    func events() async throws -> [ComplianceEvent] {
        let response = try await withRetry {
            let request = try await client.makeRequest("GET", "/compliance")
            return try await client.send(request, as: ComplianceListResponse.self)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return (response.events ?? []).filter { !$0.isStatutoryMarker }
    }

    private struct EventPayload: Encodable {
        let userId: String
        let id: String?
        let title: String
        let type: String
        let dueDate: String
        let status: String
        let notes: String?
        let caseId: String?
        /// Echoed back untouched. See `ComplianceDraft.remindDays`.
        let remindDays: Int?
    }

    /// Creates or updates an obligation.
    ///
    /// The upsert is a **full replace** — every column in the `ON CONFLICT` clause is bound
    /// from the request, so an omitted field becomes NULL. Everything is therefore sent every
    /// time, and the caller works from a complete draft rather than a patch.
    func save(_ draft: ComplianceDraft) async throws {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        let payload = EventPayload(
            userId: credentials.userIDString,
            id: draft.id,
            title: draft.title,
            type: draft.kind.wireValue,
            // `YYYY-MM-DD` in India: the value is stored verbatim and every consumer anchors
            // on that shape.
            dueDate: WireDate.dayKey(draft.dueDate),
            status: draft.isDone ? "done" : "open",
            notes: draft.notes?.isEmpty == true ? nil : draft.notes,
            caseId: draft.caseID,
            remindDays: draft.remindDays)

        let request = try await client.makeRequest("POST", "/compliance-event", body: payload)
        let response = try await client.send(request, as: WriteResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }

    func delete(id: String) async throws {
        let request = try await client.makeRequest(
            "DELETE", "/compliance-event", query: ["id": id])
        let response = try await client.send(request, as: WriteResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }
}
