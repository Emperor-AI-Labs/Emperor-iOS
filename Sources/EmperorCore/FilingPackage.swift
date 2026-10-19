import Foundation

/// The filing-ready package: a draft followed by every annexure it cites, as one document.
///
/// The web offers this from its Download menu, as Word or PDF (`buildReadyToFileHtml` in
/// `src/lib/output.js`). Everything after the draft is read fresh from the filing registry at
/// the moment of download, never from what the model streamed:
///
/// 1. the draft;
/// 2. a List of Annexures table — mark, particulars, and whether a typed copy or the original
///    follows;
/// 3. each annexure in the list's order, on a fresh page: a typed copy as the platform renders
///    it, or the original document's own pages.
///
/// The one place this differs from the web is order: the web appends every typed copy and
/// then every original, while this interleaves them in the list's order, which is the order
/// the List of Annexures promises and the order a registry reads a paperbook in.
///
/// Originals reach the two formats differently. A PDF carries the original document itself,
/// merged page for page. A Word document cannot hold a PDF, so it carries each page as a
/// picture — the platform renders them (`OriginalPages`), as the web's Word export does.
///
/// ## When it stops
///
/// A package is something a person files. One that silently lacks an annexure the list says is
/// attached is worse than no package, so an original that cannot be read **stops the build**
/// with a sentence naming it. Two things are written into the package rather than stopping it,
/// because trying again would not change them: an annexure whose kind of file cannot be
/// attached, and a typed copy the registry cannot prepare (its document has not been read yet).
/// Each is named on its own page, so the gap is visible in the document.
enum FilingPackage {

    enum Format: Equatable, Sendable {
        case word
        case pdf
    }

    /// One part of the package, in order.
    enum Piece: Equatable, Sendable {
        case draft(html: String)
        case listOfAnnexures(html: String)
        case typedCopy(mark: String, html: String)
        /// For a PDF: the original document — PDF bytes, or a single image.
        case original(mark: String, data: Data, kind: AnnexureFileKind)
        /// For Word: the original's pages as pictures.
        case originalPages(mark: String, pages: [Data])
        /// An annexure that is named but not attached, and why.
        case note(mark: String, text: String)

        var mark: String? {
            switch self {
            case .draft, .listOfAnnexures: return nil
            case .typedCopy(let mark, _), .original(let mark, _, _),
                 .originalPages(let mark, _), .note(let mark, _):
                return mark
            }
        }
    }

    enum Failure: LocalizedError, Equatable {
        /// Filing is outside this account's plan.
        case refused(Refusal)
        /// Something needed could not be read; nothing was made.
        case stopped(String)

        var errorDescription: String? {
            switch self {
            case .refused(let refusal): return DisplayText.message(for: refusal)
            case .stopped(let message): return message
            }
        }
    }

    /// The share of the work done when each stage ends, as the web reports it: the draft and
    /// the list are quick, fetching annexures is the bulk, and the last quarter is the caller
    /// laying out the file.
    enum Progress {
        static let started = 0.08
        static let listRead = 0.25
        static let annexuresRead = 0.75
        static let done = 1.0

        /// After `completed` of `total` annexures.
        static func annexures(_ completed: Int, of total: Int) -> Double {
            guard total > 0 else { return annexuresRead }
            return listRead + (annexuresRead - listRead) * Double(completed) / Double(total)
        }
    }

    // MARK: - Building

    /// Reads every piece of the package, in order.
    ///
    /// - Parameter progress: told the share of the work done, from 0 up to
    ///   `Progress.annexuresRead`. The caller reports the rest as it lays out the file.
    @MainActor
    static func build(
        format: Format,
        draftHTML: String,
        chatID: String,
        service: any FilingAnnexureProviding,
        progress: (Double) -> Void = { _ in }
    ) async throws -> [Piece] {
        progress(Progress.started)
        var pieces: [Piece] = [.draft(html: draftHTML)]

        let rows: [FilingAnnexure]
        do {
            rows = FilingAnnexure.sorted(try await service.annexures(chatID: chatID))
        } catch {
            throw failure(from: error, mark: nil)
        }
        progress(Progress.listRead)
        guard !rows.isEmpty else {
            progress(Progress.annexuresRead)
            return pieces
        }
        pieces.append(.listOfAnnexures(html: listHTML(rows)))

        for (index, row) in rows.enumerated() {
            pieces.append(try await piece(for: row, format: format, chatID: chatID, service: service))
            progress(Progress.annexures(index + 1, of: rows.count))
        }
        return pieces
    }

