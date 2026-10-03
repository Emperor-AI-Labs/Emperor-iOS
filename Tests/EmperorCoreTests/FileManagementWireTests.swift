import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The bytes My Files puts on the wire for its destructive and renaming routes.
///
/// Each of these routes reads a different spelling of "the storage root", answers success in its
/// own shape, and has no undo — so what is sent is pinned here rather than inferred from the
/// view model's fakes.
final class FileManagementWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    /// Before each test, not only after — see `HTTPStub.reset`.
    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func service() async -> FileManagementService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return FileManagementService(client: client)
    }

    // MARK: - delete-file

    /// Every destructive request carries the bearer token as well as the id, so the server can
    /// check one against the other.
    func testADeletionCarriesTheTokenAndTheCallersId() async throws {
        HTTPStub.always(.json(#"{"success":true,"message":"File successfully deleted"}"#))
        try await service().delete(name: "Plaint.pdf", folderName: "Bakshi")

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/delete-file")
        XCTAssertEqual(sent.header("Authorization"), "Bearer tok-abc")
        let body = sent.bodyJSON
        XCTAssertEqual(body["userId"] as? String, "42")
        XCTAssertEqual(body["folderName"] as? String, "Bakshi")
        XCTAssertEqual(body["fileName"] as? String, "Plaint.pdf")
    }

    /// `delete-file` rejects an empty `folderName` as missing, so a loose document's folder is
    /// spelled `"."` on this route.
    func testALooseDocumentIsDeletedFromTheDotFolder() async throws {
        HTTPStub.always(.json(#"{"success":true}"#))
        try await service().delete(name: "Loose.pdf", folderName: "")
        XCTAssertEqual(HTTPStub.lastRequest?.bodyJSON["folderName"] as? String, ".")
    }

    /// A refusal arrives as a 403 with a sentence. It is an error, not a success.
    func testARefusedDeletionThrowsTheServersSentence() async throws {
        HTTPStub.always(.json(
            #"{"success":false,"error":"You do not have access to that account’s data"}"#, status: 403))
        do {
            try await service().delete(name: "Plaint.pdf", folderName: "Bakshi")
            XCTFail("a refusal must not read as a deletion")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 403, message: "You do not have access to that account’s data"))
        }
    }

    /// A 200 without `success: true` is not a deletion either.
    func testA200WithoutSuccessIsNotADeletion() async throws {
        HTTPStub.always(.json(#"{"error":"Missing parameters"}"#))
        do {
            try await service().delete(name: "Plaint.pdf", folderName: "Bakshi")
            XCTFail("expected an error")
        } catch {}
    }

    // MARK: - delete-folder

    func testAFolderIsDeletedByItsPath() async throws {
        HTTPStub.always(.json(#"{"success":true,"message":"Folder successfully deleted"}"#))
        try await service().deleteFolder(named: "Bakshi/2025")

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/delete-folder")
        XCTAssertEqual(sent.bodyJSON["folderName"] as? String, "Bakshi/2025")
        XCTAssertEqual(sent.bodyJSON["userId"] as? String, "42")
    }

    /// Never retried: a second recursive deletion after a timeout would take a folder the user
    /// had since re-created.
    func testAFailedFolderDeletionIsSentOnce() async throws {
        HTTPStub.always(.json(#"{"error":"An error occurred while downloading files"}"#, status: 500))
        do {
            try await service().deleteFolder(named: "Bakshi")
            XCTFail("expected an error")
        } catch let error as APIError {
            if case .server(_, let message) = error {
                XCTAssertFalse(message.localizedCaseInsensitiveContains("download"))
            } else {
                XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertEqual(HTTPStub.seen.count, 1)
    }

    // MARK: - rename-folder

    func testAFolderRenameSendsThePathAndTheNewLeaf() async throws {
        HTTPStub.always(.json(
            #"{"success":true,"message":"Folder successfully renamed","folderName":"Bakshi/Writ_Petitions","from":"Bakshi/2025","to":"Bakshi/Writ_Petitions"}"#))
        let newPath = try await service().renameFolder(at: "Bakshi/2025", to: "Writ Petitions")

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/rename-folder")
        XCTAssertEqual(sent.bodyJSON["folderPath"] as? String, "Bakshi/2025")
        XCTAssertEqual(sent.bodyJSON["newName"] as? String, "Writ Petitions")
        // The echoed path, not one rebuilt from what was typed.
        XCTAssertEqual(newPath, "Bakshi/Writ_Petitions")
    }

    func testWithoutAnEchoTheSanitisedNameIsAssumedUnderTheSameParent() async throws {
        HTTPStub.always(.json(#"{"success":true}"#))
        let newPath = try await service().renameFolder(at: "Bakshi/2025", to: "Writ Petitions")
        XCTAssertEqual(newPath, "Bakshi/Writ_Petitions")
    }

    /// The server refuses to rename over an existing folder, and says so in words worth showing.
    func testARenameOntoAnExistingFolderReportsTheServersReason() async throws {
        HTTPStub.always(.json(
            #"{"success":false,"error":"\"Bakshi/Arora\" already exists — refusing to overwrite it"}"#, status: 409))
        do {
            _ = try await service().renameFolder(at: "Bakshi/2025", to: "Arora")
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 409, message: #""Bakshi/Arora" already exists — refusing to overwrite it"#))
        }
    }

    // MARK: - favorite-file

    /// The field is always present and always a boolean. An absent key stars the document.
    func testUnstarringSendsTheKeyAsFalse() async throws {
        HTTPStub.always(.json(#"{"success":true,"favorite":false}"#))
        let stored = try await service().setFavorite(false, name: "Reply.pdf", folderName: "Bakshi")

        let body = try XCTUnwrap(HTTPStub.lastRequest?.bodyJSON)
        XCTAssertEqual(body["favorite"] as? Bool, false)
        XCTAssertNotNil(body["favorite"], "omitting it would star the document")
        XCTAssertFalse(stored)
    }
}
