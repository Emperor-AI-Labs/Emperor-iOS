import XCTest
@testable import EmperorCore

/// The parts of Google and Apple sign-in that can be checked without a provider: when the
/// buttons may appear, and the PKCE handshake byte for byte.
final class SocialSignInTests: XCTestCase {

    private let clientID = "1234-abcd.apps.googleusercontent.com"

    // MARK: - When the buttons appear

    func testNothingIsOfferedUntilTheBuildSaysSo() {
        XCTAssertFalse(SocialSignInConfig.disabled.offersAny)
        let unexpanded = SocialSignInConfig(info: [
            "EmperorSocialSignIn": "$(EMPEROR_SOCIAL_SIGN_IN)",
            "EmperorGoogleClientID": "$(EMPEROR_GOOGLE_CLIENT_ID)",
        ])
        XCTAssertFalse(unexpanded.offersAny, "an unexpanded build setting is not a yes")
        XCTAssertFalse(SocialSignInConfig(info: [
            "EmperorSocialSignIn": "NO", "EmperorGoogleClientID": clientID,
        ]).offersAny)
    }

    /// Guideline 4.8: Google only ever alongside Apple; Apple alone is allowed.
    func testGoogleNeverAppearsWithoutApple() {
        let both = SocialSignInConfig(info: ["EmperorSocialSignIn": "YES", "EmperorGoogleClientID": clientID])
        XCTAssertTrue(both.offersGoogle)
        XCTAssertTrue(both.offersApple)

        let appleOnly = SocialSignInConfig(info: ["EmperorSocialSignIn": true])
        XCTAssertTrue(appleOnly.offersApple)
        XCTAssertFalse(appleOnly.offersGoogle, "no client id, no Google")

        let badID = SocialSignInConfig(info: ["EmperorSocialSignIn": "YES", "EmperorGoogleClientID": "web-client-id"])
        XCTAssertFalse(badID.offersGoogle, "only an iOS client id has a redirect scheme")
    }

    // MARK: - SHA-256 and PKCE

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// FIPS 180-4 test vectors, including the two-block one.
    func testSHA256MatchesTheStandard() {
        XCTAssertEqual(hex(SHA256Digest.hash([])),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(SHA256Digest.hash(Array("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            hex(SHA256Digest.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(hex(SHA256Digest.hash(Array(repeating: 0x61, count: 1000))),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    /// RFC 7636 appendix B — the PKCE example, end to end.
    func testThePKCEChallengeIsTheRFCsExample() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            Base64URL.encode(SHA256Digest.hash(Array(verifier.utf8))),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    // MARK: - The handshake

    func testTheRedirectIsTheReversedClientID() {
        XCTAssertEqual(GoogleOAuth.redirectScheme(clientID: clientID), "com.googleusercontent.apps.1234-abcd")
        XCTAssertEqual(GoogleOAuth.redirectURI(clientID: clientID), "com.googleusercontent.apps.1234-abcd:/oauth2redirect")
        XCTAssertNil(GoogleOAuth.redirectScheme(clientID: "x.example.com"))
    }

    func testTheRequestAsksForAnIDTokenWithAChallenge() throws {
        var counter: UInt8 = 0
        let attempt = try XCTUnwrap(GoogleOAuth.begin(clientID: clientID) { n in
            defer { counter &+= 1 }
            return Array(repeating: counter, count: n)
        })
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(
            url: attempt.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["scope"], "openid email profile")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], attempt.state)
        XCTAssertEqual(items["code_challenge"],
                       Base64URL.encode(SHA256Digest.hash(Array(attempt.verifier.utf8))))
        XCTAssertEqual(attempt.verifier.count, 43, "RFC 7636: 32 random bytes, base64url")
        XCTAssertNotEqual(attempt.verifier, attempt.state)
        XCTAssertNil(items["client_secret"], "an iOS client has no secret")
    }

    func testOnlyTheCallbackForThisRequestIsAccepted() throws {
        let attempt = try XCTUnwrap(GoogleOAuth.begin(clientID: clientID))
        let ok = URL(string: "com.googleusercontent.apps.1234-abcd:/oauth2redirect?state=\(attempt.state)&code=4/abc")!
        XCTAssertEqual(try GoogleOAuth.code(from: ok, for: attempt), "4/abc")

        let forged = URL(string: "com.googleusercontent.apps.1234-abcd:/oauth2redirect?state=other&code=4/abc")!
        XCTAssertThrowsError(try GoogleOAuth.code(from: forged, for: attempt)) {
            XCTAssertEqual($0 as? GoogleOAuth.Failure, .stateMismatch)
        }
        let denied = URL(string: "com.googleusercontent.apps.1234-abcd:/oauth2redirect?error=access_denied&state=\(attempt.state)")!
        XCTAssertThrowsError(try GoogleOAuth.code(from: denied, for: attempt)) {
            XCTAssertEqual($0 as? GoogleOAuth.Failure, .declined)
        }
    }

    func testTheTokenRequestProvesTheVerifier() throws {
        let attempt = try XCTUnwrap(GoogleOAuth.begin(clientID: clientID))
        let request = GoogleOAuth.tokenRequest(code: "4/abc", attempt: attempt, clientID: clientID)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertEqual(request.url, GoogleOAuth.tokenEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(body.contains("code=4%2Fabc"))
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code_verifier=\(attempt.verifier)"))
        XCTAssertFalse(body.contains("client_secret"))
    }

    func testTheIDTokenIsReadOrRefused() {
        XCTAssertEqual(try GoogleOAuth.idToken(from: Data(#"{"id_token":"a.b.c","access_token":"x"}"#.utf8)), "a.b.c")
        XCTAssertThrowsError(try GoogleOAuth.idToken(from: Data(#"{"error":"invalid_grant"}"#.utf8)))
    }
}
