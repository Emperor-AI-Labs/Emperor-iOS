import Foundation

/// An OCR/translate job.
///
/// - Important: **every field except `status` is optional, deliberately.** A job's entry can be
///   removed while it is still running (clearing history takes running jobs with it), and the
///   completion path then re-inserts it by spreading an `undefined` — yielding an entry with no
///   `fileName`, no `targetLang` and no `logs`. A model that declares those non-optional crashes
///   on it.
///
/// The same shape arrives from two routes: `GET /ocr-status` returns one job as the whole body,
/// and `GET /ocr-history` returns an array of them, each with its `id` spread in
/// (`sync-server.js:15631-15680`).
struct OCRJob: Codable, Equatable, Identifiable, Sendable {
    var id: String?
    var status: String
    var step: Int?
    var progress: Int?
    var fileName: String?
    var targetLang: String?
    /// The page setup the upload asked for. The server stores what `JSON.parse` made of the
    /// field — an object — so a `String` here failed to decode every job that carried one, and a
    /// history listing with one such job failed whole. Kept as raw JSON: nothing reads it.
    var pageSetup: JSONValue?
    var logs: [OCRLogLine]?
    var error: String?
    var outputFile: String?
    /// The account the job was recorded against. Sent as a string, read leniently because the
    /// record round-trips through a JSON file on the server and an older writer stored numbers.
    var ownerID: String? = nil

    var state: OCRJobState { OCRJobState(wire: status) }

    /// Whether the translation step reported a problem.
    ///
    /// `status == "completed"` did **not** always mean "translated": an earlier translate block
    /// turned a failure into a `WARN` log line and completed with the *original* text. The
    /// current pipeline fails the job instead and names the page (`sync-server.js:15566-15571`),
    /// but a job finished before that change still carries the old signal in its log — and the
    /// history list now reaches those jobs — so the check stays.
    var translationMayBeIncomplete: Bool {
        guard state == .completed, targetLang.map(OCRLanguage.translates) == true else {
            return false
        }
        return logs?.contains { $0.message?.hasPrefix("WARN: translation") == true } ?? false
    }

    /// When the job was started. The id **is** the start time — `Date.now().toString()`
    /// (`sync-server.js:15420`) — which is how the web dates its history rows too
    /// (`OCRTranslate.jsx:7`).
    var createdAt: Date? {
        guard let id, id.count >= 10, id.allSatisfy({ $0.isASCII && $0.isNumber }),
              let millis = Double(id)
        else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    /// The name to save the result under.
    ///
    /// Results are stored as `<jobId>_<name>` so two uploads of the same file cannot collide,
    /// and the server strips that prefix when it serves the file (`sync-server.js:15703`). The
    /// stored name is still what `/ocr-download` must be asked for; this is only what the user
    /// sees and saves.
    var downloadName: String? {
        guard let outputFile else { return nil }
        var digits = 0
        for character in outputFile {
            guard character.isASCII, character.isNumber else { break }
            digits += 1
        }
        guard digits >= 10, outputFile.dropFirst(digits).first == "_" else { return outputFile }
        return String(outputFile.dropFirst(digits + 1))
    }

    /// The source document's name as the user would recognise it. Stored names are
    /// underscore-sanitised on upload (`sync-server.js:15423`), which `DisplayText.fileName`
    /// undoes for display.
    var displayName: String {
        guard let fileName, !fileName.isEmpty else { return "Untitled document" }
        return DisplayText.fileName(fileName)
    }

    /// The language the result is in, for a history row: the target, or "Original language"
    /// for a job that only digitised. `nil` when the entry lost its language.
    var languageLabel: String? {
        guard let targetLang, !targetLang.isEmpty else { return nil }
        return OCRLanguage.translates(targetLang) ? targetLang : "Original language"
    }

    enum CodingKeys: String, CodingKey {
        case id, status, step, progress, fileName, targetLang, pageSetup, logs, error, outputFile
        case ownerID = "userId"
    }
}

extension OCRJob {
    /// Lenient where the server's own writers have disagreed, strict only on `status`.
    ///
    /// One malformed field must not cost the user the job, and in a history listing one
    /// malformed job must not cost them the list — `OCRHistoryResponse` handles the second.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        id = Self.text(container, .id)
        step = Self.whole(container, .step)
        progress = Self.whole(container, .progress)
        fileName = try? container.decodeIfPresent(String.self, forKey: .fileName)
        targetLang = try? container.decodeIfPresent(String.self, forKey: .targetLang)
        pageSetup = try? container.decodeIfPresent(JSONValue.self, forKey: .pageSetup)
        logs = try? container.decodeIfPresent([OCRLogLine].self, forKey: .logs)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        outputFile = try? container.decodeIfPresent(String.self, forKey: .outputFile)
        ownerID = Self.text(container, .ownerID)
    }

    /// A string, or a whole number written as one.
    private static func text(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
        return nil
    }

