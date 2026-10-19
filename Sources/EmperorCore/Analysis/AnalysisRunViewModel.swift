import Foundation
#if canImport(Darwin)
import Observation
#endif

/// A finished analysis, fresh or from the history.
struct AnalysisOutcome: Equatable, Sendable {
    var result: AnalysisResult
    /// The saved run's id — `nil` when the server did not keep it.
    var runID: String?
    var usage: AnalysisUsage?
    /// What it read, for the line above the result.
    var fileNames: [String]
    var reference: String
    /// Whether it was opened from the history rather than just run.
    var isFromHistory: Bool = false
    /// When a saved run was made, if the server's timestamp could be read.
    var savedAt: Date?

    /// "Read 3 documents: Plaint.pdf, Notice.pdf and 1 more" — the web's provenance strip.
    var provenance: String {
        let names = fileNames.map(DisplayText.fileName)
        guard !names.isEmpty else { return "" }
        var line = "Read \(names.count) document\(names.count == 1 ? "" : "s"): "
        line += names.prefix(2).joined(separator: ", ")
        if names.count > 2 { line += " and \(names.count - 2) more" }
        if !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            line += " · with your note"
        }
        return line
    }
}

/// Why a run did not finish.
struct AnalysisFailure: Equatable, Sendable {
    var message: String
    /// A refusal about the account's plan: trying again cannot help until the account changes.
    var refusal: Refusal?

    var canRetry: Bool { refusal.map { !$0.concernsThePlan || $0.clearsByItself } ?? true }
}

