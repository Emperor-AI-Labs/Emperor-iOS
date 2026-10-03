import XCTest
@testable import EmperorCore

/// Every way into the app, driven with no server.
///
/// The bodies the fake throws are the platform's own (`sync-server.js` — `/login`, `/register`,
/// `/auth/otp/verify`), so each test is a sentence the real server can actually say.
@MainActor
final class SignInFlowTests: XCTestCase {

    // MARK: - Fake

    final class FakeAuth: AuthProviding, @unchecked Sendable {
        var loginResult: Result<AuthResponse, Error> = .failure(APIError.invalidCredentials)
        var registerResult: Result<Registration, Error> = .success(.confirmationSent(email: "a@b.in"))
        var verifyResult: Result<AuthResponse, Error> = .failure(APIError.invalidCredentials)
        var codeMinutes: Int? = 10
        private(set) var calls: [String] = []

        func login(email: String, password: String) async throws -> AuthResponse {
            calls.append("login \(email)"); return try loginResult.get()
        }
        var socialResult: Result<AuthResponse, Error> = .failure(APIError.invalidCredentials)
        func register(
            name: String, email: String, password: String, phone: String?
        ) async throws -> Registration {
            calls.append("register \(name) \(email)" + (phone.map { " \($0)" } ?? ""))
            return try registerResult.get()
        }
        func signInWithGoogle(idToken: String) async throws -> AuthResponse {
            calls.append("google \(idToken)"); return try socialResult.get()
        }
        func signInWithApple(idToken: String, name: String?) async throws -> AuthResponse {
            calls.append("apple \(idToken) \(name ?? "-")"); return try socialResult.get()
        }
        func resendVerification(email: String) async throws { calls.append("resend \(email)") }
        func requestCode(email: String) async throws -> CodeRequest {
            calls.append("code \(email)"); return CodeRequest(expiresInMinutes: codeMinutes)
        }
        func verifyCode(email: String, code: String) async throws -> AuthResponse {
            calls.append("verify \(email) \(code)"); return try verifyResult.get()
        }
        func requestPasswordReset(email: String) async throws { calls.append("reset \(email)") }
    }

    private static let user = User(id: 7, email: "a@b.in", name: "A. Advocate")
    private static let signedIn = AuthResponse(success: true, user: user, token: "tok")

    private var clock = Date(timeIntervalSince1970: 1_790_000_000)

    private func make(_ auth: FakeAuth) -> (SignInFlow, () -> [AuthResponse]) {
        var adopted: [AuthResponse] = []
        let flow = SignInFlow(auth: auth, now: { [unowned self] in self.clock })
        flow.onSignedIn = { adopted.append($0) }
        return (flow, { adopted })
    }

    private func refused(_ json: String, status: Int) -> Error {
        APIError.classify(status: status, body: Data(json.utf8))
    }

    // MARK: - Creating an account

    /// The break this exists for: the server creates the account, sends a confirmation email and
    /// returns no token. The old flow expected a token and reported "unexpected response" about
    /// an account it had just made.
    func testCreatingAnAccountLeadsToTheInboxNotToAnError() async {
        let auth = FakeAuth()
        let (flow, adopted) = make(auth)
        flow.show(.createAccount)
        flow.name = "A. Advocate"; flow.email = " a@b.in "; flow.password = "longenough"
        flow.confirmPassword = "longenough"

        await flow.createAccount()

        XCTAssertEqual(flow.step, .checkInbox(email: "a@b.in"))
        XCTAssertNil(flow.error)
        XCTAssertTrue(adopted().isEmpty, "nobody is signed in until the address is confirmed")
        XCTAssertEqual(flow.password, "", "the password does not linger on a screen it left")
        XCTAssertEqual(auth.calls, ["register A. Advocate a@b.in"])
    }

    /// A server that predates confirmation still signs the new account straight in.
    func testAnOlderServerThatSignsInStraightAwayIsStillHonoured() async {
        let auth = FakeAuth()
        auth.registerResult = .success(.signedIn(Self.signedIn))
        let (flow, adopted) = make(auth)
        flow.show(.createAccount)
        flow.name = "A"; flow.email = "a@b.in"; flow.password = "longenough"; flow.confirmPassword = "longenough"
        await flow.createAccount()
        XCTAssertEqual(adopted(), [Self.signedIn])
    }

