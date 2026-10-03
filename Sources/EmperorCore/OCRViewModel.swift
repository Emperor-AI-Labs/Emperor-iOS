import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Digitising a document, watching it happen, and reopening what was done before.
///
/// One model serves two screens, as one page serves both on the web: Translate, and PDF to Word —
/// which the platform implements as the same page with its mode locked to a digitise-only DOCX
/// conversion (`src/pages/tools/PdfToDocx.jsx`, `OCRTranslate.jsx:257-262`).
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class OCRViewModel {

    enum Mode: Equatable, Sendable {
        /// Read a document, optionally translating it.
        case translate
        /// Convert a PDF to Word: digitise only, PDFs only.
        case pdfToWord
    }

    let mode: Mode

    private(set) var job: OCRJob?
    private(set) var jobID: String?
    private(set) var isSubmitting = false
    private(set) var isDownloading = false
    var errorMessage: String?
    /// The target language. Ignored in `.pdfToWord`, which always sends `Original`.
    var language: OCRLanguage = .original
    var result: OCRResult?

    // MARK: History

    /// This account's earlier jobs, newest first.
    private(set) var history: [OCRJob] = []
    private(set) var historyState: LoadState = .idle
    /// False whenever the listing covered anything not shown — see `OCRHistory.listedOtherJobs`.
    private(set) var historyIsClearable = false
    private(set) var isClearingHistory = false
    /// The history job being fetched for opening, so its row can show it.
    private(set) var openingJobID: String?
    /// A history document fetched for viewing. Set, the screen opens it.
    var opened: OCRResult?

    struct OCRResult: Identifiable, Sendable {
        let id = UUID()
        let data: Data
        let fileName: String
        /// True when the log shows the translation step reported a problem — the job still
        /// says "completed", but the text may be wholly or partly untranslated.
        let translationMayBeIncomplete: Bool
    }

    /// How long a job may sit with no observable change before this gives up.
    ///
    /// A job orphaned by a server restart stays `"starting"` **forever**: the job map is
    /// restored verbatim, the pipeline that would have advanced it lived only in the process
    /// that took the upload, and nothing sweeps the entry up afterwards. Without a deadline the
    /// app polls a dead job until the battery runs out.
    static let stallTimeout: TimeInterval = 240

    static let stalledMessage = """
        This document has not made progress for several minutes. It may have been interrupted \
        on the server — please try again.
        """

    private let service: any OCRProviding
    private let now: @Sendable () -> Date
    /// `@ObservationIgnored` so it stays a *stored* property. `@Observable` turns stored
    /// properties into MainActor-isolated computed ones, and `deinit` is nonisolated — touching
    /// a computed one there does not compile. No view observes this, so nothing is lost.
    ///
    /// - Important: the attribute and the declaration must sit inside the **same** `#if` branch,
    ///   with the plain declaration repeated in `#else`. Guarding the attribute alone and
    ///   letting the declaration fall through below the `#endif` compiles on Linux — where the
    ///   macro is never applied — and fails on Apple platforms with *"expansion of macro
    ///   'ObservationIgnored()' produced an unexpected getter"*. `CourtSearchViewModel` and
    ///   `PromptEnhancerViewModel` already use this shape; this one did not, and it was the
    ///   only error in the first real compile of this package.
    #if canImport(Darwin)
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    #else
    private var pollTask: Task<Void, Never>?
    #endif
    private var lastChangeAt = Date()
    private var lastSignature = ""
    /// Submitted, and no status has come back yet. Without it the two seconds before the first
    /// poll read as "nothing running", and the screen flashed back to its pickers.
    private var awaitingFirstStatus = false
    /// Polling gave up on a stalled job. The job's last known state is still "running", so
    /// without this the screen stayed on a progress bar with no way to start again.
    private var gaveUp = false

    init(
        service: any OCRProviding, mode: Mode = .translate,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.mode = mode
        self.now = now
        self.lastChangeAt = now()
    }

    /// What is actually sent. PDF to Word never translates (`OCRTranslate.jsx:511-513`).
    var effectiveLanguage: OCRLanguage { mode == .pdfToWord ? .original : language }

    deinit { pollTask?.cancel() }

    var isRunning: Bool {
        if gaveUp { return false }
        guard let job else { return isSubmitting || awaitingFirstStatus }
        return !job.state.isTerminal
    }

    var progress: Double {
        Double(job?.progress ?? 0) / 100
    }

    /// The most recent log lines, newest last.
    var logLines: [String] {
        (job?.logs ?? []).compactMap(\.message)
    }

    var statusDescription: String {
        guard let job else { return isSubmitting ? "Uploading…" : "" }
        switch job.state {
        case .starting: return "Queued"
        case .running: return "Reading the document…"
        case .completed: return "Done"
        case .failed: return job.error ?? "That document could not be read."
        case .unknown(let raw): return raw
        }
    }

    // MARK: - Submitting

    /// The upload goes through the edge proxy in one request, which refuses a body over 100 MB
    /// with an HTML page rather than the server's JSON. The web checks first and says so in
    /// words (`OCRTranslate.jsx:307-308`, `:500`); so does this, and points at the two tools on
    /// this phone that fix it.
    static let maxUploadBytes = 99 * 1024 * 1024

    static let tooLargeMessage = """
        This file is larger than 100 MB, the most the upload can take. Compress it or split it \
        into parts with File tools, then try again.
        """

    func submit(data: Data, fileName: String) async {
        guard !isSubmitting else { return }
        guard data.count <= Self.maxUploadBytes else {
            errorMessage = Self.tooLargeMessage
            return
        }
        isSubmitting = true
        errorMessage = nil
        job = nil
        result = nil
        gaveUp = false
        defer { isSubmitting = false }

        do {
            let id = try await service.submit(
                data: data, fileName: fileName, language: effectiveLanguage)
            jobID = id
            lastChangeAt = now()
            lastSignature = ""
            awaitingFirstStatus = true
            startPolling(id)
        } catch {
            errorMessage = DisplayText.message(for: error)
        }
    }

    // MARK: - Polling

    private func startPolling(_ id: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let finished = await self.pollOnce()
                if finished { return }
            }
        }
    }

    /// Runs one poll cycle.
    ///
    /// Public rather than private because the timer loop is not the only caller worth having:
    /// a foreground return should re-check immediately rather than wait out a sleep, and a test
    /// should not have to wait two seconds per cycle.
    ///
    /// - Returns: whether polling should stop.
    @discardableResult
    func pollOnce() async -> Bool {
        guard let id = jobID else { return true }

        guard let fetched = try? await service.status(jobID: id) else {
            // The deadline has to apply here too. A job removed from the history — cleared from
            // another device while it ran — 404s on every later poll, so checking the clock only
            // on the *success* path made the timeout unreachable in precisely the case it exists
            // for, and the loop ran until the battery died.
            if now().timeIntervalSince(lastChangeAt) > Self.stallTimeout {
                giveUp()
                return true
            }
            return false
        }
        job = fetched
        awaitingFirstStatus = false

        // Anything the server could plausibly change. If none of it moves for `stallTimeout`,
        // the job is treated as dead rather than polled forever.
        let signature = "\(fetched.status)|\(fetched.progress ?? -1)|\(fetched.step ?? -1)|\(fetched.logs?.count ?? 0)"
        if signature != lastSignature {
            lastSignature = signature
            lastChangeAt = now()
        } else if now().timeIntervalSince(lastChangeAt) > Self.stallTimeout {
            giveUp()
            return true
        }

        guard fetched.state.isTerminal else { return false }
        if fetched.state == .completed { await downloadResult(fetched) }
        if fetched.state == .failed {
            // The server's own sentence — a password-protected file, an unreadable scan. Once
            // the job is terminal the progress section is gone, so this is the only place left
            // to say it.
            errorMessage = fetched.error ?? "That document could not be read."
        }
        // The finished job now belongs in the history list, where it can be reopened later.
        await loadHistory()
        return true
    }

    private func giveUp() {
        errorMessage = Self.stalledMessage
        awaitingFirstStatus = false
        gaveUp = true
    }

    /// Clears a finished job so another document can be started.
    func reset() {
        cancelPolling()
        job = nil
        jobID = nil
        result = nil
        errorMessage = nil
        lastSignature = ""
        lastChangeAt = now()
        awaitingFirstStatus = false
        gaveUp = false
    }

    func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Result

    private func downloadResult(_ finished: OCRJob) async {
        guard let outputFile = finished.outputFile else { return }
        isDownloading = true
        defer { isDownloading = false }
        do {
            let data = try await service.download(outputFile: outputFile)
            result = OCRResult(
                data: data,
                fileName: finished.downloadName ?? outputFile,
                translationMayBeIncomplete: finished.translationMayBeIncomplete)
        } catch {
            errorMessage = DisplayText.message(for: error)
        }
    }

    /// The caveat to show above a finished document, if any.
    ///
    /// `status == "completed"` does not mean "translated" — a failed translation is a `WARN`
    /// log line and the job completes with the original text. Saying nothing would let a
    /// practitioner file a document they believe is in one language and is not.
    var resultCaveat: String? {
        guard result?.translationMayBeIncomplete == true else { return nil }
        return """
            The translation step reported a problem, so part or all of this document may still \
            be in its original language. Check it before relying on it.
            """
    }

    // MARK: - History

    var historyPresentation: ListPresentation {
        ListPresentation(state: historyState, isEmpty: visibleHistory.isEmpty)
    }

    /// The history, less the job this screen is already showing live — the same document in
    /// two places, one of them a progress bar, reads as two documents.
    var visibleHistory: [OCRJob] {
        guard let jobID, isRunning else { return history }
        return history.filter { $0.id != jobID }
    }

    func loadHistory() async {
        historyState = .loading
        do {
            let fetched = try await service.history()
            history = fetched.jobs
            historyIsClearable = !fetched.listedOtherJobs
            historyState = .loaded
        } catch {
            historyState = .failed(LoadFailure(error))
        }
    }

    /// Whether "Clear history" is on offer at all.
    ///
    /// Withheld while this screen's own document is being read — clearing would remove the job
    /// it is waiting on — and whenever the listing covered anything not shown here.
    var canClearHistory: Bool {
        historyState == .loaded && historyIsClearable && !history.isEmpty
            && !isRunning && !isClearingHistory
    }

    /// Jobs in the list that have not finished.
    var historyInProgressCount: Int {
        history.filter { !$0.state.isTerminal }.count
    }

    /// The question the confirmation asks. Clearing is server-side, so it is every device's
    /// history, and a job still running elsewhere goes with it.
    var clearHistoryConfirmation: String {
        let count = history.count
        var text = "This removes \(count) document\(count == 1 ? "" : "s") from your history on every device, including the web. Their results can no longer be downloaded."
        let running = historyInProgressCount
        if running > 0 {
            text += " \(running) still being read will be removed too, and \(running == 1 ? "its result" : "their results") will not appear here when finished."
        }
        return text
    }

    func clearHistory() async {
        guard canClearHistory else { return }
        isClearingHistory = true
        defer { isClearingHistory = false }
        do {
            try await service.clearHistory()
            history = []
            historyState = .loaded
        } catch {
            errorMessage = DisplayText.message(for: error)
        }
        await loadHistory()
    }

    /// Fetches a finished history document for viewing.
    func open(_ historyJob: OCRJob) async {
        guard historyJob.state == .completed, let outputFile = historyJob.outputFile,
              openingJobID == nil
        else { return }
        openingJobID = historyJob.id ?? outputFile
        defer { openingJobID = nil }
        do {
            let data = try await service.download(outputFile: outputFile)
            opened = OCRResult(
                data: data,
                fileName: historyJob.downloadName ?? outputFile,
                translationMayBeIncomplete: historyJob.translationMayBeIncomplete)
        } catch {
            errorMessage = DisplayText.message(for: error)
        }
    }
}
