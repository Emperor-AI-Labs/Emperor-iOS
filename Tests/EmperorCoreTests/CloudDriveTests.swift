import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

// MARK: - The wire

/// The six `/cloud/*` routes, as `src/lib/api.js` calls them and `sync-server.js` answers.
final class CloudDriveServiceTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService() async -> CloudDriveService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return CloudDriveService(client: client)
    }

    func testConnectionsReadEveryDriveInOrderWithTheIdentityInTheQuery() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"""
            {"success":true,"providers":{
              "microsoft":{"label":"OneDrive","configured":true,"connected":false,"email":null},
              "google":{"label":"Google Drive","configured":true,"connected":true,"email":"a@firm.in"}}}
            """#))

        let rows = try await service.connections()

        XCTAssertEqual(rows.map(\.drive), [.google, .microsoft])
        XCTAssertEqual(rows[0], CloudDriveConnection(
            drive: .google, label: "Google Drive", configured: true, connected: true, email: "a@firm.in"))
        XCTAssertEqual(rows[1].email, nil)
        XCTAssertFalse(rows[1].connected)
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.path, "/api/cloud/connections")
        XCTAssertEqual(sent.queryItems["userId"], "42")
        XCTAssertEqual(sent.header("Authorization"), "Bearer tok-abc")
    }

    /// An older server, or one that left a drive out: the drive is drawn, unconfigured, under its
    /// own name — never dropped, and never shown as connected.
    func testAMissingDriveReadsAsNotConfigured() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"providers":{"google":{"configured":true,"connected":false,"label":"  "}}}"#))

        let rows = try await service.connections()

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].label, "Google Drive")
        XCTAssertEqual(rows[1], CloudDriveConnection(
            drive: .microsoft, label: "OneDrive", configured: false, connected: false, email: nil))
    }

    func testConnectReturnsTheSignInPage() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"url":"https://accounts.google.com/o/oauth2/v2/auth?state=abc"}"#))

        let url = try await service.connectURL(for: .google)

        XCTAssertEqual(url.host, "accounts.google.com")
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/cloud/connect")
        XCTAssertEqual(sent.queryItems["provider"], "google")
        XCTAssertEqual(sent.queryItems["userId"], "42")
    }

    /// Only a web page is handed to a browser.
    func testAConnectAnswerThatIsNotAWebPageIsRefused() async throws {
        let service = await makeService()
        for body in [#"{"success":true}"#, #"{"success":true,"url":"javascript:alert(1)"}"#,
                     #"{"success":true,"url":"http://example.com/x"}"#] {
            HTTPStub.always(.json(body))
            do {
                _ = try await service.connectURL(for: .microsoft)
                XCTFail("accepted \(body)")
            } catch let error as APIError {
                guard case .decoding = error else { return XCTFail("\(error)") }
            }
        }
    }

    /// `/cloud/connect` answers a drive that is not set up with a 400 and a sentence.
    func testANotConfiguredDriveIsTheServersSentence() async throws {
        let service = await makeService()
        HTTPStub.always(.json(
            #"{"success":false,"error":"OneDrive is not configured on this server"}"#, status: 400))
        do {
            _ = try await service.connectURL(for: .microsoft)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(DisplayText.message(for: error), "OneDrive is not configured on this server")
        }
    }

    func testDisconnectPostsTheDriveAndTheUser() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true}"#))

        try await service.disconnect(.microsoft)

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.path, "/api/cloud/disconnect")
        XCTAssertEqual(sent.bodyJSON["userId"] as? String, "42")
        XCTAssertEqual(sent.bodyJSON["provider"] as? String, "microsoft")
    }

    func testExportSendsTheDocumentsFolderAndName() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"id":"f1","name":"Order.pdf","url":"https://drive.google.com/file/d/f1/view"}"#))

        let result = try await service.export(fileName: "Order.pdf", folderName: "Bakshi/Orders", to: .google)

        XCTAssertEqual(result.url, "https://drive.google.com/file/d/f1/view")
        let body = try XCTUnwrap(HTTPStub.lastRequest).bodyJSON
        XCTAssertEqual(body["userId"] as? String, "42")
        XCTAssertEqual(body["provider"] as? String, "google")
        XCTAssertEqual(body["folderName"] as? String, "Bakshi/Orders")
        XCTAssertEqual(body["fileName"] as? String, "Order.pdf")
        XCTAssertEqual(HTTPStub.lastRequest?.path, "/api/cloud/export")
    }

    /// The web sends `item.folderName || '.'`.
    func testATopLevelDocumentGoesAsDot() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"id":"f1"}"#))
        _ = try await service.export(fileName: "Loose.pdf", folderName: "", to: .microsoft)
        XCTAssertEqual(HTTPStub.lastRequest?.bodyJSON["folderName"] as? String, ".")
    }

    /// 409: not connected, or the drive gave narrower access. The sentence is the message.
    func testAnExportRefusalIsTheServersSentencePointedAtThisApp() async throws {
        let service = await makeService()
        HTTPStub.always(.json(
            #"{"success":false,"error":"Google Drive is not connected — connect it in Settings → Connected services"}"#,
            status: 409))
        do {
            _ = try await service.export(fileName: "a.pdf", folderName: "X", to: .google)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(
                CloudDriveWording.message(for: error),
                "Google Drive is not connected — connect it in You → Connected services")
        }
    }

    func testTheListIsTheDrivesFiles() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"""
            {"success":true,"files":[
              {"id":"g1","name":"Plaint.pdf","mime":"application/pdf","size":2411724,"modified":"2026-10-03T09:12:44.000Z"},
              {"id":"o1","name":"Notes.docx","mime":null,"size":0,"modified":null},
              {"id":"","name":"nothing"}]}
            """#))

        let files = try await service.files(in: .google)

        XCTAssertEqual(files.map(\.id), ["g1", "o1"])
        XCTAssertEqual(files[0].sizeLabel, "2.3 MB")
        XCTAssertNotNil(files[0].modifiedDate)
        XCTAssertNil(files[1].sizeLabel)
        XCTAssertNil(files[1].mime)
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/cloud/list")
        XCTAssertEqual(sent.queryItems["provider"], "google")
        XCTAssertEqual(sent.queryItems["userId"], "42")
    }

    func testImportSendsTheFileAndTheFolderAndReadsTheStoredName() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"fileName":"Plaint_1_.pdf","folderName":"Bakshi","size":2048}"#))

        let result = try await service.importFile(
            CloudDriveFile(id: "g1", name: "Plaint (1).pdf"), from: .google, into: "Bakshi")

        XCTAssertEqual(result.fileName, "Plaint_1_.pdf")
        XCTAssertEqual(result.size, 2048)
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/cloud/import")
        XCTAssertEqual(sent.bodyJSON["userId"] as? String, "42")
        XCTAssertEqual(sent.bodyJSON["provider"] as? String, "google")
        XCTAssertEqual(sent.bodyJSON["fileId"] as? String, "g1")
        XCTAssertEqual(sent.bodyJSON["fileName"] as? String, "Plaint (1).pdf")
        XCTAssertEqual(sent.bodyJSON["folderName"] as? String, "Bakshi")
    }

    /// The upload allowances answer an import too, coded — and are worded by this client.
    func testAPlanRefusalOnImportIsARefusal() async throws {
        let service = await makeService()
        HTTPStub.always(.json(
            #"{"success":false,"error":"Your 10 GB of storage is full. Upgrade your plan or delete files to upload more.","code":"STORAGE_LIMIT"}"#,
            status: 413))
        do {
            _ = try await service.importFile(CloudDriveFile(id: "g1", name: "a.pdf"), from: .google, into: "X")
            XCTFail("expected a refusal")
        } catch let error as APIError {
            XCTAssertEqual(error.refusal?.code, .storageLimit)
            XCTAssertFalse(DisplayText.message(for: error).contains("Upgrade"))
        }
    }

    /// The server's failure without a code, still `{success:false}` — a 200 is not trusted alone.
    func testASuccessFalseBodyIsAFailure() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":"Cloud file is empty"}"#))
        do {
            _ = try await service.importFile(CloudDriveFile(id: "g1", name: "a.pdf"), from: .google, into: "X")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(DisplayText.message(for: error), "Cloud file is empty")
        }
    }

    func testSignedOutSendsNothing() async throws {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        let service = CloudDriveService(client: client)
        HTTPStub.always(.json(#"{"success":true}"#))
        do {
            try await service.disconnect(.google)
            XCTFail("expected notAuthenticated")
        } catch let error as APIError {
            XCTAssertEqual(error, .notAuthenticated)
        }
        XCTAssertTrue(HTTPStub.seen.isEmpty)
    }
}

// MARK: - Pure pieces

final class CloudDriveWordingTests: XCTestCase {

    /// The four sentences `cloudTokReady` and the scope checks send, as this app should say them.
    func testTheServersSettingsPointsAtYou() {
        XCTAssertEqual(
            CloudDriveWording.forPhone("OneDrive is not connected — connect it in Settings → Connected services"),
            "OneDrive is not connected — connect it in You → Connected services")
        XCTAssertEqual(
            CloudDriveWording.forPhone("Google Drive session expired — please reconnect in Settings"),
            "Google Drive session expired — please reconnect under You → Connected services")
        XCTAssertEqual(
            CloudDriveWording.forPhone("Google Drive read access was not granted — Disconnect and reconnect Google Drive in Settings"),
            "Google Drive read access was not granted — Disconnect and reconnect Google Drive under You → Connected services")
        XCTAssertEqual(CloudDriveWording.forPhone("File not found"), "File not found")
        XCTAssertEqual(CloudDriveWording.forPhone("Settings are fine"), "Settings are fine")
    }

    /// The web's `fmtSize` (`MyFilesPage.jsx`): nothing for zero, then B, whole KB, MB to one place.
    func testSizesAreTheWebs() {
        XCTAssertNil(CloudDriveFile.sizeLabel(0))
        XCTAssertEqual(CloudDriveFile.sizeLabel(1), "1 B")
        XCTAssertEqual(CloudDriveFile.sizeLabel(1023), "1023 B")
        XCTAssertEqual(CloudDriveFile.sizeLabel(1024), "1 KB")
        XCTAssertEqual(CloudDriveFile.sizeLabel(1535), "1 KB")
        XCTAssertEqual(CloudDriveFile.sizeLabel(1536), "2 KB", "Math.round rounds half up")
        XCTAssertEqual(CloudDriveFile.sizeLabel(1_048_575), "1024 KB")
        XCTAssertEqual(CloudDriveFile.sizeLabel(1_048_576), "1.0 MB")
        XCTAssertEqual(CloudDriveFile.sizeLabel(1_572_864), "1.5 MB")
        XCTAssertEqual(CloudDriveFile.sizeLabel(2_411_724), "2.3 MB")
    }

    func testTheTopLevelIsDot() {
        XCTAssertEqual(CloudDriveService.wireFolder(""), ".")
        XCTAssertEqual(CloudDriveService.wireFolder("/"), ".")
        XCTAssertEqual(CloudDriveService.wireFolder("A/B"), "A/B")
    }

    func testAFolderReadsAsItsTrail() {
        XCTAssertEqual(CloudImportViewModel.label(forFolder: "Bakshi/2025/Writs"), "Bakshi / 2025 / Writs")
    }

    func testTheSummarySaysWhatArrived() {
        XCTAssertEqual(
            CloudImportViewModel.summary(imported: 1, of: 1, into: "Uploads"),
            "Imported 1 file into Uploads — making them searchable now.")
        XCTAssertEqual(
            CloudImportViewModel.summary(imported: 2, of: 3, into: "A/B"),
            "Imported 2 of 3 files into A / B — making them searchable now. The rest are marked below.")
        XCTAssertEqual(CloudImportViewModel.summary(imported: 0, of: 1, into: "X"), "The file wasn't imported.")
        XCTAssertEqual(CloudImportViewModel.summary(imported: 0, of: 4, into: "X"), "None of the 4 files were imported.")
    }
}

// MARK: - The screens

/// A drive account in memory. Thread-safe because the protocol is `Sendable`; the view models
/// call it from the main actor only.
final class FakeCloudDrives: CloudDriveProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _rows: [CloudDriveConnection]
    private var _files: [CloudDrive: [CloudDriveFile]] = [:]
    private var _calls: [String] = []
    private var _failures: [String: Error] = [:]
    /// What the next `connections()` reads instead — the browser closed after a sign-in.
    private var _rowsAfterNextRead: [CloudDriveConnection]?

    init(_ rows: [CloudDriveConnection]) { _rows = rows }

    static func row(_ drive: CloudDrive, configured: Bool = true, connected: Bool, email: String? = nil)
        -> CloudDriveConnection {
        CloudDriveConnection(drive: drive, label: drive.label, configured: configured, connected: connected, email: email)
    }

    var calls: [String] { lock.withLock { _calls } }
    func setFiles(_ files: [CloudDriveFile], for drive: CloudDrive) { lock.withLock { _files[drive] = files } }
    /// Fails the call whose record starts with `prefix` ("connections", "import:g2", …).
    func fail(_ prefix: String, with error: Error) { lock.withLock { _failures[prefix] = error } }
    func setRows(_ rows: [CloudDriveConnection]) { lock.withLock { _rows = rows } }

    private func record(_ call: String) throws {
        try lock.withLock {
            _calls.append(call)
            if let match = _failures.first(where: { call.hasPrefix($0.key) }) { throw match.value }
        }
    }

    func connections() async throws -> [CloudDriveConnection] {
        try record("connections")
        return lock.withLock { _rows }
    }

    func connectURL(for drive: CloudDrive) async throws -> URL {
        try record("connect:\(drive.rawValue)")
        return URL(string: "https://consent.example/\(drive.rawValue)")!
    }

    func disconnect(_ drive: CloudDrive) async throws {
        try record("disconnect:\(drive.rawValue)")
        lock.withLock {
            _rows = _rows.map { $0.drive == drive ? Self.row(drive, connected: false) : $0 }
        }
    }

    func export(fileName: String, folderName: String, to drive: CloudDrive) async throws -> CloudDriveExport {
        try record("export:\(drive.rawValue):\(folderName)/\(fileName)")
        return CloudDriveExport(success: true, id: "x", name: fileName, url: "https://drive.example/x")
    }

    func files(in drive: CloudDrive) async throws -> [CloudDriveFile] {
        try record("list:\(drive.rawValue)")
        return lock.withLock { _files[drive] ?? [] }
    }

    func importFile(_ file: CloudDriveFile, from drive: CloudDrive, into folderName: String) async throws
        -> CloudDriveImport {
        try record("import:\(file.id):\(drive.rawValue):\(folderName)")
        return CloudDriveImport(success: true, fileName: file.name.replacingOccurrences(of: " ", with: "_"),
                                folderName: folderName, size: 10)
    }
}

