import Foundation

enum WorkStatus: String, Equatable, Sendable {
    case pending
    case inProgress
    case completed
    /// The round that fired this work was rolled back. Its results were thrown away and the
    /// model redid the work — so it must never wear the same tick as a call that delivered.
    case superseded
    /// The stream ended without confirming this call came back.
    case stopped
}

/// One tool call the model chose to make.
struct WorkStep: Equatable, Identifiable, Sendable {
    let id = UUID()
    /// The server's own label, kept **raw** — "Reading pages 55–73 of Evidence_Vol_2.pdf".
    /// Generalising it to "Reading your files…" is right for a one-line status and wrong here:
    /// the document name, page range and query are exactly what makes a log worth reading.
    var label: String
    var status: WorkStatus
    /// UTF-16 offset in the raw stream where this call was announced, so a later rollback can
    /// tell which steps belonged to the discarded round.
    var at: Int

    static func == (a: WorkStep, b: WorkStep) -> Bool {
        a.label == b.label && a.status == b.status && a.at == b.at
    }
}

/// A batch of tool calls issued together, before any of their results came back.
struct WorkGroup: Equatable, Identifiable, Sendable {
    let id = UUID()
    var status: WorkStatus
    var steps: [WorkStep]

    static func == (a: WorkGroup, b: WorkGroup) -> Bool {
        a.status == b.status && a.steps == b.steps
    }
}

enum WorkLogEntry: Equatable, Identifiable, Sendable {
    /// Narration the model wrote between two rounds of work.
    case note(id: UUID = UUID(), text: String, at: Int)
    case group(WorkGroup)

    var id: UUID {
        switch self {
        case .note(let id, _, _): return id
        case .group(let group): return group.id
        }
    }
}

/// A plan row with progress attached.
struct PlanRow: Equatable, Identifiable, Sendable {
    let id = UUID()
    var title: String
    var status: WorkStatus
    var subtasks: [PlanRow]

    static func == (a: PlanRow, b: PlanRow) -> Bool {
        a.title == b.title && a.status == b.status && a.subtasks == b.subtasks
    }
}

/// Builds the reasoning panel's state from the chat stream.
///
/// A faithful port of `src/lib/streamManager.js` in the platform, because the design there
/// solves problems that are not obvious from the outside:
///
/// - The model emits `<plan>` as **one JSON blob**, so every row arrives in the same instant.
///   Without a cursor the panel would snap from empty straight to a finished list. The cursor
///   advances only on real signals — a `<status>` meaning a genuine tool call finished, or the
///   answer starting to stream — never on a timer.
/// - The server writes every tool call of a round back-to-back **before** that round's results
///   return, so a run of statuses with no prose between them *is* one agentic round. That
///   natural batching is what becomes a group.
/// - Ambient pipeline chatter ("Preparing…", "Thinking…", Pre-RAG's "Reading: a.pdf, b.pdf")
///   is useful as a live status line but is not work the model chose to do. Counting it once
///   padded a run of 8 tool calls into "14 steps".
final class ReasoningTracker {
    private(set) var plan: [PlanRow] = []
    private(set) var workLog: [WorkLogEntry] = []
    /// Sentence-by-sentence deliberation, in arrival order.
    private(set) var reasoning: [String] = []

    private var rawPlan: StreamPlan?
    private var planCursor = 0
    private var openGroupIndex: Int?
    /// Raw-stream offset where the current narration window starts.
    private var noteFrom = 0
    private var rawLength = 0
    private var latestRaw = ""

    /// The ~20s keep-alive. Never a real step, and must never advance the plan cursor.
    /// Note the server's own text ends in U+2026, not three dots.
    private static let heartbeat = try! NSRegularExpression(
        pattern: "^\\s*still working", options: [.caseInsensitive])

    /// The four shapes the provider actually emits per tool call. The colon is what separates
    /// a real step ("Reading pages 55-73 of X") from Pre-RAG's ambient "Reading: x.pdf, y.pdf".
    /// Template loading is deliberately absent — it is internal scaffolding.
    private static let stepShape = try! NSRegularExpression(
        pattern: "^(?:Reading (?:page|pages) \\d|Mapping the structure of |Searching the record(?: for:)?)",
        options: [.caseInsensitive])

