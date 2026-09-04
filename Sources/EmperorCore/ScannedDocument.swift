import Foundation

/// A paperbook captured by the camera, assembled into one PDF.
///
/// Pages are combined client-side so the DMS receives one document per bundle rather than a
/// pile of loose images. The capture itself is VisionKit's job and stays in the app target;
/// this is the part worth pinning down without a camera.
struct ScannedDocument: Equatable {
    var pdfData: Data
    var suggestedName: String

    /// Names a scan after the moment it was taken.
    ///
    /// Colons are stripped because the server sanitises them to `_` anyway
    /// (`UploadService.sanitize`) — doing it here means the name shown in the composer is the
    /// name that ends up on disk, rather than a near-miss the user has to reconcile.
    ///
    /// - Parameter date: injected rather than read from the clock so the result is assertable.
    static func suggestedName(for date: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        return "Scan-\(stamp).pdf"
    }

    /// Where scans are filed. A fixed folder rather than a prompt: the point of scanning in
    /// court is that it takes one tap, and the document can be moved later on the web.
    static let folderName = "Scans"
}

enum ScanError: LocalizedError, Equatable {
    case noPages
    case pdfGenerationFailed

    var errorDescription: String? {
        switch self {
        case .noPages: return "No pages were captured."
        case .pdfGenerationFailed: return "Those pages could not be assembled into a PDF."
        }
    }
}
