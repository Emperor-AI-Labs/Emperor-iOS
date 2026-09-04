import SwiftUI
import VisionKit
import PDFKit

/// Wraps the system document camera.
///
/// Scanning is the strongest reason for this app to exist on a phone: it turns a physical
/// paperbook on a courtroom desk into something the model can read, without a desktop
/// scanner. Pages are assembled client-side into a single PDF so the DMS receives one
/// document per bundle rather than a pile of loose images.
///
/// `ScannedDocument` and `ScanError` live in the core, along with the naming rule — what is
/// left here is only what genuinely needs a camera.
struct DocumentScannerView: UIViewControllerRepresentable {
    var onFinish: (Result<ScannedDocument, Error>) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onFinish: (Result<ScannedDocument, Error>) -> Void

        init(onFinish: @escaping (Result<ScannedDocument, Error>) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            guard scan.pageCount > 0 else {
                onFinish(.failure(ScanError.noPages))
                return
            }

            let document = PDFDocument()
            for index in 0..<scan.pageCount {
                let image = scan.imageOfPage(at: index)
                if let page = PDFPage(image: image) {
                    document.insert(page, at: document.pageCount)
                }
            }

            guard let data = document.dataRepresentation() else {
                onFinish(.failure(ScanError.pdfGenerationFailed))
                return
            }

            // A scan is an image-only PDF, so the server will mark it "scanned" rather than
            // OCR it. That is still usable — the model reads those pages visually.
            onFinish(.success(ScannedDocument(
                pdfData: data,
                suggestedName: ScannedDocument.suggestedName(for: Date()))))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            // Cancelling is not an error; the sheet simply closes.
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController, didFailWithError error: Error
        ) {
            onFinish(.failure(error))
        }
    }
}