    /// Visible characters of prose that count as "the model started talking again".
    private static let noteMinimum = 8
    private static let noteMaximum = 240

    // MARK: - Consumption

    func consume(_ event: ChatStreamEvent) {
        switch event {
        case .status(let label):
            if logStep(label) {
                // A real tool call finished, so the plan has genuinely moved on.
                advancePlan(to: planCursor + 1)
            }
        case .content(let raw):
            latestRaw = raw
            rawLength = (raw as NSString).length
            parsePlanIfNeeded(raw)
            advanceIfAnswerStarted(raw)
            closeGroupIfNarrating()
        case .rolledBack(let offset):
            supersede(from: offset)
        case .busy, .usage:
            break
        }
    }

    /// Settles anything still in flight once the stream is over.
    ///
    /// On a clean finish, work left running did come back — the model went on to write the
    /// answer. On a stop or a hard failure we genuinely do not know, so those steps are
    /// reported as unfinished rather than ticked off.
    func finish(ended: WorkStatus = .completed) {
        for index in workLog.indices {
            guard case .group(var group) = workLog[index] else { continue }
            group.steps = group.steps.map { step in
                var step = step
                if step.status == .inProgress { step.status = ended }
                return step
            }
            group.status = rollUp(group.steps)
            workLog[index] = .group(group)
        }
        openGroupIndex = nil

        if ended == .completed, rawPlan != nil {
            plan = completeAll(plan)
        }
        reasoning = StreamContent.parse(latestRaw).reasoning
    }

    // MARK: - Plan

    private func parsePlanIfNeeded(_ raw: String) {
        guard rawPlan == nil, raw.contains("</plan>") else { return }
        let parsed = StreamContent.parse(raw)
        guard let plan = parsed.plan, !plan.tasks.isEmpty else { return }
        rawPlan = plan
        planCursor = 0
        rebuildPlan()
    }

    /// Once the actual answer is being written, any reading or research steps are genuinely
    /// behind us — otherwise the panel sits stuck on step one while prose streams past.
    private func advanceIfAnswerStarted(_ raw: String) {
        guard rawPlan != nil, let end = raw.range(of: "</plan>") else { return }
        let after = StreamContent.parse(String(raw[end.upperBound...])).prose
        if after.count > 40 {
            advancePlan(to: max(totalSubtasks - 1, 0))
        }
    }

    private var totalSubtasks: Int {
        (rawPlan?.tasks ?? []).reduce(0) { $0 + ($1.subtasks?.count ?? 0) }
    }

    /// The cursor only ever moves forward, and never past the last row.
    private func advancePlan(to target: Int) {
        guard rawPlan != nil else { return }
        let last = max(0, totalSubtasks - 1)
        let next = max(planCursor, min(target, last))
        guard next != planCursor else { return }
        planCursor = next
        rebuildPlan()
    }

    /// Derives every row's status from the single flat cursor: before it is done, at it is
    /// running, after it is pending. A task rolls up from its own subtasks.
    private func rebuildPlan() {
        guard let rawPlan else { return }
        var index = 0
        plan = rawPlan.tasks.map { task in
            let subtasks = (task.subtasks ?? []).map { sub -> PlanRow in
                let status: WorkStatus =
                    index < planCursor ? .completed : (index == planCursor ? .inProgress : .pending)
                index += 1
                return PlanRow(title: sub.label, status: status, subtasks: [])
            }
            let status: WorkStatus
            if subtasks.isEmpty {
                status = .pending
            } else if subtasks.allSatisfy({ $0.status == .completed }) {
                status = .completed
            } else if subtasks.contains(where: { $0.status != .pending }) {
                status = .inProgress
            } else {
                status = .pending
            }
            return PlanRow(title: task.title, status: status, subtasks: subtasks)
        }
    }

    private func completeAll(_ rows: [PlanRow]) -> [PlanRow] {
        rows.map { row in
            PlanRow(title: row.title, status: .completed, subtasks: completeAll(row.subtasks))
        }
    }

    // MARK: - Work log

