import Foundation

/// The document utilities — the platform's `/tools` hub (`src/pages/tools/ToolsHub.jsx`).
///
/// Order and wording follow the web, which lists the document jobs together and keeps Compress
/// Image apart from them as "a media job, not a document job" (`src/shell/Sidebar.jsx:297-298`).
///
/// ## The line every tool here sits on one side of
///
/// The web says it plainly: Split, Merge, Compress, Rearrange and Image to PDF run entirely in
/// the browser and those files never leave the device; PDF to DOCX is processed on the server
/// (`ToolsHub.jsx:47`). This client keeps exactly that line. The on-device tools never touch the
/// network — the documents are privileged, and uploading a client's brief to reorder its pages
/// would be the wrong trade even if a route existed. `isOnDevice` is what the hub shows, and
/// `DocumentToolTests` pins which side each tool is on.
enum DocumentTool: String, CaseIterable, Identifiable, Sendable {
    case pdfToWord
    case split
    case merge
    case rearrange
    case compressPDF
    case imageToPDF
    case compressImage

    var id: String { rawValue }

    /// The tools grouped as the hub shows them.
    static let documentTools: [DocumentTool] = [
        .split, .merge, .rearrange, .compressPDF, .imageToPDF, .pdfToWord,
    ]
    static let imageTools: [DocumentTool] = [.compressImage]

    var title: String {
        switch self {
        case .pdfToWord: return "PDF to Word"
        case .split: return "Split PDF"
        case .merge: return "Merge PDF"
        case .rearrange: return "Rearrange PDF"
        case .compressPDF: return "Compress PDF"
        case .imageToPDF: return "Image to PDF"
        case .compressImage: return "Compress image"
        }
    }

    /// One line, from the web's own card where it is true here too.
    var summary: String {
        switch self {
        case .pdfToWord:
            return "Convert a PDF into an editable, clearly formatted Word document."
        case .split:
            return "Extract page ranges or break a PDF into separate files."
        case .merge:
            return "Combine several PDFs into one, in the order you choose."
        case .rearrange:
            return "Reorder pages exactly as you describe — backwards, or the same page more than once."
        case .compressPDF:
            // The web re-encodes the images inside a page. PDFKit cannot reach into a page's
            // image streams, so here the scanned and photographed pages are redrawn instead —
            // and the card says which pages that touches.
            return "Shrink a PDF by re-encoding its scanned and photographed pages. Typed pages are left as they are."
        case .imageToPDF:
            return "Turn photos and images into a PDF — one image per page."
        case .compressImage:
            return "Bring a photo or scan down to a target file size."
        }
    }

    /// SF Symbol, chosen to read as the web's `lucide` icon for the same card.
    var symbol: String {
        switch self {
        case .pdfToWord: return "doc.text"
        case .split: return "scissors"
        case .merge: return "square.stack.3d.down.right"
        case .rearrange: return "arrow.up.arrow.down"
        case .compressPDF: return "arrow.down.doc"
        case .imageToPDF: return "photo.on.rectangle"
        case .compressImage: return "photo"
        }
    }

    /// Whether the file stays on the phone. Only PDF to Word is uploaded, as on the web.
    var isOnDevice: Bool { self != .pdfToWord }
}

/// A finished file, ready for the share sheet.
struct ToolFile: Identifiable, Equatable, Sendable {
    let name: String
    let data: Data
    var id: String { name }
}

/// Where a tool's one action stands.
enum ToolRunState: Equatable, Sendable {
    case idle
    case running
    case finished
    case failed(String)

    var isRunning: Bool { self == .running }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// The on-device work behind the tools, so the view models can be driven without PDFKit.
///
/// Every input is a local file URL — the app copies a picked file into its own temporary space
/// first — so nothing here holds a security-scoped resource open across an `await`.
protocol DocumentToolEngine: Sendable {
    /// The pages, in exactly this order, duplicates included.
    func rearrange(_ source: URL, pages: [Int], outputName: String) async throws -> ToolFile

    /// - Parameter progress: called with a fraction from 0 to 1 as pages are processed, from
    ///   whatever thread the work runs on.
    func compressPDF(
        _ source: URL, level: PDFCompression.Level,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PDFCompression.Result

    func compressImage(_ source: URL, targetBytes: Int) async throws -> ImageCompression.Report

    /// One page per image, in the order given.
    func imagesToPDF(
        _ images: [URL], pageSize: ImagePDFLayout.PageSize, outputName: String
    ) async throws -> ToolFile
}

/// Byte sizes the way every one of the web's tools prints them.
///
/// A port of `fmtBytes` (`src/pages/tools/_shared.jsx:8-13`): 1024-based, one decimal for KB and
/// two for MB. Not `ByteCountFormatter`, which counts in thousands — Compress Image takes its
/// target in KB of 1024 bytes (`CompressImage.jsx:92`), so a result printed in thousands would
/// read as overshooting a target it actually met.
enum FileSize {
    static func format(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(fixed(bytes, divisor: 1024, places: 1)) KB" }
        return "\(fixed(bytes, divisor: 1024 * 1024, places: 2)) MB"
    }

    /// `toFixed`, done in integers. JavaScript rounds the exact quotient half-up; `%.1f` rounds
    /// the binary value half-to-even. A byte count over a power of two is exact in both, so
    /// integer arithmetic reproduces the web's rounding without depending on either.
    private static func fixed(_ bytes: Int, divisor: Int, places: Int) -> String {
        let scale = places == 1 ? 10 : 100
        let scaled = (bytes * scale * 2 + divisor) / (divisor * 2)
        let fraction = String(scaled % scale)
        return "\(scaled / scale).\(String(repeating: "0", count: places - fraction.count))\(fraction)"
    }
}

/// Filename helpers shared by the tools, each a port of the web's regex for the same job.
enum ToolFileName {
    /// `name.replace(/\.[^.]+$/, '')` — the last extension, if it has at least one character.
    static func removingExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), name.index(after: dot) < name.endIndex else {
            return name
        }
        return String(name[..<dot])
    }

    /// `name.replace(/\.pdf$/i, '')`.
    static func removingPDFExtension(_ name: String) -> String {
        name.suffix(4).lowercased() == ".pdf" ? String(name.dropLast(4)) : name
    }
}
