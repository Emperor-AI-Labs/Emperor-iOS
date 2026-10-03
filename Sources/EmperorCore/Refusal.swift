import Foundation

/// A refusal the server explains with a machine-readable `code`, rather than an error.
///
/// The platform answers some requests with a sentence *and* a code — `{"error": "...", "code":
/// "QUERY_LIMIT", ...}` — and the code is the part a client may rely on. The sentence is written
/// for a browser and will be reworded; the platform says as much about its own markers
/// (`sync-server.js`, the comment on `BUSY_STATUS_TAG`).
///
/// Two families share this shape:
///
/// - **Signing in** — an account that signs in with Google has no usable password, a new account
///   has not confirmed its email, an address is already registered, a one-time code is wrong.
///   Each needs a *different next step* on the sign-in screen, which is why they are recognised
///   rather than shown as text.
/// - **Using the product** — the platform now meters plans, and refuses new work outside one.
///   These are worded by this client, not the server: see `DisplayText.message(for:)`.
///
/// Only codes this client knows become a `Refusal`. An unknown code falls through to the ordinary
/// server error with the server's own sentence, because replacing a message we cannot interpret
/// with a guess would be worse than showing it.
struct Refusal: Equatable, Sendable {

    enum Code: String, Sendable, CaseIterable {
        // Signing in.
        /// 409 from `/login`: the account was created through a provider and has no password.
        case providerAccount = "SSO_ACCOUNT"
        /// 403 from `/login`: a password account that has not confirmed its email address.
        case emailUnverified = "EMAIL_UNVERIFIED"
        /// 409 from `/register`: a password account already holds this address.
        case accountExists = "EXISTS"
        /// 401 from `/auth/otp/verify`: wrong, expired or exhausted code. The server's reason is
        /// specific ("That code has expired. Request a new one.") and is shown as written.
        case invalidCode = "OTP_INVALID"

        // Using the product.
        /// 402: the account has no plan, so new AI work and uploads are refused.
        case planRequired = "PLAN_REQUIRED"
        /// 402: this month's chat queries are spent. Carries `limit`, `used` and `resetsAt`.
        case queryLimit = "QUERY_LIMIT"
        /// 402: a feature outside this account's plan.
        case featureNotInPlan = "FEATURE_NOT_IN_PLAN"
        /// 402: this month's document uploads are spent.
        case documentLimit = "DOCUMENT_LIMIT"
        /// 413: the account's storage is full.
        case storageLimit = "STORAGE_LIMIT"
        /// 402: the plan tracks a fixed number of matters and they are all in use.
        case matterLimit = "MATTER_LIMIT"
        /// 402: this month's scanned pages are spent.
        case scanLimit = "SCAN_LIMIT"
        /// 403: an administrator has paused the account. Reading still works.
        case accountSuspended = "ACCOUNT_SUSPENDED"
        /// 429: more requests in an hour than anyone sends by hand.
        case rateLimit = "RATE_LIMIT"
    }

    var code: Code
    var status: Int
    /// The server's own sentence. Kept for diagnosis; **shown** only where `DisplayText` says so.
    var serverMessage: String
    /// For `.providerAccount`: which provider the account signs in with ("google").
    var provider: String?
    /// For sign-in refusals: the address the server matched, as it stores it.
    var email: String?
    /// For `.queryLimit`: the month's allowance, how much of it is used, and when it renews.
    var limit: Int?
    var used: Int?
    var resetsAt: Date?

    /// Whether this is about the account's plan or standing, rather than about signing in.
    var concernsThePlan: Bool {
        switch code {
        case .providerAccount, .emailUnverified, .accountExists, .invalidCode: return false
        default: return true
        }
    }

    /// Whether waiting and trying again can succeed without anything changing on the account.
    /// Only the hourly ceiling clears by itself on a timescale worth offering a retry for.
    var clearsByItself: Bool { code == .rateLimit }

    /// Recognises a refusal in an error response, or returns nil.
    static func parse(status: Int, body: Data) -> Refusal? {
        guard let decoded = try? JSONDecoder().decode(Body.self, from: body),
              let raw = decoded.code, let code = Code(rawValue: raw)
        else { return nil }
        return Refusal(
            code: code,
            status: status,
            serverMessage: decoded.error ?? decoded.message ?? "",
            provider: decoded.provider,
            email: decoded.email,
            limit: decoded.limit,
            used: decoded.used,
            resetsAt: WireDate.parse(decoded.resetsAt))
    }

    /// The error envelope with the optional fields refusals carry. Every field is optional and
    /// decoded leniently: a refusal whose extras are malformed is still a refusal.
    private struct Body: Decodable {
        var error: String?
        var message: String?
        var code: String?
        var provider: String?
        var email: String?
        var limit: Int?
        var used: Int?
        var resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case error, message, code, provider, email, limit, used, resetsAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            error = try? c.decodeIfPresent(String.self, forKey: .error)
            message = try? c.decodeIfPresent(String.self, forKey: .message)
            code = try? c.decodeIfPresent(String.self, forKey: .code)
            provider = try? c.decodeIfPresent(String.self, forKey: .provider)
            email = try? c.decodeIfPresent(String.self, forKey: .email)
            limit = Self.integer(c, .limit)
            used = Self.integer(c, .used)
            resetsAt = try? c.decodeIfPresent(String.self, forKey: .resetsAt)
        }

        /// Counts arrive as JSON numbers, which a JavaScript server may write as `30` or `30.0`.
        private static func integer(
            _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) -> Int? {
            if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
            if let value = try? c.decodeIfPresent(Double.self, forKey: key), value.isFinite {
                return Int(value)
            }
            return nil
        }
    }
}
