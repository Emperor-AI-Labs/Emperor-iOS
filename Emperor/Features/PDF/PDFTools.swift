import Foundation
import PDFKit
import UIKit

/// Splitting and merging, entirely on the device.
///
/// Image compression lives here too (`compress(image:targetBytes:)`) and matches the platform's
/// `/tools/compress-image`, but **no screen reaches it** — `PDFToolsView` offers Split and Merge
/// only. It is listed in `README.md` under what is built but not yet reachable, so it is findable
/// rather than a surprise.
///
/// **Nothing here is uploaded.** These are the operations an advocate does to a paperbook before
/// filing it, and the documents are privileged — sending a client's brief to a server to cut
/// three pages out of it would be the wrong trade even if the platform offered the route, which
/// it does not: the web's own PDF tools are client-side too.
///
/// ## The rule that governs all of it
///
/// **Pages are copied structurally, never re-rendered.** `PDFDocument.insert(_:at:)` carries the
/// page's own content stream across, so text stays selectable, searchable and copyable and any
/// OCR layer survives. Drawing each page into a new graphics context would produce a file that
/// looks identical, cannot be searched, and is usually *larger* — and on a bundle whose whole
/// purpose is to be cited from, that is a silent downgrade nobody would notice until they tried
/// to find a paragraph.
///
/// This is easier here than on Android, which had to bundle PDFBox for the same guarantee.
/// PDFKit is part of the OS.
enum PDFTools {

