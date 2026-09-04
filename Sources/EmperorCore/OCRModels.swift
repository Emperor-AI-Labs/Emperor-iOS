import Foundation

/// An OCR/translate job.
///
/// - Important: **every field except `status` is optional, deliberately.** The server's job map
///   can be cleared wholesale while a job is still running, and the completion path then
///   re-inserts that job by spreading an `undefined` — yielding an entry with no `fileName`, no
///   `targetLang` and no `logs`. A model that declares those non-optional crashes on it.
struct OCRJob: Codable, Equatable, Identifiable, Sendable {
    var id: String?
    var status: String
    var step: Int?
    var progress: Int?
    var fileName: String?
    var targetLang: String?
    var pageSetup: String?
    var logs: [OCRLogLine]?
    var error: String?
    var outputFile: String?

    var state: OCRJobState { OCRJobState(wire: status) }

    /// Whether the translation step reported a problem.
    ///
    /// `status == "completed"` does **not** mean "translated". The translate block has its own
    /// try/catch: a failure becomes a `WARN` log line and the job completes with the *original*
    /// untranslated text (`sync-server.js:12227-12254`). There is no field on the wire for
    /// this — scanning the log is the only signal there is.
    var translationMayBeIncomplete: Bool {
        guard state == .completed, targetLang.map(OCRLanguage.translates) == true else {
            return false
        }
        return logs?.contains { $0.message?.hasPrefix("WARN: translation") == true } ?? false
    }

    /// The source is truncated to 60,000 characters before translation
    /// (`sync-server.js:12228`), recorded only on an internal usage row and never surfaced.
    /// This is the client's own estimate so a long document can at least carry a caveat.
    static let translationCharacterLimit = 60_000
}

/// One log line.
///
/// - Important: the two channels disagree on shape. `GET /ocr-status` returns `logs` as an
///   array of **plain strings** — `addLog` pushes the raw message (`sync-server.js:12163-12167`).
///   The `{timestamp, msg}` object exists only on the `/ocr-logs` SSE stream (`:12172`), and
///   even there the key is `msg`, not `message`. Modelling only the object shape makes the
///   *entire* OCR feature fail silently: the first poll throws `typeMismatch`, the poll loop
///   swallows it, and the job spins forever with no error and no result.
struct OCRLogLine: Codable, Equatable, Sendable {
    var timestamp: String?
    var message: String?

    init(timestamp: String? = nil, message: String?) {
        self.timestamp = timestamp
        self.message = message
    }

    private enum CodingKeys: String, CodingKey { case timestamp, message, msg }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let text = try? single.decode(String.self) {
            self.init(message: text)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decodeIfPresent(String.self, forKey: .message)
            ?? container.decodeIfPresent(String.self, forKey: .msg)
        self.init(
            timestamp: try container.decodeIfPresent(String.self, forKey: .timestamp),
            message: text)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

enum OCRJobState: Equatable, Sendable {
    case starting
    case running
    case completed
    case failed
    case unknown(String)

    init(wire: String) {
        switch wire.lowercased() {
        case "starting", "queued": self = .starting
        case "processing", "running": self = .running
        case "completed", "complete", "done": self = .completed
        case "failed", "error": self = .failed
        default: self = .unknown(wire)
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        case .starting, .running, .unknown: return false
        }
    }
}

/// The target language for a job.
///
/// - Important: **`lang` must always be sent.** Omitting it silently defaults to *Hindi*
///   (`sync-server.js:12118`) — so a "just digitise this" request comes back translated, and
///   billed. `Original` is the digitise-only value; the server skips translation for
///   `none|original|english|en` (`sync-server.js:12224`), which is why "English" here means
///   "leave it as it is" rather than "translate to English".
///
///   The server never validates this string — it is interpolated straight into the prompt
///   (`:12228`) — so a typo produces a job that "succeeds" and yields nonsense.
enum OCRLanguage: String, CaseIterable, Sendable, Codable {
    case original = "Original"
    case hindi = "Hindi"
    case bengali = "Bengali"
    case marathi = "Marathi"
    case telugu = "Telugu"
    case tamil = "Tamil"
    case gujarati = "Gujarati"
    case urdu = "Urdu"
    case kannada = "Kannada"
    case odia = "Odia"
    case malayalam = "Malayalam"
    case punjabi = "Punjabi"
    case assamese = "Assamese"
    case maithili = "Maithili"
    case sanskrit = "Sanskrit"
    case nepali = "Nepali"
    case konkani = "Konkani"
    case sindhi = "Sindhi"
    case dogri = "Dogri"
    case manipuri = "Manipuri"
    case bodo = "Bodo"
    case santali = "Santali"
    case kashmiri = "Kashmiri"

    var label: String {
        self == .original ? "Keep the original language" : rawValue
    }

    /// Whether asking for this language actually triggers a translation pass.
    static func translates(_ wire: String) -> Bool {
        !["none", "original", "english", "en"].contains(wire.lowercased())
    }

    var translates: Bool { Self.translates(rawValue) }
}

// MARK: - Envelopes

struct OCRSubmitResponse: Codable, Sendable {
    var success: Bool?
    var jobId: String?
    var error: String?
}

struct OCRStatusResponse: Codable, Sendable {
    var success: Bool?
    var job: OCRJob?
    var error: String?
    /// Some shapes return the job's fields at the top level rather than nested.
    var status: String?
    var step: Int?
    var progress: Int?
    var fileName: String?
    var targetLang: String?
    var logs: [OCRLogLine]?
    var outputFile: String?

    /// The job, however the server chose to shape this particular response.
    var resolvedJob: OCRJob? {
        if let job { return job }
        guard let status else { return nil }
        return OCRJob(
            id: nil, status: status, step: step, progress: progress, fileName: fileName,
            targetLang: targetLang, pageSetup: nil, logs: logs, error: error,
            outputFile: outputFile)
    }
}
