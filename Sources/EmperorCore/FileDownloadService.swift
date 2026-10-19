import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A file the server made for this download, ready for the share sheet.
struct DownloadedFile: Equatable, Sendable {
    /// What the receiving app should call it.
    let fileName: String
    let data: Data
}

/// One document in a zip, as `/download-files` names it: its folder and its on-disk name.
struct FileZipEntry: Encodable, Equatable, Hashable, Sendable {
    let folderName: String
    let fileName: String

    /// A document from the library, with the storage root spelled `"."` as the web's bulk
    /// download spells it.
    init(_ file: FileNode.StoredFile) {
        self.init(folderName: file.folderPath, fileName: file.name)
    }

    init(folderName: String, fileName: String) {
        let folder = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.folderName = folder.isEmpty ? "." : folder
        self.fileName = fileName
    }
}

/// The downloads the server assembles rather than serves as stored: several documents as one
/// zip, and a PDF with an invisible text layer over its scanned pages.
protocol FileDownloading: Sendable {
    /// - Parameter suggestedName: what to call the archive — the web names a folder's zip after
    ///   the folder. `nil` takes the server's name, `documents.zip`.
    func zip(files: [FileZipEntry], suggestedName: String?) async throws -> DownloadedFile
    /// The searchable copy of a PDF. Only a PDF has one.
    func searchablePDF(name: String, folderName: String?) async throws -> DownloadedFile
}

/// `POST /download-files` and `GET /download-searchable`.
///
/// Both answer with the file itself — `application/zip` or `application/pdf`, each with a
/// `Content-Disposition` naming it — and with an error otherwise: the zip route in JSON, the
/// searchable route in plain text. The zip route takes its credential from the bearer header and
/// nothing else, which this client always sends.
struct FileDownloadService: FileDownloading {
    let client: APIClient

    /// The server's own name for a zip of several documents.
    static let defaultZipName = "documents.zip"

    private struct ZipPayload: Encodable {
        let userId: String
        let files: [FileZipEntry]
    }

    func zip(files: [FileZipEntry], suggestedName: String? = nil) async throws -> DownloadedFile {
        guard !files.isEmpty else { throw FileDownloadWording.nothingToZip }
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        let request = try await client.makeRequest(
            "POST", "/download-files",
            body: ZipPayload(userId: credentials.userIDString, files: files))
        let (data, response) = try await client.perform(request)
        switch response.statusCode {
        case 200..<300:
            // A zip opens with its local-file signature. Anything else — an empty body, a page
            // from something in between — is not a download worth handing on.
            guard data.starts(with: [0x50, 0x4B]) else { throw FileDownloadWording.incomplete }
            let named = suggestedName.map(FileDownloadWording.zipName(for:))
                ?? FileDownloadWording.filename(fromContentDisposition: response.value(forHTTPHeaderField: "Content-Disposition"))
                ?? Self.defaultZipName
            return DownloadedFile(fileName: named, data: data)
        case 400:
            throw FileDownloadWording.nothingToZip
        case 404:
            throw FileDownloadWording.noneFound(count: files.count)
        default:
            throw APIError.classify(status: response.statusCode, body: data)
        }
    }

    func searchablePDF(name: String, folderName: String?) async throws -> DownloadedFile {
        guard FileDownloadWording.offersSearchableCopy(fileName: name) else {
            throw FileDownloadWording.notAPDF
        }
        let folder = folderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Like `/view-file`, this route refuses an empty folder, so the root is `"."`.
        let request = try await client.makeRequest(
            "GET", "/download-searchable",
            query: ["folderName": folder.isEmpty ? "." : folder, "fileName": name])
        let (data, response) = try await client.perform(request)
        switch response.statusCode {
        case 200..<300:
            guard data.starts(with: Array("%PDF".utf8)) else { throw FileDownloadWording.incomplete }
            let named = FileDownloadWording.filename(fromContentDisposition: response.value(forHTTPHeaderField: "Content-Disposition"))
                ?? FileDownloadWording.searchableName(for: name)
            return DownloadedFile(fileName: named, data: data)
        case 404:
            throw FileDownloadWording.searchableNotFound
        case 400:
            throw FileDownloadWording.incomplete
        case 401:
            throw APIError.invalidCredentials
        default:
            // A plain-text body: the server's sentence, when it sent one.
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw APIError.server(
                status: response.statusCode,
                message: text.isEmpty || text.count > 200
                    ? "The searchable copy could not be made. Try again in a moment." : text)
        }
    }
}

/// Names and sentences for the two downloads, apart from the service so the screens and the tests
/// read the same ones.
enum FileDownloadWording {

    static let nothingToZip = APIError.server(
        status: 400, message: "Choose at least one document to download.")
    static let incomplete = APIError.server(
        status: 200, message: "The download arrived incomplete. Try again.")
    static let notAPDF = APIError.server(
        status: 400, message: "Only a PDF has a searchable copy.")
    static let searchableNotFound = APIError.server(
        status: 404, message: "That document is no longer in your library.")

    static func noneFound(count: Int) -> APIError {
        .server(status: 404, message: count == 1
            ? "That document is no longer in your library."
            : "None of those documents are in your library any more.")
    }

    /// Whether a document has a searchable copy to offer — a PDF, by its name, as the web's viewer
    /// decides it.
    static func offersSearchableCopy(fileName: String) -> Bool {
        fileName.lowercased().hasSuffix(".pdf")
    }

    /// `Plaint.pdf` → `Plaint_searchable.pdf`, as the server names it: the stored name with its
    /// `.pdf` taken off.
    static func searchableName(for fileName: String) -> String {
        var stem = UploadService.sanitize(fileName: fileName)
        if stem.lowercased().hasSuffix(".pdf") { stem.removeLast(4) }
        return stem + "_searchable.pdf"
    }

    /// How many documents a zip holds, read from its end-of-central-directory record; `nil` when
    /// the bytes do not end like a zip.
    ///
    /// The zip route leaves out any document it cannot find and still answers 200, so the count
    /// is the only way to know a zip of three holds two.
    static func zipEntryCount(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        // The record is 22 bytes plus a comment of at most 65,535.
        guard bytes.count >= 22 else { return nil }
        let lowest = max(0, bytes.count - 22 - 65_535)
        var index = bytes.count - 22
        while index >= lowest {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B,
               bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                return Int(bytes[index + 10]) | Int(bytes[index + 11]) << 8
            }
            index -= 1
        }
        return nil
    }

    /// Said when a zip came back holding fewer documents than were asked for. `nil` when it holds
    /// them all, or when its count cannot be read.
    static func shortfallNotice(asked: Int, archive: DownloadedFile) -> String? {
        guard let held = zipEntryCount(archive.data), held < asked else { return nil }
        let missing = asked - held
        return "\(missing) of the \(asked) documents \(missing == 1 ? "was" : "were") no longer in "
            + "your library, so \(archive.fileName) holds \(held)."
    }

    /// `Wadhwa` → `Wadhwa.zip`, as the web names a folder's zip.
    static func zipName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
        guard !trimmed.isEmpty else { return FileDownloadService.defaultZipName }
        return trimmed.lowercased().hasSuffix(".zip") ? trimmed : trimmed + ".zip"
    }

    /// The `filename="…"` of a `Content-Disposition` header, or `nil` when it names none.
    static func filename(fromContentDisposition header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard pair.lowercased().hasPrefix("filename=") else { continue }
            var value = String(pair.dropFirst("filename=".count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            // Never a path, whatever arrives.
            value = String(value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? "")
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}
