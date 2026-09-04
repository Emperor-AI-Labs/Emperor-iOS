import SwiftUI
import UIKit
import PDFKit

/// A PDF held in memory, optionally opened at a page.
///
/// Shared by the citation viewer and the order viewer so the page-jump behaviour cannot drift
/// between them — landing on the right page is the product's central claim in one case and the
/// whole point of the fetch in the other.
struct PDFDataView: UIViewRepresentable {
    let data: Data
    /// The cited page, **1-based**. `SourceDocumentViewModel.pageIndex` converts and clamps it.
    var page: Int?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false, withViewOptions: nil)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard view.document == nil, let document = PDFDocument(data: data) else { return }
        view.document = document

        guard let index = SourceDocumentViewModel.pageIndex(
            for: page, pageCount: document.pageCount),
              let target = document.page(at: index) else { return }
        // Deferred: PDFView ignores go(to:) until it has laid the document out.
        DispatchQueue.main.async {
            view.go(to: target)
        }
    }
}

/// Writes bytes to a temporary file so they can be shared.
///
/// `ShareLink` needs a `Transferable`, and `Data` is not one — a `URL` is. The file lands in
/// the temporary directory, which the system reclaims, so nothing confidential outlives the
/// share sheet by long.
@MainActor
enum ShareableFile {
    static func url(for data: Data, named name: String) -> URL? {
        // A `/` here would become a path separator, the intermediate directory would not
        // exist, and the write would throw — making the Share button silently disappear for
        // any document whose name carries a court reference like "W.P.(C) 1234/2024".
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = cleaned.isEmpty ? "Document.pdf" : cleaned
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmperorShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(safe)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            // Last resort: a name we know is writable, so sharing never silently vanishes.
            let fallback = directory.appendingPathComponent("\(UUID().uuidString).pdf")
            return (try? data.write(to: fallback, options: .atomic)) == nil ? nil : fallback
        }
    }

    /// Removes everything this has written. Called on sign-out: a shared order PDF sitting in
    /// `tmp` would otherwise outlive the session that fetched it.
    ///
    /// `nonisolated` because it is called from `ResponseCache.onClear`, which is `@Sendable` —
    /// a `@Sendable` closure literal gets no MainActor inference, so an isolated method would
    /// not compile there. It touches only `FileManager`, so there is no actor state to protect.
    nonisolated static func clear() {
        try? FileManager.default.removeItem(
            at: FileManager.default.temporaryDirectory
                .appendingPathComponent("EmperorShare", isDirectory: true))
    }
}
