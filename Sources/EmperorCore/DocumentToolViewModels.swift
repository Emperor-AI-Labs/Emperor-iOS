import Foundation
#if canImport(Darwin)
import Observation
#endif

/// A file the user picked, copied into the app's own space so it can be read at leisure.
struct PickedFile: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    /// The name the user knows it by, extension included.
    let name: String
    let bytes: Int

    init(id: UUID = UUID(), url: URL, name: String, bytes: Int) {
        self.id = id
        self.url = url
        self.name = name
        self.bytes = bytes
    }
}

// MARK: - Rearrange

/// Rearrange PDF — `src/pages/tools/RearrangePdf.jsx`.
///
/// The instruction is the single source of truth. The preview's chip actions (move, duplicate,
/// remove) never keep a parallel "edited" list: each rewrites the instruction through
/// `PageOrder.format`, so the text field and the preview are two views of one value and cannot
/// disagree (`RearrangePdf.jsx:157-168`).
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class RearrangeViewModel {

    private(set) var source: PickedFile?
    private(set) var pageCount = 0
    /// What the user typed. Bound to the text field.
    var spec = ""
    private(set) var state: ToolRunState = .idle
    /// The last file built, and the instruction it was built from — so a result never stays on
    /// screen beside an instruction that would produce something else.
    private var built: (spec: String, file: ToolFile)?

    private let engine: any DocumentToolEngine

    init(engine: any DocumentToolEngine) {
        self.engine = engine
    }

    /// Opens a document, seeded with its own order.
    func load(_ file: PickedFile, pageCount: Int) {
        source = file
        self.pageCount = pageCount
        spec = PageOrder.identity(pageCount: pageCount)
        state = .idle
        built = nil
    }

    func clear() {
        source = nil
        pageCount = 0
        spec = ""
        state = .idle
        built = nil
    }

    var parsed: PageOrder.Parsed { PageOrder.parse(spec, pageCount: pageCount) }

    /// "12 pages out · 2 repeated" (`RearrangePdf.jsx:270-273`).
    var countLine: String {
        let pages = parsed.pages
        let repeated = pages.count - Set(pages).count
        let out = "\(pages.count) page\(pages.count == 1 ? "" : "s") out"
        return repeated > 0 ? "\(out) · \(repeated) repeated" : out
    }

    /// Said rather than silently fixed: leaving pages out is a legitimate thing to want here,
    /// so it is a notice, not an error (`RearrangePdf.jsx:318-327`).
    var droppedNotice: String? {
        let dropped = parsed.dropped
        guard !dropped.isEmpty, !parsed.pages.isEmpty else { return nil }
        return "Page\(dropped.count > 1 ? "s" : "") \(PageOrder.summarise(dropped)) will not appear in the result."
    }

    var canRun: Bool { source != nil && !parsed.pages.isEmpty && !state.isRunning }

    var outputName: String {
        ToolFileName.removingPDFExtension(source?.name ?? "document") + "_rearranged.pdf"
    }

    /// The built file, if it still matches what is typed.
    var output: ToolFile? {
        guard let built, built.spec == spec else { return nil }
        return built.file
    }

    var resultMessage: String? {
        guard let output, state == .finished else { return nil }
        let count = parsed.pages.count
        return "Rearranged into \(count) page\(count == 1 ? "" : "s") — \(FileSize.format(output.data.count))."
    }

    // MARK: Editing through the preview

    func apply(_ example: PageOrder.Example) { spec = example.spec(pageCount: pageCount) }

    func resetOrder() { spec = PageOrder.identity(pageCount: pageCount) }

    /// "Add them to the end" (`RearrangePdf.jsx:324`).
    func appendDropped() {
        let current = parsed
        spec = PageOrder.format(current.pages + current.dropped)
    }

    func remove(at index: Int) {
        var pages = parsed.pages
        guard pages.indices.contains(index) else { return }
        pages.remove(at: index)
        spec = PageOrder.format(pages)
    }

    /// The copy goes straight after the original (`RearrangePdf.jsx:162`).
    func duplicate(at index: Int) {
        var pages = parsed.pages
        guard pages.indices.contains(index) else { return }
        pages.insert(pages[index], at: index + 1)
        spec = PageOrder.format(pages)
    }

    /// `moveTo` (`RearrangePdf.jsx:163-168`): out of range or onto itself does nothing.
    func move(from: Int, to: Int) {
        var pages = parsed.pages
        guard pages.indices.contains(from), pages.indices.contains(to), from != to else { return }
        pages.insert(pages.remove(at: from), at: to)
        spec = PageOrder.format(pages)
    }

    // MARK: Running

    func run() async {
        guard let source, canRun else { return }
        let request = spec
        let pages = parsed.pages
        state = .running
        do {
            let file = try await engine.rearrange(source.url, pages: pages, outputName: outputName)
            built = (request, file)
            state = .finished
        } catch {
            state = .failed(DisplayText.message(for: error))
        }
    }
}

