import Foundation

// The numbers an upload shows while it runs — the measured speed, the estimates, and the
// wording of each — ported from the web app's upload tray so the two say the same thing about
// the same upload. Pure arithmetic over values the caller hands in, including the time, so all
// of it is tested without a network or a clock.

// MARK: - Speed band

/// How the measured upstream rate reads to a person: enough to judge whether a slow upload is
/// the connection or something stuck.
enum UploadSpeedBand: String, Equatable, Sendable {
    case poor
    case average
    case good

    /// The web's thresholds: 10 Mbps and up is good, 2 Mbps and up is average.
    static func band(forMbps mbps: Double) -> UploadSpeedBand {
        if mbps >= 10 { return .good }
        if mbps >= 2 { return .average }
        return .poor
    }

    var label: String {
        switch self {
        case .poor: return "Poor"
        case .average: return "Average"
        case .good: return "Good"
        }
    }
}

// MARK: - Speed meter

/// Upload speed measured from the bytes actually leaving the device — no probe request, and no
/// reading of the system's own link estimate, which reports the downlink rather than the
/// upstream that decides how long an upload takes.
///
/// The caller reports every new byte sent (`record(bytes:)`), across every file and chunk of the
/// batch, and calls `tick(at:)` about once a second while the upload runs. Each tick that is at
/// least a second after the previous sample takes one: `Δbytes × 8 / Δseconds / 1e6`. The
/// figure shown is the mean of the last five samples, and nothing is shown until three exist —
/// one noisy second is a guess, and a wrong "Poor" sends someone off to restart a router that
/// is working.
///
/// When the upload stops the last measured figure is kept (it was real) but the estimate goes,
/// since nothing is in flight to estimate.
struct UploadSpeedMeter: Equatable, Sendable {
    /// Seconds between samples.
    static let sampleInterval: TimeInterval = 1
    /// Samples averaged into the published figure.
    static let window = 5
    /// Samples needed before anything is published.
    static let minimumSamples = 3
    /// Below this the divisor is noise and an estimate would be measured in days.
    static let minimumMbpsForEstimate = 0.05

    /// Every byte reported since the meter was created.
    private(set) var totalBytes = 0
    private(set) var isActive = false
    /// The last few samples, in Mbps, oldest first.
    private(set) var recent: [Double] = []
    /// Samples taken since the current upload started.
    private(set) var sampleCount = 0
    /// The published speed, in Mbps. `nil` until an upload has produced enough samples; then
    /// kept, including after the upload ends.
    private(set) var mbps: Double?

    private var lastSampleAt: Date?
    private var lastSampleBytes = 0

    init() {}

    /// Starts sampling. A fresh upload is measured afresh, but the previous figure stays on show
    /// until the new one has enough samples to replace it.
    mutating func start(at now: Date) {
        guard !isActive else { return }
        isActive = true
        recent = []
        sampleCount = 0
        lastSampleAt = now
        lastSampleBytes = totalBytes
    }

    /// New bytes sent. Negative or zero deltas are ignored: only bytes leaving the device count.
    mutating func record(bytes: Int) {
        guard bytes > 0 else { return }
        totalBytes += bytes
    }

    /// Takes a sample if a second has passed since the last one.
    mutating func tick(at now: Date) {
        guard isActive, let last = lastSampleAt else { return }
        let elapsed = now.timeIntervalSince(last)
        // A ticker sleeping for a second wakes a hair early now and then; a strict `>= 1` would
        // skip that sample and make the next one span two seconds.
        guard elapsed >= Self.sampleInterval * 0.95 else { return }
        let delta = totalBytes - lastSampleBytes
        lastSampleAt = now
        lastSampleBytes = totalBytes
        let sample = Double(delta) * 8 / elapsed / 1_000_000
        recent.append(sample)
        if recent.count > Self.window { recent.removeFirst(recent.count - Self.window) }
        sampleCount += 1
        if sampleCount >= Self.minimumSamples {
            mbps = recent.reduce(0, +) / Double(recent.count)
        }
    }

