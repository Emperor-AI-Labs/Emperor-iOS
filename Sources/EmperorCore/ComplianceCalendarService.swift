import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the Corporate Calendar reads.
protocol ComplianceCalendarProviding: Sendable {
    /// Every obligation the compliance pipeline tracks, dated or not.
    func deadlines() async throws -> [StatutoryDeadline]
    /// The rows that record a statutory deadline as done, for every team the user is in.
    func statutoryMarkers() async throws -> [ComplianceEvent]
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
    /// - Note: read-only by design. Marking a statutory deadline done is held back on this
    ///   client until the endpoint contract for statutory markers is confirmed — do not add a
    ///   write here without doing that first. What the web records is still shown.
    func statutoryMarkers() async throws -> [ComplianceEvent] {
        let response = try await withRetry {
            let request = try await client.makeRequest("GET", "/compliance")
            return try await client.send(request, as: ComplianceListResponse.self)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return (response.events ?? []).filter(\.isStatutoryMarker)
    }
}
