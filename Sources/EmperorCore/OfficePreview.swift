import Foundation

/// Viewing a Word document without leaving the app.
///
/// A `.docx` in the library could not be opened at all before this — the file was listed, could
/// be attached to a chat, and could not be read. For a product whose users are sent drafts as
/// Word documents constantly, that is a hole in the middle of the library.
///
/// The server converts with LibreOffice and caches the result by content hash, so the phone
/// receives a PDF and draws it with PDFKit like anything else.
///
/// ## Two things about this route that will catch you out
///
/// 1. **It answers `200` on failure.** A document that cannot be converted comes back as
///    `200 {"success": false, "reason": …}`. Branching on the status code alone would show an
///    empty viewer and no explanation, so `success` is what decides here.
/// 2. **The bytes come from a second request.** `/office-preview` returns metadata and warms
///    the cache; `/office-preview-pdf` returns the PDF. The second is normally a cache read,
///    but it re-converts rather than 404ing if the cache file went away in between.
enum OfficePreview {

    /// Word-processor formats only.
    ///
    /// Spreadsheets and slides are deliberately absent: LibreOffice will convert them with the
    /// same command, but a spreadsheet paginated onto A4 loses whatever falls off the right
    /// edge — a worse outcome than declining, because it looks like it worked.
    static let supportedExtensions: Set<String> = [".doc", ".docx", ".odt", ".rtf"]

    static func canPreview(fileName: String) -> Bool {
        guard let dot = fileName.lastIndex(of: ".") else { return false }
        return supportedExtensions.contains(fileName[dot...].lowercased())
    }

    struct Response: Codable, Equatable, Sendable {
        let success: Bool?
        let fileName: String?
        let pages: Int?
        /// Whether LibreOffice ran for this request rather than the cache answering.
        let cached: Bool?
        let reason: String?
        let error: String?
    }

    /// Why a document could not be converted, in words a user can act on.
    ///
    /// The server's own reasons are terse tokens meant for a log. Passing them through would
    /// put "unsupported" in front of someone holding a brief.
    static func message(forReason reason: String?, fallback: String?) -> String {
        switch reason {
        case "unsupported":
            return "This kind of file has no preview. You can still share it to open it elsewhere."
        case "missing":
            return "That document is no longer on the server."
        case "empty":
            return "That document is empty."
        case "too-big":
            return "That document is too large to preview. Share it to open it elsewhere."
        case "busy":
            return "The server is converting several documents at the moment. Try again shortly."
        case "refused":
            return fallback ?? "That document could not be previewed."
        default:
            return fallback ?? "That document could not be previewed."
        }
    }
}

protocol OfficePreviewProviding: Sendable {
    func preview(fileName: String, folderName: String?) async throws -> OfficePreview.Response
    func previewPDF(fileName: String, folderName: String?) async throws -> Data
}

struct OfficePreviewService: OfficePreviewProviding {
    let client: APIClient

    /// As `/view-file`, an empty `folderName` is a 400 and the storage root is spelled `"."`.
    private func query(fileName: String, folderName: String?) -> [String: String] {
        ["folderName": (folderName?.isEmpty ?? true) ? "." : folderName!, "fileName": fileName]
    }

    func preview(fileName: String, folderName: String?) async throws -> OfficePreview.Response {
        let request = try await client.makeRequest(
            "GET", "/office-preview", query: query(fileName: fileName, folderName: folderName))
        return try await client.send(request, as: OfficePreview.Response.self)
    }

    func previewPDF(fileName: String, folderName: String?) async throws -> Data {
        let request = try await client.makeRequest(
            "GET", "/office-preview-pdf",
            query: query(fileName: fileName, folderName: folderName))
        let (data, response) = try await client.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            // This one answers `text/plain`, not the JSON error envelope — decoding it as JSON
            // would report a parse failure instead of the reason the server actually gave.
            throw APIError.server(
                status: response.statusCode,
                message: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
