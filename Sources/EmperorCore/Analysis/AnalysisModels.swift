import Foundation

// The server-run analysis tools: a job is started on documents already in My Files, polled
// until it is done, and its result is drawn as a report, an index or a list of dates. Each
// finished run is kept in a per-tool history.
//
// These are separate from the prompt-only tools in `Tools/AnalysisTools.swift`, which go
// through `/chat`. Those stay; these are the web's Analysis pages.

/// A tool the server runs as a background job.
///
/// The ids are the wire's (`tool` on `/analysis/start` and `/analysis/history`); the words are
/// the web's own, from its Analysis pages and their hub, so someone who uses both reads one
/// vocabulary.
///
/// The web also has a Highlighter page. It is **not offered**: the web's page is a sample with
/// no route behind it.
enum AnalysisJobTool: String, CaseIterable, Codable, Sendable, Identifiable {
    // The hub's order.
    case devilsAdvocate = "devils-advocate"
    case docIndex = "doc-index"
    case listOfDates = "list-of-dates"

    var id: String { rawValue }

    /// The most documents one run may read — the server refuses an eleventh.
    static let maxFiles = 10
    /// The longest note the server takes, in JavaScript characters (UTF-16 code units).
    static let maxReferenceLength = 2000

    var title: String {
        switch self {
        case .devilsAdvocate: return "Devil's Advocate"
        case .docIndex: return "Doc Index"
        case .listOfDates: return "List of Dates"
        }
    }

    /// The other name the web gives it, if any.
    var alsoCalled: String? {
        self == .listOfDates ? "Synopsis of dates" : nil
    }

    /// The hub card's line.
    var blurb: String {
        switch self {
        case .devilsAdvocate:
            return "Where is my case weak? The questions the other side will ask, as a full report."
        case .docIndex:
            return "One table of every document: what it is, who it is between, what it says."
        case .listOfDates:
            return "Every date and event, by side, with a timeline beside it."
        }
    }

    /// The line under the tool's title.
    var tagline: String {
        switch self {
        case .devilsAdvocate:
            return "Find where your case is weak and what the other side's lawyer will ask, so you are ready before they ask it."
        case .docIndex:
            return "One table of every document: what it is, who it is between, what it says. The AI picks the columns."
        case .listOfDates:
            return "Every date in your papers, on one page: who did what, and when."
        }
    }

    var systemImage: String {
        switch self {
        case .devilsAdvocate: return "exclamationmark.shield"
        case .docIndex: return "tablecells"
        case .listOfDates: return "calendar"
        }
    }

    var referenceLabel: String {
        switch self {
        case .devilsAdvocate: return "Say who you act for and where you feel exposed"
        case .docIndex: return "Anything the index should focus on?"
        case .listOfDates: return "Which side are you? Anything to emphasise?"
        }
    }

    var referencePlaceholder: String {
        switch self {
        case .devilsAdvocate:
            return "For example: We act for Helios, the plaintiff. I am worried about the arbitration clause and the older invoices."
        case .docIndex:
            return "For example: flag anything that helps prove the unpaid invoices, and note which papers have missing signatures."
        case .listOfDates:
            return "For example: We act for the plaintiff, Helios. Please stress the payment history and the dates that matter for limitation."
        }
    }

    var referenceHint: String {
        switch self {
        case .devilsAdvocate: return "Optional. A line or two helps the report focus on what keeps you up at night."
        case .docIndex: return "Leave this blank and the AI will choose the columns on its own."
        case .listOfDates: return "Optional. It helps decide which side of the table each event goes on."
        }
    }

    var runLabel: String {
        switch self {
        case .devilsAdvocate: return "Find my blind spots"
        case .docIndex: return "Build my index"
        case .listOfDates: return "Build the list of dates"
        }
    }

    var runNote: String {
        switch self {
        case .devilsAdvocate: return "You will get a full prep report: weak spots, likely questions, missing papers."
        case .docIndex: return "Usually takes under a minute. The AI decides which columns are useful for these papers."
        case .listOfDates: return "Takes a few minutes for long papers. You can copy or share it when it is done."
        }
    }

    /// The heading while it runs.
    var runningTitle: String {
        switch self {
        case .devilsAdvocate: return "Playing the other side"
        case .docIndex: return "Building your index"
        case .listOfDates: return "Building your list of dates"
        }
    }

    /// The heading over a failure.
    var failureTitle: String {
        switch self {
        case .devilsAdvocate: return "We could not finish the report"
        case .docIndex: return "We could not build your index"
        case .listOfDates: return "The list could not be built"
        }
    }

    /// When the job finished but its result could not be read.
    var unreadableResult: String {
        switch self {
        case .devilsAdvocate: return "The report came back in a form we could not read."
        case .docIndex: return "The AI sent back an index we could not read. Please try again."
        case .listOfDates: return "The list came back in a form we could not read. Please try again."
        }
    }
}

// MARK: - The job

/// What `/analysis/job` says while a job runs and once it is over.
struct AnalysisJob: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable {
        case reading, thinking, writing, done, error
    }

    var success: Bool?
    var status: Status
    /// A plain-words line about what the server is doing now.
    var stage: String?
    /// 0…1.
    var progress: Double?
    /// The tool's result, on `done`. Typed by `AnalysisResult.decode(_:tool:)`.
    var result: JSONValue?
    /// The saved run's id, on `done` — `nil` when the result was too large to keep.
    var runId: String?
    var error: String?
    var usage: AnalysisUsage?
}

/// What a run cost.
struct AnalysisUsage: Codable, Equatable, Sendable {
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var costUsd: Double?
}

