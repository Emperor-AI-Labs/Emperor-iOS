import CoreGraphics
import CoreText
import Foundation
import PDFKit
import UIKit

/// The file tools' work, done on the phone with PDFKit and Core Graphics.
///
/// **Nothing here touches the network.** The decisions — which pages, what size, which order,
/// where an image sits — are made in the core (`PageOrder`, `PDFCompression`, `ImageCompression`,
/// `ImagePDFLayout`), where they are tested against the platform's own JavaScript. This file only
/// carries them out.
///
/// Everything runs off the main actor in a detached task, and stops between pages if the caller
/// is cancelled. Each input is a local copy the app made when the file was picked, so no
/// security-scoped resource is held open across the work.
struct OnDeviceToolEngine: DocumentToolEngine {

    enum Failure: LocalizedError {
        case missingPage(Int)
        case unreadableImage(String)

        var errorDescription: String? {
            switch self {
            case .missingPage(let page):
                return "Page \(page) could not be read from the document."
            case .unreadableImage(let name):
                return "\(name) could not be opened as an image."
            }
        }
    }

    func rearrange(_ source: URL, pages: [Int], outputName: String) async throws -> ToolFile {
        try await Self.offMain { try Self.rearrangeNow(source, pages: pages, outputName: outputName) }
    }

