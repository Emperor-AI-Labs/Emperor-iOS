import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Opening a cited source document at the page the citation names.
///
/// This is the claim the product rests on — every line names a page you can open — so the
/// jump has to actually land, and the failure has to be honest when it cannot.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class SourceDocumentViewModel {
    private(set) var data: Data?
    private(set) var isLoading = true
    var errorMessage: String?

    /// True when `data` holds a server-rendered PDF of a Word document rather than the document
    /// itself. Worth surfacing: the user should know they are looking at a rendering, because
    /// the layout is LibreOffice's reading of it and not necessarily what the sender saw.
    private(set) var isConvertedPreview = false

    /// When `data` is the copy kept on this device rather than what the server just sent, the
    /// moment that copy was fetched.
    private(set) var savedCopyAt: Date?
    /// Set when the document opened but could not be kept for reading offline, because the room
    /// for offline copies is taken. Said rather than left to be discovered in a corridor with no
    /// signal.
    private(set) var offlineNote: String?

    let attachment: ChatAttachment
    let mention: AnnexureMention

    private let service: any FileProviding
    private let officePreview: (any OfficePreviewProviding)?
    private let offline: OfflineDocuments?
    private let connectivity: (any ConnectivityReporting)?

    /// - Parameters:
    ///   - offline: where this account keeps documents for reading offline. Every document that
    ///     opens is kept there, and opens from there when the server cannot be reached.
    ///   - connectivity: whether the device is known to have no connection.
    init(
        attachment: ChatAttachment,
        mention: AnnexureMention,
        service: any FileProviding,
        officePreview: (any OfficePreviewProviding)? = nil,
        offline: OfflineDocuments? = nil,
        connectivity: (any ConnectivityReporting)? = nil
    ) {
        self.attachment = attachment
        self.mention = mention
        self.service = service
        self.officePreview = officePreview
        self.offline = offline
        self.connectivity = connectivity
    }

    // MARK: - Titles

    var displayName: String { DisplayText.fileName(attachment.name) }

    /// The mark is how the document is referred to in the filing, so it belongs next to the
    /// page rather than being dropped.
    var subtitle: String {
        [mention.mark, mention.pageDescription].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Content

    /// A converted Word document counts: what `data` holds in that case *is* a PDF, and the
    /// renderer has to be told so or a successful preview would fall through to the "not a
    /// format this app can display" branch.
    var isPDF: Bool {
        isConvertedPreview || attachment.name.lowercased().hasSuffix(".pdf")
    }

    /// Whether this is a document the server can render for viewing.
    var isOfficeDocument: Bool { OfficePreview.canPreview(fileName: attachment.name) }

    /// The document as text, when it is text at all.
    ///
    /// Only consulted after the PDF and image paths have been ruled out, so a `nil` here means
    /// the format genuinely cannot be shown rather than that it is empty.
    var textContents: String? {
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// What to say when nothing can be rendered.
    ///
    /// A load failure is the more useful explanation when there was one; otherwise the file
    /// arrived intact and simply is not a format this app displays.
    var unavailableMessage: String {
        errorMessage ?? "\(displayName) is not a format this app can display."
    }

    /// The 0-based page to open, from the citation's 1-based page number.
    ///
    /// The server indexes pages as `idx + 1` (`sync-server.js:1479`) while PDFKit is 0-based.
    /// Out-of-range pages are clamped rather than refused: a citation can name a page beyond
    /// the file if the model read a different edition, and landing on the last page beats
    /// showing nothing.
    /// `nonisolated` because it is arithmetic on its arguments: the caller is `PDFView`
    /// layout code, which has no reason to hop to the main actor to ask.
    nonisolated static func pageIndex(for page: Int?, pageCount: Int) -> Int? {
        guard let page, page > 0, pageCount > 0 else { return nil }
        return min(page - 1, pageCount - 1)
    }

    // MARK: - Loading

    /// Fetches the document — a Word document through the server's converter, see
    /// `DocumentFetch` — and keeps what arrived for reading offline.
    ///
    /// - Important: the converter's metadata route answers **200 with `success: false`** when
    ///   conversion fails. Branching on the status code would leave `data` nil with no
    ///   `errorMessage`, and the screen would show "not a format this app can display" — which is
    ///   wrong, and hides the reason the server actually gave. `DocumentFetch` throws it instead.
    ///
    /// The copy kept on the device opens in two cases only, per `OfflineReading`: the system says
    /// there is no connection, or the request could not reach the server. A document is a file
    /// rather than a feed, so with no connection the copy is opened without asking the network at
    /// all — the person is reading it, and it should not reload under them.
    func load() async {
        isLoading = true
        defer { isLoading = false }

        if OfflineReading.opensSavedCopyFirst(connectivity), openSavedCopy() { return }

        do {
            let document = try await DocumentFetch.fetch(
                attachment, files: service, officePreview: officePreview)
            data = document.data
            isConvertedPreview = document.isConvertedPreview
            savedCopyAt = nil
            keep(document)
        } catch {
            if OfflineReading.mayStandIn(after: error), openSavedCopy() { return }
            errorMessage = (error as? DocumentNotViewable)?.message
                ?? DisplayText.message(for: error)
        }
    }

    /// "Offline — showing the copy saved yesterday", while the kept copy is on screen.
    func offlineNotice(now: Date = Date()) -> String? {
        savedCopyAt.map { OfflineReading.notice(savedAt: $0, now: now) }
    }

    /// The rendering this viewer fetches for the document, which is the one to look for offline.
    private var showsConverted: Bool { isOfficeDocument && officePreview != nil }

    private func openSavedCopy() -> Bool {
        guard let copy = offline?.copy(of: attachment, converted: showsConverted) else {
            return false
        }
        data = copy.data
        isConvertedPreview = showsConverted
        savedCopyAt = copy.savedAt
        errorMessage = nil
        return true
    }

    /// Keeps what opened, without changing whether it was saved on purpose. Nothing is kept of a
    /// document that arrived empty: on this API an empty body is "unknown", never a document.
    private func keep(_ document: ViewableDocument) {
        guard let offline else { return }
        switch offline.keep(document, of: attachment, pin: nil) {
        case .notSaved(.noRoom):
            offlineNote = "Not kept for reading offline — the space for offline copies is taken by documents you saved."
        case .notSaved(.tooLarge):
            offlineNote = "Too large to keep for reading offline."
        default:
            offlineNote = nil
        }
    }
}
