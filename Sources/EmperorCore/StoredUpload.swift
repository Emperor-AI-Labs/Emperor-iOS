import Foundation

/// The name a document was stored under, which is not always the name it was sent as.
///
/// Since the platform's searchable-PDF change, a PNG or JPEG sent to `/upload-chunk` is converted
/// to a one-page PDF **on arrival** — the pixels kept byte for byte under an invisible text layer
/// — and the image itself never reaches storage. The completing chunk's answer names the result:
/// `{storedName: "Photo_1.pdf", convertedFrom: "Photo_1.jpg"}`.
///
/// Everything after the last chunk must use that name. `/upload-status` asked about the image
/// answers "Reading document content..." for as long as it is asked — there is no file and no
/// `.md` to find — so a client that keeps polling the name it sent waits out its whole timeout
/// and then reports a document that was in fact ready within seconds as unconfirmed. A chat
/// attachment made from the sent name points at nothing. The same holds for the name shown in
/// the upload panel and the one My Files is opened on.
///
/// When the server says nothing (an older server, a non-JSON answer), the stored name is the
/// sanitised sent name, which is what every caller assumed before.
struct StoredUpload: Equatable, Sendable {
    /// The on-disk name, already in the server's sanitised spelling.
    let name: String
    /// The sanitised name of the image this was made from, when the server converted one.
    let convertedFrom: String?

    /// Whether the document on the server is a different file type from the one that was sent.
    var wasConverted: Bool { convertedFrom != nil && convertedFrom != name }

    /// What the server said, or what it would have said before it started saying anything.
    ///
    /// `storedName` is preferred over `filename`: both carry the stored name, but only the first
    /// was added together with the conversion, so it is the one guaranteed to be post-conversion
    /// on any server that converts.
    static func resolve(requested: String, response: UploadChunkResponse?) -> StoredUpload {
        let fallback = UploadService.sanitize(fileName: requested)
        guard let response else { return StoredUpload(name: fallback, convertedFrom: nil) }
        let stored = [response.storedName, response.filename]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? fallback
        let from = response.convertedFrom?.trimmingCharacters(in: .whitespacesAndNewlines)
        return StoredUpload(name: stored, convertedFrom: (from?.isEmpty ?? true) ? nil : from)
    }

    /// The same, from the raw bytes of the completing chunk's answer — the shape the background
    /// session hands over, where nothing has been decoded yet. Anything that is not the expected
    /// JSON reads as "the server said nothing".
    static func parse(body: Data, requested: String) -> StoredUpload {
        let response = try? JSONDecoder().decode(UploadChunkResponse.self, from: body)
        return resolve(requested: requested, response: response)
    }

    /// The best guess when the completing answer is gone — an upload whose last chunk landed
    /// while the app was closed and whose poll is picked up again on the next launch.
    ///
    /// A PNG or JPEG is stored as the PDF of the same stem (`searchablePdf.js` keeps the stem and
    /// changes the extension); anything else keeps its sanitised name. The one case this cannot
    /// know is a photo whose PDF name was already taken, which the server stores as
    /// `Stem__2_.pdf` — that poll reads "unconfirmed", and the document is in My Files regardless.
    static func assumed(requested: String) -> StoredUpload {
        let sent = UploadService.sanitize(fileName: requested)
        guard let dot = sent.lastIndex(of: "."), dot != sent.startIndex else {
            return StoredUpload(name: sent, convertedFrom: nil)
        }
        let ext = sent[sent.index(after: dot)...].lowercased()
        guard convertedExtensions.contains(String(ext)) else {
            return StoredUpload(name: sent, convertedFrom: nil)
        }
        return StoredUpload(name: sent[..<dot] + ".pdf", convertedFrom: sent)
    }

    /// The image types the server converts on arrival (`isConvertibleImageName`). TIFF and BMP
    /// are accepted only for conversion and this client never offers them.
    static let convertedExtensions: Set<String> = ["png", "jpg", "jpeg"]

    /// The line the upload panel adds under a converted photo: "Saved as Photo_1.pdf".
    var notice: String? {
        wasConverted ? "Saved as \(DisplayText.fileName(name))" : nil
    }
}
