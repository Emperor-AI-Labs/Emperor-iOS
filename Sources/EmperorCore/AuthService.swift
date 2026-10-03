import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in Foundation on Apple platforms but in FoundationNetworking on Linux,
// where the core package is compiled for tests.
import FoundationNetworking
#endif

/// The sign-in routes, as a seam the sign-in screen's view model can be driven through.
///
/// `SignInFlow` takes this rather than `AuthService` so every branch of signing in — a Google
/// account, an unconfirmed address, a wrong code — can be exercised with no server.
protocol AuthProviding: Sendable {
    func login(email: String, password: String) async throws -> AuthResponse
    func register(name: String, email: String, password: String, phone: String?) async throws
        -> Registration
    func resendVerification(email: String) async throws
    func requestCode(email: String) async throws -> CodeRequest
    func verifyCode(email: String, code: String) async throws -> AuthResponse
    func requestPasswordReset(email: String) async throws
    func signInWithGoogle(idToken: String) async throws -> AuthResponse
    func signInWithApple(idToken: String, name: String?) async throws -> AuthResponse
}

/// What creating an account produced.
enum Registration: Equatable, Sendable {
    /// The account exists and must be confirmed from the inbox before it can sign in. This is
    /// what the platform does now: `/register` deliberately returns no token
    /// (`sync-server.js`, "Deliberately NO token and NO cookie").
    case confirmationSent(email: String)
    /// The account exists and is signed in — what a server that predates verification returns.
    case signedIn(AuthResponse)
}

/// What asking for a one-time code produced.
struct CodeRequest: Equatable, Sendable {
    /// How long the code lives, as the server states it. `nil` if it did not say.
    var expiresInMinutes: Int?
}

struct AuthService: AuthProviding {
    let client: APIClient

    private struct LoginBody: Encodable {
        let email: String
        let password: String
    }

    private struct RegisterBody: Encodable {
        let name: String
        let email: String
        let password: String
        /// `+91XXXXXXXXXX`, or absent. Optional on the platform as here: blank stores nothing,
        /// and anything else must be a complete Indian mobile number (400 `BAD_PHONE`).
        let phone: String?
    }

    private struct IDTokenBody: Encodable {
        let idToken: String
        /// Apple sends the person's name on the very first authorisation only, ever — it is
        /// passed along then or lost.
        let name: String?
    }

    private struct EmailBody: Encodable { let email: String }

    private struct CodeBody: Encodable {
        let email: String
        let code: String
    }

    /// `/register`'s envelope. Every field optional, because two server generations answer it:
    /// the current one returns `verificationRequired` and no token, an older one a full sign-in.
    private struct RegisterResponse: Decodable {
        var success: Bool?
        var verificationRequired: Bool?
        var email: String?
        var user: User?
        var token: String?
    }

    private struct CodeResponse: Decodable {
        var success: Bool?
        var expiresInMinutes: Int?
    }

    /// Signs in.
    ///
    /// Both wrong-password and unknown-email answer 401 `{"error":"Invalid credentials"}` —
    /// the server deliberately does not distinguish them, and neither should the UI. Two
    /// refusals *are* distinguished, because each has a different way forward: an account
    /// created through Google has no password at all (409 `SSO_ACCOUNT`), and a new account
    /// that has not confirmed its email is refused until it does (403 `EMAIL_UNVERIFIED`).
    /// Both arrive as `APIError.refused`.
    func login(email: String, password: String) async throws -> AuthResponse {
        let request = try await client.makeRequest(
            "POST", "/login",
            body: LoginBody(email: email, password: password),
            requiresAuth: false)
        return try await client.send(request, as: AuthResponse.self)
    }

    /// Creates an account.
    ///
    /// The server emails a confirmation link and signs nobody in, so a new account cannot use
    /// the app until the address is confirmed — by the link, or by a one-time code, which
    /// confirms it too (`/auth/otp/verify` sets `email_verified`). It requires a password of at
    /// least eight characters and refuses an address already registered (409 `EXISTS`), or one
    /// that signs in with Google (409 `SSO_ACCOUNT`).
    func register(
        name: String, email: String, password: String, phone: String?
    ) async throws -> Registration {
        let request = try await client.makeRequest(
            "POST", "/register",
            body: RegisterBody(name: name, email: email, password: password, phone: phone),
            requiresAuth: false)
        let response = try await client.send(request, as: RegisterResponse.self)
        if let token = response.token, !token.isEmpty, let user = response.user {
            return .signedIn(AuthResponse(success: response.success ?? true, user: user, token: token))
        }
        // The address the server will match on is the one it stored, which it normalises.
        return .confirmationSent(email: response.email ?? email)
    }