    /// The upload has stopped. The figure stays; the estimate goes.
    mutating func stop() {
        isActive = false
        lastSampleAt = nil
    }

    var band: UploadSpeedBand? { mbps.map(UploadSpeedBand.band(forMbps:)) }

    /// Seconds until `remainingBytes` have gone at the published rate, or `nil` when nothing is
    /// uploading, nothing has been measured, or the rate is too low to divide by honestly.
    func etaSeconds(remainingBytes: Int) -> Int? {
        guard isActive, let mbps, mbps > Self.minimumMbpsForEstimate else { return nil }
        let seconds = Double(max(0, remainingBytes)) * 8 / (mbps * 1_000_000)
        return Int(seconds.rounded())
    }
}

// MARK: - Per-file estimate

/// One file's time left, extrapolated from how long it has taken so far.
///
/// Per file rather than a share of the batch rate: several files go over one connection at once,
/// so dividing one file's remaining bytes by the whole batch's throughput would promise each of
/// them the whole line. Withheld for the first second and a half and below 3%, where the
/// extrapolation swings by a factor of ten; then smoothed toward the running estimate so a chunk
/// that is sent again does not make the number leap.
struct UploadETAEstimator: Equatable, Sendable {
    private(set) var startedAt: Date?
    private(set) var smoothed: Double?

    init() {}

    /// Starts the clock — when the file begins sending, and again if it starts over.
    mutating func restart(at now: Date) {
        startedAt = now
        smoothed = nil
    }

    /// Feeds in the file's percentage (0–100) and returns the seconds left to show, if any.
    ///
    /// A percentage of zero or less means the file is starting (or starting again), which
    /// restarts the clock.
    mutating func update(percent: Double, at now: Date) -> Int? {
        if startedAt == nil || percent <= 0 {
            restart(at: now)
        }
        guard let startedAt else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard percent > 0, percent < 100, elapsed > 1.5, percent >= 3 else { return nil }
        let raw = elapsed * (100 - percent) / percent
        let next = smoothed.map { $0 * 0.7 + raw * 0.3 } ?? raw
        smoothed = next
        return max(1, Int(next.rounded()))
    }
}

// MARK: - Wording

/// How each of the upload numbers is written, matching the web's tray word for word.
enum UploadProgressFormat {

    /// "400 kbps" below 1 Mbps, where "0.4 Mbps" would read as a rounding error rather than
    /// as slow; otherwise "12 Mbps" or "3.4 Mbps".
    static func speed(mbps: Double) -> String {
        if mbps < 1 {
            return "\(Int((mbps * 1000).rounded())) kbps"
        }
        if mbps.rounded(.towardZero) == mbps {
            return "\(Int(mbps)) Mbps"
        }
        return String(format: "%.1f Mbps", mbps)
    }

    /// The whole-batch estimate, deliberately coarse and worded to admit it.
    static func coarseETA(seconds: Int) -> String {
        if seconds < 60 { return "under a minute left" }
        if seconds < 3600 {
            return "~\(Int((Double(seconds) / 60).rounded())) min left"
        }
        return String(format: "~%.1f hr left", Double(seconds) / 3600)
    }

    /// One file's estimate: to the second under a minute, in whole minutes after that.
    static func eta(seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds) second\(seconds == 1 ? "" : "s") left"
        }
        let minutes = Int((Double(seconds) / 60).rounded())
        return "\(minutes) minute\(minutes == 1 ? "" : "s") left"
    }

    /// "512 B", "340 KB", "12.4 MB" — empty for an unknown or empty size, as on the web.
    static func size(bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 {
            return "\(Int((Double(bytes) / 1024).rounded())) KB"
        }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// "Upload speed: Good (12.3 Mbps) · ~2 min left", or without the estimate when there is
    /// none. `nil` until a speed has been measured.
    static func speedLine(mbps: Double?, etaSeconds: Int?) -> String? {
        guard let mbps else { return nil }
        var line = "Upload speed: \(UploadSpeedBand.band(forMbps: mbps).label) (\(speed(mbps: mbps)))"
        if let etaSeconds { line += " · " + coarseETA(seconds: etaSeconds) }
        return line
    }

    /// Said alongside the speed line, so nobody mistakes it for a speed test.
    static let speedExplanation =
        "Measured from the bytes actually leaving this device during the upload."
}

