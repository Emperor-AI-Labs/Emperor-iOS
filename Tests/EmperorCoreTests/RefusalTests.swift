import XCTest
@testable import EmperorCore

/// Refusals the server explains with a code: recognised, classified and worded by this client.
///
/// Bodies here are copied from the platform's own handlers (`sync-server.js` — the paywall gate,
/// the chat allowance check, `/login`, `/auth/otp/verify`), not invented.
final class RefusalTests: XCTestCase {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Recognition

    func testAQueryLimitCarriesItsCountsAndRenewal() throws {
        let refusal = try XCTUnwrap(Refusal.parse(status: 402, body: body("""
            {"error":"You've used all 1,000 chat queries on your Premium plan this month. Upgrade to keep going, or your queries reset on 1 Nov.","code":"QUERY_LIMIT","limit":1000,"used":1000,"resetsAt":"2026-10-31T18:30:00.000Z"}
            """)))
        XCTAssertEqual(refusal.code, .queryLimit)
        XCTAssertEqual(refusal.status, 402)
        XCTAssertEqual(refusal.limit, 1000)
        XCTAssertEqual(refusal.used, 1000)
        XCTAssertEqual(refusal.resetsAt.map(WireDate.dayKey), "2026-11-01",
                       "the month turns over at midnight in India")
        XCTAssertTrue(refusal.concernsThePlan)
    }