@MainActor
private func withConnections(
    _ rows: [CloudDriveConnection],
    _ body: @MainActor (FakeCloudDrives, CloudConnectionsViewModel) async -> Void
) async {
    let fake = FakeCloudDrives(rows)
    await body(fake, CloudConnectionsViewModel(service: fake))
}

@MainActor
private func withImport(
    _ rows: [CloudDriveConnection],
    destinations: [String] = ["Bakshi", "Bakshi/Orders"],
    initial: String = "",
    _ body: @MainActor (FakeCloudDrives, CloudImportViewModel) async -> Void
) async {
    let fake = FakeCloudDrives(rows)
    fake.setFiles([
        CloudDriveFile(id: "g1", name: "Plaint.pdf", size: 2048),
        CloudDriveFile(id: "g2", name: "Reply brief.pdf"),
        CloudDriveFile(id: "g3", name: "Order.pdf"),
    ], for: .google)
    fake.setFiles([CloudDriveFile(id: "o1", name: "Notes.docx")], for: .microsoft)
    await body(fake, CloudImportViewModel(service: fake, destinations: destinations, initialDestination: initial))
}

final class CloudConnectionsViewModelTests: XCTestCase {

    func testEachRowSaysHowTheDriveStands() async {
        await withConnections([
            FakeCloudDrives.row(.google, connected: true, email: "a@firm.in"),
            FakeCloudDrives.row(.microsoft, configured: false, connected: false),
        ]) { _, model in
            await model.load()
            XCTAssertEqual(model.state, .loaded)
            XCTAssertEqual(model.status(of: model.connections[0]), "Connected as a@firm.in")
            XCTAssertEqual(model.status(of: model.connections[1]), CloudConnectionsViewModel.Copy.notConfigured)
            XCTAssertEqual(model.connectedDrives, [.google])
            XCTAssertEqual(
                model.status(of: FakeCloudDrives.row(.microsoft, connected: false)),
                CloudConnectionsViewModel.Copy.invitation)
            XCTAssertEqual(model.status(of: FakeCloudDrives.row(.google, connected: true)), "Connected")
        }
    }

