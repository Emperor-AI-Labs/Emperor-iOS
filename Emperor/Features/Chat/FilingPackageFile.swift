import Foundation
import PDFKit
import UIKit

/// Lays a filing-ready package out as a file. What goes in, and in what order, is
/// `FilingPackage`'s; this only does what needs UIKit and PDFKit.
///
/// - **Word:** the package as one HTML fragment through the same exporter as any draft, with the
///   originals' pages as pictures.
/// - **PDF:** the draft and every typed copy laid out by `AnswerPDF`, the same renderer as a
///   draft's own PDF; each original PDF merged after its heading, page for page, by the Merge
///   tool's code — so its text stays selectable and any OCR layer survives; a photograph placed on
///   an A4 page as the Image to PDF tool places it.
@MainActor
enum FilingPackageFile {

    enum Failure: LocalizedError {
        case lockedOriginal

        var errorDescription: String? {
            "One of the original annexures is password-protected, so it could not be merged. "
                + "Remove the password from it in Files and try again."
        }
    }

    static func render(_ pieces: [FilingPackage.Piece], as format: FilingPackage.Format) throws -> Data {
        switch format {
        case .word: return DocxDocument.make(fromHTML: FilingPackage.wordHTML(pieces))
        case .pdf: return try pdf(pieces)
        }
    }

    private static func pdf(_ pieces: [FilingPackage.Piece]) throws -> Data {
        var documents: [PDFDocument] = []
        for segment in FilingPackage.pdfSegments(pieces) {
            switch segment {
            case .html(let html):
                if let document = PDFDocument(data: AnswerPDF.render(html: html)) {
                    documents.append(document)
                }
            case .pdf(let data):
                guard let document = PDFDocument(data: data) else { throw PDFTools.Failure.unreadable }
                guard !document.isLocked else { throw Failure.lockedOriginal }
                documents.append(document)
            case .image(let data):
                if let document = imagePage(data) { documents.append(document) }
            }
        }
        guard let data = try PDFTools.merged(documents).dataRepresentation() else {
            throw PDFTools.Failure.writeFailed
        }
        return data
    }

    /// One picture, fitted inside the margins of an A4 page.
    private static func imagePage(_ data: Data) -> PDFDocument? {
        guard let image = UIImage(data: data) else { return nil }
        let page = ImagePDFLayout.PageSize.a4
        let (width, height) = page.points
        let placement = ImagePDFLayout.placement(
            imageWidth: Double(image.size.width * image.scale),
            imageHeight: Double(image.size.height * image.scale), on: page)
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: height))
            .pdfData { context in
                context.beginPage()
                image.draw(in: CGRect(
                    x: placement.x, y: placement.topLeftY(pageHeight: height),
                    width: placement.width, height: placement.height))
            }
        return PDFDocument(data: bytes)
    }
}