    /// Said before submitting, not discovered after: the server refuses fewer than eight.
    func testAShortPasswordIsCaughtBeforeTheServerSeesIt() async {
        let auth = FakeAuth()
        let (flow, _) = make(auth)
        flow.show(.createAccount)
        flow.name = "A"; flow.email = "a@b.in"; flow.password = "seven77"
        XCTAssertFalse(flow.canCreateAccount)
        XCTAssertEqual(flow.passwordHint, "1 more character — at least 8 in all.")
        await flow.createAccount()
        XCTAssertTrue(auth.calls.isEmpty)

        flow.password = "eight888"
        XCTAssertFalse(flow.canCreateAccount, "the confirmation is required, as on the web")
        flow.confirmPassword = "eight888"
        XCTAssertTrue(flow.canCreateAccount)
        XCTAssertNil(flow.passwordHint)
    }

    func testAnExistingAccountSendsThePersonToSignInWithTheAddressKept() async {
        let auth = FakeAuth()
        auth.registerResult = .failure(refused(
            #"{"error":"An account with this email already exists. Try signing in instead.","code":"EXISTS"}"#,
            status: 409))
        let (flow, _) = make(auth)
        flow.show(.createAccount)
        flow.name = "A"; flow.email = "a@b.in"; flow.password = "longenough"; flow.confirmPassword = "longenough"
        await flow.createAccount()
        XCTAssertEqual(flow.step, .signIn)
        XCTAssertEqual(flow.email, "a@b.in")
        XCTAssertEqual(flow.error, "An account with this email already exists. Sign in instead.")
    }

    // MARK: - The web's sign-up fields

    /// Name, email, password and its confirmation are required, as on the web; a mismatch is
    /// said on submit in the web's words, and nothing is sent.
    func testMismatchedPasswordsAreCaughtInTheWebsWords() async {
        let auth = FakeAuth()
        let (flow, _) = make(auth)
        flow.show(.createAccount)
        flow.name = "John Doe"; flow.email = "name@firm.com"
        flow.password = "longenough"; flow.confirmPassword = "longenoug"
        XCTAssertTrue(flow.canCreateAccount)
        await flow.createAccount()
        XCTAssertEqual(flow.error, "Passwords do not match")
        XCTAssertTrue(auth.calls.isEmpty)
    }

    /// The mobile number is optional; when given it must be a complete Indian mobile, and it is
    /// sent in the form the platform stores.
    func testAMobileNumberIsOptionalAndSentInternationally() async {
        let auth = FakeAuth()
        let (flow, _) = make(auth)
        flow.show(.createAccount)
        flow.name = "John Doe"; flow.email = "name@firm.com"
        flow.password = "longenough"; flow.confirmPassword = "longenough"
        XCTAssertTrue(flow.canCreateAccount, "no number at all is fine")

        flow.setPhone("+91 98765 4")
        XCTAssertFalse(flow.canCreateAccount, "a half-typed number is not")
        XCTAssertEqual(flow.phoneHint, "4 more digits.")

        flow.setPhone("+91 98765 43210")
        XCTAssertEqual(flow.phoneDisplay, "98765 43210")
        XCTAssertNil(flow.phoneHint)
        await flow.createAccount()
        XCTAssertEqual(auth.calls, ["register John Doe name@firm.com +919876543210"])
    }

    func testANumberThatCannotBeAMobileSaysWhy() {
        let flow = SignInFlow(auth: FakeAuth())
        flow.show(.createAccount)
        flow.setPhone("5876543210")
        XCTAssertEqual(flow.phoneHint, "An Indian mobile number starts with 6, 7, 8 or 9.")
    }

    // MARK: - Google and Apple

    func testAGoogleTokenSignsIn() async {
        let auth = FakeAuth()
        auth.socialResult = .success(Self.signedIn)
        let (flow, adopted) = make(auth)
        await flow.completeGoogle(idToken: "g.jwt")
        XCTAssertEqual(adopted(), [Self.signedIn])
        XCTAssertEqual(auth.calls, ["google g.jwt"])
    }

    /// Apple shares the name only on the very first authorisation; a blank one is not sent.
    func testAppleSendsTheNameOnlyWhenThereIsOne() async {
        let auth = FakeAuth()
        auth.socialResult = .success(Self.signedIn)
        let (flow, _) = make(auth)
        await flow.completeApple(idToken: "a.jwt", name: "  ")
        await flow.completeApple(idToken: "a.jwt", name: " John Doe ")
        XCTAssertEqual(auth.calls, ["apple a.jwt -", "apple a.jwt John Doe"])
    }

    /// Before the platform has the route, the button would meet a bare 404 — said plainly.
    func testAMissingRouteSaysTheProviderIsNotAvailableYet() async {
        let auth = FakeAuth()
        auth.socialResult = .failure(APIError.classify(status: 404, body: Data()))
        let (flow, _) = make(auth)
        await flow.completeGoogle(idToken: "g.jwt")
        XCTAssertEqual(flow.error, "Signing in with Google isn't available yet. Use your email instead.")
    }

