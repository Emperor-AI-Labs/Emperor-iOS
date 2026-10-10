import Foundation

/// What the reading card says, in plain words.
///
/// The server's step labels are kept raw in the work log (`WorkStep.label`) because they are the
/// record of what ran: "Reading pages 55–73 of Evidence_Vol_2.pdf", "Searching the record for:
/// part payments received". The Record design says what is happening the way a person would —
/// "Reading Evidence Vol 2.pdf", "Searching your documents" — and never shows a page range, a
/// tool's name or the query the model searched with. This is that translation, and the card's
/// title and one-line summary built from it.
///
/// The web keeps its own mapping in `src/lib/stepLabels.js`, which is not available to this
/// client; the rules here follow the design's examples and the four step shapes the provider
/// emits (`ReasoningTracker.stepShape`). Anything else is shown as it came, minus a trailing
/// ellipsis, rather than guessed at.
enum StepLabels {

    /// What a step was doing.
    enum Kind: Equatable, Sendable {
        /// Reading, or mapping the structure of, one document.
        case read(document: String)
        case searchDocuments
        case searchWeb
        case verify
        case causeList
        case other(String)
    }

    /// One line of the reading card.
    struct Step: Equatable, Sendable {
        let text: String
        let status: WorkStatus
    }

    static func kind(of raw: String) -> Kind {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = label.lowercased()

        if let document = capture(readingPages, in: label) ?? capture(mapping, in: label)
            ?? capture(readingList, in: label) {
            return .read(document: displayName(document))
        }
        if lower.hasPrefix("searching the record") || lower.hasPrefix("searching your") {
            return .searchDocuments
        }
        if lower.hasPrefix("searching the web") || lower.hasPrefix("searching online") {
            return .searchWeb
        }
        if lower.hasPrefix("checking quotation") || lower.hasPrefix("verifying") {
            return .verify
        }
        if lower.hasPrefix("checking the cause list") {
            return .causeList
        }
        return .other(trimmedEllipsis(label))
    }

    /// The step in plain words — "Reading AWARD.pdf", "Searching your documents".
    static func friendly(_ raw: String) -> String {
        switch kind(of: raw) {
        case .read(let document): return "Reading \(document)"
        case .searchDocuments: return "Searching your documents"
        case .searchWeb: return "Searching the web"
        case .verify: return "Checking quotations against the source"
        case .causeList: return "Checking the cause list"
        case .other(let text):
            let lower = text.lowercased()
            if lower.hasSuffix("is thinking") || lower == "thinking" { return "Thinking" }
            return text
        }
    }

    /// The card's lines: every step in the work log, in order, in plain words. A step that says
    /// the same as the one before it — page 1–5 of a file, then 6–9 of it — is one line.
    static func steps(_ snapshot: ReasoningSnapshot) -> [Step] {
        var steps: [Step] = []
        for entry in snapshot.workLog {
            guard case .group(let group) = entry else { continue }
            for step in group.steps where step.status != .superseded {
                let text = friendly(step.label)
                if let last = steps.last, last.text == text {
                    steps[steps.count - 1] = Step(text: text, status: step.status)
                } else {
                    steps.append(Step(text: text, status: step.status))
                }
            }
        }
        return steps
    }

    /// The documents read, each once, first read first.
    static func documents(_ snapshot: ReasoningSnapshot) -> [String] {
        var seen: [String] = []
        for entry in snapshot.workLog {
            guard case .group(let group) = entry else { continue }
            for step in group.steps where step.status != .superseded {
                if case .read(let document) = kind(of: step.label), !seen.contains(document) {
                    seen.append(document)
                }
            }
        }
        return seen
    }

    /// The card's heading while the answer is being prepared.
    static func runningTitle(_ snapshot: ReasoningSnapshot) -> String {
        let count = documents(snapshot).count
        guard count > 0 else { return "Looking through your record…" }
        return count == 1 ? "Reading 1 document…" : "Reading \(count) documents…"
    }

    /// The card's heading once the answer is in: what was done, in one line.
    /// "Read 2 documents · searched your files · checked quotations".
    static func summary(_ snapshot: ReasoningSnapshot) -> String {
        let kinds = snapshot.workLog.flatMap { entry -> [Kind] in
            guard case .group(let group) = entry else { return [] }
            return group.steps.filter { $0.status != .superseded }.map { kind(of: $0.label) }
        }
        var parts: [String] = []
        let count = documents(snapshot).count
        if count > 0 { parts.append(count == 1 ? "Read 1 document" : "Read \(count) documents") }
        func add(_ phrase: String, when present: Bool) {
            guard present else { return }
            parts.append(parts.isEmpty ? phrase.prefix(1).uppercased() + phrase.dropFirst() : phrase)
        }
        add("searched your files", when: kinds.contains(.searchDocuments))
        add("searched the web", when: kinds.contains(.searchWeb))
        add("checked quotations", when: kinds.contains(.verify))
        add("checked the cause list", when: kinds.contains(.causeList))
        if parts.isEmpty {
            let steps = Self.steps(snapshot).count
            if steps == 0 { return "Answered directly" }
            return steps == 1 ? "Worked through 1 step" : "Worked through \(steps) steps"
        }
        return parts.joined(separator: " · ")
    }

    /// A document's name as people say it: underscores read as spaces. The extension stays — it is
    /// how a reader tells the scan from the Word copy.
    static func displayName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Patterns

    /// "Reading pages 55–73 of Evidence_Vol_2.pdf", "Reading page 4 of X".
    nonisolated(unsafe) private static let readingPages = try! NSRegularExpression(
        pattern: "^Reading pages? [0-9][^ ]* (?:of|from) (.+)$", options: [.caseInsensitive])
    /// "Mapping the structure of Order.pdf".
    nonisolated(unsafe) private static let mapping = try! NSRegularExpression(
        pattern: "^Mapping the structure of (.+)$", options: [.caseInsensitive])
    /// The ambient "Reading: a.pdf" — one document only; a list is not one step.
    nonisolated(unsafe) private static let readingList = try! NSRegularExpression(
        pattern: "^Reading:? ([^,]+?\\.[A-Za-z0-9]{2,5})$", options: [.caseInsensitive])

    private static func capture(_ pattern: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text)
        else { return nil }
        let value = trimmedEllipsis(String(text[captured]))
        return value.isEmpty ? nil : value
    }

    private static func trimmedEllipsis(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(".") || result.hasSuffix("…") {
            // "Thinking..." and "Thinking…" — but never the dot of a file's extension, which is
            // followed by letters, not by the end of the line.
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
