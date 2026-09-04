import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the server actually did to a file, read back rather than assumed.
///
/// The name matters: `rename-file` **force-preserves the original extension**, so renaming
/// `award.pdf` to `award` produces `award.pdf`, and it sanitises every character outside
/// `[A-Za-z0-9._-]` to an underscore. Rendering the name the user typed would show them a file
/// that does not exist under that name — and annexure citations match on the exact on-disk
/// name, so the difference is not cosmetic.
struct FileOperationResult: Equatable, Sendable {
    var fileName: String
    var folderName: String
    /// True when the search index still points at the old name. Disk and database succeeded;
    /// retrieval did not. Surfaced rather than swallowed, because the symptom otherwise is
    /// "the assistant can no longer find a document that is plainly right there".
    var searchIndexStale: Bool = false
}

/// Editing the document library, as opposed to reading it.
///
/// Kept apart from `FileProviding` because the read side is what most screens need and these
/// are all destructive — a screen that only lists files should not be handed a `delete`.
protocol FileManaging: Sendable {
    /// - Warning: **held back — no caller in the app.** Destructive and not reversible, and
    ///   withheld until the contract of the endpoint is confirmed. Do not put a control in front
    ///   of this without doing that first.
    func delete(name: String, folderName: String?) async throws
    func rename(
        name: String, in folderName: String?, to newName: String
    ) async throws -> FileOperationResult
    /// - Note: implemented and never wired to a screen — moving is left to the web. Its wire
    ///   shape is pinned by `ServiceWireTests.testMovingToTheRootSendsEmptyStringsNotDots`,
    ///   because this route spells the root differently from `delete` and nothing exercises it
    ///   in the app.
    func move(name: String, from folderName: String?, to destination: String?) async throws
    func setFavorite(_ favorite: Bool, name: String, folderName: String?) async throws -> Bool
    func createFolder(named path: String) async throws
    /// - Warning: **held back — no caller in the app.** As `delete`, and wider: this takes a
    ///   whole matter and everything indexed from it, with no undo.
    func deleteFolder(named path: String) async throws
}

struct FileManagementService: FileManaging {
    let client: APIClient

    /// How these routes spell "the storage root".
    ///
    /// Two different spellings, and they are not interchangeable. `delete-file` guards with a
    /// **truthiness** check (`!folderName`), so an empty string is rejected as a missing
    /// parameter and the root must be sent as `"."`. `rename-file` guards with
    /// `!folderName && folderName !== ''`, deliberately admitting the empty string. Sending
    /// `"."` to a route that then joins it into a path is fine — `safeFolderPath` drops `.`
    /// segments — but sending `""` to `delete-file` is a 500 that reads as a server fault.
    private static let rootForDelete = "."
    private static let rootForRename = ""

    private struct DeletePayload: Encodable {
        let userId: String
        let folderName: String
        let fileName: String
    }

    /// - Important: deleting something that is not there **still succeeds**. Both delete routes
    ///   guard on existence and fall through to the same 200, so a stale path is
    ///   indistinguishable from a real deletion. Refresh the tree afterwards rather than
    ///   trusting the local model.
    func delete(name: String, folderName: String?) async throws {
        let userID = try await requireUserID()
        let request = try await client.makeRequest(
            "POST", "/delete-file",
            body: DeletePayload(
                userId: userID,
                folderName: folder(folderName, root: Self.rootForDelete),
                fileName: name))
        _ = try await sendExpectingSuccess(request)
    }

    private struct RenamePayload: Encodable {
        let userId: String
        let folderName: String
        let oldName: String
        let newName: String
    }

    func rename(
        name: String, in folderName: String?, to newName: String
    ) async throws -> FileOperationResult {
        let userID = try await requireUserID()
        let request = try await client.makeRequest(
            "POST", "/rename-file",
            body: RenamePayload(
                userId: userID,
                folderName: folder(folderName, root: Self.rootForRename),
                oldName: name,
                newName: newName))
        let body = try await sendExpectingSuccess(request)
        // The echoed name is authoritative; the requested one is not.
        return FileOperationResult(
            fileName: body.fileName ?? newName,
            folderName: body.folderName ?? (folderName ?? ""),
            searchIndexStale: body.chroma?.ok == false)
    }

    private struct MovePayload: Encodable {
        let userId: String
        let fromFolder: String
        let toFolder: String
        let fileName: String
    }

    /// - Note: `fromFolder` and `toFolder` are checked against `null`, not truthiness, so the
    ///   empty string is the correct spelling of the root on both sides here.
    func move(name: String, from folderName: String?, to destination: String?) async throws {
        let userID = try await requireUserID()
        let request = try await client.makeRequest(
            "POST", "/move-file",
            body: MovePayload(
                userId: userID,
                fromFolder: folder(folderName, root: Self.rootForRename),
                toFolder: folder(destination, root: Self.rootForRename),
                fileName: name))
        _ = try await sendExpectingSuccess(request)
    }