/// One analysis tool's screen: the documents and note it will read, the run in flight, its
/// result, and opening a saved run in place of a fresh one.
///
/// ## The run is a poll
///
/// `start()` asks the server to begin, then asks every `pollInterval` how it is going, showing
/// the server's own line about what it is doing. It ends on `done`, on `error`, or after
/// `maxPolls` asks — 25 minutes at the default, as the web gives up. `cancel()` stops asking;
/// the job on the server runs on and, if it finishes, lands in the history.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class AnalysisRunViewModel {

    enum Phase: Equatable, Sendable {
        case idle
        case running(stage: String, progress: Double)
        case done(AnalysisOutcome)
        case failed(AnalysisFailure)
    }

    static let firstStage = "Getting your documents ready…"
    static let tooLongMessage = "This is taking too long. Try fewer or shorter documents."
    static let failedMessage = "The analysis failed. Try again."
    static let savedRunUnreadable = "This saved run could not be read."

    let tool: AnalysisJobTool

    private(set) var files: [ChatAttachment] = []
    /// What the last change to the documents could not keep, said once.
    var filesNotice: String?
    /// The note, kept within the server's length as it is typed.
    var reference: String = "" {
        didSet {
            if reference.utf16.count > AnalysisJobTool.maxReferenceLength {
                reference = AnalysisService.cleanReference(reference)
            }
        }
    }
    private(set) var phase: Phase = .idle
    /// The saved run being opened, by id.
    private(set) var opening: String?
    /// The saved run that last failed to open, so "Try again" opens it again.
    private var failedRunID: String?

    private let service: any AnalysisProviding
    private let pollInterval: TimeInterval
    private let maxPolls: Int
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Bumped by every start, cancel and reset: only the latest run may write.
    private var generation = 0

    init(
        tool: AnalysisJobTool,
        service: any AnalysisProviding,
        pollInterval: TimeInterval = 2,
        maxPolls: Int = 750,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.tool = tool
        self.service = service
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
        self.sleep = sleep
    }

    // MARK: - Inputs

    /// Takes what the picker chose: duplicates dropped, documents the tools cannot read left
    /// out, and no more than the server takes — each with a line saying so.
    func setFiles(_ chosen: [ChatAttachment]) {
        var seen = Set<ChatAttachment>()
        var kept: [ChatAttachment] = []
        var notes: [String] = []
        for file in chosen where seen.insert(file).inserted {
            if let refused = AnalysisService.refusal(for: file) {
                if !notes.contains(refused) { notes.append(refused) }
                continue
            }
            kept.append(file)
        }
        if kept.count > AnalysisJobTool.maxFiles {
            kept = Array(kept.prefix(AnalysisJobTool.maxFiles))
            notes.append("Only the first \(AnalysisJobTool.maxFiles) documents were kept — one run reads at most \(AnalysisJobTool.maxFiles).")
        }
        files = kept
        filesNotice = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    func remove(_ file: ChatAttachment) {
        files.removeAll { $0 == file }
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var canRun: Bool { !files.isEmpty && !isRunning }

    /// The line under the run button — the web's.
    var runHint: String { files.isEmpty ? AnalysisService.noFilesMessage : tool.runNote }

    // MARK: - Running

    /// "Try again": the saved run that failed to open, else the run itself.
    func retry() async {
        if let runID = failedRunID {
            await open(runID: runID)
        } else {
            await start()
        }
    }

    func start() async {
        guard canRun else { return }
        failedRunID = nil
        generation += 1
        let mine = generation
        let files = self.files
        let reference = self.reference
        phase = .running(stage: Self.firstStage, progress: 0)
        do {
            let jobID = try await service.start(tool: tool, files: files, reference: reference)
            var polls = 0
            while true {
                guard mine == generation else { return }
                let job = try await service.job(id: jobID)
                guard mine == generation else { return }
                switch job.status {
                case .done:
                    finish(job, files: files, reference: reference)
                    return
                case .error:
                    phase = .failed(AnalysisFailure(message: nonEmpty(job.error) ?? Self.failedMessage))
                    return
                case .reading, .thinking, .writing:
                    if case .running(let stage, let progress) = phase {
                        phase = .running(
                            stage: nonEmpty(job.stage) ?? stage,
                            progress: min(1, max(0, job.progress ?? progress)))
                    }
                }
                polls += 1
                if polls >= maxPolls {
                    phase = .failed(AnalysisFailure(message: Self.tooLongMessage))
                    return
                }
                try await sleep(pollInterval)
            }
        } catch is CancellationError {
            return
        } catch {
            guard mine == generation else { return }
            phase = .failed(Self.failure(error))
        }
    }

    private func finish(_ job: AnalysisJob, files: [ChatAttachment], reference: String) {
        guard let raw = job.result, let result = try? AnalysisResult.decode(raw, tool: tool) else {
            phase = .failed(AnalysisFailure(message: tool.unreadableResult))
            return
        }
        phase = .done(AnalysisOutcome(
            result: result, runID: job.runId, usage: job.usage,
            fileNames: files.map(\.name),
            reference: AnalysisService.cleanReference(reference)))
    }

    /// Stops following the run and goes back to the documents, which are kept.
    func cancel() {
        generation += 1
        opening = nil
        failedRunID = nil
        phase = .idle
    }

    /// Back to an empty screen: no documents, no note, no result.
    func startOver() {
        cancel()
        files = []
        filesNotice = nil
        reference = ""
    }

    // MARK: - Saved runs

    /// Shows a saved run in place of the screen's own. Its tool must be this one.
    func show(_ run: AnalysisRun) {
        generation += 1
        opening = nil
        guard run.summary.tool == tool, let result = try? AnalysisResult.decode(run.result, tool: tool) else {
            phase = .failed(AnalysisFailure(message: Self.savedRunUnreadable))
            return
        }
        phase = .done(AnalysisOutcome(
            result: result, runID: run.summary.id, usage: run.summary.usage,
            fileNames: run.summary.fileNames, reference: run.summary.reference,
            isFromHistory: true, savedAt: run.summary.createdDate))
    }

    /// Fetches a saved run and shows it. Returns whether it opened.
    @discardableResult
    func open(runID: String) async -> Bool {
        generation += 1
        let mine = generation
        opening = runID
        failedRunID = nil
        do {
            let run = try await service.run(id: runID)
            guard mine == generation else { return false }
            show(run)
            if case .done = phase { return true }
            failedRunID = runID
            return false
        } catch {
            guard mine == generation else { return false }
            opening = nil
            failedRunID = runID
            phase = .failed(Self.failure(error))
            return false
        }
    }

    // MARK: -

    static func failure(_ error: Error) -> AnalysisFailure {
        let refusal = (error as? APIError)?.refusal
        return AnalysisFailure(message: DisplayText.message(for: error), refusal: refusal)
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