    /// Connect fetches the page; closing it re-reads, and the row says what happened.
    func testConnectingOpensThePageAndClosingItChecksAgain() async {
        await withConnections([FakeCloudDrives.row(.google, connected: false)]) { fake, model in
            await model.load()
            await model.connect(.google)
            XCTAssertEqual(model.consentPage?.url.absoluteString, "https://consent.example/google")
            XCTAssertNil(model.busy)

            fake.setRows([FakeCloudDrives.row(.google, connected: true, email: "a@firm.in")])
            await model.browserDidClose(.google)

            XCTAssertNil(model.consentPage)
            XCTAssertEqual(model.connectedDrives, [.google])
            XCTAssertEqual(model.notice, "Google Drive is connected.")
            XCTAssertEqual(fake.calls, ["connections", "connect:google", "connections"])
        }
    }

    func testABackedOutSignInSaysSo() async {
        await withConnections([FakeCloudDrives.row(.microsoft, connected: false)]) { _, model in
            await model.load()
            await model.connect(.microsoft)
            await model.browserDidClose(.microsoft)
            XCTAssertEqual(
                model.notice,
                "OneDrive is not connected. If you finished signing in, check again in a moment.")
        }
    }

    func testARefusedConnectIsTheNoticeAndOpensNothing() async {
        await withConnections([FakeCloudDrives.row(.google, connected: false)]) { fake, model in
            fake.fail("connect", with: APIError.refused(
                Refusal(code: .featureNotInPlan, status: 402, serverMessage: "Cloud Sync is part of the paid plans. Upgrade to use it.")))
            await model.connect(.google)
            XCTAssertNil(model.consentPage)
            XCTAssertNotNil(model.notice)
            XCTAssertFalse(model.notice?.contains("Upgrade") ?? true)
        }
    }