struct AnalysisStartResponse: Decodable, Sendable {
    var success: Bool?
    var jobId: String?
    var error: String?
}

// MARK: - History

/// One saved run, without its result.
struct AnalysisRunSummary: Decodable, Equatable, Sendable, Identifiable {
    var id: String
    var tool: AnalysisJobTool
    var title: String
    /// ISO 8601; decoded by `WireDate`.
    var createdAt: String?
    var fileNames: [String]
    var reference: String
    var usage: AnalysisUsage?

    init(
        id: String, tool: AnalysisJobTool, title: String = "", createdAt: String? = nil,
        fileNames: [String] = [], reference: String = "", usage: AnalysisUsage? = nil
    ) {
        self.id = id
        self.tool = tool
        self.title = title
        self.createdAt = createdAt
        self.fileNames = fileNames
        self.reference = reference
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey { case id, tool, title, createdAt, fileNames, reference, usage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tool = try c.decode(AnalysisJobTool.self, forKey: .tool)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        fileNames = try c.decodeIfPresent([String].self, forKey: .fileNames) ?? []
        reference = try c.decodeIfPresent(String.self, forKey: .reference) ?? ""
        usage = try c.decodeIfPresent(AnalysisUsage.self, forKey: .usage)
    }

    var createdDate: Date? { WireDate.parse(createdAt) }

    /// The row's title — the web's `runTitle`.
    var displayTitle: String {
        if !title.isEmpty { return title }
        return fileNames.first.map(DisplayText.fileName) ?? "Untitled run"
    }

    /// "Plaint.pdf, Notice.pdf +3" — the web's `fileLine`.
    var fileLine: String {
        let names = fileNames.map(DisplayText.fileName)
        guard names.count > 2 else { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
    }
}

/// One saved run with its result.
struct AnalysisRun: Decodable, Equatable, Sendable {
    var summary: AnalysisRunSummary
    var result: JSONValue

    init(summary: AnalysisRunSummary, result: JSONValue) {
        self.summary = summary
        self.result = result
    }

    enum CodingKeys: String, CodingKey { case result }

    init(from decoder: Decoder) throws {
        summary = try AnalysisRunSummary(from: decoder)
        result = try decoder.container(keyedBy: CodingKeys.self).decode(JSONValue.self, forKey: .result)
    }
}

struct AnalysisHistoryResponse: Decodable, Sendable {
    var success: Bool?
    var runs: [AnalysisRunSummary]?
    var error: String?
}

struct AnalysisRunResponse: Decodable, Sendable {
    var success: Bool?
    var run: AnalysisRun?
    var error: String?
}

struct AnalysisDeleteResponse: Decodable, Sendable {
    var success: Bool?
    var error: String?
}

// MARK: - Results

/// A finished run's result, typed by its tool.
///
/// The server validates and repairs the model's answer before it is sent
/// (`lib/analysis/schemas.js`), so these decoders accept what that repair guarantees and nothing
/// looser: a field it always fills is required, and a field it may leave out is optional. A
/// result that does not fit is a contract break and fails as `.decoding`, rather than being
/// drawn half-filled.
enum AnalysisResult: Equatable, Sendable {
    case docIndex(DocIndexResult)
    case listOfDates(ListOfDatesResult)
    case devilsAdvocate(DevilsAdvocateResult)

    var tool: AnalysisJobTool {
        switch self {
        case .docIndex: return .docIndex
        case .listOfDates: return .listOfDates
        case .devilsAdvocate: return .devilsAdvocate
        }
    }

    static func decode(_ value: JSONValue, tool: AnalysisJobTool) throws -> AnalysisResult {
        do {
            let data = try JSONEncoder().encode(value)
            let decoder = JSONDecoder()
            switch tool {
            case .docIndex: return .docIndex(try decoder.decode(DocIndexResult.self, from: data))
            case .listOfDates: return .listOfDates(try decoder.decode(ListOfDatesResult.self, from: data))
            case .devilsAdvocate: return .devilsAdvocate(try decoder.decode(DevilsAdvocateResult.self, from: data))
            }
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// The whole result as plain text, for copying or sharing.
    var plainText: String {
        switch self {
        case .docIndex(let r): return r.plainText
        case .listOfDates(let r): return r.plainText
        case .devilsAdvocate(let r): return r.plainText
        }
    }
}

/// `**bold**` in a model's text, split for drawing. A stray `**` is dropped, not shown.
struct RichRun: Equatable, Sendable {
    var text: String
    var bold: Bool

    /// The web's `parseRich`: alternate plain and bold runs around each `**…**` pair.
    static func runs(_ text: String) -> [RichRun] {
        var out: [RichRun] = []
        var rest = Substring(text)
        while let open = rest.range(of: "**") {
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "**"), close.lowerBound > after.startIndex else {
                // No partner (or an empty pair): the marker is dropped and the rest is plain.
                let plain = String(rest[..<open.lowerBound]) + String(after)
                appendPlain(plain.replacingOccurrences(of: "**", with: ""), to: &out)
                return out
            }
            appendPlain(String(rest[..<open.lowerBound]), to: &out)
            out.append(RichRun(text: String(after[..<close.lowerBound]), bold: true))
            rest = after[close.upperBound...]
        }
        appendPlain(String(rest), to: &out)
        return out
    }

    private static func appendPlain(_ text: String, to out: inout [RichRun]) {
        guard !text.isEmpty else { return }
        out.append(RichRun(text: text, bold: false))
    }

    /// The text with every `**` removed.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
    }
}