    private struct FavoritePayload: Encodable {
        let userId: String
        let folderName: String
        let fileName: String
        /// **Never optional.** The server tests `favorite !== false`, so a key that is absent —
        /// or null — stars the document. Omitting it is not a read; it is a write in the
        /// opposite direction from the one the user asked for.
        let favorite: Bool
    }

    /// - Returns: the state the server **read back from the database**, not the one requested.
    func setFavorite(_ favorite: Bool, name: String, folderName: String?) async throws -> Bool {
        let userID = try await requireUserID()
        let request = try await client.makeRequest(
            "POST", "/favorite-file",
            body: FavoritePayload(
                userId: userID,
                folderName: folder(folderName, root: Self.rootForRename),
                fileName: name,
                favorite: favorite))
        let body = try await sendExpectingSuccess(request)
        return body.favorite ?? favorite
    }

    private struct FolderPayload: Encodable {
        let userId: String
        let folderName: String
    }

    /// - Important: a name that sanitises away to nothing — `"."`, `"/"`, `"..."` — creates the
    ///   storage root, which already exists, and reports success. `FolderName.isCreatable`
    ///   rejects those before the round trip, because the response says nothing about what was
    ///   actually made and the user would simply see no new folder.
    func createFolder(named path: String) async throws {
        let userID = try await requireUserID()
        let request = try await client.makeRequest(
            "POST", "/create-folder",
            body: FolderPayload(userId: userID, folderName: path))
        _ = try await sendExpectingSuccess(request)
    }

    /// - Important: recursive, and there is no confirmation step server-side. Every document
    ///   inside is deleted along with its extracted text, page index and search vectors.
    func deleteFolder(named path: String) async throws {
        let userID = try await requireUserID()
        let request = try await client.makeRequest(
            "POST", "/delete-folder",
            body: FolderPayload(userId: userID, folderName: path))
        _ = try await sendExpectingSuccess(request)
    }

    // MARK: - Plumbing

    private func requireUserID() async throws -> String {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        return credentials.userIDString
    }

    private func folder(_ value: String?, root: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? root : trimmed
    }

    /// Sends a write and insists the server said it worked.
    ///
    /// Never retried. Every route here is destructive or creative, and a second `delete-folder`
    /// after a timeout would take out a folder the user had since re-created.
    private func sendExpectingSuccess(_ request: URLRequest) async throws -> FileOperationBody {
        let (data, response) = try await client.perform(request)
        let body = try? JSONDecoder().decode(FileOperationBody.self, from: data)
        guard (200..<300).contains(response.statusCode), body?.success == true else {
            throw APIError.server(
                status: response.statusCode,
                message: Self.message(from: body, status: response.statusCode))
        }
        return body ?? FileOperationBody()
    }

    /// - Note: `delete-folder`'s own error message is wrong at the source — it says
    ///   "An error occurred while downloading files" for a failed deletion
    ///   (`sync-server.js:11427`). Passing that through would tell a user their deletion failed
    ///   because of a download. A 500 with no usable text gets our own wording instead.
    static func message(from body: FileOperationBody?, status: Int) -> String {
        let raw = (body?.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw.localizedCaseInsensitiveContains("downloading files") {
            return "That change could not be saved. Your documents are unchanged."
        }
        return raw
    }
}

/// The shared response shape across these routes. Every field is optional because they answer
/// with different subsets of it.
struct FileOperationBody: Codable, Sendable {
    struct ChromaResult: Codable, Sendable {
        var ok: Bool?
    }

    var success: Bool?
    var error: String?
    var message: String?
    var fileName: String?
    var folderName: String?
    var favorite: Bool?
    var chroma: ChromaResult?
}

/// Rules about folder names that the server enforces silently, applied before the round trip.
enum FolderName {
    /// The characters that survive the server's sanitiser. Everything else becomes `_`.
    static func sanitized(_ name: String) -> String {
        String(name.map { character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "." || character == "_" || character == "-")
                ? character
                : "_"
        })
    }

    /// Whether creating this would visibly produce a folder.
    ///
    /// A name of only dots, slashes or symbols sanitises down to nothing, at which point
    /// `create-folder` makes the storage root — which exists — and answers `{"success":true}`.
    /// The user sees no new folder and no error.
    static func isCreatable(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.split(separator: "/").contains { segment in
            sanitized(String(segment)).contains { $0 != "." && $0 != "_" }
        }
    }

    /// What the folder will actually be called, so the screen can warn when that differs from
    /// what was typed rather than letting a renamed folder appear out of nowhere.
    static func preview(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .map { sanitized(String($0)) }
            .joined(separator: "/")
    }
}