    @MainActor
    private static func piece(
        for row: FilingAnnexure, format: Format, chatID: String,
        service: any FilingAnnexureProviding
    ) async throws -> Piece {
        if let earlier = row.duplicateOf, !row.isTypedCopy {
            return .note(mark: row.mark, text: duplicateSentence(earlier))
        }
        do {
            if row.isTypedCopy {
                switch try await service.typedCopy(chatID: chatID, mark: row.mark) {
                case .html(let html): return .typedCopy(mark: row.mark, html: html)
                case .skipped(let reason): return .note(mark: row.mark, text: reason)
                }
            }
            switch format {
            case .pdf:
                let data = try await service.original(chatID: chatID, mark: row.mark)
                let kind = AnnexureFileKind.of(data)
                guard kind != .unknown else {
                    return .note(mark: row.mark, text: notAttachedSentence(row.mark))
                }
                return .original(mark: row.mark, data: data, kind: kind)
            case .word:
                switch try await service.originalPages(chatID: chatID, mark: row.mark) {
                case .duplicate(let earlier):
                    return .note(mark: row.mark, text: duplicateSentence(earlier))
                case .pages(let pages):
                    // Word holds PNG, JPEG and GIF. A page in any other format is named rather
                    // than dropped.
                    guard pages.allSatisfy({ EmbeddedImage.read($0) != nil }) else {
                        return .note(mark: row.mark, text: notAttachedSentence(row.mark))
                    }
                    return .originalPages(mark: row.mark, pages: pages)
                }
            }
        } catch {
            let reason = FilingAnnexureError.from(error, mark: row.mark)
            switch reason {
            case .refused(let refusal):
                throw Failure.refused(refusal)
            case .unsupportedFile:
                return .note(mark: row.mark, text: notAttachedSentence(row.mark))
            case .declined(_, let message) where row.isTypedCopy:
                return .note(mark: row.mark, text: message)
            default:
                throw failure(from: reason, mark: row.mark)
            }
        }
    }

    private static func failure(from error: Error, mark: String?) -> Failure {
        let reason = FilingAnnexureError.from(error, mark: mark)
        if let refusal = reason.refusal { return .refused(refusal) }
        let detail = reason.errorDescription ?? "It could not be read."
        let lead = mark.map { "Annexure \($0) could not be attached, so the package was not made." }
            ?? "The list of annexures could not be read, so the package was not made."
        return .stopped("\(lead) \(detail)")
    }

    static func duplicateSentence(_ earlier: String) -> String {
        "Same document and page range as Annexure \(earlier) above — see there for the original, "
            + "so it is not attached twice."
    }

    static func notAttachedSentence(_ mark: String) -> String {
        "The original of Annexure \(mark) is a kind of file that can't be attached here. "
            + "Attach it to the filing separately."
    }

