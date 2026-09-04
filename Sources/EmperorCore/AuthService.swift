import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in Foundation on Apple platforms but in FoundationNetworking on Linux,
// where the core package is compiled for tests.
import FoundationNetworking
#endif

struct AuthService {
    let client: APIClient

    private struct LoginBody: Encodable {
        let email: String
        let password: String
    }

    private struct RegisterBody: Encodable {
        let name: String
        let email: String
        let password: String
    }

    /// Signs in.
    ///
    /// Both wrong-password and unknown-email answer 401 `{"error":"Invalid credentials"}` —
    /// the server deliberately does not distinguish them, and neither should the UI.
    func login(email: String, password: String) async throws -> AuthResponse {
        let request = try await client.makeRequest(
            "POST", "/login",
            body: LoginBody(email: email, password: password),
            requiresAuth: false)
        return try await client.send(request, as: AuthResponse.self)
    }

    /// Registers a new account.
    ///
    /// The returned `user` is a hand-built object carrying only `id`, `name` and `email` —
    /// not the fuller row `/login` returns. Fetch the rest on next sign-in if needed.
    func register(name: String, email: String, password: String) async throws -> AuthResponse {
        let request = try await client.makeRequest(
            "POST", "/register",
            body: RegisterBody(name: name, email: email, password: password),
            requiresAuth: false)
        return try await client.send(request, as: AuthResponse.self)
    }

    private struct ForgotBody: Encodable { let email: String }

    /// Asks the server to email a reset link.
    ///
    /// - Important: this **always succeeds**, whether or not the address has an account — the
    ///   route returns 200 unconditionally so it never leaks which emails exist
    ///   (`sync-server.js:10511`). So the caller must show the same message either way, and must
    ///   not say "we found your account".
    ///
    ///   Two further caveats worth surfacing to the user rather than hiding:
    ///   the link is a **web** URL (`APP_BASE_URL/reset-password?token=…`), so the reset itself
    ///   happens in a browser; and delivery depends on SMTP, which ships **disabled**
    ///   (`smtp_config.enabled` defaults to 0 with a NULL host, `sync-server.js:3559-3566`).
    ///   If mail is not configured, nothing arrives and no error is raised anywhere.
    func requestPasswordReset(email: String) async throws {
        let request = try await client.makeRequest(
            "POST", "/forgot-password",
            body: ForgotBody(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
            requiresAuth: false)
        _ = try await client.send(request, as: APIErrorBody.self)
    }

    /// Signing out discards the token locally. The credential is long-lived, which is also why
    /// it is held in the Keychain rather than `UserDefaults` — see `Keychain`.
    func signOut() async {
        await client.setCredentials(nil)
    }
}
