import Foundation

/// The uploads a person started together, as the upload panel shows them: one row per file
/// with its own bar and estimate, a measured speed for the whole batch, and a summary.
///
/// A value the background uploader owns and feeds — files added as they start, bytes as they
/// leave, a tick about once a second, and each file's outcome — and the panel only draws. It
/// observes the upload; nothing here decides what is sent or when.
///
/// A batch is the files added while any of them is still sending. Once every file has finished
/// sending, the next upload starts a new batch.
struct UploadBatch: Equatable, Sendable {

    enum Status: Equatable, Sendable {
        /// Handed to the system, no bytes gone yet.
        case queued
        case uploading
        /// Every byte has landed; the server is reading the document. Carries the server's own
        /// sentence when it has sent one.
        case processing(String?)
        /// Uploaded and readable.
        case done
        /// Did not upload — the server declined it, or it could not be prepared.
        case failed(String)
        /// Uploaded, but the server could not read it.
        case processingFailed(String)
        /// Uploaded, and the server had not finished reading it when this stopped asking — it
        /// was taking too long, or the question could not be put. Not a failure: the document
        /// turns up in the library when it is ready.
        case unconfirmed(String)
    }

    struct File: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let size: Int
        let folderName: String
        fileprivate(set) var loaded: Int
        fileprivate(set) var status: Status
        /// Seconds left, once there is evidence enough to say.
        fileprivate(set) var eta: Int?
        fileprivate var estimator = UploadETAEstimator()

        /// Share of the file's bytes that have left. A sent file counts as whole whatever
        /// happens to it afterwards.
        var fraction: Double {
            switch status {
            case .processing, .done, .processingFailed, .unconfirmed: return 1
            default:
                guard size > 0 else { return 0 }
                return min(1, Double(loaded) / Double(size))
            }
        }

        var percent: Int { Int((fraction * 100).rounded()) }

        /// Its bytes have all landed, whatever the server then made of them.
        var isSent: Bool {
            switch status {
            case .processing, .done, .processingFailed, .unconfirmed: return true
            default: return false
            }
        }

        var isSending: Bool {
            switch status {
            case .queued, .uploading: return true
            default: return false
            }
        }

        var needsAttention: Bool {
            switch status {
            case .failed, .processingFailed: return true
            default: return false
            }
        }

        /// "1.2 MB · 40 seconds left", "1.2 MB · Waiting", or the server's word on it.
        var detail: String {
            var parts: [String] = []
            let size = UploadProgressFormat.size(bytes: self.size)
            if !size.isEmpty { parts.append(size) }
            switch status {
            case .queued:
                parts.append("Waiting")
            case .uploading:
                if let eta { parts.append(UploadProgressFormat.eta(seconds: eta)) }
            case .processing(let message):
                parts.append(message ?? "Reading the document…")
            case .unconfirmed(let message):
                parts.append(message)
            case .done, .failed, .processingFailed:
                break
            }
            return parts.joined(separator: " · ")
        }

        /// The figure at the end of the row.
        var trailing: String {
            switch status {
            case .failed, .processingFailed: return "Failed"
            case .done, .processing, .unconfirmed: return "Done"
            case .queued, .uploading: return "\(percent)%"
            }
        }