    func testTheSignInRefusalsAreRecognised() {
        let provider = Refusal.parse(status: 409, body: body(
            #"{"error":"This account signs in with Google. Continue with Google, or we can email you a one-time code.","code":"SSO_ACCOUNT","provider":"google","canUseOtp":true}"#))
        XCTAssertEqual(provider?.code, .providerAccount)
        XCTAssertEqual(provider?.provider, "google")
        XCTAssertEqual(provider?.concernsThePlan, false)

        let unverified = Refusal.parse(status: 403, body: body(
            #"{"error":"Please confirm your email address first — check your inbox for the link we sent.","code":"EMAIL_UNVERIFIED","email":"a@b.in"}"#))
        XCTAssertEqual(unverified?.code, .emailUnverified)
        XCTAssertEqual(unverified?.email, "a@b.in")
    }

    /// An unknown code must not become a refusal: replacing a sentence we cannot interpret with a
    /// guess is worse than showing the server's own.
    func testAnUnknownCodeIsNotARefusal() {
        XCTAssertNil(Refusal.parse(status: 402, body: body(#"{"error":"x","code":"SOMETHING_NEW"}"#)))
        XCTAssertNil(Refusal.parse(status: 500, body: body(#"{"error":"Missing userId"}"#)))
        XCTAssertNil(Refusal.parse(status: 400, body: body("not json")))
    }

    /// Extras that arrive malformed must not cost the refusal itself.
    func testMalformedExtrasDoNotLoseTheRefusal() {
        let refusal = Refusal.parse(status: 402, body: body(
            #"{"code":"QUERY_LIMIT","limit":"lots","used":30.0,"resetsAt":12}"#))
        XCTAssertEqual(refusal?.code, .queryLimit)
        XCTAssertNil(refusal?.limit)
        XCTAssertEqual(refusal?.used, 30)
        XCTAssertNil(refusal?.resetsAt)
    }

    // MARK: - Classification

    /// A wrong one-time code is a 401 that says nothing about the session. Reading it as
    /// "signed out" would end a session that is fine — so the code is read first.
    func testACodedFourOhOneIsARefusalNotASignOut() {
        let error = APIError.classify(status: 401, body: body(
            #"{"error":"That code is not correct.","code":"OTP_INVALID"}"#))
        XCTAssertEqual(error.refusal?.code, .invalidCode)
        XCTAssertNotEqual(error, .invalidCredentials)
    }

    func testAnUncodedFourOhOneIsStillTheEndOfTheSession() {
        XCTAssertEqual(
            APIError.classify(status: 401, body: body(#"{"error":"Invalid credentials"}"#)),
            .invalidCredentials)
    }

    func testAnUncodedFailureKeepsTheServersSentence() {
        XCTAssertEqual(
            APIError.classify(status: 500, body: body(#"{"error":"Missing userId"}"#)),
            .server(status: 500, message: "Missing userId"))
        XCTAssertEqual(
            APIError.classify(status: 502, body: Data()),
            .server(status: 502, message: "The server returned status 502."))
    }

    /// The client answers a refusal with silence, not three retries that count against the
    /// hourly ceiling.
    func testARefusalIsNeverRetried() {
        let refusal = Refusal(code: .rateLimit, status: 429, serverMessage: "")
        XCTAssertFalse(RetryPolicy.default.shouldRetry(APIError.refused(refusal)))
    }

    /// "Try again" is offered only for the refusal that lifts by itself.
    func testOnlyTheHourlyCeilingOffersTryAgain() {
        let planRequired = LoadFailure(APIError.refused(
            Refusal(code: .planRequired, status: 402, serverMessage: "")))
        XCTAssertEqual(planRequired.kind, .refused)
        XCTAssertFalse(planRequired.isRetryable)
        XCTAssertEqual(planRequired.refusal?.code, .planRequired)

        let rate = LoadFailure(APIError.refused(
            Refusal(code: .rateLimit, status: 429, serverMessage: "")))
        XCTAssertTrue(rate.isRetryable)
    }

    // MARK: - Wording

    /// **The App Store rule.** This app takes no money, so no plan refusal may tell the reader to
    /// upgrade, buy or visit a pricing page — even though every server sentence for these codes
    /// does exactly that.
    func testNoPlanRefusalTellsTheReaderToBuyAnything() {
        let banned = ["upgrade", "buy", "purchase", "pricing", "subscribe", "plans page",
                      "choose a plan", "₹", "price"]
        for code in Refusal.Code.allCases {
            let refusal = Refusal(
                code: code, status: 402,
                serverMessage: "Upgrade your plan to keep going.",
                provider: "google", limit: 1000, used: 1000,
                resetsAt: WireDate.parse("2026-10-31T18:30:00.000Z"))
            let text = DisplayText.message(for: refusal).lowercased()
            for word in banned {
                XCTAssertFalse(text.contains(word), "\(code): \"\(text)\" contains \"\(word)\"")
            }
            XCTAssertFalse(DisplayText.title(for: refusal).isEmpty, "\(code) has no title")
        }
    }

    func testAQueryLimitSaysHowManyAndWhenTheyRenew() {
        let refusal = Refusal(
            code: .queryLimit, status: 402, serverMessage: "", limit: 1000, used: 1000,
            resetsAt: WireDate.parse("2026-10-31T18:30:00.000Z"))
        XCTAssertEqual(
            DisplayText.message(for: refusal),
            "This account has used all 1,000 of this month's questions. They renew on 1 November.")
    }

    /// Without the extras it still says something true rather than printing "nil".
    func testAQueryLimitWithoutItsExtrasStillReads() {
        let refusal = Refusal(code: .queryLimit, status: 402, serverMessage: "")
        XCTAssertEqual(
            DisplayText.message(for: refusal), "This account has used this month's questions.")
    }

    /// The server is the only one that knows *why* a code failed, so its reason is read — each
    /// of the four reasons `authFlows.verifyOtp` can give gets its own sentence.
    func testAWrongCodeSaysWhyItFailed() {
        func say(_ reason: String) -> String {
            DisplayText.message(for: Refusal(code: .invalidCode, status: 401, serverMessage: reason))
        }
        XCTAssertEqual(say("That code has expired. Request a new one."),
                       "That code has expired. Ask for a new one.")
        XCTAssertEqual(say("Too many attempts. Request a new code."),
                       "Too many attempts with that code. Ask for a new one.")
        XCTAssertEqual(say("Request a new code."),
                       "That code can't be used any more. Ask for a new one.")
        XCTAssertEqual(say("That code is not correct."),
                       "That code is not correct. Check it, or ask for a new one.")
    }

    /// Error text reaches every screen through `DisplayText.message(for: Error)`, so the refusal
    /// wording has to arrive there too, not only where a screen asks for it by name.
    func testTheGenericErrorPathUsesTheRefusalWording() {
        let error = APIError.refused(Refusal(code: .storageLimit, status: 413, serverMessage: "Upgrade"))
        XCTAssertEqual(
            DisplayText.message(for: error),
            "This account's storage is full, so this document wasn't uploaded.")
    }

    func testCountsAreGroupedTheIndianWay() {
        XCTAssertEqual(DisplayText.grouped(30), "30")
        XCTAssertEqual(DisplayText.grouped(1000), "1,000")
        XCTAssertEqual(DisplayText.grouped(30000), "30,000")
        XCTAssertEqual(DisplayText.grouped(100000), "1,00,000")
        XCTAssertEqual(DisplayText.grouped(12345678), "1,23,45,678")
    }
}

/// What the background uploader does with each chunk's answer.
final class ChunkOutcomeTests: XCTestCase {

    private func outcome(_ status: Int?, _ body: String = "", failed: Bool = false) -> ChunkOutcome {
        ChunkOutcome.classify(transportFailed: failed, status: status, body: Data(body.utf8))
    }

    func testDeliveredAndTheNetworksFailuresAreAsBefore() {
        XCTAssertEqual(outcome(200, #"{"success":true}"#), .delivered)
        XCTAssertEqual(outcome(nil, failed: true), .retryLater)
        XCTAssertEqual(outcome(503), .retryLater)
        XCTAssertEqual(outcome(408), .retryLater)
        XCTAssertEqual(outcome(401, #"{"error":"Your session has expired — please sign in again"}"#), .retryLater)
    }

    /// The bug this exists for: a refused upload used to be re-sent on every launch, forever.
    func testAPlanRefusalStopsTheUploadAndSaysWhy() {
        XCTAssertEqual(
            outcome(413, #"{"error":"Your 10 GB of storage is full. Upgrade your plan or delete files to upload more.","code":"STORAGE_LIMIT"}"#),
            .refused(message: "This account's storage is full, so this document wasn't uploaded."))
        guard case .refused(let message) = outcome(402, #"{"error":"Choose a plan to start using Emperor AI.","code":"PLAN_REQUIRED"}"#) else {
            return XCTFail("a paywalled upload must stop")
        }
        XCTAssertFalse(message.lowercased().contains("plan to start"), "worded by the client")
    }

    func testTheHourlyCeilingIsWaitedOut() {
        XCTAssertEqual(outcome(429, #"{"error":"…","code":"RATE_LIMIT"}"#), .retryLater)
    }

    /// An uncoded refusal keeps the server's own sentence, which for the per-file cap is the
    /// useful one: it names the limit.
    func testAnUncodedRefusalIsFinalAndKeepsItsSentence() {
        XCTAssertEqual(
            outcome(413, #"{"error":"File too large: exceeds the 500 MB per-file limit."}"#),
            .refused(message: "File too large: exceeds the 500 MB per-file limit."))
        XCTAssertEqual(
            outcome(400, "not json"),
            .refused(message: "The server would not accept this document (status 400)."))
    }
}
