import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Per-route conventions that fail **silently** against this backend.
///
/// Each of these is a rule where getting it wrong produces no error at all — a hang, a
/// scrambled file, or a request that quietly addresses the wrong thing. That is exactly the
/// class of bug a wire test earns its keep on.
final class ServiceWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeClient(authenticated: Bool = true) async -> APIClient {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        if authenticated {
            await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        }
        return client
    }

    // MARK: - /view-file's folder convention

    /// `folderName` is **required** and an empty one is a 400, so a file at the storage root
    /// must send `"."` — that is how these routes spell "the root" (`safeFolderPath`,
    /// sync-server.js:293). Sending `"_"` instead addresses a directory that does not exist,
    /// which is the bug that once broke root-level files server-side.
    func testRootLevelFileAsksForTheDotFolder() async throws {
        let client = await makeClient()
        HTTPStub.always(.text("%PDF-1.4"))
        let files = FileService(client: client)

        _ = try await files.fileData(name: "Notes.txt", folderName: nil)

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.queryItems["folderName"], ".")
        XCTAssertEqual(sent.queryItems["fileName"], "Notes.txt")
    }

    func testAnEmptyFolderIsAlsoSentAsDot() async throws {
        let client = await makeClient()
        HTTPStub.always(.text("%PDF-1.4"))
        let files = FileService(client: client)

        _ = try await files.fileData(name: "Notes.txt", folderName: "")

        XCTAssertEqual(HTTPStub.lastRequest?.queryItems["folderName"], ".")
    }

    func testANestedFileSendsItsRealFolder() async throws {
        let client = await makeClient()
        HTTPStub.always(.text("%PDF-1.4"))
        let files = FileService(client: client)

        _ = try await files.fileData(name: "Sale_Deed.pdf", folderName: "Partition_Suit")

        XCTAssertEqual(HTTPStub.lastRequest?.queryItems["folderName"], "Partition_Suit")
    }

    /// This route answers with a bare text body rather than the JSON envelope, so a 404 has to
    /// be translated here or the user gets a decoding error about a document that was deleted.
    func testAMissingDocumentGetsAReadableMessage() async {
        let client = await makeClient()
        HTTPStub.always(.text("Not found", status: 404))
        let files = FileService(client: client)

        do {
            _ = try await files.fileData(name: "Gone.pdf", folderName: nil)
            XCTFail("expected a server error")
        } catch let error as APIError {
            XCTAssertEqual(
                error, .server(status: 404,
                               message: "That document is no longer in your library."))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Upload chunking

    /// **`chunkSize` must always be sent.** With it the server writes each chunk at an absolute
    /// offset and order stops mattering; without it it falls back to append-mode
    /// (sync-server.js:6842-6846), which silently scrambles the file and still answers 200.
    func testEveryChunkCarriesItsChunkSize() async throws {
        let client = await makeClient()
        HTTPStub.respond { request in
            request.path.hasSuffix("/upload-status")
                ? .json(#"{"status":"ready"}"#)
                : .json(#"{"success":true}"#)
        }
        let uploads = UploadService(client: client)

        // Three chunks of 4 bytes each.
        let payload = Data("ABCDEFGHIJKL".utf8)
        for try await _ in uploads.upload(
            data: payload, fileName: "Scan.pdf", folderName: "Scans", chunkSize: 4) {}

        let chunkRequests = HTTPStub.seen.filter { $0.path.hasSuffix("/upload-chunk") }
        XCTAssertEqual(chunkRequests.count, 3)
        for request in chunkRequests {
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"chunkSize\""), "chunkSize field must be present")
            XCTAssertTrue(body.contains("\r\n\r\n4\r\n"), "and must carry the real value")
        }
    }

    /// The file part is ignored unless it carries a `filename` parameter.
    func testTheFilePartIsNamed() async throws {
        let client = await makeClient()
        HTTPStub.respond { request in
            request.path.hasSuffix("/upload-status")
                ? .json(#"{"status":"ready"}"#)
                : .json(#"{"success":true}"#)
        }
        let uploads = UploadService(client: client)

        for try await _ in uploads.upload(
            data: Data("x".utf8), fileName: "Scan.pdf", folderName: "Scans") {}

        let chunk = try XCTUnwrap(HTTPStub.seen.first { $0.path.hasSuffix("/upload-chunk") })
        let body = String(decoding: chunk.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="file"; filename="Scan.pdf""#))
    }

    /// A 200 on the final chunk means "bytes received", not "file ready" — assembly,
    /// verification and ingestion all happen after the response closes. Polling is mandatory.
    func testUploadPollsIngestionAfterTheLastChunk() async throws {
        let client = await makeClient()
        HTTPStub.respond { request in
            request.path.hasSuffix("/upload-status")
                ? .json(#"{"status":"ready"}"#)
                : .json(#"{"success":true}"#)
        }
        let uploads = UploadService(client: client)

        var finished: IngestState?
        for try await event in uploads.upload(
            data: Data("x".utf8), fileName: "Scan.pdf", folderName: "Scans") {
            if case .finished(let state) = event { finished = state }
        }

        XCTAssertEqual(finished, .ready)
        XCTAssertTrue(
            HTTPStub.seen.contains { $0.path.hasSuffix("/upload-status") },
            "the upload is only half the job")
    }

    /// Status polls must use the **sanitised** name, because the server re-sanitises before
    /// resolving the path. Polling with the original silently never resolves, and the upload
    /// appears to hang forever rather than failing.
    func testIngestionPollsUseTheSanitisedName() async throws {
        let client = await makeClient()
        HTTPStub.respond { request in
            request.path.hasSuffix("/upload-status")
                ? .json(#"{"status":"ready"}"#)
                : .json(#"{"success":true}"#)
        }
        let uploads = UploadService(client: client)

        for try await _ in uploads.upload(
            data: Data("x".utf8), fileName: "देखिए.pdf", folderName: "Scans") {}

        let poll = try XCTUnwrap(HTTPStub.seen.last { $0.path.hasSuffix("/upload-status") })
        XCTAssertEqual(
            poll.queryItems["fileName"], UploadService.sanitize(fileName: "देखिए.pdf"))
        XCTAssertNotEqual(poll.queryItems["fileName"], "देखिए.pdf")
    }

    /// An ingestion failure arrives with no HTTP error at all — only as an `ERROR:` string.
    func testIngestionFailureIsReportedFromTheStatusBody() async throws {
        let client = await makeClient()
        HTTPStub.respond { request in
            request.path.hasSuffix("/upload-status")
                ? .json(#"{"status":"ERROR: could not read this document"}"#)
                : .json(#"{"success":true}"#)
        }
        let uploads = UploadService(client: client)

        var finished: IngestState?
        for try await event in uploads.upload(
            data: Data("x".utf8), fileName: "Scan.pdf", folderName: "Scans") {
            if case .finished(let state) = event { finished = state }
        }

        XCTAssertEqual(finished, .failed("ERROR: could not read this document"))
    }

    // MARK: - Auth

    func testLoginPostsCredentialsWithoutRequiringAToken() async throws {
        let client = await makeClient(authenticated: false)
        HTTPStub.always(.json(#"{"success":true,"token":"t","user":{"id":7,"email":"a@b.c"}}"#))
        let auth = AuthService(client: client)

        let response = try await auth.login(email: "a@b.c", password: "pw")

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/login")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertNil(sent.header("Authorization"), "sign-in has no token yet")
        XCTAssertEqual(sent.bodyJSON["email"] as? String, "a@b.c")
        XCTAssertEqual(sent.bodyJSON["password"] as? String, "pw")
        XCTAssertEqual(response.user.id, 7)
    }

    /// Wrong password and unknown email both answer 401; the server deliberately does not
    /// distinguish them, and neither should the message.
    func testBadCredentialsSurfaceAsOneMessage() async {
        let client = await makeClient(authenticated: false)
        HTTPStub.always(.json(#"{"error":"Invalid credentials"}"#, status: 401))
        let auth = AuthService(client: client)

        do {
            _ = try await auth.login(email: "a@b.c", password: "wrong")
            XCTFail("expected .invalidCredentials")
        } catch let error as APIError {
            XCTAssertEqual(error, .invalidCredentials)
            XCTAssertEqual(error.errorDescription, "That email and password did not match.")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testRegisterPostsTheName() async throws {
        let client = await makeClient(authenticated: false)
        HTTPStub.always(.json(#"{"success":true,"token":"t","user":{"id":8}}"#))
        let auth = AuthService(client: client)

        _ = try await auth.register(name: "R. Iyer", email: "r@x.in", password: "pw")

        XCTAssertEqual(HTTPStub.lastRequest?.bodyJSON["name"] as? String, "R. Iyer")
    }

    /// Signing out is local — there is no logout route — so it must not hit the network, and
    /// must leave the client unable to make an authenticated request.
    func testSignOutIsPurelyLocal() async throws {
        let client = await makeClient()
        let auth = AuthService(client: client)

        await auth.signOut()

        XCTAssertTrue(HTTPStub.seen.isEmpty, "there is no logout endpoint to call")
        let credentials = await client.currentCredentials()
        XCTAssertNil(credentials)
    }

    // MARK: - Chat history

    /// The in-flight checkpoint row is a live partial, not a finished turn.
    func testTypingRowsAreFilteredOutOfHistory() async throws {
        let client = await makeClient()
        HTTPStub.always(.json("""
            {"success":true,"messages":[
              {"role":"user","content":"Question"},
              {"role":"assistant","content":"partial","isTyping":true}
            ]}
            """))
        let chats = ChatService(client: client)

        let messages = try await chats.messages(chatID: "c-1")

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .user)
    }

    /// `/stream-status` answers **200 for errors** — it writes the head before validating
    /// anything (sync-server.js:13007). Branching on the HTTP status makes a forbidden chat
    /// look idle and finished.
    func testStreamStatusErrorsArriveInsideA200() async throws {
        let client = await makeClient()
        HTTPStub.always(.json(#"{"active":false,"error":"Forbidden"}"#, status: 200))
        let chats = ChatService(client: client)

        let status = try await chats.streamStatus(chatID: "c-1")

        XCTAssertEqual(status.error, "Forbidden")
        XCTAssertFalse(status.active)
    }
}