    func compressPDF(
        _ source: URL, level: PDFCompression.Level,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PDFCompression.Result {
        try await Self.offMain { try Self.compressNow(source, level: level, progress: progress) }
    }

    func compressImage(_ source: URL, targetBytes: Int) async throws -> ImageCompression.Report {
        try await Self.offMain { try Self.compressImageNow(source, targetBytes: targetBytes) }
    }

    func imagesToPDF(
        _ images: [URL], pageSize: ImagePDFLayout.PageSize, outputName: String
    ) async throws -> ToolFile {
        try await Self.offMain {
            try Self.imagesToPDFNow(images, pageSize: pageSize, outputName: outputName)
        }
    }

    /// Runs blocking work on a background thread, cancelling it with its caller.
    private static func offMain<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try work() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Opening

    private static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            throw PDFTools.Failure.unreadable
        }
        guard document.pageCount > 0 else { throw PDFTools.Failure.empty }
        return document
    }

    private static func fileSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Rearrange

    private static func rearrangeNow(_ url: URL, pages: [Int], outputName: String) throws -> ToolFile {
        let source = try open(url)
        let output = PDFDocument()
        for (position, number) in pages.enumerated() {
            try Task.checkCancellation()
            // A fresh copy for every slot. Inserting one page object twice would leave the
            // document referencing a single page from two places — the copy is what makes a
            // duplicated page a real second page (the web's `copyPages` makes the same point,
            // `RearrangePdf.jsx:179-183`). The copy is structural: text stays text.
            guard let page = source.page(at: number - 1), let copy = page.copy() as? PDFPage else {
                throw Failure.missingPage(number)
            }
            output.insert(copy, at: position)
        }
        guard output.pageCount > 0 else { throw PDFTools.Failure.nothingSelected }
        guard let data = output.dataRepresentation() else { throw PDFTools.Failure.writeFailed }
        return ToolFile(name: outputName, data: data)
    }

    // MARK: - Compress PDF

    /// One page's verdict: redrawn from this JPEG, or kept as it is.
    private struct Redraw {
        let index: Int
        let box: CGRect
        let jpeg: Data
        let lines: [(text: String, bounds: CGRect)]
    }

    /// See `PDFCompression` for the rules. In short: only image-backed pages are candidates,
    /// a candidate is redrawn as a JPEG at the level's size and quality, and the redraw is kept
    /// only if it beats the original page by the web's 3%.
    ///
    /// The redrawn pages are drawn into **one** new document, so the font behind their invisible
    /// text layer is embedded once rather than once per page, and then interleaved with the
    /// untouched originals.
    private static func compressNow(
        _ url: URL, level: PDFCompression.Level, progress: @Sendable (Double) -> Void
    ) throws -> PDFCompression.Result {
        let source = try open(url)
        let count = source.pageCount

        var redraws: [Redraw] = []
        for index in 0..<count {
            try Task.checkCancellation()
            if let page = source.page(at: index),
               let redraw = autoreleasepool(invoking: { redrawIfWorthIt(page, index: index, level: level) }) {
                redraws.append(redraw)
            }
            // The first 90% is deciding; the rest is writing the file.
            progress(0.9 * Double(index + 1) / Double(count))
        }

        let redrawn = try redrawnDocument(redraws)
        // Page index in the source → its position in the redrawn document.
        var positions: [Int: Int] = [:]
        for (position, redraw) in redraws.enumerated() { positions[redraw.index] = position }

        let output = PDFDocument()
        for index in 0..<count {
            guard let original = source.page(at: index) else { continue }
            if let position = positions[index], let redrawn,
               let replacement = redrawn.page(at: position)?.copy() as? PDFPage {
                // The redrawn page was drawn in the page's own unrotated space, so the
                // original's rotation makes it display exactly as the original did.
                replacement.rotation = original.rotation
                output.insert(replacement, at: output.pageCount)
            } else if let copy = original.copy() as? PDFPage {
                output.insert(copy, at: output.pageCount)
            }
        }
        guard let data = output.dataRepresentation() else { throw PDFTools.Failure.writeFailed }
        progress(1)

        let outcome = PDFCompression.Outcome(
            originalBytes: fileSize(url), compressedBytes: data.count,
            pageCount: count, pagesReencoded: redraws.count)
        return PDFCompression.Result(outcome: outcome, data: data)
    }

    private static func redrawIfWorthIt(
        _ page: PDFPage, index: Int, level: PDFCompression.Level
    ) -> Redraw? {
        // A page with annotations, links or form fields is left alone: redrawing would flatten
        // them into pixels, and a link that stops working is a worse file, not a smaller one.
        guard page.annotations.isEmpty, let pageRef = page.pageRef else { return nil }
        let box = pageRef.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0,
              let size = PDFCompression.rasterSize(
                pageWidth: Double(box.width), pageHeight: Double(box.height),
                imagePixels: imagePixels(on: pageRef), level: level)
        else { return nil }

        // The page measured on its own, as the web measures one image's bytes. A page under the
        // web's 4 KB floor is never worth touching.
        let single = PDFDocument()
        guard let copy = page.copy() as? PDFPage else { return nil }
        single.insert(copy, at: 0)
        guard let originalBytes = single.dataRepresentation()?.count,
              originalBytes >= PDFCompression.minimumBytes,
              let jpeg = rasterise(pageRef, box: box, width: size.width, height: size.height,
                                   quality: level.quality),
              PDFCompression.worthReplacing(originalBytes: originalBytes, candidateBytes: jpeg.count)
        else { return nil }

        return Redraw(index: index, box: box, jpeg: jpeg, lines: textLines(of: page))
    }

    /// The page drawn into a white bitmap of exactly `width × height` pixels, as a JPEG.
    private static func rasterise(
        _ pageRef: CGPDFPage, box: CGRect, width: Int, height: Int, quality: Double
    ) -> Data? {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            // The renderer's origin is the top-left; PDF space's is the bottom-left. Flip, scale
            // the box onto the bitmap, and move the box's corner to the origin. `drawPDFPage`
            // ignores the page's rotation, which is restored on the new page afterwards.
            let cg = context.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: size.width / box.width, y: -size.height / box.height)
            cg.translateBy(x: -box.minX, y: -box.minY)
            cg.drawPDFPage(pageRef)
        }
        return image.jpegData(compressionQuality: quality)
    }

    /// The page's text, a line at a time, with where each line sits — so it can be laid back
    /// over the picture of the page as invisible text, and search and copy keep working.
    private static func textLines(of page: PDFPage) -> [(text: String, bounds: CGRect)] {
        guard let selection = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }
            return (text: text, bounds: line.bounds(for: page))
        }
    }

    /// Draws every redrawn page into one document, in order.
    private static func redrawnDocument(_ redraws: [Redraw]) throws -> PDFDocument? {
        guard !redraws.isEmpty else { return nil }
        var cancelled = false
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            .pdfData { context in
                for redraw in redraws {
                    if Task.isCancelled {
                        cancelled = true
                        break
                    }
                    autoreleasepool {
                        let bounds = CGRect(origin: .zero, size: redraw.box.size)
                        context.beginPage(withBounds: bounds, pageInfo: [:])
                        drawJPEG(redraw.jpeg, in: bounds)
                        drawInvisibleText(redraw.lines, box: redraw.box, in: context.cgContext)
                    }
                }
            }
        if cancelled { throw CancellationError() }
        guard let document = PDFDocument(data: data), document.pageCount == redraws.count else {
            throw PDFTools.Failure.writeFailed
        }
        return document
    }

    /// The text layer, drawn in Core Graphics' invisible mode — the way a scanner's OCR layer is
    /// carried. Each line is stretched to the width it occupied, so a selection lands on the
    /// words it covers.
    private static func drawInvisibleText(
        _ lines: [(text: String, bounds: CGRect)], box: CGRect, in cg: CGContext
    ) {
        cg.saveGState()
        cg.setTextDrawingMode(.invisible)
        for line in lines where line.bounds.width > 1 && line.bounds.height > 1 {
            let font = UIFont.systemFont(ofSize: max(1, line.bounds.height * 0.8))
            let attributed = NSAttributedString(string: line.text, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attributed as CFAttributedString)
            let naturalWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard naturalWidth > 0 else { continue }
            // The renderer is top-left; the selection's bounds are in PDF space. Its bottom edge,
            // measured from the top, less a descender's worth, is the baseline.
            let bottomFromTop = box.height - (line.bounds.minY - box.minY)
            cg.textMatrix = CGAffineTransform(
                scaleX: line.bounds.width / CGFloat(naturalWidth), y: -1)
            cg.textPosition = CGPoint(
                x: line.bounds.minX - box.minX, y: bottomFromTop - line.bounds.height * 0.2)
            CTLineDraw(ctLine, cg)
        }
        cg.restoreGState()
    }

    /// Draws JPEG bytes so that the PDF carries the JPEG itself rather than a re-compression of
    /// its pixels: an image made with `jpegDataProviderSource` is passed through by a PDF
    /// context. Falls back to decoding when the bytes are not a JPEG after all.
    private static func drawJPEG(_ jpeg: Data, in rect: CGRect) {
        if let provider = CGDataProvider(data: jpeg as CFData),
           let image = CGImage(
            jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent) {
            UIImage(cgImage: image).draw(in: rect)
        } else {
            UIImage(data: jpeg)?.draw(in: rect)
        }
    }

    /// The total pixels of the images a page paints, read from its resources.
    ///
    /// PDFKit cannot say what a page is made of, so the page's own dictionary is read: each
    /// image XObject's `Width × Height`, and the images inside any form XObject, a few levels
    /// down. Resources a page inherits from its parent in the page tree are followed too.
    private static func imagePixels(on pageRef: CGPDFPage) -> Int {
        guard var node = pageRef.dictionary else { return 0 }
        for _ in 0..<8 {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(node, "Resources", &resources), let resources {
                return imagePixels(in: resources, depth: 0)
            }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(node, "Parent", &parent), let parent else { return 0 }
            node = parent
        }
        return 0
    }

    private static func imagePixels(in resources: CGPDFDictionaryRef, depth: Int) -> Int {
        var xObjects: CGPDFDictionaryRef?
        guard depth < 4, CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects),
              let xObjects
        else { return 0 }

        var total = 0
        CGPDFDictionaryApplyBlock(xObjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream)
            else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else {
                return true
            }
            switch String(cString: subtype) {
            case "Image":
                var width: CGPDFInteger = 0
                var height: CGPDFInteger = 0
                if CGPDFDictionaryGetInteger(dictionary, "Width", &width),
                   CGPDFDictionaryGetInteger(dictionary, "Height", &height),
                   width > 0, height > 0 {
                    total += min(Int(width), 100_000) * min(Int(height), 100_000)
                }
            case "Form":
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &inner), let inner {
                    total += OnDeviceToolEngine.imagePixels(in: inner, depth: depth + 1)
                }
            default:
                break
            }
            return true
        }, nil)
        return total
    }

    // MARK: - Compress image

    private static func compressImageNow(_ url: URL, targetBytes: Int) throws -> ImageCompression.Report {
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            throw ImageCompression.Failure.unreadable
        }
        // The upright pixel size: `size` already accounts for orientation, `scale` for points.
        let width = max(1, Int((image.size.width * image.scale).rounded()))
        let height = max(1, Int((image.size.height * image.scale).rounded()))

        let result = try ImageCompression.search(
            width: width, height: height, targetBytes: targetBytes
        ) { w, h, quality in
            try Task.checkCancellation()
            return autoreleasepool {
                let size = CGSize(width: w, height: h)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                // White first: JPEG has no alpha, and the web flattens onto white too
                // (`CompressImage.jsx:27-28`).
                let drawn = UIGraphicsImageRenderer(size: size, format: format).image { context in
                    UIColor.white.setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                return drawn.jpegData(compressionQuality: quality)
            }
        }
        return ImageCompression.Report(originalWidth: width, originalHeight: height, result: result)
    }

    // MARK: - Image to PDF

    private static func imagesToPDFNow(
        _ urls: [URL], pageSize: ImagePDFLayout.PageSize, outputName: String
    ) throws -> ToolFile {
        guard !urls.isEmpty else { throw PDFTools.Failure.nothingSelected }
        let (pageWidth, pageHeight) = pageSize.points
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        var failure: Error?
        let data = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { context in
            for url in urls {
                if failure != nil { break }
                if Task.isCancelled {
                    failure = CancellationError()
                    break
                }
                autoreleasepool {
                    guard let bytes = try? Data(contentsOf: url), let image = UIImage(data: bytes) else {
                        failure = Failure.unreadableImage(url.lastPathComponent)
                        return
                    }
                    let upright = (
                        width: Double(image.size.width * image.scale),
                        height: Double(image.size.height * image.scale))
                    let placement = ImagePDFLayout.placement(
                        imageWidth: upright.width, imageHeight: upright.height, on: pageSize)
                    let rect = CGRect(
                        x: placement.x, y: placement.topLeftY(pageHeight: pageHeight),
                        width: placement.width, height: placement.height)

                    context.beginPage()
                    switch ImagePDFLayout.embedding(
                        forFileName: url.lastPathComponent, isUpright: image.imageOrientation == .up) {
                    case .originalJPEG:
                        drawJPEG(bytes, in: rect)
                    case .jpeg:
                        if let jpeg = uprightJPEG(image) {
                            drawJPEG(jpeg, in: rect)
                        } else {
                            image.draw(in: rect)
                        }
                    case .lossless:
                        image.draw(in: rect)
                    }
                }
            }
        }
        if let failure { throw failure }
        return ToolFile(name: outputName, data: data)
    }

    /// The image redrawn the right way up and encoded as a high-quality JPEG.
    private static func uprightJPEG(_ image: UIImage) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return upright.jpegData(compressionQuality: ImagePDFLayout.reencodeQuality)
    }
}
