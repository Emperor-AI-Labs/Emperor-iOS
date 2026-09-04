import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What actually goes on the wire.
///
/// This layer had no tests at all before: `APIClient` accepted an injectable `URLSession` that
/// nothing injected. Request construction is where a client silently talks past a server —
/// a missing `userId`, a `"_"` where the API wants `"."` — and none of it fails loudly.
final class APIClientTests: XCTestCase {

    private static let config = APIConfig(
        baseURL: URL(string: "https://example.test/api")!)
    private static let credentials = Credentials(token: "tok-abc", userID: 42)

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeClient(authenticated: Bool = true) async -> APIClient {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        if authenticated { await client.setCredentials(Self.credentials) }
        return client
    }

    // MARK: - Identity

    /// The client sends **both** credentials deliberately. The bearer token is enforced on
    /// almost nothing today; everything else selects on a client-supplied `userId`. Sending
    /// both is what lets the app keep working unchanged once the backend is hardened.
    func testGetRequestsCarryBothTheTokenAndTheUserId() async throws {
        let client = await makeClient()
        HTTPStub.always(.json(#"{"success":true,"chats":[]}"#))

        let request = try await client.makeRequest("GET", "/chats")
        _ = try await client.send(request, as: ChatListResponse.self)

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.header("Authorization"), "Bearer tok-abc")
        XCTAssertEqual(sent.header("X-Auth-Token"), "tok-abc")
        XCTAssertEqual(sent.queryItems["userId"], "42")
        XCTAssertEqual(sent.path, "/api/chats")
        XCTAssertEqual(sent.httpMethod, "GET")
    }

    /// A POST carries identity in its body, built by the caller — so the query string must not
    /// also acquire one. Duplicating it is harmless today but hides which source the server used.
    func testPostRequestsDoNotPutTheUserIdInTheQueryString() async throws {
        let client = await makeClient()
        let request = try await client.makeRequest("POST", "/chat")

        XCTAssertNil(request.queryItems["userId"])
        XCTAssertEqual(request.header("Authorization"), "Bearer tok-abc")
    }

    func testDeleteCarriesTheUserIdLikeAGet() async throws {
        let client = await makeClient()
        let request = try await client.makeRequest("DELETE", "/case", query: ["caseId": "c-1"])

        XCTAssertEqual(request.queryItems["userId"], "42")
        XCTAssertEqual(request.queryItems["caseId"], "c-1")
    }

    /// Signing in has no credentials yet, so the auth routes must opt out rather than throw.
    func testUnauthenticatedRoutesAreAllowedWithoutCredentials() async throws {
        let client = await makeClient(authenticated: false)
        let request = try await client.makeRequest("POST", "/login", requiresAuth: false)

        XCTAssertNil(request.header("Authorization"))
        XCTAssertEqual(request.path, "/api/login")
    }

    func testAuthenticatedRouteWithoutCredentialsThrows() async {
        let client = await makeClient(authenticated: false)
        do {
            _ = try await client.makeRequest("GET", "/chats")
            XCTFail("expected .notAuthenticated")
        } catch let error as APIError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// The base URL already ends in `/api`; a path with a leading slash must not produce `//`.
    func testPathsComposeWithoutDoubledSeparators() async throws {
        let client = await makeClient()
        let withSlash = try await client.makeRequest("GET", "/user-files")
        let withoutSlash = try await client.makeRequest("GET", "user-files")

        XCTAssertEqual(withSlash.path, "/api/user-files")
        XCTAssertEqual(withoutSlash.path, "/api/user-files")
    }

    // MARK: - Error conventions

    /// 401 is the one status this API uses consistently.
    func testUnauthorizedMapsToInvalidCredentials() async {
        let client = await makeClient()
        HTTPStub.always(.json(#"{"error":"Invalid credentials"}"#, status: 401))

        await assertThrows(.invalidCredentials) {
            let request = try await client.makeRequest("GET", "/chats")
            _ = try await client.send(request, as: ChatListResponse.self)
        }
    }

    /// Most routes answer a missing parameter with a 500 carrying an `error` key. That message
    /// is written for this product and is what the user should read.
    func testServerErrorUsesTheBodysMessageNotTheStatus() async {
        let client = await makeClient()
        HTTPStub.always(.json(#"{"error":"Missing parameters"}"#, status: 500))

        await assertThrows(.server(status: 500, message: "Missing parameters")) {
            let request = try await client.makeRequest("GET", "/upload-status")
            _ = try await client.send(request, as: UploadStatusResponse.self)
        }
    }

    /// Some routes answer with a bare body and no envelope. The user still needs a sentence.
    func testErrorWithoutAnEnvelopeStillProducesAMessage() async {
        let client = await makeClient()
        HTTPStub.always(.text("Internal Server Error", status: 500))

        await assertThrows(.server(status: 500, message: "The server returned status 500.")) {
            let request = try await client.makeRequest("GET", "/chats")
            _ = try await client.send(request, as: ChatListResponse.self)
        }
    }

    func testMalformedJSONSurfacesAsADecodingError() async {
        let client = await makeClient()
        HTTPStub.always(.json("{not json at all"))

        do {
            let request = try await client.makeRequest("GET", "/chats")
            _ = try await client.send(request, as: ChatListResponse.self)
            XCTFail("expected .decoding")
        } catch let error as APIError {
            guard case .decoding = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTransportFailureIsWrapped() async {
        let client = await makeClient()
        HTTPStub.fail(URLError(.notConnectedToInternet))

        do {
            let request = try await client.makeRequest("GET", "/chats")
            _ = try await client.send(request, as: ChatListResponse.self)
            XCTFail("expected .transport")
        } catch let error as APIError {
            guard case .transport = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// A 2xx is taken at face value — which is correct here, because several routes signal
    /// failure inside a 200 body and each call site handles that itself.
    func testSuccessDecodes() async throws {
        let client = await makeClient()
        HTTPStub.always(.json(#"{"success":true,"chats":[{"id":"c-1","title":"Partition suit"}]}"#))

        let request = try await client.makeRequest("GET", "/chats")
        let response = try await client.send(request, as: ChatListResponse.self)

        XCTAssertEqual(response.chats.count, 1)
        XCTAssertEqual(response.chats.first?.displayTitle, "Partition suit")
    }

    // MARK: - Helper

    private func assertThrows(
        _ expected: APIError,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as APIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
    }
}
