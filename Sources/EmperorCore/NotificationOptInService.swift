import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The account's daily cause-list email, as `GET /notif/status` reports it.
///
/// The platform's briefing (`lib/dailyNotify.js`) is account-level: one opt-in covers the email
/// and every browser the account has allowed push in. This app sends no browser subscription,
/// so for the phone it is the email alone.
struct EmailBriefingStatus: Codable, Equatable, Sendable {
    /// Whether the account has ever answered the web's "turn on daily notifications?" prompt.
    var asked: Bool?
    var optedIn: Bool?
    /// Browsers holding a push subscription for this account. Turning the briefing off removes
    /// them all, which is why the switch here says so.
    var pushCount: Int?
    /// Whether the daily run is switched on for everyone. An administrator can pause it; the
    /// account's choice is kept meanwhile.
    var systemEnabled: Bool?
    /// When the daily run goes, "HH:MM" in IST.
    var notifTime: String?

    var isOptedIn: Bool { optedIn == true }
    /// `nil` reads as running: an older server without the field still sent the email.
    var isPaused: Bool { systemEnabled == false }

    /// "08:00", falling back to the platform's own default when the server sends nothing usable.
    var sendTime: String {
        NotificationPreferences.clock(
            NotificationPreferences.minutes(fromClock: notifTime) ?? 8 * 60)
    }
}

/// What `POST /notif/test` reports.
struct EmailBriefingTestResult: Codable, Equatable, Sendable {
    var success: Bool?
    var emailed: Int?
    var pushed: Int?
    var error: String?

    /// Whether an email actually left. The run reports per-channel counts rather than failing,
    /// so a 200 with `emailed: 0` is a test that sent nothing.
    var didEmail: Bool { (emailed ?? 0) > 0 }
}

protocol EmailBriefingProviding: Sendable {
    func status() async throws -> EmailBriefingStatus
    func optIn() async throws
    func optOut() async throws
    func sendTest() async throws -> EmailBriefingTestResult
}

/// The four `/notif/*` routes behind the daily cause-list email.
///
/// Each one carries the caller's id the way the rest of this client does — in the query for the
/// read, in the body for the writes — alongside the bearer token, so it keeps working unchanged
/// once the server takes identity from the token alone.
///
/// - Note: `optIn` never sends the `subscription` field. That is a browser's Web Push
///   subscription, which a phone does not have; this app's own reminders are local
///   (`NotificationPlanner`).
struct NotificationOptInService: EmailBriefingProviding {
    let client: APIClient

    /// The account's standing. No `success` key on this route — the body is the status itself,
    /// and a failure is a non-2xx with `error`, which `APIClient` already throws on.
    func status() async throws -> EmailBriefingStatus {
        try await withRetry {
            let request = try await client.makeRequest("GET", "/notif/status")
            return try await client.send(request, as: EmailBriefingStatus.self)
        }
    }

    private struct Payload: Encodable {
        let userId: String
    }

    func optIn() async throws {
        try await post("/notif/optin")
    }

    /// - Important: the server also deletes **every** browser push subscription the account
    ///   holds (`lib/dailyNotify.js`, the opt-out branch). Turning the email off here therefore
    ///   stops the web's browser alerts too, which the settings screen says beside the switch.
    func optOut() async throws {
        try await post("/notif/optout")
    }

    /// Sends one briefing now, to this account, through every channel it has.
    ///
    /// - Important: the route also marks the account opted in, exactly as `optIn` does. The
    ///   settings screen offers it only while the email is already on, so pressing it can never
    ///   switch the daily email on behind the person's back.
    func sendTest() async throws -> EmailBriefingTestResult {
        let request = try await makePost("/notif/test")
        let result = try await client.send(request, as: EmailBriefingTestResult.self)
        try CaseService.throwIfUnsuccessful(success: result.success, error: result.error)
        return result
    }

    private func post(_ path: String) async throws {
        let request = try await makePost(path)
        let response = try await client.send(request, as: WriteResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }

    private func makePost(_ path: String) async throws -> URLRequest {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        return try await client.makeRequest(
            "POST", path, body: Payload(userId: credentials.userIDString))
    }
}
