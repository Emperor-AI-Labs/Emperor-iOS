import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension FileNode.StoredFile {
    /// The folder portion of `path`, as `/chat` and `/upload-status` expect it.
    ///
    /// `path` is relative to the user's storage root, so a nested file gives `"A/B"` and a
    /// loose file at the root gives `""` — which is exactly the default the chat path uses.
    var folderPath: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    /// How to refer to this file when attaching it to a turn.
    ///
    /// `name` is taken verbatim from the server's own listing, which enumerates the
    /// filesystem and therefore already carries the sanitised on-disk name. Never rebuild it
    /// from a user-visible label — annexure citations match on the exact name and fail
    /// silently otherwise.
    var attachment: ChatAttachment {
        ChatAttachment(name: name, folderName: folderPath.isEmpty ? nil : folderPath)
    }

    var state: IngestState { IngestState.classify(status) }

    /// Whether the model can read this file right now.
    ///
    /// A `scanned` file counts: it is an image-only PDF that is deliberately never OCR'd,
    /// and the model reads those pages visually.
    var isReadable: Bool { state.isUsable }
}

/// Works out which stored document a citation points at.
///
/// A mention token carries only the filename — `<@MHA_OM.pdf:P-5:7>` — but every route that
/// can serve the file needs a folder as well. Resolution prefers the turn's own attachments,
/// since a citation is by construction a file the model was given, and only then falls back
/// to searching the whole library.
enum CitationResolver {
    static func resolve(
        _ mention: AnnexureMention,
        attachments: [ChatAttachment],
        files: [FileNode.StoredFile]
    ) -> ChatAttachment? {
        let target = UploadService.sanitize(fileName: mention.fileName)

        if let match = attachments.first(where: {
            UploadService.sanitize(fileName: $0.name) == target
        }) {
            return match
        }

        // The platform treats `{name, folderName}` as identity — the same filename in two
        // matters is two different documents. With only a name to go on we cannot tell them
        // apart, so prefer a unique match and otherwise take the first in path order, which
        // is at least stable rather than arbitrary.
        let candidates = files
            .filter { UploadService.sanitize(fileName: $0.name) == target }
            .sorted { $0.path < $1.path }
        return candidates.first?.attachment
    }
}

/// The document-library reads a view model needs.
///
/// Both calls are expensive or awkward against a live server — `tree()` triggers a full
/// storage walk, `fileData` returns raw bytes — so the screens that depend on them are
/// exercised through this instead.
protocol FileProviding: Sendable {
    func tree() async throws -> [FileNode]
    func fileData(name: String, folderName: String?) async throws -> Data
}

struct FileService: FileProviding {
    let client: APIClient

    /// Fetches the whole document tree.
    ///
    /// - Note: this is not a cheap read. The server runs a consolidation pass that physically
    ///   copies files into AI-named folders, then walks the entire storage tree with a
    ///   `statSync` per entry. The web client polls it every few seconds; a mobile client
    ///   should not. Refresh on appear and on pull-to-refresh only.
    func tree() async throws -> [FileNode] {
        try await withRetry {
            let request = try await client.makeRequest("GET", "/user-files")
            return try await client.send(request, as: UserFilesResponse.self).folders
        }
    }

    /// Downloads a document's bytes for local display.
    ///
    /// `/view-file` serves inline with a correct content type. Its `folderName` parameter is
    /// **required** — an empty one is a 400 — so a root-level file must send `"."`, which is
    /// how these routes spell "the storage root" (`safeFolderPath`, `sync-server.js:293`).
    /// Sending `"_"` instead would address a directory that does not exist, which is exactly
    /// the bug that once broke root-level files server-side.
    func fileData(name: String, folderName: String?) async throws -> Data {
        let folder = (folderName?.isEmpty ?? true) ? "." : folderName!
        let request = try await client.makeRequest(
            "GET", "/view-file",
            query: ["folderName": folder, "fileName": name])

        let (data, response) = try await client.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            // This route answers with a bare text body, not the usual JSON error envelope.
            throw APIError.server(
                status: response.statusCode,
                message: response.statusCode == 404
                    ? "That document is no longer in your library."
                    : String(decoding: data, as: UTF8.self))
        }
        return data
    }

    /// Every file in the tree, depth-first, with folders flattened away.
    ///
    /// Files and folders are mixed at every level of the response — including the top — so
    /// this discriminates rather than assuming the shape.
    static func allFiles(in nodes: [FileNode]) -> [FileNode.StoredFile] {
        nodes.flatMap { node -> [FileNode.StoredFile] in
            switch node {
            case .file(let file):
                return [file]
            case .folder(let folder):
                return allFiles(in: folder.files ?? [])
            }
        }
    }

    /// Case- and separator-insensitive search over the flattened tree.
    ///
    /// Matches on the folder path too, so "partition" finds everything filed under a matter
    /// even when the query does not appear in the filename.
    static func search(_ query: String, in files: [FileNode.StoredFile]) -> [FileNode.StoredFile] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return files }
        // Filenames are underscore-sanitised on disk, so a user typing spaces should still
        // match "Partition_Suit".
        let needle = normalize(trimmed)
        return files.filter { normalize($0.path).contains(needle) }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: " ", with: "_")
    }
}