// MARK: - Compress PDF

/// Compress PDF — `src/pages/tools/CompressPdf.jsx`. See `PDFCompression` for what is redrawn
/// and why.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class CompressPDFViewModel {

    private(set) var source: PickedFile?
    private(set) var pageCount = 0
    var level: PDFCompression.Level = PDFCompression.defaultLevel
    private(set) var state: ToolRunState = .idle
    /// From 0 to 1 while running.
    private(set) var progress = 0.0
    private(set) var outcome: PDFCompression.Outcome?
    /// Offered only when the file actually got smaller — the web shows no download otherwise.
    private(set) var output: ToolFile?
    /// The level the shown outcome was made at, so changing the level clears a stale result.
    private var outcomeLevel: PDFCompression.Level?

    private let engine: any DocumentToolEngine

    init(engine: any DocumentToolEngine) {
        self.engine = engine
    }

    func load(_ file: PickedFile, pageCount: Int) {
        source = file
        self.pageCount = pageCount
        reset()
    }

    func clear() {
        source = nil
        pageCount = 0
        reset()
    }

    private func reset() {
        state = .idle
        progress = 0
        outcome = nil
        output = nil
        outcomeLevel = nil
    }

    var canRun: Bool { source != nil && !state.isRunning }

    /// The outcome, if it was made at the level now selected.
    var currentOutcome: PDFCompression.Outcome? {
        outcomeLevel == level ? outcome : nil
    }

    var currentOutput: ToolFile? { outcomeLevel == level ? output : nil }

    func run() async {
        guard let source, canRun else { return }
        let chosen = level
        reset()
        state = .running
        do {
            let result = try await engine.compressPDF(source.url, level: chosen) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.state == .running else { return }
                    self.progress = min(1, max(self.progress, fraction))
                }
            }
            // The web measures against the file's own size (`CompressPdf.jsx:141`), and so does
            // this, rather than trusting the engine's idea of where the original came from.
            let outcome = PDFCompression.Outcome(
                originalBytes: source.bytes, compressedBytes: result.data.count,
                pageCount: result.outcome.pageCount, pagesReencoded: result.outcome.pagesReencoded)
            self.outcome = outcome
            outcomeLevel = chosen
            output = outcome.hasReduction
                ? ToolFile(name: PDFCompression.outputName(for: source.name), data: result.data)
                : nil
            progress = 1
            state = .finished
        } catch {
            state = .failed(DisplayText.message(for: error))
        }
    }
}

// MARK: - Compress image