        /// Why it failed, in the server's own words.
        var error: String? {
            switch status {
            case .failed(let message), .processingFailed(let message): return message
            default: return nil
            }
        }
    }

    /// A destination's files, under its own heading.
    struct Destination: Identifiable, Equatable, Sendable {
        let folderName: String
        let files: [File]

        var id: String { folderName }

        /// The destination, or "My Files (root)" for the top of the library.
        var title: String {
            folderName.isEmpty ? "My Files (root)" : DisplayText.fileName(folderName)
        }

        /// "2/5" while any is sending, "5 files" once none is.
        var count: String {
            if files.contains(where: \.isSending) {
                return "\(files.filter(\.isSent).count)/\(files.count)"
            }
            return "\(files.count) file\(files.count == 1 ? "" : "s")"
        }
    }

    private(set) var files: [File] = []
    private(set) var meter = UploadSpeedMeter()

    init() {}

    // MARK: - Feeding

    /// A file has been handed over. Starts a new batch if the last one has finished sending.
    ///
    /// - Parameter loaded: bytes already sent — non-zero for an upload picked up again after the
    ///   app was closed.
    mutating func add(
        id: String, name: String, size: Int, folderName: String, loaded: Int = 0,
        sent: Bool = false, at now: Date
    ) {
        if !files.isEmpty, !isSending { files = [] }
        guard !files.contains(where: { $0.id == id }) else { return }
        let status: Status = sent ? .processing(nil) : (loaded > 0 ? .uploading : .queued)
        var file = File(
            id: id, name: name, size: max(0, size), folderName: folderName,
            loaded: min(max(0, loaded), max(0, size)), status: status)
        if case .uploading = status { file.estimator.restart(at: now) }
        files.append(file)
        if file.isSending { meter.start(at: now) }
    }

    func contains(_ id: String) -> Bool { files.contains { $0.id == id } }

    /// New bytes that left the device, for the speed. Any file, any chunk.
    mutating func record(sentBytes: Int) {
        meter.record(bytes: sentBytes)
    }

    /// How much of one file has been sent.
    ///
    /// Never moves a file's figure backwards: a chunk that is sent again is still the same
    /// part of the same file, and a bar that retreats reads as something broken.
    mutating func setLoaded(_ bytes: Int, of id: String, at now: Date) {
        guard let index = files.firstIndex(where: { $0.id == id }), files[index].isSending
        else { return }
        let clamped = min(max(0, bytes), files[index].size)
        guard clamped >= files[index].loaded else { return }
        if case .queued = files[index].status, clamped > 0 {
            files[index].status = .uploading
            files[index].estimator.restart(at: now)
        }
        files[index].loaded = clamped
        if case .uploading = files[index].status {
            let percent = files[index].size > 0
                ? Double(clamped) / Double(files[index].size) * 100 : 0
            files[index].eta = files[index].estimator.update(percent: percent, at: now)
        }
    }

    /// Takes a speed sample when one is due.
    mutating func tick(at now: Date) {
        meter.tick(at: now)
    }

    /// Every byte of the file has landed and the server is reading it.
    ///
    /// Ignored once the file has an outcome: a progress sentence from a poll can arrive after
    /// the poll's own answer, and must not put a finished file back to "reading".
    mutating func markProcessing(_ id: String, message: String? = nil) {
        guard let file = files.first(where: { $0.id == id }) else { return }
        switch file.status {
        case .queued, .uploading, .processing: break
        default: return
        }
        update(id) { file in
            file.loaded = file.size
            file.eta = nil
            file.status = .processing(message)
        }
    }

    /// The server finished reading the file and it can be asked about.
    mutating func markDone(_ id: String) {
        update(id) { file in
            file.loaded = file.size
            file.eta = nil
            file.status = .done
        }
    }

    /// Stopped asking before the server finished reading the file.
    mutating func markUnconfirmed(_ id: String, message: String) {
        update(id) { file in
            file.loaded = file.size
            file.eta = nil
            file.status = .unconfirmed(message)
        }
    }

    mutating func markFailed(_ id: String, message: String) {
        update(id) { file in
            file.eta = nil
            file.status = .failed(message)
        }
    }

    mutating func markProcessingFailed(_ id: String, message: String) {
        update(id) { file in
            file.eta = nil
            file.status = .processingFailed(message)
        }
    }

    /// Clears a finished batch. Does nothing while anything is still being sent or read.
    mutating func dismiss() {
        guard !isActive else { return }
        files = []
    }

    private mutating func update(_ id: String, _ change: (inout File) -> Void) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        change(&files[index])
        if !isSending { meter.stop() }
    }

    // MARK: - Reading

    var isEmpty: Bool { files.isEmpty }

    /// Any file still sending bytes.
    var isSending: Bool { files.contains(where: \.isSending) }

    /// Any file still sending or still being read.
    var isActive: Bool {
        files.contains { file in
            if file.isSending { return true }
            if case .processing = file.status { return true }
            return false
        }
    }

    var groups: [Destination] {
        var order: [String] = []
        var byFolder: [String: [File]] = [:]
        for file in files {
            if byFolder[file.folderName] == nil { order.append(file.folderName) }
            byFolder[file.folderName, default: []].append(file)
        }
        return order.map { Destination(folderName: $0, files: byFolder[$0] ?? []) }
    }

    /// "Uploading", "Finished with errors" or "Uploads".
    var title: String {
        if isSending { return "Uploading" }
        if files.contains(where: \.needsAttention) { return "Finished with errors" }
        return "Uploads"
    }

    /// "2 of 5 files · 48%", "1 of 5 files need attention" or "All 5 files uploaded".
    var subtitle: String {
        let total = files.count
        let noun = "file\(total == 1 ? "" : "s")"
        if isSending {
            let done = files.filter(\.isSent).count
            return "\(done) of \(total) \(noun) · \(overallPercent)%"
        }
        let failed = files.filter(\.needsAttention).count
        if failed > 0 {
            return "\(failed) of \(total) \(noun) need attention"
        }
        return "All \(total) \(noun) uploaded"
    }

    /// The mean of every file's own percentage, as the web computes it.
    var overallPercent: Int {
        guard !files.isEmpty else { return 0 }
        let sum = files.reduce(0.0) { $0 + $1.fraction }
        return Int((sum / Double(files.count) * 100).rounded())
    }

    /// Bytes still to send across the batch.
    var remainingBytes: Int {
        files.filter(\.isSending).reduce(0) { $0 + max(0, $1.size - $1.loaded) }
    }

    /// Seconds left for the whole batch at the measured speed, while anything is sending.
    var etaSeconds: Int? {
        isSending ? meter.etaSeconds(remainingBytes: remainingBytes) : nil
    }

    /// "Upload speed: Good (12.3 Mbps) · ~2 min left" — `nil` until a speed has been measured,
    /// and kept without the estimate after the batch has sent everything.
    var speedLine: String? {
        UploadProgressFormat.speedLine(mbps: meter.mbps, etaSeconds: etaSeconds)
    }

    /// Said once every file has been sent and read: whether the documents can now be asked
    /// about, or which need uploading again. `nil` while any is still on its way, and for a
    /// batch in which nothing reached the server.
    var completionNotice: String? {
        guard !isActive else { return nil }
        let unreadable = files.filter {
            if case .processingFailed = $0.status { return true }
            return false
        }.count
        if unreadable > 0 {
            return unreadable == 1
                ? "1 file could not be processed — please re-upload it."
                : "\(unreadable) files could not be processed — please re-upload them."
        }
        let ready = files.filter { $0.status == .done }.count
        if ready == 1 {
            return "Your document is now searchable — ask Emperor anything about it."
        }
        if ready > 1 {
            return "All \(ready) uploads are now searchable — ask Emperor anything about them."
        }
        return nil
    }
}
