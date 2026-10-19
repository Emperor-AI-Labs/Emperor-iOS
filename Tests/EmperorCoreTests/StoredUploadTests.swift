import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Since the searchable-PDF change a photo sent to `/upload-chunk` is stored as a PDF, and only
// the completing chunk's answer says so. Every test here is named for what a person sees when
// the stored name is ignored: an upload that "never finishes", an attachment that points at
// nothing, a document they cannot find in My Files.

final class StoredUploadTests: XCTestCase {

    func testTheCompletingAnswerNamesTheStoredPDFAndWhatItWasMadeFrom() throws {
        let response = try JSONDecoder().decode(
            UploadChunkResponse.self,
            from: Data(#"{"success":true,"message":"Upload complete","filename":"Photo_1.pdf","storedName":"Photo_1.pdf","convertedFrom":"Photo_1.jpg","folder":"Chat_Uploads"}"#.utf8))
        let stored = StoredUpload.resolve(requested: "Photo_1.jpg", response: response)
        XCTAssertEqual(stored.name, "Photo_1.pdf")
        XCTAssertEqual(stored.convertedFrom, "Photo_1.jpg")
        XCTAssertTrue(stored.wasConverted)
        // The display form: underscores read as spaces, as every file name shown in the app does.
        XCTAssertEqual(stored.notice, "Saved as Photo 1.pdf")
    }

    func testADocumentStoredUnderItsOwnNameIsNotReportedAsConverted() throws {
        let response = try JSONDecoder().decode(
            UploadChunkResponse.self,
            from: Data(#"{"success":true,"filename":"Plaint.pdf","storedName":"Plaint.pdf","convertedFrom":null}"#.utf8))
        let stored = StoredUpload.resolve(requested: "Plaint.pdf", response: response)
        XCTAssertEqual(stored.name, "Plaint.pdf")
        XCTAssertFalse(stored.wasConverted)
        XCTAssertNil(stored.notice)
    }

    /// An older server answers `{success, message}` only. The name then has to be the sanitised
    /// sent name — the one every caller assumed before — not an empty string.
    func testAServerThatSaysNothingLeavesTheSanitisedSentName() throws {
        let response = try JSONDecoder().decode(
            UploadChunkResponse.self, from: Data(#"{"success":true,"message":"Upload complete"}"#.utf8))
        let stored = StoredUpload.resolve(requested: "मुकदमा 1.pdf", response: response)
        XCTAssertEqual(stored.name, UploadService.sanitize(fileName: "मुकदमा 1.pdf"))
        XCTAssertFalse(stored.wasConverted)
    }

    func testANonJSONBodyReadsAsTheServerSayingNothing() {
        let stored = StoredUpload.parse(body: Data("<html>502</html>".utf8), requested: "Photo.jpg")
        XCTAssertEqual(stored.name, "Photo.jpg")
        XCTAssertFalse(stored.wasConverted)
    }

    /// `filename` alone is what the server sent before the change; a blank `storedName` must not
    /// shadow it.
    func testFilenameIsReadWhenStoredNameIsBlank() throws {
        let response = try JSONDecoder().decode(
            UploadChunkResponse.self,
            from: Data(#"{"success":true,"filename":"Scan.pdf","storedName":""}"#.utf8))
        XCTAssertEqual(StoredUpload.resolve(requested: "Scan.pdf", response: response).name, "Scan.pdf")
    }

    // MARK: - After a relaunch, with no answer to read

    func testAPhotoResumedAfterRelaunchIsAssumedToBeItsPDFTwin() {
        let stored = StoredUpload.assumed(requested: "Photo 2026.JPG")
        XCTAssertEqual(stored.name, "Photo_2026.pdf")
        XCTAssertEqual(stored.convertedFrom, "Photo_2026.JPG")
        XCTAssertTrue(stored.wasConverted)
    }

    func testADocumentResumedAfterRelaunchKeepsItsName() {
        XCTAssertEqual(StoredUpload.assumed(requested: "Plaint.pdf").name, "Plaint.pdf")
        XCTAssertEqual(StoredUpload.assumed(requested: "notes").name, "notes")
        XCTAssertEqual(StoredUpload.assumed(requested: ".jpg").name, ".jpg")
    }
}

/// The whole upload over a stand-in server: the poll after the last chunk must ask after the
/// **stored** name. Asked after the photo, `/upload-status` answers "Reading document content..."
/// for as long as it is asked, and the upload shows as unconfirmed a quarter of an hour later.
final class UploadServiceStoredNameTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService() async -> UploadService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return UploadService(client: client)
    }

    func testThePollAfterAConvertedPhotoAsksAfterThePDF() async throws {
        let service = await makeService()
        HTTPStub.respond { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/upload-chunk") {
                return .json(#"{"success":true,"message":"Upload complete","storedName":"Photo_1.pdf","convertedFrom":"Photo_1.jpg"}"#)
            }
            if path.hasSuffix("/upload-status") { return .json(#"{"status":"ready"}"#) }
            return .json(#"{"success":false,"error":"unexpected"}"#, status: 500)
        }

        var storedEvents: [StoredUpload] = []
        var finished: IngestState?
        for try await event in service.upload(
            data: Data(repeating: 1, count: 10), fileName: "Photo_1.jpg",
            folderName: "Chat_Uploads", chunkSize: 1024
        ) {
            if case .stored(let stored) = event { storedEvents.append(stored) }
            if case .finished(let state) = event { finished = state }
        }

        XCTAssertEqual(storedEvents.map(\.name), ["Photo_1.pdf"])
        XCTAssertEqual(finished, .ready)

        let poll = try XCTUnwrap(HTTPStub.seen.last { $0.url?.path.hasSuffix("/upload-status") == true })
        let items = URLComponents(url: poll.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "fileName" }?.value, "Photo_1.pdf")
        XCTAssertEqual(items.first { $0.name == "folderName" }?.value, "Chat_Uploads")
    }

    func testTheStoredEventComesOnceAndBeforeTheFinish() async throws {
        let service = await makeService()
        HTTPStub.respond { request in
            if request.url?.path.hasSuffix("/upload-chunk") == true {
                return .json(#"{"success":true,"filename":"Plaint.pdf"}"#)
            }
            return .json(#"{"status":"ready"}"#)
        }
        var order: [String] = []
        for try await event in service.upload(
            data: Data(repeating: 1, count: 3000), fileName: "Plaint.pdf",
            folderName: "Chat_Uploads", chunkSize: 1024
        ) {
            switch event {
            case .progress: order.append("progress")
            case .stored(let stored):
                order.append("stored")
                XCTAssertEqual(stored.name, "Plaint.pdf")
                XCTAssertFalse(stored.wasConverted)
            case .processing: order.append("processing")
            case .finished: order.append("finished")
            }
        }
        XCTAssertEqual(order, ["progress", "progress", "progress", "stored", "finished"])
    }
}

final class UploadBatchSavedAsTests: XCTestCase {

    func testAConvertedPhotoSaysWhatItWasSavedAs() {
        var batch = UploadBatch()
        let now = Date(timeIntervalSince1970: 1_000)
        batch.add(id: "u1", name: "Photo_1.jpg", size: 2_000, folderName: "Chat_Uploads", at: now)
        batch.markDone("u1", savedAs: "Photo_1.pdf")
        let row = batch.files[0]
        XCTAssertEqual(row.savedAs, "Photo_1.pdf")
        XCTAssertTrue(row.detail.hasSuffix("Saved as Photo_1.pdf"), row.detail)
    }

    func testTheSameNameIsNotAnnounced() {
        var batch = UploadBatch()
        let now = Date(timeIntervalSince1970: 1_000)
        batch.add(id: "u1", name: "Plaint.pdf", size: 2_000, folderName: "Chat_Uploads", at: now)
        batch.markDone("u1", savedAs: "Plaint.pdf")
        XCTAssertNil(batch.files[0].savedAs)
        XCTAssertFalse(batch.files[0].detail.contains("Saved as"))
    }
}