    /// Sends the confirmation email again.
    ///
    /// Answers the same whether or not the address is registered or already confirmed, so it
    /// cannot be used to learn which addresses exist — and the screen must not imply otherwise.
    func resendVerification(email: String) async throws {
        let request = try await client.makeRequest(
            "POST", "/auth/resend-verification", body: EmailBody(email: email),
            requiresAuth: false)
        _ = try await client.send(request, as: APIErrorBody.self)
    }

    /// Emails a six-digit sign-in code.
    ///
    /// The way in for an account that has no password (one made through Google), and the
    /// fastest way to confirm a new one. Uniform like resend: the server answers alike for an
    /// unknown address, and quietly sends nothing past three codes in fifteen minutes —
    /// `SignInFlow` paces requests so a person is never left waiting for a code that is not
    /// coming.
    func requestCode(email: String) async throws -> CodeRequest {
        let request = try await client.makeRequest(
            "POST", "/auth/otp/request", body: EmailBody(email: email), requiresAuth: false)
        let response = try await client.send(request, as: CodeResponse.self)
        return CodeRequest(expiresInMinutes: response.expiresInMinutes)
    }

    /// Exchanges a code for a session. A wrong, expired or exhausted code is a 401
    /// `OTP_INVALID`, which arrives as `APIError.refused` — never as "signed out".
    func verifyCode(email: String, code: String) async throws -> AuthResponse {
        let request = try await client.makeRequest(
            "POST", "/auth/otp/verify", body: CodeBody(email: email, code: code),
            requiresAuth: false)
        return try await client.send(request, as: AuthResponse.self)
    }

    /// Asks the server to email a reset link.
    ///
    /// - Important: this **always succeeds**, whether or not the address has an account — the
    ///   route returns 200 unconditionally so it never leaks which emails exist. So the caller
    ///   must show the same message either way, and must not say "we found your account".
    ///   The link is a **web** URL (`APP_BASE_URL/reset-password?token=…`), so the reset itself
    ///   finishes in a browser.
    func requestPasswordReset(email: String) async throws {
        let request = try await client.makeRequest(
            "POST", "/forgot-password",
            body: EmailBody(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
            requiresAuth: false)
        _ = try await client.send(request, as: APIErrorBody.self)
    }

    /// Who the token belongs to, as the server sees it now — the closest thing this API has to
    /// a `/me`.
    ///
    /// `GET /auth/session` answers with the account as it stands (plan, whether it needs one,
    /// whether it is paused, the starting model) **and a freshly signed token**, so calling it
    /// when the app opens is what keeps an account that is in daily use signed in rather than
    /// lapsing a fixed number of days after the last password entry. A 401 here means the token
    /// is spent or was revoked, and is handled like any other: the session ends.
    func currentSession() async throws -> AuthResponse {
        let request = try await client.makeRequest("GET", "/auth/session")
        return try await client.send(request, as: AuthResponse.self)
    }

    /// Exchanges a Google ID token for an Emperor session.
    ///
    /// The token, never an email or a user id: the server verifies it against Google's keys and
    /// decides who it names. Answered exactly as `/login` is. Not reachable until
    /// `SocialSignInConfig` turns the button on — see there for what has to exist first.
    func signInWithGoogle(idToken: String) async throws -> AuthResponse {
        let request = try await client.makeRequest(
            "POST", "/auth/google", body: IDTokenBody(idToken: idToken, name: nil),
            requiresAuth: false)
        return try await client.send(request, as: AuthResponse.self)
    }

    /// Exchanges an Apple identity token for an Emperor session, with the name Apple shares only
    /// the first time.
    func signInWithApple(idToken: String, name: String?) async throws -> AuthResponse {
        let request = try await client.makeRequest(
            "POST", "/auth/apple", body: IDTokenBody(idToken: idToken, name: name),
            requiresAuth: false)
        return try await client.send(request, as: AuthResponse.self)
    }

    /// Ends the session.
    ///
    /// `POST /logout` clears the platform's auth cookie, and is called first, while the request
    /// can still carry the token. It is best-effort: signing out must work offline, so a failure
    /// here never keeps anyone signed in. The credential itself is then discarded locally —
    /// which is also why it is held in the Keychain rather than `UserDefaults`.
    func signOut() async {
        if let request = try? await client.makeRequest("POST", "/logout", body: [String: String]()) {
            _ = try? await client.perform(request)
        }
        await client.setCredentials(nil)
        await client.clearCookies()
    }
}
