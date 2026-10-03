import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Everything the sign-in screen does, as a state machine that runs without a device.
///
/// Signing in used to be one form. The platform has since grown four more ways in and out of
/// it, each of which needs its own next step rather than an error message:
///
/// - **Creating an account** no longer signs anyone in. The server emails a confirmation link and
///   returns no token, so the old flow — which expected one — failed with "unexpected response"
///   on an account it had in fact just created.
/// - **An account made through Google** has no password. `/login` says so with `SSO_ACCOUNT`, and
///   the way in from a phone is a one-time code.
/// - **An unconfirmed account** is refused at `/login` until the address is confirmed.
/// - **A one-time code** both signs in and confirms the address (`/auth/otp/verify` sets
///   `email_verified`), which makes it the quickest way out of the two states above — a
///   confirmation link opens a web page, and a code does not.
///
/// The screen lays out `step`; everything else — validation, pacing, wording — is here.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class SignInFlow {

    enum Step: Equatable, Sendable {
        case signIn
        case createAccount
        /// A confirmation email is on its way to this address.
        case checkInbox(email: String)
        /// A one-time code has been sent to this address and is being typed in.
        case enterCode(email: String)
    }

    // MARK: - State the screen binds to

    private(set) var step: Step = .signIn
    var name = ""
    var email = ""
    var password = ""
    /// Creating an account asks for the password twice, as the web's form does.
    var confirmPassword = ""
    /// Ten digits at most, kept local while typing — see `setPhone`. Optional.
    private(set) var phone = ""

    /// Which providers the sign-in screen may offer. Off unless the build is configured — see
    /// `SocialSignInConfig`.
    var social: SocialSignInConfig = .disabled
    /// Digits only, at most six — see `setCode`.
    private(set) var code = ""

    private(set) var isWorking = false
    /// What went wrong, in words for the person signing in.
    private(set) var error: String?
    /// Something worth saying that is not a failure: "We've sent a code to …".
    private(set) var notice: String?
    /// Whether to offer "Email me a sign-in code" on the sign-in step — after the server has
    /// said this account has no password, or on request.
    private(set) var offersCode = false

    /// Set when a reset link has been asked for; the sheet shows the confirmation.
    private(set) var passwordResetSent = false

    // MARK: - Rules

    /// The server's own test (`/register`): `^[^@\s]+@[^@\s]+\.[^@\s]+$`. The same pattern,
    /// not a stricter or looser one of our own, so the screen never accepts an address the server
    /// will refuse and never refuses one it would accept.
    nonisolated static func isPlausibleEmail(_ raw: String) -> Bool {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(email.startIndex..., in: email)
        return emailPattern.firstMatch(in: email, options: [], range: range) != nil
    }

    nonisolated(unsafe) private static let emailPattern = try! NSRegularExpression(
        pattern: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: [])

    /// The platform's minimum (`/register`): eight characters.
    nonisolated static let minimumPasswordLength = 8

    /// Six digits (`authFlows.issueOtp`).
    nonisolated static let codeLength = 6

    /// How long before "Send again" is offered. Long enough for an email to arrive; short
    /// enough that someone whose code went to spam is not left staring at a disabled button.
    nonisolated static let resendDelay: TimeInterval = 30

    /// The server sends at most three codes to one address in fifteen minutes and answers
    /// alike past that (`recentOtpCount` in `/auth/otp/request`) — a fourth request "succeeds"
    /// and nothing arrives. Pacing it here is what keeps the screen from promising a code that
    /// is not coming.
    nonisolated static let codeWindow: TimeInterval = 15 * 60
    nonisolated static let codesPerWindow = 3

    // MARK: - Dependencies

    private let auth: any AuthProviding
    private let now: () -> Date
    /// Called with a successful sign-in. `Session` stores the credential and moves on.
    var onSignedIn: (@MainActor (AuthResponse) async -> Void)?

    private var codesSent: [String: [Date]] = [:]
    private(set) var lastSendAt: Date?

    init(auth: any AuthProviding, now: @escaping () -> Date = Date.init) {
        self.auth = auth
        self.now = now
    }

    // MARK: - Derived

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canSignIn: Bool {
        Self.isPlausibleEmail(email) && !password.isEmpty && !isWorking
    }

    /// Every field the web marks required — name, email, password and its confirmation — and a
    /// mobile number only if one was started. Whether the two passwords match is said on submit,
    /// in the web's words, rather than by a button that will not press.
    var canCreateAccount: Bool {
        !trimmedName.isEmpty && Self.isPlausibleEmail(email)
            && password.count >= Self.minimumPasswordLength && !confirmPassword.isEmpty
            && (phone.isEmpty || IndianMobile.isValid(phone)) && !isWorking
    }

    /// Under the mobile field: what is wrong with it, or nil when it is empty or complete.
    var phoneHint: String? {
        guard step == .createAccount, !phone.isEmpty, !IndianMobile.isValid(phone) else { return nil }
        if phone.count < 10 { return "\(10 - phone.count) more digit\(10 - phone.count == 1 ? "" : "s")." }
        return "An Indian mobile number starts with 6, 7, 8 or 9."
    }

    /// The field's display form, "98765 43210".
    var phoneDisplay: String { IndianMobile.local(phone) }

    var canVerifyCode: Bool { code.count == Self.codeLength && !isWorking }

    /// A hint under the password while creating an account — said before submitting rather than
    /// discovered after it.
    var passwordHint: String? {
        guard step == .createAccount, !password.isEmpty,
              password.count < Self.minimumPasswordLength
        else { return nil }
        let short = Self.minimumPasswordLength - password.count
        return "\(short) more character\(short == 1 ? "" : "s") — at least "
            + "\(Self.minimumPasswordLength) in all."
    }

    /// When another email may be asked for, or nil if one may be asked for now.
    func nextSendAllowed(for address: String) -> Date? {
        let key = address.lowercased()
        let current = now()
        let recent = (codesSent[key] ?? []).filter { current.timeIntervalSince($0) < Self.codeWindow }
        if recent.count >= Self.codesPerWindow, let oldest = recent.min() {
            return oldest.addingTimeInterval(Self.codeWindow)
        }
        if let last = lastSendAt, current.timeIntervalSince(last) < Self.resendDelay {
            return last.addingTimeInterval(Self.resendDelay)
        }
        return nil
    }

    // MARK: - Moving between steps

    func show(_ next: Step) {
        error = nil
        notice = nil
        if next == .signIn || next == .createAccount { code = "" }
        step = next
    }

    /// Back from a code or an inbox to signing in, keeping the address.
    func backToSignIn() {
        if case .enterCode(let address) = step { email = address }
        if case .checkInbox(let address) = step { email = address }
        password = ""
        show(.signIn)
    }

    /// Clears everything — after signing out, so the next person to hold the phone starts clean.
    func reset() {
        name = ""; email = ""; password = ""; confirmPassword = ""; phone = ""; code = ""
        error = nil; notice = nil; offersCode = false
        passwordResetSent = false
        step = .signIn
    }

    /// Keeps the ten local digits of whatever was typed or pasted — "+91 98765-43210" from a
    /// contact card included — by the platform's own rules (`IndianMobile`).
    func setPhone(_ raw: String) {
        phone = IndianMobile.normalize(raw)
    }

    /// Keeps only digits and at most six of them, so a code pasted from an email with spaces or
    /// a dash in it ("482 913") still works.
    func setCode(_ raw: String) {
        code = String(raw.filter(\.isNumber).prefix(Self.codeLength))
        if error != nil, code.count < Self.codeLength { error = nil }
    }

    // MARK: - Actions

    func signIn() async {
        guard canSignIn else { return }
        await run {
            let response = try await self.auth.login(email: self.trimmedEmail, password: self.password)
            await self.finish(response)
        } refused: { refusal in
            switch refusal.code {
            case .providerAccount:
                self.offersCode = true
                self.error = DisplayText.message(for: refusal)
            case .emailUnverified:
                self.offersCode = true
                self.step = .checkInbox(email: refusal.email ?? self.trimmedEmail)
                self.notice = "This address hasn't been confirmed yet. Open the link we sent, "
                    + "or sign in with a one-time code — that confirms it too."
            default:
                self.error = DisplayText.message(for: refusal)
            }
        }
    }

    func createAccount() async {
        guard canCreateAccount else { return }
        // The web's check and the web's words (`Register.jsx`).
        guard password == confirmPassword else {
            error = "Passwords do not match"
            return
        }
        let phone = phone.isEmpty ? nil : IndianMobile.international(phone)
        await run {
            let outcome = try await self.auth.register(
                name: self.trimmedName, email: self.trimmedEmail, password: self.password,
                phone: phone)
            switch outcome {
            case .signedIn(let response):
                await self.finish(response)
            case .confirmationSent(let address):
                self.password = ""
                self.confirmPassword = ""
                self.lastSendAt = self.now()
                self.step = .checkInbox(email: address)
                self.notice = nil
            }
        } refused: { refusal in
            switch refusal.code {
            case .accountExists:
                // The person has an account already: take them to it with the address kept.
                self.password = ""
                self.step = .signIn
                self.error = DisplayText.message(for: refusal)
            case .providerAccount:
                self.password = ""
                self.step = .signIn
                self.offersCode = true
                self.error = DisplayText.message(for: refusal)
            default:
                self.error = DisplayText.message(for: refusal)
            }
        }
    }

    /// Sends the confirmation email again, for the address on the inbox step.
    func resendConfirmation() async {
        guard case .checkInbox(let address) = step, nextSendAllowed(for: address) == nil else { return }
        await run {
            try await self.auth.resendVerification(email: address)
            self.lastSendAt = self.now()
            self.notice = "We've sent the confirmation email again to \(address). It can take a "
                + "minute to arrive — check spam if it doesn't."
        }
    }

    /// Emails a one-time code to the current address and moves to typing it in.
    func requestCode() async {
        let address: String
        switch step {
        case .checkInbox(let pending), .enterCode(let pending): address = pending
        default: address = trimmedEmail
        }
        guard Self.isPlausibleEmail(address) else {
            error = "Enter your email address first."
            return
        }
        if let wait = nextSendAllowed(for: address) {
            error = waitMessage(until: wait)
            return
        }
        await run {
            let request = try await self.auth.requestCode(email: address)
            let sentAt = self.now()
            self.codesSent[address.lowercased(), default: []].append(sentAt)
            self.lastSendAt = sentAt
            self.code = ""
            self.step = .enterCode(email: address)
            let minutes = request.expiresInMinutes.map { " It works for \($0) minutes." } ?? ""
            self.notice = "We've emailed a \(Self.codeLength)-digit code to \(address).\(minutes)"
        }
    }

    func verifyCode() async {
        guard case .enterCode(let address) = step, canVerifyCode else { return }
        await run {
            let response = try await self.auth.verifyCode(email: address, code: self.code)
            await self.finish(response)
        } refused: { refusal in
            self.error = DisplayText.message(for: refusal)
            // A code that cannot be used again is cleared, so the next attempt starts empty
            // rather than re-submitting the same six digits.
            self.code = ""
        }
    }

    // MARK: - Google and Apple

    /// Finishes a Google sign-in with the ID token Google returned.
    func completeGoogle(idToken: String) async {
        await run {
            let response = try await self.auth.signInWithGoogle(idToken: idToken)
            await self.finish(response)
        } refused: { refusal in
            self.error = DisplayText.message(for: refusal)
        }
        explainUnavailable(provider: "Google")
    }

    /// Finishes a Sign in with Apple, passing on the name Apple shares only the first time.
    func completeApple(idToken: String, name: String?) async {
        let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        await run {
            let response = try await self.auth.signInWithApple(
                idToken: idToken, name: cleaned?.isEmpty == false ? cleaned : nil)
            await self.finish(response)
        } refused: { refusal in
            self.error = DisplayText.message(for: refusal)
        }
        explainUnavailable(provider: "Apple")
    }

    /// The provider's own sheet failed or was closed. Closing it is a choice, not an error.
    func socialSignInFailed(provider: String, declined: Bool) {
        error = declined ? nil : "Signing in with \(provider) didn't finish. Please try again."
    }

    /// A 404 here means the platform has not grown the route yet. Said as such, rather than as
    /// "The server returned status 404."
    private func explainUnavailable(provider: String) {
        if let message = error, message.contains("status 404") || message == "Not found" {
            error = "Signing in with \(provider) isn't available yet. Use your email instead."
        }
    }

    func requestPasswordReset(email address: String) async {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleEmail(trimmed), !isWorking else {
            error = "Enter the email address you sign in with."
            return
        }
        await run {
            try await self.auth.requestPasswordReset(email: trimmed)
            self.passwordResetSent = true
        }
    }

    func clearPasswordReset() {
        passwordResetSent = false
        error = nil
    }

    /// The confirmation shown after asking for a reset link.
    ///
    /// Unconditional, because the route answers alike for an unknown address on purpose. The
    /// link opens in a browser, where the new password is set.
    nonisolated static let passwordResetNotice = """
        If an account exists for that address, a reset link is on its way. The link opens in \
        your browser, where you choose the new password.

        If nothing arrives in a few minutes, check your spam folder. An account that signs in \
        with Google has no password to reset — use a one-time code instead.
        """

    // MARK: - Plumbing

    private func finish(_ response: AuthResponse) async {
        password = ""
        code = ""
        notice = nil
        offersCode = false
        await onSignedIn?(response)
    }

    private func waitMessage(until date: Date) -> String {
        let seconds = max(1, Int(date.timeIntervalSince(now()).rounded(.up)))
        if seconds < 90 {
            return "Wait \(seconds) seconds before asking for another email."
        }
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        return "Several emails have gone to this address already. Wait \(minutes) minutes "
            + "before asking for another — check spam for the ones already sent."
    }

    /// Runs one request with the working flag and error wording handled in one place.
    private func run(
        _ body: @MainActor () async throws -> Void,
        refused: (@MainActor (Refusal) -> Void)? = nil
    ) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await body()
        } catch let apiError as APIError {
            if let refusal = apiError.refusal, let refused {
                refused(refusal)
            } else if apiError == .invalidCredentials, case .enterCode = step {
                // A 401 with no code from `/auth/otp/verify` ("No such account.").
                error = "That code is not correct. Check it, or ask for a new one."
                code = ""
            } else {
                error = DisplayText.message(for: apiError)
            }
        } catch {
            self.error = DisplayText.message(for: error)
        }
    }
}