/// Compress image — `src/pages/tools/CompressImage.jsx`.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class CompressImageViewModel {

    private(set) var source: PickedFile?
    /// The target, as typed. Bound to the field; the presets write it too.
    var targetKB = String(ImageCompression.defaultTargetKB)
    private(set) var state: ToolRunState = .idle
    private(set) var report: ImageCompression.Report?
    private(set) var output: ToolFile?
    /// A refusal that happened before anything ran — a file over the limit, a target that is
    /// not a number.
    var notice: String?

    private let engine: any DocumentToolEngine

    init(engine: any DocumentToolEngine) {
        self.engine = engine
    }

    /// Refuses a source over the web's 1 GB limit rather than trying (`CompressImage.jsx:73-79`).
    func load(_ file: PickedFile) {
        guard file.bytes <= ImageCompression.maxSourceBytes else {
            notice = ImageCompression.Failure.tooLarge.errorDescription
            return
        }
        source = file
        notice = nil
        state = .idle
        report = nil
        output = nil
    }

    func clear() {
        source = nil
        state = .idle
        report = nil
        output = nil
        notice = nil
    }

    func choosePreset(_ kilobytes: Int) { targetKB = String(kilobytes) }

    var targetBytes: Int? { ImageCompression.targetBytes(kilobytes: targetKB) }

    var canRun: Bool { source != nil && !state.isRunning }

    var percentSmaller: Int? {
        guard let source, let report else { return nil }
        return ImageCompression.percentSmaller(original: source.bytes, compressed: report.result.data.count)
    }

    /// The line under the two sizes (`CompressImage.jsx:169-173`).
    var resultCaption: String? {
        guard let report, let percentSmaller else { return nil }
        let base = "\(percentSmaller)% smaller"
        return report.result.hitTarget
            ? base
            : "\(base) · the target was smaller than the smallest this image could reach"
    }

    func run() async {
        guard let source, canRun else { return }
        guard let target = targetBytes else {
            notice = "Enter a target size in KB."
            return
        }
        notice = nil
        report = nil
        output = nil
        state = .running
        do {
            let report = try await engine.compressImage(source.url, targetBytes: target)
            self.report = report
            output = ToolFile(
                name: ImageCompression.outputName(for: source.name), data: report.result.data)
            state = .finished
        } catch {
            state = .failed(DisplayText.message(for: error))
        }
    }
}

// MARK: - Image to PDF

/// Image to PDF — `src/pages/tools/ImageToPdf.jsx`.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class ImageToPDFViewModel {

    /// In page order. The user's order, never sorted — a set of exhibit photographs goes in the
    /// sequence it is meant to be read.
    private(set) var images: [PickedFile] = []
    var pageSize: ImagePDFLayout.PageSize = .a4
    private(set) var state: ToolRunState = .idle
    /// The file built, and the inputs it was built from.
    private var built: (images: [UUID], pageSize: ImagePDFLayout.PageSize, file: ToolFile)?

    private let engine: any DocumentToolEngine

    init(engine: any DocumentToolEngine) {
        self.engine = engine
    }

    /// Adds to the end, keeping only what the tool can read (`ImageToPdf.jsx:17-19`).
    ///
    /// - Returns: how many were left out for not being an image this accepts.
    @discardableResult
    func add(_ files: [PickedFile]) -> Int {
        let accepted = files.filter { ImagePDFLayout.isAccepted(fileName: $0.name) }
        images.append(contentsOf: accepted)
        if state != .running { state = .idle }
        return files.count - accepted.count
    }

    func remove(_ id: UUID) {
        images.removeAll { $0.id == id }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        // `Array.move(fromOffsets:toOffset:)` is SwiftUI's; this is the same operation in
        // Foundation terms, so the core keeps no UI import.
        let moving = source.sorted().map { images[$0] }
        var remaining = images.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let before = source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: destination - before)
        images = remaining
    }

    func clear() {
        images = []
        state = .idle
        built = nil
    }

    var outputName: String { ImagePDFLayout.outputName(firstImageName: images.first?.name) }

    var canRun: Bool { !images.isEmpty && !state.isRunning }

    var actionLabel: String {
        images.count > 1 ? "Create a \(images.count)-page PDF" : "Create PDF"
    }

    /// The built file, if the images and paper size are still what it was built from.
    var output: ToolFile? {
        guard let built, built.images == images.map(\.id), built.pageSize == pageSize else {
            return nil
        }
        return built.file
    }

    func run() async {
        guard canRun else { return }
        let ids = images.map(\.id)
        let size = pageSize
        state = .running
        do {
            let file = try await engine.imagesToPDF(
                images.map(\.url), pageSize: size, outputName: outputName)
            built = (ids, size, file)
            state = .finished
        } catch {
            state = .failed(DisplayText.message(for: error))
        }
    }
}