    /// - Returns: true when this status was a genuine tool call.
    @discardableResult
    private func logStep(_ raw: String) -> Bool {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !matches(Self.heartbeat, label), matches(Self.stepShape, label)
        else { return false }

        let gap = proseSince(noteFrom)
        if openGroupIndex == nil || gap.count >= Self.noteMinimum {
            closeOpenGroup()
            if gap.count >= Self.noteMinimum {
                workLog.append(.note(text: Self.summarise(gap), at: rawLength))
            }
            workLog.append(.group(WorkGroup(status: .inProgress, steps: [])))
            openGroupIndex = workLog.count - 1
            noteFrom = rawLength
        }

        guard let index = openGroupIndex, case .group(var group) = workLog[index] else {
            return false
        }
        group.steps.append(WorkStep(label: label, status: .inProgress, at: rawLength))
        workLog[index] = .group(group)
        return true
    }

    /// The model talking again means the round's results are back.
    private func closeGroupIfNarrating() {
        guard openGroupIndex != nil,
              proseSince(noteFrom).count >= Self.noteMinimum else { return }
        closeOpenGroup()
    }

    private func closeOpenGroup() {
        guard let index = openGroupIndex, case .group(var group) = workLog[index] else {
            openGroupIndex = nil
            return
        }
        group.steps = group.steps.map { step in
            var step = step
            if step.status == .inProgress { step.status = .completed }
            return step
        }
        group.status = rollUp(group.steps)
        workLog[index] = .group(group)
        openGroupIndex = nil
    }

    private func rollUp(_ steps: [WorkStep]) -> WorkStatus {
        if !steps.isEmpty, steps.allSatisfy({ $0.status == .superseded }) { return .superseded }
        if steps.contains(where: { $0.status == .stopped }) { return .stopped }
        return .completed
    }

    /// Applies a server-issued rollback.
    ///
    /// The discarded round really did fire those tool calls — their results were just thrown
    /// away. Mark them rather than delete them, so a reader can see a stretch of work was
    /// superseded. Narration written after the rollback point *is* dropped, because that prose
    /// no longer exists in the stream and the retry writes its own.
    private func supersede(from offset: Int) {
        for index in workLog.indices {
            guard case .group(var group) = workLog[index] else { continue }
            group.steps = group.steps.map { step in
                var step = step
                if step.at >= offset, step.status != .superseded { step.status = .superseded }
                return step
            }
            if !group.steps.isEmpty, group.steps.allSatisfy({ $0.status == .superseded }) {
                group.status = .superseded
            }
            workLog[index] = .group(group)
        }

        workLog.removeAll { entry in
            if case .note(_, _, let at) = entry { return at >= offset }
            return false
        }

        // A round with nothing left standing is finished as far as the log goes; the retry's
        // first tool call opens a fresh group rather than appending to the discarded one.
        if let index = openGroupIndex {
            let stillOpen = workLog.indices.contains(index)
            if !stillOpen {
                openGroupIndex = nil
            } else if case .group(let group) = workLog[index],
                      !group.steps.isEmpty,
                      group.steps.allSatisfy({ $0.status == .superseded }) {
                openGroupIndex = nil
            }
        }
        if noteFrom > offset { noteFrom = offset }
    }

    /// Prose the model has written since the current group opened — i.e. what a reader would
    /// actually see, with every control tag removed.
    private func proseSince(_ from: Int) -> String {
        let ns = latestRaw as NSString
        guard from < ns.length else { return "" }
        let slice = ns.substring(from: max(0, from))
        return StreamContent.parse(slice).prose
    }

    private func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(
            in: text, options: [],
            range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Narration between rounds can run to a paragraph, but the part that reads as a lead-in to
    /// the next batch of work is at its **end** ("Now let me read the remaining files"). Keep
    /// the tail, trimmed to a sentence boundary when one is close by.
    static func summarise(_ text: String) -> String {
        let clean = text
            .replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > noteMaximum else { return clean }

        let tail = String(clean.suffix(noteMaximum))
        let ns = tail as NSString
        let boundary = try! NSRegularExpression(pattern: "[.!?]\\s+[A-Z(]", options: [])
        if let match = boundary.firstMatch(
            in: tail, options: [], range: NSRange(location: 0, length: ns.length)) {
            let cut = match.range.location + match.range.length - 1
            if cut > 0, cut < 90 { return ns.substring(from: cut) }
        }
        return "…" + tail
    }
}
