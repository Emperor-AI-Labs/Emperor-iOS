import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The reading room for one document — the web's `ReadingRoom.jsx` + `DocumentBody`: the row's
/// facts in the head, and the body: a judgment's reader for text, the PDF for everything else,
/// after a check that the file is on this server (a row whose file is not would otherwise put
/// the API's JSON 404 inside the viewer).
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class LibraryDocumentViewModel {

    /// The row that was tapped; `/doc` refreshes it with `hasFile` and the family.
    private(set) var doc: CatalogueDocument
    private(set) var detail: LibraryDocumentDetail?
    private(set) var detailState: LoadState = .idle

    private(set) var pdf: Data?
    private(set) var fileState: LoadState = .idle
    private(set) var isMissing = false

    private let service: any LibraryProviding

    init(doc: CatalogueDocument, service: any LibraryProviding) {
        self.doc = doc
        self.service = service
    }

    var isText: Bool { doc.isTextDocument }
    var title: String { LibraryTitles.tidyTitle(doc) }
    var kind: String { doc.theme.cap }
    var meta: [String] { LibraryTitles.meta(doc) }
    var theme: LibraryCollectionTheme { doc.theme }

    /// `/doc` says `hasFile: false` when the bytes are not on this server: download and share
    /// would 404, so neither is offered.
    var onShelf: Bool { doc.hasFile != false && !isMissing }

    var presentation: ListPresentation { ListPresentation(state: fileState, isEmpty: pdf == nil) }

    /// The name a shared copy gets.
    var shareName: String {
        let base = title.replacingOccurrences(of: "/", with: "-").prefix(120)
        return "\(base).\(isText ? "txt" : "pdf")"
    }

    // MARK: - Loading

    func load() async {
        async let meta: Void = loadDetail()
        async let body: Void = loadFileIfPDF()
        _ = await (meta, body)
    }

    func loadDetail() async {
        guard detail == nil else { return }
        detailState = .loading
        do {
            let fetched = try await service.document(id: doc.id)
            detail = fetched
            doc = fetched.doc
            detailState = .loaded
        } catch {
            // The row already paints the head; a failed refresh costs only `hasFile`.
            detailState = .failed(LoadFailure(error))
        }
    }

    /// The PDF's bytes, after a HEAD: "not on the shelf yet" rather than a broken viewer.
    func loadFileIfPDF() async {
        guard !isText, pdf == nil else { return }
        fileState = .loading
        isMissing = false
        do {
            let exists = doc.hasFile == false ? false : try await service.fileExists(id: doc.id)
            if !exists {
                isMissing = true
                fileState = .loaded
                return
            }
            let data = try await service.file(id: doc.id, prefer: .original)
            // Sniffed rather than trusted: the route answers JSON for a row it cannot serve.
            guard CaseService.looksLikePDF(data) else {
                isMissing = true
                fileState = .loaded
                return
            }
            pdf = data
            fileState = .loaded
        } catch let error as LibraryCatalogueError where error.status == 404 {
            isMissing = true
            fileState = .loaded
        } catch {
            fileState = .failed(LoadFailure(error))
        }
    }

    enum Copy {
        static let missingTitle = "This document is not on the shelf yet"
        static let missingHint = "It is listed in the catalogue, but its file has not been copied to this server. Try again later."
        static let failedTitle = "This document could not be opened"
        static let goneTitle = "There is no such document"
        static let goneHint = "The link may be old. Search the library for it instead."
    }
}

/// The page-1 thumbnails, fetched once each and kept for the session.
///
/// `/cover` renders on demand: a first ask can answer `cover_pending` (back in five seconds), and
/// a PDF that cannot be rendered answers `no_cover` for good. Both are remembered, so a grid of
/// forty never asks forty times — and a backend without the route pauses every attempt for two
/// minutes rather than firing forty doomed requests.
actor LibraryCoverLoader {
    enum Entry: Equatable, Sendable {
        case image(Data)
        case none
    }

    private let service: any LibraryProviding
    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<Entry, Never>] = [:]
    private var routeMissingUntil: Date?
    private let retryDelays: [UInt64] = [1_500_000_000, 4_000_000_000]
    private let clock: @Sendable () -> Date

    init(service: any LibraryProviding, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.clock = clock
    }

    /// The bytes of the cover, or nil when none can be had — then the typographic cover stands.
    func image(for doc: CatalogueDocument, width: Int) async -> Data? {
        guard doc.isPDF else { return nil }
        if let until = routeMissingUntil, clock() < until { return nil }
        let key = "\(doc.id)@\(width)"
        if let hit = cache[key] { if case .image(let data) = hit { return data } else { return nil } }
        if let running = inFlight[key] {
            if case .image(let data) = await running.value { return data } else { return nil }
        }
        let task = Task<Entry, Never> { [service, retryDelays] in
            var attempt = 0
            while true {
                do {
                    switch try await service.cover(id: doc.id, width: width) {
                    case .image(let data): return .image(data)
                    case .none: return .none
                    case .pending(let after):
                        guard attempt < retryDelays.count else { return .none }
                        let wait = max(retryDelays[attempt], UInt64(after) * 1_000_000_000)
                        attempt += 1
                        try? await Task.sleep(nanoseconds: wait)
                        if Task.isCancelled { return .none }
                    }
                } catch let error as LibraryCatalogueError where error.isMissingRoute {
                    return .none
                } catch {
                    return .none
                }
            }
        }
        inFlight[key] = task
        let entry = await task.value
        inFlight[key] = nil
        cache[key] = entry
        if case .image(let data) = entry { return data }
        return nil
    }

    /// Remember that the route is absent, so the next two minutes of grids draw typographic covers.
    func noteRouteMissing() {
        routeMissingUntil = clock().addingTimeInterval(120)
    }

    func cachedImage(for doc: CatalogueDocument, width: Int) -> Data? {
        if case .image(let data)? = cache["\(doc.id)@\(width)"] { return data }
        return nil
    }
}
