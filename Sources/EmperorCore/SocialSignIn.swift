import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Which sign-in providers this build may offer.
///
/// **Off unless configured.** "Continue with Google" needs two things outside this app: a Google
/// Cloud OAuth client of the *iOS* type, whose id goes in the build setting
/// `EMPEROR_GOOGLE_CLIENT_ID`, and a platform route that exchanges a Google ID token for an
/// Emperor session (`POST /auth/google`). Sign in with Apple needs the same route for Apple
/// (`POST /auth/apple`) and the Sign in with Apple capability on the app id. Until
/// `EMPEROR_SOCIAL_SIGN_IN` is `YES` neither button is drawn — a button that cannot work is
/// worse than none.
///
/// The two go together on purpose. App Review guideline 4.8 requires an app that offers a
/// third-party sign-in such as Google to offer Sign in with Apple as well, so Google is only ever
/// offered alongside it.
struct SocialSignInConfig: Equatable, Sendable {
    var isEnabled: Bool
    var googleClientID: String?

    static let disabled = SocialSignInConfig(isEnabled: false, googleClientID: nil)

    /// Read from the app's Info.plist keys `EmperorSocialSignIn` and `EmperorGoogleClientID`,
    /// which the build settings of the same names fill in.
    init(info: [String: Any]) {
        let flag = info["EmperorSocialSignIn"]
        if let bool = flag as? Bool {
            isEnabled = bool
        } else if let text = flag as? String {
            isEnabled = ["yes", "true", "1"].contains(text.lowercased())
        } else {
            isEnabled = false
        }
        let id = (info["EmperorGoogleClientID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded build setting arrives as the literal "$(…)"; that is not an id.
        googleClientID = (id?.isEmpty == false && id?.hasPrefix("$(") == false) ? id : nil
    }

    init(isEnabled: Bool, googleClientID: String?) {
        self.isEnabled = isEnabled
        self.googleClientID = googleClientID
    }

    var offersApple: Bool { isEnabled }

    /// Google only with Apple beside it (guideline 4.8), and only with a usable client id.
    var offersGoogle: Bool {
        offersApple && googleClientID.flatMap(GoogleOAuth.redirectScheme(clientID:)) != nil
    }

    var offersAny: Bool { offersApple || offersGoogle }
}

/// Signing in with Google from an app: OAuth 2.0 with PKCE, in the system's own browser sheet.
///
/// Google refuses sign-in inside an embedded web view, so the flow runs in
/// `ASWebAuthenticationSession` and returns to the app on the iOS client's reversed-id scheme.
/// The code is exchanged for an **ID token** directly with Google — an iOS client has no secret,
/// which is what PKCE is for — and the ID token, never an email or a user id, is what is handed
/// to the platform to say who this is (`POST /auth/google`).
enum GoogleOAuth {

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// "1234-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.1234-abc", the scheme
    /// Google redirects an iOS client to. Nil for anything that is not an iOS client id.
    static func redirectScheme(clientID: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        let head = String(clientID.dropLast(suffix.count))
        guard !head.isEmpty, head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            return nil
        }
        return "com.googleusercontent.apps." + head
    }

    static func redirectURI(clientID: String) -> String? {
        redirectScheme(clientID: clientID).map { $0 + ":/oauth2redirect" }
    }

    /// One attempt at signing in: what was sent, and what must come back.
    struct Attempt: Equatable, Sendable {
        let url: URL
        let callbackScheme: String
        let redirectURI: String
        let state: String
        let verifier: String
    }

    /// Builds the authorisation request.
    ///
    /// - Parameter random: a source of cryptographically secure bytes. Injected so tests can pin
    ///   the output; the app uses the system generator.
    static func begin(
        clientID: String, random: (Int) -> [UInt8] = SecureRandom.bytes
    ) -> Attempt? {
        guard let scheme = redirectScheme(clientID: clientID),
              let redirect = redirectURI(clientID: clientID)
        else { return nil }
        // RFC 7636: 32 random bytes, base64url, is a 43-character verifier.
        let verifier = Base64URL.encode(random(32))
        let state = Base64URL.encode(random(16))
        let challenge = Base64URL.encode(SHA256Digest.hash(Array(verifier.utf8)))
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Always offer the account chooser: a phone shared at a counter is the case where
            // silently reusing the last account is wrong.
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return Attempt(
            url: components.url!, callbackScheme: scheme, redirectURI: redirect,
            state: state, verifier: verifier)
    }

    enum Failure: Error, Equatable {
        /// The person closed the sheet or chose not to share their account.
        case declined
        /// The callback did not answer the request this app made — a replayed or forged link.
        case stateMismatch
        /// Google answered without a code, or with an error this app does not expect.
        case noCode
        /// The token exchange failed or returned no ID token.
        case noIDToken
    }

    /// Reads the authorisation code from Google's redirect back to the app.
    static func code(from callback: URL, for attempt: Attempt) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? Failure.declined : Failure.noCode
        }
        // Checked before the code is used: a callback for some other request must never sign
        // anyone in.
        guard value("state") == attempt.state else { throw Failure.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw Failure.noCode }
        return code
    }

    /// The token request: the code, the verifier that proves this app asked for it, and no
    /// secret.
    static func tokenRequest(code: String, attempt: Attempt, clientID: String) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            ("code", code), ("client_id", clientID), ("redirect_uri", attempt.redirectURI),
            ("grant_type", "authorization_code"), ("code_verifier", attempt.verifier),
        ]
        request.httpBody = Data(fields.map { "\($0)=\(formEncode($1))" }.joined(separator: "&").utf8)
        return request
    }

    /// The ID token from Google's token response.
    static func idToken(from data: Data) throws -> String {
        struct Response: Decodable { var id_token: String? }
        guard let token = (try? JSONDecoder().decode(Response.self, from: data))?.id_token,
              !token.isEmpty
        else { throw Failure.noIDToken }
        return token
    }

    /// Exchanges the code with Google, on a session that keeps no cookies.
    static func exchange(
        code: String, attempt: Attempt, clientID: String, session: URLSession? = nil
    ) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        APIClient.refuseCookies(configuration)
        let urlSession = session ?? URLSession(configuration: configuration)
        let (data, response) = try await urlSession.data(
            for: tokenRequest(code: code, attempt: attempt, clientID: clientID))
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true
        else { throw Failure.noIDToken }
        return try idToken(from: data)
    }

    /// `application/x-www-form-urlencoded`: unreserved characters as they are, everything else
    /// percent-encoded.
    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Cryptographically secure random bytes from the system generator (`arc4random_buf` on Apple
/// platforms, `getrandom` on Linux).
enum SecureRandom {
    static func bytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

/// base64url without padding (RFC 4648 §5), as PKCE and OAuth use it.
enum Base64URL {
    static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// SHA-256 (FIPS 180-4), in plain Swift.
///
/// The core is Foundation-only so that it builds and tests on Linux, where neither CryptoKit nor
/// CommonCrypto exists; PKCE needs exactly one hash, and this is it. Pinned against the RFC 7636
/// example and the FIPS test vectors in `SocialSignInTests`.
enum SHA256Digest {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var bytes = message
        let bitLength = UInt64(message.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j + 1]) << 16
                    | UInt32(bytes[j + 2]) << 8 | UInt32(bytes[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - $0 * 8)) } }
    }
}