    /// "Petition — filing package.pdf".
    static func fileName(title: String, format: Format) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = trimmed.isEmpty ? "Document" : trimmed
        return "\(stem) — filing package.\(format == .pdf ? "pdf" : "docx")"
    }

    // MARK: - The pieces as markup

    /// Starts the next part on a fresh page, in print and in Word (`DocxDocument`).
    static let pageBreak = #"<div style="page-break-before:always"></div>"#

    /// The List of Annexures table, after the web's.
    static func listHTML(_ rows: [FilingAnnexure]) -> String {
        let body = rows.enumerated().map { index, row in
            "<tr><td>\(index + 1).</td><td>\(escape(row.mark))</td><td>\(escape(row.title))</td>"
                + "<td>\(row.isTypedCopy ? "Typed copy (attached below)" : "Original (attached below)")</td></tr>"
        }.joined()
        return pageBreak
            + #"<p style="text-align:center"><strong><u>LIST OF ANNEXURES</u></strong></p>"#
            + #"<table style="width:100%;border-collapse:collapse">"#
            + "<thead><tr><th>S. No.</th><th>Mark</th><th>Particulars</th><th>Form</th></tr></thead>"
            + "<tbody>\(body)</tbody></table>"
    }

    /// "ANNEXURE P-1 (ORIGINAL)", centred, on a fresh page.
    static func originalHeading(_ mark: String) -> String {
        pageBreak
            + #"<p style="text-align:center"><strong><u>ANNEXURE "#
            + escape(mark) + " (ORIGINAL)</u></strong></p>"
    }

    static func noteHTML(mark: String, text: String) -> String {
        pageBreak
            + #"<p style="text-align:center"><strong><u>ANNEXURE "#
            + escape(mark) + "</u></strong></p>"
            + #"<p style="font-style:italic">"# + escape(text) + "</p>"
    }

    /// The whole package as one HTML fragment, for `DocxDocument.make(fromHTML:)`. Original
    /// pages travel as `data:` pictures, which is the only kind the Word exporter embeds.
    static func wordHTML(_ pieces: [Piece]) -> String {
        pieces.map { piece in
            switch piece {
            case .draft(let html), .listOfAnnexures(let html), .typedCopy(_, let html):
                return html
            case .originalPages(let mark, let pages):
                let pictures = pages.compactMap(dataURI).map { #"<img src=""# + $0 + #"" style="max-width:100%"/>"# }
                return originalHeading(mark) + pictures.joined(separator: pageBreak)
            case .original(let mark, _, _):
                // A PDF original has no place in Word; the PDF package is where it goes.
                return noteHTML(mark: mark, text: notAttachedSentence(mark))
            case .note(let mark, let text):
                return noteHTML(mark: mark, text: text)
            }
        }.joined()
    }

    /// A stretch of the PDF package: markup to lay out, or a document to merge as it is.
    enum Segment: Equatable, Sendable {
        case html(String)
        case pdf(Data)
        case image(Data)
    }

    /// The package as the PDF renderer takes it: neighbouring markup laid out together, each
    /// original merged after its heading.
    ///
    /// A segment's leading page break is dropped. Each segment is laid out on its own and so
    /// already starts on a fresh page; a break at its top would add a blank one.
    static func pdfSegments(_ pieces: [Piece]) -> [Segment] {
        var segments: [Segment] = []
        func add(_ html: String) {
            if case .html(let previous) = segments.last {
                segments[segments.count - 1] = .html(previous + html)
            } else {
                segments.append(.html(withoutLeadingBreak(html)))
            }
        }
        for piece in pieces {
            switch piece {
            case .draft(let html), .listOfAnnexures(let html), .typedCopy(_, let html):
                add(html)
            case .note(let mark, let text):
                add(noteHTML(mark: mark, text: text))
            case .original(let mark, let data, let kind):
                add(originalHeading(mark))
                switch kind {
                case .pdf: segments.append(.pdf(data))
                case .image: segments.append(.image(data))
                case .unknown: add(noteHTML(mark: mark, text: notAttachedSentence(mark)))
                }
            case .originalPages(let mark, let pages):
                add(originalHeading(mark))
                segments.append(contentsOf: pages.map(Segment.image))
            }
        }
        return segments
    }

    private static func withoutLeadingBreak(_ html: String) -> String {
        let trimmed = html.drop { $0.isWhitespace }
        guard trimmed.hasPrefix(pageBreak) else { return html }
        return String(trimmed.dropFirst(pageBreak.count))
    }

    private static func dataURI(_ data: Data) -> String? {
        guard let image = EmbeddedImage.read(data) else { return nil }
        return "data:image/\(image.format.rawValue);base64,\(data.base64EncodedString())"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