    func testDisconnectReadsBack() async {
        await withConnections([FakeCloudDrives.row(.google, connected: true)]) { fake, model in
            await model.load()
            await model.disconnect(.google)
            XCTAssertEqual(model.notice, "Google Drive is disconnected.")
            XCTAssertEqual(model.connectedDrives, [])
            XCTAssertEqual(fake.calls, ["connections", "disconnect:google", "connections"])
        }
    }

    /// A re-check that fails keeps the rows on screen.
    func testAFailedRecheckKeepsTheRows() async {
        await withConnections([FakeCloudDrives.row(.google, connected: true)]) { fake, model in
            await model.load()
            fake.fail("connections", with: APIError.transport("The Internet connection appears to be offline."))
            await model.load()
            XCTAssertEqual(model.connections.count, 1)
            guard case .failed = model.state else { return XCTFail("\(model.state)") }
        }
    }
}

final class CloudFileActionsViewModelTests: XCTestCase {

    func testOnlyConnectedDrivesAreOffered() async {
        await onMainActor {
            let fake = FakeCloudDrives([
                FakeCloudDrives.row(.google, connected: false),
                FakeCloudDrives.row(.microsoft, connected: true),
            ])
            let model = CloudFileActionsViewModel(service: fake)
            XCTAssertFalse(model.offersImport)
            await model.refresh()
            XCTAssertEqual(model.connectedDrives, [.microsoft])
            XCTAssertEqual(model.importTitle, "Import from OneDrive")

            fake.setRows([FakeCloudDrives.row(.google, connected: true), FakeCloudDrives.row(.microsoft, connected: true)])
            await model.refresh()
            XCTAssertEqual(model.importTitle, "Import from a drive")

            // A failed read leaves what was known.
            fake.fail("connections", with: APIError.transport("offline"))
            await model.refresh()
            XCTAssertEqual(model.connectedDrives, [.google, .microsoft])
        }
    }

