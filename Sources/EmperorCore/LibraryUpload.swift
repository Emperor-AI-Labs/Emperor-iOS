import Foundation

/// The rules for putting a document into the library, shared by the attach picker and My Files.
///
/// The transfer itself is `BackgroundUploader`'s and the duplicate question is `DuplicateCheck`'s.
/// What lives here is what both screens must agree on before either starts: which documents the
/// library can hold, how a picked file is matched to the server's verdict about it, and what a
/// photo — which has no name of its own — is called.
enum LibraryUpload {

    /// The types the library holds.
    ///
    /// The web's upload dialog accepts exactly these (`accept=` on
    /// `src/components/upload/UploadModal.jsx:569`), and `/user-files` lists only these
    /// (`sync-server.js:14318`). The second is the one that matters: a document of any other type
    /// uploads, is stored, and then never appears in any list — so it could neither be attached
    /// nor deleted from here. A photo from the library is usually HEIC, which is why photos are
    /// converted to JPEG before they are offered.
    static let acceptedExtensions = ["pdf", "docx", "doc", "odt", "rtf", "txt", "csv", "png", "jpg", "jpeg"]

    static func isAccepted(fileName: String) -> Bool {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return false }
        let ext = fileName[fileName.index(after: dot)...].lowercased()
        return acceptedExtensions.contains(ext)
    }

    /// What to say about picked documents the library cannot hold. `nil` when there are none.
    static func refusal(for fileNames: [String]) -> String? {
        let refused = fileNames.filter { !isAccepted(fileName: $0) }
        guard !refused.isEmpty else { return nil }
        let subject = refused.count == 1 ? "\(refused[0]) was" : "\(DisplayText.list(refused)) were"
        return "\(subject) not added. The library holds PDF, Word, OpenDocument, RTF, text, CSV, "
            + "PNG and JPEG documents."
    }

    /// The server's verdict for each picked file, in the order the files were picked.
    ///
    /// Matched **by hash**, never by position: the server caps the batch and may answer short, and
    /// pairing a short answer up by index would attribute one document's verdict to another. A
    /// file with no hash — one that could not be read to hash it — or no verdict is uploaded
    /// without a question, because the check is a courtesy and must never block an upload
    /// (`DuplicateCheck`).
    static func decisions(
        forHashes hashes: [String?], results: [DuplicateCheck.Result]
    ) -> [DuplicateCheck.Decision] {
        var byHash: [String: DuplicateCheck.Result] = [:]
        for result in results {
            if let hash = result.hash, byHash[hash] == nil { byHash[hash] = result }
        }
        return hashes.map { hash in
            hash.flatMap { byHash[$0] }.map(DuplicateCheck.decision(for:)) ?? .upload
        }
    }

    /// A name for a photo, which arrives from the photo library with none.
    ///
    /// The moment it was added, in India — the same clock every other date in the product reads —
    /// with only the characters that survive the server's filename sanitiser, so the name shown
    /// in the list is the name that was sent. `index` separates photos picked together, which
    /// would otherwise share a second and overwrite each other on arrival.
    static func photoFileName(at date: Date, index: Int = 0) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WireDate.india
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d-%02d-%02d_%02d%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return index > 0 ? "Photo_\(stamp)_\(index + 1).jpg" : "Photo_\(stamp).jpg"
    }
}