// MARK: - Processing stages

/// The server's ingest pipeline, named for a person rather than for the code.
///
/// The server reports a `stage` on each file's `progress` object. The numbering is
/// presentational and lives here so the wording can change without the server. `queued` is not
/// a step — a file no worker has touched has not started step 1, and "1/4" for it would be a
/// claim the user can see through — and `done` and `error` are terminal, never steps.
enum IngestStage {
    static let stepCount = 4

    /// The step number and its name, for a working stage.
    static func step(for stage: String?) -> (number: Int, label: String)? {
        switch stage {
        case "reading": return (1, "Reading file")
        case "ocr": return (2, "Extracting data")
        case "embedding": return (3, "Making searchable")
        case "indexing": return (4, "Organising")
        default: return nil
        }
    }

    /// "2/4 Extracting data · 45%", "1/4 Reading file", "Queued #3" or "Queued…" — or `nil`
    /// when the progress object says nothing that can be put into words (a terminal stage, or
    /// none at all).
    static func line(for progress: IngestProgress?) -> String? {
        guard let progress else { return nil }
        if let step = step(for: progress.stage) {
            let label = "\(step.number)/\(stepCount) \(step.label)"
            guard let percent = progress.percent else { return label }
            return "\(label) · \(clamp(percent))%"
        }
        if progress.stage == "queued" || (progress.stage == nil && progress.percent == nil) {
            if let position = progress.queuePosition { return "Queued #\(position)" }
            return "Queued…"
        }
        if progress.stage == "done" || progress.stage == "error" { return nil }
        // A stage this client does not know yet: the number is still true.
        return progress.percent.map { "\(clamp($0))%" }
    }

    /// The stage's own percentage as a fraction, for a bar — `nil` when there is no number to
    /// draw (queued, or a stage that has not reported one).
    static func fraction(for progress: IngestProgress?) -> Double? {
        guard let progress, step(for: progress.stage) != nil, let percent = progress.percent
        else { return nil }
        return Double(clamp(percent)) / 100
    }

    private static func clamp(_ percent: Int) -> Int { min(100, max(0, percent)) }
}

/// Keeps a document's stage percentage from going backwards between two reads of the library.
///
/// Each stage owns its own 0–100, so a new stage starting at 0 is expected and passes through;
/// within one stage a lower figure than one already shown — a read served from before a worker
/// reported — is raised back to it, so a bar never visibly retreats.
struct IngestPercentLatch: Equatable, Sendable {
    private struct Seen: Equatable, Sendable {
        let stage: String
        let percent: Int
    }

    private var seen: [String: Seen] = [:]

    init() {}

    /// The percentage to show for `progress` on the document at `path`, remembering it.
    mutating func percent(for progress: IngestProgress, at path: String) -> Int? {
        guard let stage = progress.stage, let percent = progress.percent else {
            return progress.percent
        }
        if let previous = seen[path], previous.stage == stage, previous.percent > percent {
            return previous.percent
        }
        seen[path] = Seen(stage: stage, percent: percent)
        return percent
    }

    /// The tree with every in-progress document's percentage held where `percent(for:at:)` says.
    mutating func apply(to nodes: [FileNode]) -> [FileNode] {
        nodes.map { node in
            switch node {
            case .folder(var folder):
                folder.files = folder.files.map { apply(to: $0) }
                return .folder(folder)
            case .file(var file):
                if var progress = file.progress {
                    progress.percent = percent(for: progress, at: file.path)
                    file.progress = progress
                }
                return .file(file)
            }
        }
    }
}
