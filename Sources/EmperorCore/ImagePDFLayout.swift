import Foundation

/// Where each image lands on its page — the platform's `/tools/image-to-pdf`.
///
/// A port of `src/lib/imagePdf.js`: one page per image, the page at a chosen paper size, the
/// image fitted inside a uniform 40-point margin keeping its proportions, and centred.
/// `ImagePDFLayoutTests` holds the arithmetic to a fixture made by running `imagesToPdf` itself
/// under Node with a pdf-lib stand-in that records every page and every placement.
///
/// The fit is a true fit, as on the web: a small image is scaled *up* to fill the usable area,
/// so a page never carries a postage stamp in the middle of white space.
enum ImagePDFLayout {

    /// The paper sizes the web offers, in its order (`imagePdf.js:12-17`).
    enum PageSize: String, CaseIterable, Identifiable, Sendable {
        case a4 = "A4"
        case a3 = "A3"
        case letter = "Letter"
        case legal = "Legal"

        var id: String { rawValue }

        /// Width and height in points (1/72 inch), portrait.
        var points: (width: Double, height: Double) {
            switch self {
            case .a4: return (595.28, 841.89)
            case .a3: return (841.89, 1190.55)
            case .letter: return (612, 792)
            case .legal: return (612, 1008)
            }
        }
    }

    /// Blank space around each image, in points (`imagePdf.js:20`).
    static let margin = 40.0

    /// A rectangle in PDF page space: origin at the **bottom-left**, as pdf-lib draws.
    struct Placement: Equatable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        /// The same rectangle measured from the top, for a drawing context whose origin is the
        /// top-left (UIKit's). Centring makes the two equal, but saying so is clearer than
        /// relying on it.
        func topLeftY(pageHeight: Double) -> Double { pageHeight - y - height }
    }

    /// `imagePdf.js:61-75`, for one image.
    ///
    /// - Parameters:
    ///   - imageWidth, imageHeight: the image's upright pixel size.
    static func placement(imageWidth: Double, imageHeight: Double, on page: PageSize) -> Placement {
        let (pageWidth, pageHeight) = page.points
        let usableWidth = pageWidth - margin * 2
        let usableHeight = pageHeight - margin * 2
        let scale = min(usableWidth / imageWidth, usableHeight / imageHeight)
        let width = imageWidth * scale
        let height = imageHeight * scale
        return Placement(
            x: (pageWidth - width) / 2, y: (pageHeight - height) / 2,
            width: width, height: height)
    }

    /// The extensions the web accepts (`imagePdf.js:9`).
    static let webExtensions = [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"]

    /// What this client accepts: the web's list, plus what an iPhone's own camera and scanner
    /// write. HEIC is the camera's default format, so leaving it out would refuse most photos
    /// on the phone they were taken with.
    static let acceptedExtensions = webExtensions + [".heic", ".heif", ".tif", ".tiff"]

    static func isAccepted(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return acceptedExtensions.contains { lower.hasSuffix($0) }
    }

    /// `files[0].name.replace(/\.[^.]+$/, '') + '_images.pdf'`, or `images.pdf`
    /// (`ImageToPdf.jsx:36`).
    static func outputName(firstImageName: String?) -> String {
        guard let firstImageName else { return "images.pdf" }
        return ToolFileName.removingExtension(firstImageName) + "_images.pdf"
    }

    // MARK: - How each image is carried into the PDF

    /// How an image's bytes become a page.
    ///
    /// The web embeds JPEG and PNG as they are and rasterises everything else to PNG
    /// (`imagePdf.js:33-53`) — lossless, so nothing is lost that the source had. The same intent
    /// here, with one case the web never meets: an iPhone photo is HEIC, and carrying a 12 MP
    /// photograph losslessly would make a single page tens of megabytes. Photographic formats
    /// therefore become a high-quality JPEG; graphic ones stay lossless.
    enum Embedding: Equatable, Sendable {
        /// The file's own JPEG bytes, untouched.
        case originalJPEG
        /// Re-encoded as a JPEG at `reencodeQuality`.
        case jpeg
        /// Drawn without loss, keeping transparency.
        case lossless
    }

    static let reencodeQuality = 0.9

    /// The extension an image's bytes actually call for, read from its signature.
    ///
    /// A photo-library item has no filename, and what it hands over is not always the format its
    /// listing implies — the library may transcode on the way out. Naming the bytes by what they
    /// are keeps `embedding(forFileName:isUpright:)` from passing HEIC through as if it were a
    /// JPEG. `nil` when the signature is not one recognised here.
    static func sniffedExtension(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if starts(Array("GIF8".utf8)) { return "gif" }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return "webp" }
        if starts(Array("BM".utf8)) { return "bmp" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if starts(Array("ftyp".utf8), at: 4) {
            let brand = String(decoding: bytes.dropFirst(8).prefix(4), as: UTF8.self)
            if ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"].contains(brand) { return "heic" }
        }
        return nil
    }

    /// - Parameter isUpright: whether the image needs no rotation to display. A JPEG carrying an
    ///   EXIF rotation is redrawn upright rather than passed through: the web embeds the raw
    ///   bytes, which is how a portrait phone photo ends up on its side in its PDF.
    static func embedding(forFileName name: String, isUpright: Bool) -> Embedding {
        let lower = name.lowercased()
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") {
            return isUpright ? .originalJPEG : .jpeg
        }
        if lower.hasSuffix(".heic") || lower.hasSuffix(".heif") { return .jpeg }
        return .lossless
    }
}
