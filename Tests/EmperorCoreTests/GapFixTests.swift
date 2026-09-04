import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The four first-day failures found by measuring the app against the live platform.
final class GapFixTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeClient(authenticated: Bool = true) async -> APIClient {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        if authenticated {
            await client.setCredentials(Credentials(token: "tok", userID: 42))
        }
        return client
    }

    // MARK: - Maintenance

    /// A planned outage answered 503 with the operator's message, and the app rendered
    /// "Could not load" — so every user saw what looked like a bug.
    func testMaintenanceIsRecognisedAndCarriesTheOperatorsMessage() async {
        let client = await makeClient()
        HTTPStub.always(.json("""
            {"maintenance":true,"error":"Service temporarily unavailable for maintenance.",
             "message":"Back at 18:00 IST — we are migrating the case index.",
             "since":"2026-08-26T09:00:00.000Z"}
            """, status: 503))

        do {
            let request = try await client.makeRequest("GET", "/cases")
            _ = try await client.send(request, as: CaseListResponse.self)
            XCTFail("expected .maintenance")
        } catch let error as APIError {
            XCTAssertEqual(
                error,
                .maintenance(message: "Back at 18:00 IST — we are migrating the case index."))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMaintenanceIsItsOwnFailureKindAndIsRetryable() {
        let failure = LoadFailure(APIError.maintenance(message: "Back shortly."))
        XCTAssertEqual(failure.kind, .maintenance)
        XCTAssertEqual(failure.message, "Back shortly.")
        XCTAssertTrue(failure.isRetryable, "an outage is finite — unlike an expired session")
        XCTAssertFalse(LoadState.failed(failure).requiresReauthentication)
    }

    /// A 503 that is *not* a maintenance body must stay an ordinary server error, or a real
    /// outage of the upstream would be mislabelled as planned.
    func testAPlain503IsNotMistakenForMaintenance() async {
        let client = await makeClient()
        HTTPStub.always(.json(#"{"error":"upstream unavailable"}"#, status: 503))

        do {
            let request = try await client.makeRequest("GET", "/cases")
            _ = try await client.send(request, as: CaseListResponse.self)
            XCTFail("expected a server error")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 503, message: "upstream unavailable"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Expired session

    /// `requiresReauthentication` was computed and read by nothing, so an expired 30-day token
    /// left every screen dead with no way back except deleting the app.
    func testA401SignsTheUserOut() async {
        let store = InMemoryCredentialStore([
            "auth.token": "tok",
            "auth.user": String(decoding: try! JSONEncoder().encode(User(id: 42)), as: UTF8.self),
        ])
        await withSignedInSession(store) { session in
            XCTAssertEqual(session.state, .signedIn(User(id: 42)))

            HTTPStub.always(.json(#"{"error":"Invalid credentials"}"#, status: 401))
            _ = try? await session.chats.chats()

            // The handler hops to the main actor, so give it a turn to land.
            for _ in 0..<200 where session.state != .signedOut {
                try? await Task.sleep(for: .milliseconds(5))
            }

            XCTAssertEqual(session.state, .signedOut, "an expired token must lead somewhere")
            XCTAssertNil(store.string(for: "auth.token"), "and the spent token is discarded")
        }
    }

    /// A 500 is not an authentication problem and must not sign anyone out.
    func testAnOrdinaryFailureDoesNotSignTheUserOut() async {
        let store = InMemoryCredentialStore([
            "auth.token": "tok",
            "auth.user": String(decoding: try! JSONEncoder().encode(User(id: 42)), as: UTF8.self),
        ])
        await withSignedInSession(store) { session in
            HTTPStub.always(.json(#"{"error":"Database is locked"}"#, status: 500))
            _ = try? await session.chats.chats()
            try? await Task.sleep(for: .milliseconds(50))

            XCTAssertEqual(session.state, .signedIn(User(id: 42)))
        }
    }

    // MARK: - Password reset

    func testRequestingAResetPostsTheLowercasedEmailWithoutAToken() async throws {
        let client = await makeClient(authenticated: false)
        HTTPStub.always(.json(#"{"success":true}"#))
        let auth = AuthService(client: client)

        try await auth.requestPasswordReset(email: "  R.Iyer@Example.TEST ")

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/forgot-password")
        XCTAssertEqual(sent.bodyJSON["email"] as? String, "r.iyer@example.test")
        XCTAssertNil(sent.header("Authorization"), "you are locked out — there is no token")
    }

    /// The route answers 200 for an unknown address on purpose, so it never leaks which emails
    /// exist. The confirmation therefore cannot claim an account was found.
    func testTheConfirmationNeverClaimsTheAccountExists() {
        let notice = Session.passwordResetNotice.lowercased()
        XCTAssertTrue(notice.contains("if an account exists"))
        XCTAssertFalse(notice.contains("we found"))
        XCTAssertFalse(notice.contains("check your inbox"), "SMTP may not be configured at all")
        XCTAssertTrue(
            notice.contains("administrator"),
            "accounts are created for you — there is no self-signup to fall back on")
        XCTAssertTrue(notice.contains("browser"), "the reset link is a web URL")
    }

    // MARK: - Upload from Files

    /// The camera was the only path into the DMS, so a PDF in Files could not be asked about.
    func testADocumentFromFilesReachesTheLibrary() async {
        await withLibrary { files, uploads, model in
            uploads.events = [.finished(.ready)]
            files.tree = [folder("Uploads", [.file(readyFile("Uploads/Order.pdf"))])]

            await model.upload(data: Data("%PDF-1.4".utf8), fileName: "Order.pdf")

            XCTAssertEqual(uploads.uploadedNames, ["Order.pdf"])
            XCTAssertEqual(uploads.uploadedFolders, [FileLibraryViewModel.uploadFolder])
            XCTAssertEqual(model.files.count, 1, "and the library is re-read once it is readable")
            XCTAssertNil(model.uploadError)
        }
    }

    /// Ingestion failures arrive with no HTTP error at all — only as an `ERROR:` status.
    func testAnIngestionFailureIsSurfacedAndTheLibraryIsNotReRead() async {
        await withLibrary { files, uploads, model in
            uploads.events = [.finished(.failed("ERROR: could not read this document"))]

            await model.upload(data: Data("%PDF".utf8), fileName: "Order.pdf")

            XCTAssertEqual(model.uploadError, "ERROR: could not read this document")
            XCTAssertEqual(files.treeCallCount, 0)
        }
    }

    /// A file still ingesting when the stream ends is not in the library yet.
    func testAFileStillIngestingDoesNotClaimSuccess() async {
        await withLibrary { files, uploads, model in
            uploads.events = [.progress(sent: 10, total: 10), .processing("Extracting text")]

            await model.upload(data: Data("%PDF".utf8), fileName: "Order.pdf")

            XCTAssertNil(model.uploadError, "still working is not a failure")
            XCTAssertEqual(files.treeCallCount, 0)
            XCTAssertFalse(model.isUploading)
        }
    }

    func testAConcurrentUploadIsIgnoredRatherThanInterleaved() async {
        await withLibrary { _, uploads, model in
            uploads.events = [.finished(.ready)]
            async let first: Void = model.upload(data: Data("a".utf8), fileName: "A.pdf")
            async let second: Void = model.upload(data: Data("b".utf8), fileName: "B.pdf")
            _ = await (first, second)

            XCTAssertLessThanOrEqual(uploads.uploadedNames.count, 2)
        }
    }
}

@MainActor
private func withSignedInSession(
    _ store: InMemoryCredentialStore,
    _ body: @MainActor (Session) async -> Void
) async {
    let session = Session(
        config: APIConfig(baseURL: URL(string: "https://example.test/api")!),
        store: store,
        cache: ResponseCache(store: InMemoryCacheStore()),
        urlSession: HTTPStub.session())
    await session.restore()
    await body(session)
}

@MainActor
private func withLibrary(
    _ body: @MainActor (FakeFiles, FakeUploads, FileLibraryViewModel) async -> Void
) async {
    let files = FakeFiles()
    let uploads = FakeUploads()
    await body(files, uploads, FileLibraryViewModel(service: files, uploads: uploads))
}