    func testClosingTheProvidersSheetIsNotAnError() {
        let flow = SignInFlow(auth: FakeAuth())
        flow.socialSignInFailed(provider: "Google", declined: true)
        XCTAssertNil(flow.error)
        flow.socialSignInFailed(provider: "Google", declined: false)
        XCTAssertEqual(flow.error, "Signing in with Google didn't finish. Please try again.")
    }

    // MARK: - Signing in

    func testASuccessfulSignInIsHandedToTheSession() async {
        let auth = FakeAuth()
        auth.loginResult = .success(Self.signedIn)
        let (flow, adopted) = make(auth)
        flow.email = "a@b.in"; flow.password = "pw"
        await flow.signIn()
        XCTAssertEqual(adopted(), [Self.signedIn])
        XCTAssertEqual(flow.password, "")
    }

    /// An account made through Google has no password. "Invalid credentials" would leave the
    /// person typing passwords that can never work; the way in is a one-time code.
    func testAGoogleAccountIsOfferedACodeInsteadOfAPasswordError() async {
        let auth = FakeAuth()
        auth.loginResult = .failure(refused(
            #"{"error":"This account signs in with Google. Continue with Google, or we can email you a one-time code.","code":"SSO_ACCOUNT","provider":"google","canUseOtp":true}"#,
            status: 409))
        let (flow, _) = make(auth)
        flow.email = "a@b.in"; flow.password = "anything"
        await flow.signIn()
        XCTAssertTrue(flow.offersCode)
        XCTAssertEqual(flow.step, .signIn)
        XCTAssertEqual(
            flow.error,
            "This account signs in with Google, so it has no password here. We can email you a one-time code instead.")
    }

    func testAnUnconfirmedAccountIsTakenToItsInbox() async {
        let auth = FakeAuth()
        auth.loginResult = .failure(refused(
            #"{"error":"Please confirm your email address first — check your inbox for the link we sent.","code":"EMAIL_UNVERIFIED","email":"a@b.in"}"#,
            status: 403))
        let (flow, adopted) = make(auth)
        flow.email = "A@B.in"; flow.password = "right"
        await flow.signIn()
        XCTAssertEqual(flow.step, .checkInbox(email: "a@b.in"), "the server's stored form of the address")
        XCTAssertNotNil(flow.notice)
        XCTAssertNil(flow.error)
        XCTAssertTrue(adopted().isEmpty)
    }

    /// A wrong password is still the plain sentence it always was — and it must not end anything.
    func testAWrongPasswordReadsAsAWrongPassword() async {
        let auth = FakeAuth()
        let (flow, _) = make(auth)
        flow.email = "a@b.in"; flow.password = "wrong"
        await flow.signIn()
        XCTAssertEqual(flow.error, "That email and password did not match.")
        XCTAssertEqual(flow.step, .signIn)
    }

    func testTheServersEmailRuleIsTheScreensEmailRule() {
        for good in ["a@b.in", "first.last@chambers.co.in", "x@y.z", "a@b.c.", "  a@b.in  "] {
            XCTAssertTrue(SignInFlow.isPlausibleEmail(good), good)
        }
        for bad in ["", "a@b", "@b.in", "a@.in", "a b@c.in", "a@b@c.in", "a@b.", "plain"] {
            XCTAssertFalse(SignInFlow.isPlausibleEmail(bad), bad)
        }
    }

    // MARK: - One-time codes

    func testACodeSignsInAndIsDigitsOnly() async {
        let auth = FakeAuth()
        auth.verifyResult = .success(Self.signedIn)
        let (flow, adopted) = make(auth)
        flow.email = "a@b.in"
        await flow.requestCode()
        XCTAssertEqual(flow.step, .enterCode(email: "a@b.in"))
        XCTAssertEqual(flow.notice, "We've emailed a 6-digit code to a@b.in. It works for 10 minutes.")

        flow.setCode("48 29-13 7")
        XCTAssertEqual(flow.code, "482913", "pasted with spaces and a dash, kept as six digits")
        await flow.verifyCode()
        XCTAssertEqual(adopted(), [Self.signedIn])
        XCTAssertEqual(auth.calls.last, "verify a@b.in 482913")
    }

    func testAnIncompleteCodeIsNotSent() async {
        let auth = FakeAuth()
        let (flow, _) = make(auth)
        flow.email = "a@b.in"
        await flow.requestCode()
        flow.setCode("123")
        XCTAssertFalse(flow.canVerifyCode)
        await flow.verifyCode()
        XCTAssertFalse(auth.calls.contains { $0.hasPrefix("verify") })
    }