    func testSavingSendsTheDocumentsOwnFolderAndSaysWhere() async {
        await onMainActor {
            let fake = FakeCloudDrives([FakeCloudDrives.row(.google, connected: true)])
            let model = CloudFileActionsViewModel(service: fake)
            let file = FileNode.StoredFile(name: "Order_dt_3.10.pdf", path: "Bakshi/Orders/Order_dt_3.10.pdf")

            await model.export(file, to: .google)

            XCTAssertEqual(fake.calls, ["export:google:Bakshi/Orders/Order_dt_3.10.pdf"])
            XCTAssertEqual(model.notice, "\(DisplayText.fileName("Order_dt_3.10.pdf")) saved to Google Drive.")
            XCTAssertNil(model.failure)
            XCTAssertFalse(model.isExporting)
        }
    }

    func testAFailedSaveIsAnAlertInThisAppsWords() async {
        await onMainActor {
            let fake = FakeCloudDrives([FakeCloudDrives.row(.google, connected: true)])
            fake.fail("export", with: APIError.server(
                status: 409,
                message: "Google Drive write access was not granted — Disconnect and reconnect Google Drive in Settings"))
            let model = CloudFileActionsViewModel(service: fake)

            await model.export(FileNode.StoredFile(name: "a.pdf", path: "a.pdf"), to: .google)

            XCTAssertNil(model.notice)
            XCTAssertEqual(model.failure?.title, "Couldn't save to Google Drive")
            XCTAssertEqual(
                model.failure?.message,
                "Google Drive write access was not granted — Disconnect and reconnect Google Drive under You → Connected services")
        }
    }
}

