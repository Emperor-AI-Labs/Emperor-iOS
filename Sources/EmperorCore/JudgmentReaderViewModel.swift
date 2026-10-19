import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The judgment reader — the web's `caselaw/JudgmentView.jsx`: the structured judgment from
/// `/judgment` typeset under a header card, with a contents rail, find-in-judgment, "go to
/// paragraph", reading comfort, and copy-able citations.
///
/// If `/judgment` fails for any reason but "the file is not here", the stored text is fetched
/// and split into paragraphs instead (and a note says so). Errors are plain: not on this server
/// yet, too long, or try again.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class JudgmentReaderViewModel {

    enum Source: Equatable, Sendable { case structured, plain }

    let doc: CatalogueDocument

    private(set) var source: Source?
    private(set) var header: JudgmentHeader?
    private(set) var blocks: [JudgmentBlock] = []
    private(set) var toc: [JudgmentTOCEntry] = []
    private(set) var stats: JudgmentStats?
    private(set) var state: LoadState = .idle
    private(set) var isMissing = false
    private(set) var isTooLarge = false

    var preferences: JudgmentReaderModel.Preferences {
        didSet { store.setString(preferences.encoded, for: JudgmentReaderModel.Preferences.storageKey) }
    }

    // Find
    var find = "" {
        didSet { if find != oldValue { refreshSearch() } }
    }
    private(set) var search = JudgmentReaderModel.Search.empty
    private(set) var currentHit = -1

    /// The block the screen should scroll to, set by the contents, a paragraph jump or a match.
    private(set) var scrollTarget: ScrollTarget?

    struct ScrollTarget: Equatable, Sendable {
        var blockID: String
        var flash: Bool
        /// Changes on every jump, so the same block can be asked for twice.
        var token: Int
    }

    /// A short message for the toast: "Citation copied", "There is no paragraph 90."
    var notice: String?

    private let service: any LibraryProviding
    private let store: any PreferenceStore
    private let todayKey: () -> String
    private var jumpToken = 0

    init(doc: CatalogueDocument, service: any LibraryProviding, store: any PreferenceStore = InMemoryPreferenceStore(),
         todayKey: @escaping () -> String = { WireDate.todayKey() }) {
        self.doc = doc
        self.service = service
        self.store = store
        self.todayKey = todayKey
        self.preferences = JudgmentReaderModel.Preferences.decode(store.string(for: JudgmentReaderModel.Preferences.storageKey))
    }

    var presentation: ListPresentation { ListPresentation(state: state, isEmpty: blocks.isEmpty && header == nil) }

    // MARK: - Loading

    func load() async {
        state = .loading
        isMissing = false
        isTooLarge = false
        do {
            let judgment = try await service.judgment(id: doc.id)
            source = .structured
            header = judgment.header
            blocks = judgment.blocks
            toc = judgment.toc
            stats = judgment.stats
            state = .loaded
        } catch let error as LibraryCatalogueError where error.isFileMissing {
            isMissing = true
            state = .failed(LoadFailure(error))
        } catch let error as APIError {
            // The session ending is not something the text fallback can get past.
            state = .failed(LoadFailure(error))
        } catch {
            await loadPlainText(after: error)
        }
    }

    /// Anything else (a formatter error, an older backend): the plain text, split into paragraphs.
    private func loadPlainText(after original: Error) async {
        do {
            let data = try await service.file(id: doc.id, prefer: .text)
            if data.count > LibraryService.maxReaderBytes {
                isTooLarge = true
                state = .failed(LoadFailure(LibraryCatalogueError(status: 413, code: "too_large", message: nil, reason: nil, retryAfter: nil)))
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            let parsed = JudgmentReaderModel.paragraphs(fromPlainText: text)
            source = .plain
            header = nil
            blocks = JudgmentReaderModel.blocks(fromParagraphs: parsed.paragraphs)
            toc = []
            stats = nil
            state = .loaded
        } catch let error as LibraryCatalogueError where error.isFileMissing || error.status == 404 {
            isMissing = true
            state = .failed(LoadFailure(error))
        } catch {
            if let catalogue = original as? LibraryCatalogueError, catalogue.isTooLarge { isTooLarge = true }
            state = .failed(LoadFailure(original))
        }
    }

    var failureTitle: String {
        if isMissing { return "This judgment is not on the shelf yet" }
        if isTooLarge { return "This judgment is too long to open here" }
        return "We couldn’t load this judgment"
    }

    var failureHint: String {
        if isMissing { return "It is listed in the catalogue, but its text has not been copied to this server yet." }
        if isTooLarge { return "The reader opens judgments up to \(LibraryService.maxReaderBytes / 1_048_576) MB. Download the original to read all of it." }
        if state.requiresReauthentication { return "Your session has ended. Sign in again, then reopen it." }
        return "Something went wrong on the way. Try again."
    }

    var canRetry: Bool { !isMissing && !isTooLarge && (state.failure?.isRetryable ?? false) }
    var offersDownload: Bool { !isMissing }

    /// Shown over plain text: the formatted version could not be prepared.
    var plainTextNote: String? {
        source == .plain ? "Shown as plain text: the formatted version of this judgment could not be prepared." : nil
    }

    /// No text at all — a scanned image, most likely.
    var noTextNote: String? {
        state.hasLoaded && blocks.isEmpty ? "This judgment has no text we can show. It may be a scanned image; download the original." : nil
    }

    // MARK: - The header card

    var court: CaseLawVocabulary.CourtInfo {
        CaseLawVocabulary.court(header?.court ?? doc.court, label: header?.courtLabel ?? doc.courtLabel)
    }

    var caseTitle: String { CaseLawVocabulary.caseTitle(doc, header: header) }
    var parties: (String, String)? { header.flatMap(CaseLawVocabulary.parties(of:)) ?? CaseLawVocabulary.parties(of: doc) }

    var caseNumberLine: String? {
        (header.map(CaseLawVocabulary.caseNumberText)?.nilIfEmpty) ?? CaseLawVocabulary.caseNumberText(doc).nilIfEmpty
    }

    /// Decided · Bench · Judgment by · Length — each only where the court said.
    var facts: [(label: String, value: String)] {
        var out: [(String, String)] = []
        if let decided = header?.decidedOn?.nilIfEmpty ?? doc.decidedOn?.nilIfEmpty {
            let day = LibraryTitles.shortDay(decided)
            out.append(("Decided", CaseLawVocabulary.isFutureDate(decided, today: todayKey()) ? "\(day) (as printed)" : day))
        }
        let bench = header?.bench.isEmpty == false
            ? header!.bench
            : (doc.bench ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !bench.isEmpty { out.append((bench.count > 1 ? "Bench of \(bench.count)" : "Bench", bench.joined(separator: "\n"))) }
        if let author = header?.author?.nilIfEmpty { out.append(("Judgment by", author)) }
        if let words = stats?.words, words > 0 {
            let paras = stats?.paragraphs.map { "\(LibraryTitles.count($0)) paragraphs · " } ?? ""
            out.append(("Length", "\(paras)\(CaseLawVocabulary.readingMinutes(words)) min read"))
        }
        return out
    }

    var citations: [String] { JudgmentReaderModel.citations(doc, header: header) }
    var neutralCitation: String? { header?.neutralCitation?.nilIfEmpty ?? doc.neutralCitation?.nilIfEmpty }
    var citationLine: String { JudgmentReaderModel.citationLine(doc, header: header) }
    var sourceURL: URL? { JudgmentReaderModel.sourceURL(header) }

    /// "Cites 12 · Cited by 4", when the source counted.
    var citesLine: String? {
        let cites = header?.citesCount ?? 0, citedBy = header?.citedByCount ?? 0
        guard cites > 0 || citedBy > 0 else { return nil }
        return "Cites \(LibraryTitles.count(cites)) · Cited by \(LibraryTitles.count(citedBy))"
    }

    /// "1,204 words · about 6 min".
    var lengthLine: String? {
        guard let words = stats?.words, words > 0 else { return nil }
        let paras = stats?.paragraphs.map { "\(LibraryTitles.count($0)) paragraphs · " } ?? ""
        return "\(paras)\(LibraryTitles.count(words)) words · about \(CaseLawVocabulary.readingMinutes(words)) min"
    }

    // MARK: - Contents

    var headings: [JudgmentTOCEntry] { JudgmentReaderModel.headings(toc) }
    var paragraphMarks: [(id: String, n: Int)] { JudgmentReaderModel.paragraphMarks(blocks) }
    var lastParagraph: String? { JudgmentReaderModel.lastParagraphNumber(blocks) }

    /// The header card's anchor, above the first block.
    static let topID = "jv-top"

    func jump(to blockID: String, flash: Bool = true) {
        guard blockID == Self.topID || JudgmentReaderModel.index(of: blockID, in: blocks) >= 0 else { return }
        jumpToken += 1
        scrollTarget = ScrollTarget(blockID: blockID, flash: flash, token: jumpToken)
    }

    /// "Go to paragraph": exact, else the first at or past it (and says so), else why not.
    func goToParagraph(_ n: String) {
        let want = n.trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty else { return }
        let idx = JudgmentReaderModel.findParagraph(blocks, numbered: want)
        guard idx >= 0 else {
            notice = lastParagraph.map { "There is no paragraph \(want). The last is \($0)." } ?? "This judgment has no numbered paragraphs."
            return
        }
        jump(to: blocks[idx].id)
        if blocks[idx].n != want { notice = "No paragraph \(want); showing \(blocks[idx].n ?? "")." }
    }

    // MARK: - Find

    private func refreshSearch() {
        search = JudgmentReaderModel.search(blocks, for: find)
        currentHit = -1
    }

    var findCountLine: String? {
        guard find.trimmingCharacters(in: .whitespaces).count >= 2 else { return nil }
        guard search.total > 0 else { return "None" }
        let at = currentHit >= 0 ? LibraryTitles.count(currentHit + 1) : "–"
        return "\(at) / \(LibraryTitles.count(search.total))\(search.capped ? "+" : "")"
    }

    func stepFind(_ direction: Int) {
        guard let next = JudgmentReaderModel.step(from: currentHit, by: direction, in: search) else { return }
        currentHit = next
        jump(to: blocks[search.hits[next].block].id, flash: false)
    }

    func clearFind() { find = "" }

    /// The hits in one block, as UTF-16 ranges into its searchable text.
    func hits(in blockIndex: Int) -> [JudgmentReaderModel.Hit] { search.byBlock[blockIndex] ?? [] }

    /// The index of the current hit, when it is in this block.
    func currentHitIndex(in blockIndex: Int) -> Int? {
        guard currentHit >= 0, currentHit < search.hits.count, search.hits[currentHit].block == blockIndex else { return nil }
        return currentHit
    }

    // MARK: - Reading comfort

    func shrink() { if preferences.canShrink { preferences.size -= 1 } }
    func grow() { if preferences.canGrow { preferences.size += 1 } }

    // MARK: - Copying

    /// What "Copy citation" puts on the clipboard, and the toast it earns.
    func copied(_ what: String) { notice = "\(what) copied" }

    /// A paragraph's own link: the web's `/library/doc/<id>#para-12`, so it opens in a browser.
    func paragraphLink(_ block: JudgmentBlock, host: URL) -> String {
        "\(host.absoluteString)/library/doc/\(doc.id)#\(block.id)"
    }

    /// The whole judgment as plain text, for sharing.
    var plainText: String {
        var lines: [String] = [caseTitle]
        if let number = caseNumberLine { lines.append(number) }
        lines.append(citationLine)
        lines.append("")
        for b in blocks {
            if b.type == "heading" { lines.append(b.text.uppercased()) }
            else if let n = b.n { lines.append("\(n). \(b.text)") }
            else { lines.append(JudgmentReaderModel.blockText(b)) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    enum Copy {
        static let findPrompt = "Find in this judgment"
        static let contents = "Contents"
        static let caseDetails = "Case details"
        static let goToParagraph = "Go to paragraph"
        static let reading = "Reading"
        static let copyCitation = "Copy citation"
        static let indianKanoon = "Indian Kanoon"
        static let download = "Download the original (.txt)"
        static let end = "✦ ✦ ✦"
    }
}
