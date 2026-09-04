import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Digitising a document, and watching it happen.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class OCRViewModel {

    private(set) var job: OCRJob?
    private(set) var jobID: String?
    private(set) var isSubmitting = false
    private(set) var isDownloading = false
    var errorMessage: String?
    var language: OCRLanguage = .original
    var result: OCRResult?

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

    init(service: any OCRProviding, now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.now = now
        self.lastChangeAt = now()
    }

    deinit { pollTask?.cancel() }

    var isRunning: Bool {
        guard let job else { return isSubmitting }
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

    func submit(data: Data, fileName: String) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        job = nil
        result = nil
        defer { isSubmitting = false }

        do {
            let id = try await service.submit(
                data: data, fileName: fileName, language: language)
            jobID = id
            lastChangeAt = now()
            lastSignature = ""
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
            // The deadline has to apply here too. A job wiped by a global clear 404s on every
            // later poll, so checking the clock only on the *success* path made the timeout
            // unreachable in precisely the case it exists for, and the loop ran until the
            // battery died.
            if now().timeIntervalSince(lastChangeAt) > Self.stallTimeout {
                errorMessage = Self.stalledMessage
                return true
            }
            return false
        }
        job = fetched

        // Anything the server could plausibly change. If none of it moves for `stallTimeout`,
        // the job is treated as dead rather than polled forever.
        let signature = "\(fetched.status)|\(fetched.progress ?? -1)|\(fetched.step ?? -1)|\(fetched.logs?.count ?? 0)"
        if signature != lastSignature {
            lastSignature = signature
            lastChangeAt = now()
        } else if now().timeIntervalSince(lastChangeAt) > Self.stallTimeout {
            errorMessage = Self.stalledMessage
            return true
        }

        guard fetched.state.isTerminal else { return false }
        if fetched.state == .completed { await downloadResult(fetched) }
        return true
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
                fileName: outputFile,
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
}