@MainActor
private func onMainActor(_ body: @MainActor () async -> Void) async {
    await body()
}

final class CloudImportViewModelTests: XCTestCase {

    /// Google first when both are connected, as the web chooses; the other drive is a choice.
    func testOpensOnTheFirstConnectedDrive() async {
        await withImport([
            FakeCloudDrives.row(.google, connected: true),
            FakeCloudDrives.row(.microsoft, connected: true),
        ]) { fake, model in
            await model.load()
            XCTAssertEqual(model.drives, [.google, .microsoft])
            XCTAssertEqual(model.drive, .google)
            XCTAssertEqual(model.title, "Import from Google Drive")
            XCTAssertEqual(model.files.map(\.id), ["g1", "g2", "g3"])

            model.toggle(model.files[0])
            await model.choose(.microsoft)
            XCTAssertEqual(model.files.map(\.id), ["o1"])
            XCTAssertTrue(model.selected.isEmpty, "ids belong to a drive")
            XCTAssertEqual(fake.calls, ["connections", "list:google", "list:microsoft"])
        }
    }

    func testOnlyOneConnectedDriveIsListed() async {
        await withImport([
            FakeCloudDrives.row(.google, connected: false),
            FakeCloudDrives.row(.microsoft, connected: true),
        ]) { _, model in
            await model.load()
            XCTAssertEqual(model.drives, [.microsoft])
            XCTAssertEqual(model.drive, .microsoft)
        }
    }

    func testNoDriveSaysWhy() async {
        await withImport([
            FakeCloudDrives.row(.google, connected: false),
            FakeCloudDrives.row(.microsoft, configured: false, connected: false),
        ]) { fake, model in
            await model.load()
            XCTAssertEqual(model.unavailable, .notConnected)
            XCTAssertEqual(fake.calls, ["connections"])
        }
        await withImport([
            FakeCloudDrives.row(.google, configured: false, connected: false),
            FakeCloudDrives.row(.microsoft, configured: false, connected: false),
        ]) { _, model in
            await model.load()
            XCTAssertEqual(model.unavailable, .notConfigured)
        }
    }

    /// The list's refusal is the server's sentence, pointed at this app.
    func testAListRefusalIsTheServersSentence() async {
        await withImport([FakeCloudDrives.row(.google, connected: true)]) { fake, model in
            fake.fail("list", with: APIError.server(
                status: 409,
                message: "Google Drive read access was not granted — Disconnect and reconnect Google Drive in Settings"))
            await model.load()
            guard case .failed(let failure) = model.state else { return XCTFail("\(model.state)") }
            XCTAssertTrue(failure.message.hasSuffix("under You → Connected services"), failure.message)
        }
    }