    /// An integer, accepting one written with a fraction.
    private static func whole(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return Int(value)
        }
        return nil
    }
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
///   (`sync-server.js:15384`) — so a "just digitise this" request comes back translated, and
///   counted against the account. `Original` is the digitise-only value: the server skips
///   translation for `none|original` and nothing else (`sync-server.js:15471`, `:15572`).
///
///   English is a real target. It used to be treated as "leave it as it is", which handed a
///   Punjabi order back in Punjabi as a completed translation into English; the platform now
///   translates into it (`sync-server.js:15566-15571`) and lists it first, as the web does
///   (`OCRTranslate.jsx:10-15`).
///
///   The server never validates this string — it is interpolated into the prompt — so a typo
///   produces a job that "succeeds" and yields nonsense. This enum is the whole allowed set.
enum OCRLanguage: String, CaseIterable, Sendable, Codable {
    case original = "Original"
    // English plus the 22 scheduled languages, in the web's order: English, Hindi, then
    // alphabetical.
    case english = "English"
    case hindi = "Hindi"
    case assamese = "Assamese"
    case bengali = "Bengali"
    case bodo = "Bodo"
    case dogri = "Dogri"
    case gujarati = "Gujarati"
    case kannada = "Kannada"
    case kashmiri = "Kashmiri"
    case konkani = "Konkani"
    case maithili = "Maithili"
    case malayalam = "Malayalam"
    case manipuri = "Manipuri"
    case marathi = "Marathi"
    case nepali = "Nepali"
    case odia = "Odia"
    case punjabi = "Punjabi"
    case sanskrit = "Sanskrit"
    case santali = "Santali"
    case sindhi = "Sindhi"
    case tamil = "Tamil"
    case telugu = "Telugu"
    case urdu = "Urdu"

    var label: String {
        self == .original ? "Keep the original language" : rawValue
    }

    /// Whether asking for this language actually triggers a translation pass.
    static func translates(_ wire: String) -> Bool {
        !["none", "original"].contains(wire.lowercased())
    }

    var translates: Bool { Self.translates(rawValue) }

    /// What Translate offers: every real language, and not "Original". Keeping the document in
    /// its own language is OCR's job now, a mode of its own — the web's Translate tab lists the
    /// same twenty-three and no "keep" option (`src/pages/OCRTranslate.jsx`, `LANGUAGES`).
    static var translationTargets: [OCRLanguage] { allCases.filter(\.translates) }

    /// Where Translate starts, as the web's does.
    static let defaultTranslationTarget = OCRLanguage.hindi
}

// MARK: - Envelopes

struct OCRSubmitResponse: Codable, Sendable {
    var success: Bool?
    var jobId: String?
    var error: String?
}

/// `GET /ocr-status`.
///
/// The route answers with the job itself as the whole body (`sync-server.js:15639`); an earlier
/// shape nested it under `job`. Both are read, and the top-level form goes through `OCRJob`'s own
/// lenient decoding rather than a second, stricter copy of its fields.
struct OCRStatusResponse: Decodable, Sendable {
    var success: Bool?
    var job: OCRJob?
    var error: String?

    private enum CodingKeys: String, CodingKey { case success, job, error, status }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try? container.decodeIfPresent(Bool.self, forKey: .success)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        if let nested = try? container.decodeIfPresent(OCRJob.self, forKey: .job) {
            job = nested
        } else if container.contains(.status) {
            job = try OCRJob(from: decoder)
        } else {
            job = nil
        }
    }

    /// The job, however the server chose to shape this particular response.
    var resolvedJob: OCRJob? { job }
}

/// `GET /ocr-history`: a bare array of jobs, newest first (`sync-server.js:15672-15679`).
///
/// Decoded one element at a time. A job the decoder cannot read is skipped and counted rather
/// than failing the listing, so one odd entry — a record from an older writer — cannot turn the
/// whole history into "could not load".
struct OCRHistoryResponse: Decodable, Sendable {
    var jobs: [OCRJob] = []
    var unreadable = 0

    init(jobs: [OCRJob], unreadable: Int = 0) {
        self.jobs = jobs
        self.unreadable = unreadable
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let job = try? container.decode(OCRJob.self) {
                jobs.append(job)
            } else if (try? container.decode(JSONValue.self)) != nil {
                // Consumed as raw JSON so the container moves past it.
                unreadable += 1
            } else {
                break
            }
        }
    }
}

/// The signed-in account's history of documents digitised, translated or converted.
struct OCRHistory: Equatable, Sendable {
    /// This account's jobs, newest first.
    var jobs: [OCRJob]
    /// Whether the server listed jobs recorded against another account, or against none.
    ///
    /// An administrator's listing is wider than their own work. Those entries are not shown
    /// here — this screen is the user's own history — and Clear is withheld whenever they were
    /// listed, because clearing removes everything the listing covers, not only what is shown.
    var listedOtherJobs: Bool
}

struct OCRClearResponse: Decodable, Sendable {
    var success: Bool?
    var error: String?
}