    /// A wrong code is a 401 that has nothing to do with the session, and is cleared so the next
    /// attempt does not resubmit the same digits.
    func testAWrongCodeIsExplainedAndCleared() async {
        let auth = FakeAuth()
        auth.verifyResult = .failure(refused(
            #"{"error":"That code has expired. Request a new one.","code":"OTP_INVALID"}"#, status: 401))
        let (flow, adopted) = make(auth)
        flow.email = "a@b.in"
        await flow.requestCode()
        flow.setCode("111111")
        await flow.verifyCode()
        XCTAssertEqual(flow.error, "That code has expired. Ask for a new one.")
        XCTAssertEqual(flow.code, "")
        XCTAssertTrue(adopted().isEmpty)
        XCTAssertEqual(flow.step, .enterCode(email: "a@b.in"))
    }

    /// The server sends nothing past three codes in fifteen minutes and still answers 200. The
    /// screen paces requests so it never promises a code that is not coming.
    func testCodesArePacedToWhatTheServerWillActuallySend() async {
        let auth = FakeAuth()
        let (flow, _) = make(auth)
        flow.email = "a@b.in"

        await flow.requestCode()
        // Too soon for a second email.
        await flow.requestCode()
        XCTAssertEqual(auth.calls.filter { $0.hasPrefix("code") }.count, 1)
        XCTAssertEqual(flow.error, "Wait 30 seconds before asking for another email.")

        clock += 31; await flow.requestCode()
        clock += 31; await flow.requestCode()
        XCTAssertEqual(auth.calls.filter { $0.hasPrefix("code") }.count, 3)

        // A fourth inside the window would "succeed" on the server and send nothing.
        clock += 31; await flow.requestCode()
        XCTAssertEqual(auth.calls.filter { $0.hasPrefix("code") }.count, 3)
        XCTAssertTrue(flow.error?.hasPrefix("Several emails have gone to this address already.") ?? false)

        // Once the first falls out of the window, another may go.
        clock += 15 * 60; await flow.requestCode()
        XCTAssertEqual(auth.calls.filter { $0.hasPrefix("code") }.count, 4)
    }

    /// The inbox step's two ways forward: send the email again, or use a code instead — the
    /// code confirms the address too, without a trip through a browser.
    func testTheInboxOffersResendAndACode() async {
        let auth = FakeAuth()
        let (flow, _) = make(auth)
        flow.show(.createAccount)
        flow.name = "A"; flow.email = "a@b.in"; flow.password = "longenough"; flow.confirmPassword = "longenough"
        await flow.createAccount()

        await flow.resendConfirmation()
        XCTAssertFalse(auth.calls.contains("resend a@b.in"), "the first email went seconds ago")

        clock += 31
        await flow.resendConfirmation()
        XCTAssertTrue(auth.calls.contains("resend a@b.in"))
        XCTAssertNotNil(flow.notice)

        clock += 31
        await flow.requestCode()
        XCTAssertEqual(flow.step, .enterCode(email: "a@b.in"))
    }

    func testBackKeepsTheAddressAndDropsTheRest() async {
        let auth = FakeAuth()
        let (flow, _) = make(auth)
        flow.email = "a@b.in"
        await flow.requestCode()
        flow.setCode("12")
        flow.backToSignIn()
        XCTAssertEqual(flow.step, .signIn)
        XCTAssertEqual(flow.email, "a@b.in")
        XCTAssertEqual(flow.code, "")
    }

    /// After signing out the next person to hold the phone sees an empty form.
    func testResetForgetsEverything() {
        let flow = SignInFlow(auth: FakeAuth())
        flow.name = "A"; flow.email = "a@b.in"; flow.password = "pw"
        flow.reset()
        XCTAssertEqual([flow.name, flow.email, flow.password, flow.code], ["", "", "", ""])
        XCTAssertEqual(flow.step, .signIn)
    }

    // MARK: - Password reset

    func testAResetLinkNeedsAnAddressAndConfirmsUnconditionally() async {
        let auth = FakeAuth()
        let (flow, _) = make(auth)
        await flow.requestPasswordReset(email: "not an address")
        XCTAssertFalse(flow.passwordResetSent)
        XCTAssertNotNil(flow.error)

        await flow.requestPasswordReset(email: " a@b.in ")
        XCTAssertTrue(flow.passwordResetSent)
        XCTAssertEqual(auth.calls.last, "reset a@b.in")
    }
}