    enum Failure: LocalizedError {
        case unreadable
        case empty
        case nothingSelected
        case needsTwo
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That file could not be opened. It may be password-protected or damaged."
            case .empty:
                return "That document has no pages."
            case .nothingSelected:
                return "No pages were selected."
            case .needsTwo:
                return "Merging needs at least two documents."
            case .writeFailed:
                return "The result could not be written."
            }
        }
    }

    /// One output: bytes, and the name they should be filed under.
    struct Output: Identifiable {
        let name: String
        let data: Data
        var id: String { name }
    }

    // MARK: - Reading

    static func pageCount(of url: URL) -> Int? {
        PDFDocument(url: url)?.pageCount
    }

    // MARK: - Extract

    /// Pulls the named pages into **one** document, in page order.
    ///
    /// `PageRanges.parse` flattens and de-duplicates, so `3-1, 2` and `1-3` extract the same
    /// three pages and asking for page 2 twice cannot include it twice.
    static func extract(from url: URL, selection: String, baseName: String) throws -> Output {
        let source = try open(url)
        let pages = PageRanges.parse(selection, pageCount: source.pageCount)
        guard !pages.isEmpty else { throw Failure.nothingSelected }

        let output = PDFDocument()
        for (position, page) in pages.enumerated() {
            // `pages` is 1-based, PDFKit is 0-based. Converted here, once, at the boundary —
            // which is exactly why `PageRanges` stays 1-based throughout.
            guard let copied = source.page(at: page - 1) else { continue }
            output.insert(copied, at: position)
        }
        return try write(output, named: "\(baseName)_\(PageRanges.label(pages)).pdf")
    }

    // MARK: - Split

    /// Each comma-separated segment becomes its **own** document.
    ///
    /// `1-3, 5, 8-10` produces three files, not one of seven pages — the difference between
    /// split and extract, and the reason `PageRanges` exposes both.
    static func split(_ url: URL, selection: String, baseName: String) throws -> [Output] {
        let source = try open(url)
        let groups = PageRanges.parseGroups(selection, pageCount: source.pageCount)
        guard !groups.isEmpty else { throw Failure.nothingSelected }

        return try groups.map { group in
            let output = PDFDocument()
            for (position, page) in group.pages.enumerated() {
                guard let copied = source.page(at: page - 1) else { continue }
                output.insert(copied, at: position)
            }
            return try write(output, named: "\(baseName)_\(group.label).pdf")
        }
    }

    /// Every page as its own file.
    static func splitEveryPage(_ url: URL, baseName: String) throws -> [Output] {
        let source = try open(url)
        guard source.pageCount > 0 else { throw Failure.empty }
        // Zero-padded so a file browser sorts page 2 before page 10 — an unpadded split of a
        // 200-page bundle lists as 1, 10, 100, 101…
        let width = String(source.pageCount).count
        return try (0..<source.pageCount).map { index in
            let output = PDFDocument()
            if let page = source.page(at: index) { output.insert(page, at: 0) }
            let number = String(format: "%0\(width)d", index + 1)
            return try write(output, named: "\(baseName)_\(number).pdf")
        }
    }

    /// Consecutive pages packed into parts no larger than `targetBytes`.
    ///
    /// Sizes are measured by writing each page out, because a PDF page has no size until it is
    /// serialised — there is no cheaper honest answer.
    static func splitBySize(_ url: URL, targetBytes: Int, baseName: String) throws -> [Output] {
        let source = try open(url)
        guard source.pageCount > 0 else { throw Failure.empty }

        let sizes: [Int] = (0..<source.pageCount).map { index in
            let single = PDFDocument()
            if let page = source.page(at: index) { single.insert(page, at: 0) }
            return single.dataRepresentation()?.count ?? 0
        }

        return try PageRanges.packBySize(sizes, targetBytes: targetBytes).map { part in
            let output = PDFDocument()
            for (position, page) in part.enumerated() {
                guard let copied = source.page(at: page - 1) else { continue }
                output.insert(copied, at: position)
            }
            return try write(output, named: "\(baseName)_\(PageRanges.label(part)).pdf")
        }
    }

    // MARK: - Merge

    /// Joins documents in the order given.
    ///
    /// Order is the caller's, deliberately: a paperbook is assembled in a sequence the registry
    /// expects, and sorting by filename would quietly reorder an annexure bundle.
    static func merge(_ urls: [URL], name: String) throws -> Output {
        guard urls.count >= 2 else { throw Failure.needsTwo }
        let output = PDFDocument()
        var position = 0
        for url in urls {
            let source = try open(url)
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index) else { continue }
                output.insert(page, at: position)
                position += 1
            }
        }
        guard position > 0 else { throw Failure.empty }
        return try write(output, named: name.hasSuffix(".pdf") ? name : "\(name).pdf")
    }

    // MARK: - Compress an image

    /// Trades quality before resolution, the way the platform's own `CompressImage` does.
    ///
    /// A scan that has been downscaled is a scan whose small print has stopped being legible,
    /// which for an exhibit is worse than a larger file. So quality is spent first, and the
    /// image is only made smaller once the lowest useful quality still overshoots.
    ///
    /// Returns the smallest result it achieved even when that is still over target — with the
    /// caller expected to say so, because refusing to produce anything is not more helpful than
    /// producing something honest about its size.
    ///
    /// - Note: **no caller.** `PDFToolsView` offers Split and Merge only, so the "caller expected
    ///   to say so" above is currently nobody. Kept rather than deleted because the platform
    ///   ships the same tool at `/tools/compress-image` and this is the whole of the work; what
    ///   is missing is a third `Mode` case and a picker that takes an image instead of a PDF.
    static func compress(image: UIImage, targetBytes: Int) -> Data? {
        for quality in stride(from: 0.9, through: 0.3, by: -0.1) {
            guard let data = image.jpegData(compressionQuality: quality) else { continue }
            if data.count <= targetBytes { return data }
        }

        var working = image
        var smallest = image.jpegData(compressionQuality: 0.3)
        // Six halvings floors a 12 MP photo at roughly 50 KP, past which an exhibit is not worth
        // keeping. Bounded so a target of 1 byte cannot loop forever.
        for _ in 0..<6 {
            let size = CGSize(width: working.size.width * 0.75, height: working.size.height * 0.75)
            guard size.width >= 200, size.height >= 200 else { break }
            let renderer = UIGraphicsImageRenderer(size: size)
            working = renderer.image { _ in working.draw(in: CGRect(origin: .zero, size: size)) }
            guard let data = working.jpegData(compressionQuality: 0.6) else { break }
            smallest = data
            if data.count <= targetBytes { return data }
        }
        return smallest
    }

    // MARK: - Plumbing

    private static func open(_ url: URL) throws -> PDFDocument {
        // A picker URL is security-scoped and must be opened before it can be read.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable }
        guard document.pageCount > 0 else { throw Failure.empty }
        return document
    }

    private static func write(_ document: PDFDocument, named name: String) throws -> Output {
        guard document.pageCount > 0 else { throw Failure.nothingSelected }
        guard let data = document.dataRepresentation() else { throw Failure.writeFailed }
        return Output(name: name, data: data)
    }
}