    /// The open folder, or at the top level the folder uploads use — never the root.
    func testTheDestinationIsAFolder() async {
        await withImport([], destinations: ["", "Bakshi"], initial: "") { _, model in
            XCTAssertEqual(model.destination, FileLibraryViewModel.uploadFolder)
            XCTAssertEqual(model.destinations, ["Bakshi", FileLibraryViewModel.uploadFolder])
        }
        await withImport([], destinations: ["Bakshi", "Bakshi/Orders"], initial: "Bakshi/Orders") { _, model in
            XCTAssertEqual(model.destination, "Bakshi/Orders")
            XCTAssertEqual(model.destinations, ["Bakshi", "Bakshi/Orders"])
        }
    }

    /// One at a time, in the drive's order, into the chosen folder; each file's outcome kept.
    func testImportsRunInOrderAndEachIsReported() async {
        await withImport([FakeCloudDrives.row(.google, connected: true)]) { fake, model in
            await model.load()
            XCTAssertFalse(model.canImport)
            XCTAssertEqual(model.importButtonTitle, "Import")
            model.toggle(model.files[2])
            model.toggle(model.files[0])
            model.toggle(model.files[1])
            model.toggle(model.files[1])
            XCTAssertEqual(model.importButtonTitle, "Import 2")
            model.destination = "Bakshi/Orders"
            fake.fail("import:g3", with: APIError.server(status: 400, message: "That file type cannot be imported"))

            let imported = await model.importSelected()

            XCTAssertEqual(imported, 1)
            XCTAssertEqual(Array(fake.calls.suffix(2)), [
                "import:g1:google:Bakshi/Orders", "import:g3:google:Bakshi/Orders",
            ])
            XCTAssertEqual(model.outcome(of: model.files[0]), .imported(storedName: "Plaint.pdf"))
            XCTAssertEqual(model.outcome(of: model.files[2]), .failed("That file type cannot be imported"))
            XCTAssertNil(model.outcome(of: model.files[1]))
            XCTAssertEqual(
                model.summary,
                "Imported 1 of 2 files into Bakshi / Orders — making them searchable now. The rest are marked below.")
            XCTAssertFalse(model.canImport, "a finished run is not repeated")
            XCTAssertFalse(model.isImporting)
        }
    }

    /// A coded refusal would come back for every file after it: the run stops there.
    func testAPlanRefusalStopsTheRun() async {
        await withImport([FakeCloudDrives.row(.google, connected: true)]) { fake, model in
            await model.load()
            model.files.forEach { model.toggle($0) }
            fake.fail("import:g2", with: APIError.refused(
                Refusal(code: .documentLimit, status: 402, serverMessage: "Upgrade your plan to upload more.")))

            let imported = await model.importSelected()

            XCTAssertEqual(imported, 1)
            XCTAssertFalse(fake.calls.contains { $0.hasPrefix("import:g3") }, "never sent")
            guard case .failed = model.outcome(of: model.files[1]) else { return XCTFail() }
            guard case .skipped(let reason) = model.outcome(of: model.files[2]) else { return XCTFail() }
            XCTAssertTrue(reason.hasPrefix("Not tried"))
            XCTAssertFalse(reason.contains("Upgrade"))
        }
    }

    func testTheStoredNameIsTheServers() async {
        await withImport([FakeCloudDrives.row(.google, connected: true)]) { _, model in
            await model.load()
            model.toggle(model.files[1])
            await model.importSelected()
            XCTAssertEqual(model.outcome(of: model.files[1]), .imported(storedName: "Reply_brief.pdf"))
            XCTAssertEqual(
                model.summary,
                "Imported 1 file into \(FileLibraryViewModel.uploadFolder) — making them searchable now.")
        }
    }

    func testTheDetailLineIsSizeAndDay() async {
        await withImport([]) { _, model in
            let now = WireDate.parse("2026-10-19T06:00:00.000Z")!
            XCTAssertEqual(
                model.detail(for: CloudDriveFile(id: "a", name: "a", size: 2048, modified: "2026-10-19T03:00:00.000Z"), now: now),
                "2 KB · Today")
            XCTAssertNil(model.detail(for: CloudDriveFile(id: "b", name: "b", size: 0), now: now))
        }
    }
}
