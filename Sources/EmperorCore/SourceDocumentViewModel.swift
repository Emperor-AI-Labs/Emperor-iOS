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

    let attachment: ChatAttachment
    let mention: AnnexureMention

    private let service: any FileProviding

    init(attachment: ChatAttachment, mention: AnnexureMention, service: any FileProviding) {
        self.attachment = attachment
        self.mention = mention
        self.service = service
    }

    // MARK: - Titles

    var displayName: String { DisplayText.fileName(attachment.name) }

    /// The mark is how the document is referred to in the filing, so it belongs next to the
    /// page rather than being dropped.
    var subtitle: String {
        [mention.mark, mention.pageDescription].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Content

    var isPDF: Bool { attachment.name.lowercased().hasSuffix(".pdf") }

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

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            data = try await service.fileData(
                name: attachment.name, folderName: attachment.folderName)
        } catch {
            errorMessage = DisplayText.message(for: error)
        }
    }
}
