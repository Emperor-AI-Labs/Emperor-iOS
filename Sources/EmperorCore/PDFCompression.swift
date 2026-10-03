import Foundation

/// The decisions behind Compress PDF — the platform's `/tools/compress-pdf`.
///
/// ## What the web does, and what this does instead
///
/// The web walks the PDF's object graph with pdf-lib and re-encodes each embedded JPEG in place,
/// leaving text and vector drawing byte-for-byte alone (`src/pages/tools/CompressPdf.jsx:73-118`).
/// PDFKit has no way into a page's image streams, so that exact operation is not available on the
/// phone. The honest equivalent works a page at a time:
///
/// 1. A page is a candidate only if it carries enough image to be a scan or a photograph — see
///    `nativeSize`. Typed pages, which are what the web's approach leaves untouched, are left
///    untouched here too: they are copied structurally, so their text stays real text.
/// 2. A candidate is redrawn as a JPEG at the chosen level's resolution and quality — the same
///    three levels and numbers the web uses — with its text kept as an invisible layer so search
///    and copy still work.
/// 3. The redrawn page replaces the original only if it is meaningfully smaller, by the web's own
///    3% rule. Otherwise the original page is kept.
///
/// The result is offered only if the file as a whole got smaller, and the original is never
/// touched: the output is a new file the user chooses to share or save.
///
/// The level table and the two per-image rules are held to the web by `PDFCompressionTests`,
/// against a fixture made by running `recompressImage` itself under Node.
enum PDFCompression {

    struct Level: Identifiable, Equatable, Hashable, Sendable {
        /// The web's own id — `max`, `bal`, `low`.
        let id: String
        let label: String
        /// The longest side, in pixels, a re-encoded image may keep.
        let maxDimension: Int
        let quality: Double
        let detail: String
    }

    /// `CompressPdf.jsx:12-19`, in the web's order.
    static let levels: [Level] = [
        Level(id: "max", label: "Maximum", maxDimension: 1120, quality: 0.48,
              detail: "Smallest file — re-encoded for on-screen reading, fine for print at lower DPI."),
        Level(id: "bal", label: "Balanced", maxDimension: 1680, quality: 0.68,
              detail: "Good mix of size and quality — the default for most documents."),
        Level(id: "low", label: "Light", maxDimension: 2240, quality: 0.85,
              detail: "Best image quality, modest savings."),
    ]

    /// Balanced, as on the web (`CompressPdf.jsx:123`).
    static let defaultLevel = levels[1]

    /// Below this, re-encoding never pays off (`CompressPdf.jsx:39`). The web applies it to one
    /// image's bytes; here it applies to one page's.
    static let minimumBytes = 4096

    /// `Math.min(1, maxDim / Math.max(w, h))`, then `Math.max(1, Math.round(…))` per side
    /// (`CompressPdf.jsx:44-47`). Never scales up.
    static func scaledSize(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        let longest = Double(max(width, height))
        let scale = longest > 0 ? min(1, Double(maxDimension) / longest) : 1
        return (
            max(1, Int((Double(width) * scale).rounded(.toNearestOrAwayFromZero))),
            max(1, Int((Double(height) * scale).rounded(.toNearestOrAwayFromZero))))
    }

    /// A loss is only worth taking if it shrinks the original by more than 3%
    /// (`CompressPdf.jsx:55`: `blob.size >= jpeg.length - jpeg.length * 0.03` keeps the original).
    static func worthReplacing(originalBytes: Int, candidateBytes: Int) -> Bool {
        let original = Double(originalBytes)
        return !(Double(candidateBytes) >= original - original * 0.03)
    }

    // MARK: - Which pages, at what size

    /// A page counts as a scan or a photograph when its images hold at least half as many
    /// pixels as the page has points — about a full A4 page at 50 dpi, or half of it at 72.
    ///
    /// A letterhead logo, a seal or a signature falls well short, so a typed page carrying one
    /// is left alone; a scanned page at any usable resolution clears it easily.
    static let imagePixelsPerPoint = 0.5

    /// The size the page's own images imply: the page at the pixel density of its images.
    ///
    /// This is the page's equivalent of an embedded image's own width and height, which is what
    /// the web scales from — so the level's limit is applied the web's way and a low-resolution
    /// scan is never blown up past what it holds. `nil` when the page is not image-backed.
    ///
    /// - Parameters:
    ///   - pageWidth, pageHeight: the page's box, in points.
    ///   - imagePixels: the total pixel count of the images painted on the page.
    static func nativeSize(
        pageWidth: Double, pageHeight: Double, imagePixels: Int
    ) -> (width: Int, height: Int)? {
        let area = pageWidth * pageHeight
        guard area > 0, Double(imagePixels) >= area * imagePixelsPerPoint else { return nil }
        let density = (Double(imagePixels) / area).squareRoot()
        return (
            max(1, Int((pageWidth * density).rounded(.toNearestOrAwayFromZero))),
            max(1, Int((pageHeight * density).rounded(.toNearestOrAwayFromZero))))
    }

    /// The pixel size to redraw a page at, or `nil` if the page should be left alone.
    static func rasterSize(
        pageWidth: Double, pageHeight: Double, imagePixels: Int, level: Level
    ) -> (width: Int, height: Int)? {
        guard let native = nativeSize(
            pageWidth: pageWidth, pageHeight: pageHeight, imagePixels: imagePixels)
        else { return nil }
        return scaledSize(width: native.width, height: native.height, maxDimension: level.maxDimension)
    }

    // MARK: - The result

    struct Outcome: Equatable, Sendable {
        let originalBytes: Int
        let compressedBytes: Int
        let pageCount: Int
        let pagesReencoded: Int

        /// `Math.max(0, original - compressed)` (`CompressPdf.jsx:153`).
        var savedBytes: Int { max(0, originalBytes - compressedBytes) }

        /// `Math.round((saved / original) * 100)` (`CompressPdf.jsx:159`).
        var savedPercent: Int {
            guard originalBytes > 0 else { return 0 }
            return Int((Double(savedBytes) / Double(originalBytes) * 100 + 0.5).rounded(.down))
        }

        /// Whether there is anything worth offering. The web shows its Download button only
        /// when something was saved (`CompressPdf.jsx:228-230`).
        var hasReduction: Bool { savedBytes > 0 }

        /// Under 2% the web warns that nothing meaningful happened (`CompressPdf.jsx:154`).
        var isMeaningful: Bool { Double(savedBytes) >= Double(originalBytes) * 0.02 }

        /// The headline beside the two sizes.
        var headline: String { hasReduction ? "\(savedPercent)% smaller" : "No reduction" }

        /// What happened, in the user's terms — which pages were redrawn and which kept.
        var detail: String {
            guard isMeaningful else {
                return "No meaningful reduction — this PDF has few or small scanned or photographed pages."
            }
            let kept = pageCount - pagesReencoded
            let redrawn = "Re-encoded \(pagesReencoded) scanned or photographed page\(pagesReencoded == 1 ? "" : "s")"
            return kept == 0
                ? "\(redrawn)."
                : "\(redrawn); the other \(kept) \(kept == 1 ? "page is" : "pages are") unchanged."
        }
    }

    /// What the engine hands back: the outcome, and the new file's bytes.
    struct Result: Equatable, Sendable {
        let outcome: Outcome
        let data: Data
    }

    /// `name.replace(/\.pdf$/i, '') + '_compressed.pdf'` (`CompressPdf.jsx:169`).
    static func outputName(for sourceName: String) -> String {
        ToolFileName.removingPDFExtension(sourceName) + "_compressed.pdf"
    }
}
