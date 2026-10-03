import Foundation

/// The reasoning panel as it is stored on an answer, in the web client's own shapes.
///
/// ## Where the shapes come from
///
/// The web finishes every chat turn by building the message it persists as
/// `{ role, content, reasoning, workflowTasks, workLog }` (`src/lib/streamManager.js`, the end of
/// `startStream`) and redraws its panel from those three fields when the conversation is reopened
/// (`src/tools/ToolWorkspace.jsx`, the `ReasoningChain` under each stored answer). The server
/// stores message JSON verbatim, so they come back from `GET /messages` untouched. Reading them is
/// how a reopened conversation keeps its work log; writing them is how an answer asked on this
/// phone keeps its log on the phone and on the web.
///
/// - `reasoning`: `{ points: [{ text, done: true }], seconds }` — the reasoner's `finish()`
///   (`src/tools/reasoning.js`): one point per `<think>` sentence, whitespace collapsed.
/// - `workflowTasks`: `completePlanTasks(planTasks)` — the `<plan>` tasks *as the model wrote
///   them*, every key kept, each given a `status`, and each subtask likewise.
/// - `workLog`: `finalizeLog()` — `{ kind: "note", text }` and
///   `{ kind: "group", status, steps: [{ label, status }] }`, the stream offsets dropped.
///
/// `Tests/EmperorCoreTests/WorkLogGolden.swift` pins both directions against those functions run
/// under Node (`scripts/generate-worklog-fixtures.mjs`).
enum WorkLogWire {
    /// The message keys the panel lives under, in the order the web writes them.
    static let keys = ["reasoning", "workflowTasks", "workLog"]

    // MARK: - Status vocabulary

    /// The web's spelling. Only `in-progress` differs from the case name, and getting it wrong
    /// would make every running row read as unknown on the other client.
    static func wireName(_ status: WorkStatus) -> String {
        switch status {
        case .pending: return "pending"
        case .inProgress: return "in-progress"
        case .completed: return "completed"
        case .superseded: return "superseded"
        case .stopped: return "stopped"
        }
    }

    private static func parse(_ value: JSONValue?) -> WorkStatus? {
        switch value?.stringValue {
        case "pending": return .pending
        case "in-progress": return .inProgress
        case "completed": return .completed
        case "superseded": return .superseded
        case "stopped": return .stopped
        default: return nil
        }
    }

    // MARK: - Writing

    /// The three fields for a finished turn, exactly as the web would have stored them.
    ///
    /// - Parameters:
    ///   - ended: how the stream ended. Anything still running is settled first, the way
    ///     `finalizeLog` does, so a stored log can never carry a spinner that will never stop.
    ///   - seconds: wall-clock length of the turn, which the web shows as "Worked · 4 steps · 00:47".
    static func fields(
        for snapshot: ReasoningSnapshot, seconds: Int, ended: WorkStatus
    ) -> [String: JSONValue] {
        let finished = snapshot.settled(ended: ended)
        let points: [JSONValue] = finished.reasoning.compactMap { sentence in
            let text = collapsingWhitespace(sentence)
            guard !text.isEmpty else { return nil }
            return .object(["text": .string(text), "done": .bool(true)])
        }
        return [
            "reasoning": .object([
                "points": .array(points),
                "seconds": .number(Double(max(0, seconds))),
            ]),
            "workflowTasks": .array(finished.plan.map { encode($0, isTask: true) }),
            "workLog": .array(finished.workLog.map(encode)),
        ]
    }

    /// A plan row as the model wrote it, plus its status — `completePlanTasks`, which spreads the
    /// task (`{ ...t, status, subtasks }`) rather than rebuilding it, so a `tools` list or a
    /// `description` survives. A row with no source (built here rather than parsed) falls back to
    /// the one key the web reads from it.
    private static func encode(_ row: PlanRow, isTask: Bool) -> JSONValue {
        var object = row.source
        if object.isEmpty { object[isTask ? "title" : "label"] = .string(row.title) }
        object["status"] = .string(wireName(row.status))
        if isTask {
            object["subtasks"] = .array(row.subtasks.map { encode($0, isTask: false) })
        }
        return .object(object)
    }

    private static func encode(_ entry: WorkLogEntry) -> JSONValue {
        switch entry {
        case .note(_, let text, _):
            return .object(["kind": .string("note"), "text": .string(text)])
        case .group(let group):
            return .object([
                "kind": .string("group"),
                // Re-derived, as `finalizeLog` derives it, rather than trusting the live value.
                "status": .string(wireName(WorkGroup.rollUp(group.steps))),
                "steps": .array(group.steps.map { step in
                    .object(["label": .string(step.label), "status": .string(wireName(step.status))])
                }),
            ])
        }
    }

    // MARK: - Reading

    /// The panel a stored answer carries, or nil when it carries none worth drawing.
    ///
    /// Every field is optional and read on its own: a malformed `workLog` must not cost the plan,
    /// and nothing here can fail the message — the transcript is what matters, the panel is a
    /// courtesy. An entry that cannot be read is skipped rather than guessed at.
    ///
    /// A stored log describes a run that is over, so nothing in it may still look as if it is
    /// running. A step the web never settled, or whose status this build does not know, reads as
    /// stopped — never with the tick, which the platform keeps for work that delivered.
    static func snapshot(from fields: [String: JSONValue]) -> ReasoningSnapshot? {
        var snapshot = ReasoningSnapshot()

        if case .array(let points)? = fields["reasoning"]?["points"] {
            snapshot.reasoning = points.compactMap { point in
                let text = (point["text"] ?? point).stringValue
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                return text?.isEmpty == false ? text : nil
            }
        }

        if case .array(let tasks)? = fields["workflowTasks"] {
            snapshot.plan = tasks.compactMap { task -> PlanRow? in
                guard case .object(let object) = task else { return nil }
                var subtasks: [PlanRow] = []
                if case .array(let raw)? = object["subtasks"] {
                    subtasks = raw.compactMap { sub -> PlanRow? in
                        guard case .object(let subObject) = sub,
                              let label = subObject["label"]?.stringValue
                        else { return nil }
                        return PlanRow(
                            title: label, status: storedPlanStatus(subObject["status"]),
                            subtasks: [], source: subObject)
                    }
                }
                return PlanRow(
                    title: object["title"]?.stringValue ?? "",
                    status: storedPlanStatus(object["status"]),
                    subtasks: subtasks, source: object)
            }
        }

        if case .array(let entries)? = fields["workLog"] {
            snapshot.workLog = entries.compactMap { entry -> WorkLogEntry? in
                switch entry["kind"]?.stringValue {
                case "note":
                    guard let text = entry["text"]?.stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                    else { return nil }
                    return .note(text: text, at: 0)
                case "group":
                    guard case .array(let rawSteps)? = entry["steps"] else { return nil }
                    let steps = rawSteps.compactMap { step -> WorkStep? in
                        guard let label = step["label"]?.stringValue else { return nil }
                        return WorkStep(label: label, status: storedStepStatus(step["status"]), at: 0)
                    }
                    // An empty round has nothing to show; the panel lists steps, not rounds.
                    guard !steps.isEmpty else { return nil }
                    let status = parse(entry["status"]).flatMap { $0 == .inProgress ? nil : $0 }
                    return .group(WorkGroup(status: status ?? WorkGroup.rollUp(steps), steps: steps))
                default:
                    return nil
                }
            }
        }

        return snapshot.isEmpty ? nil : snapshot
    }

    private static func storedStepStatus(_ value: JSONValue?) -> WorkStatus {
        switch parse(value) {
        case .completed: return .completed
        case .superseded: return .superseded
        default: return .stopped
        }
    }

    /// Plan rows also know `pending` — a row the run never reached — which the web draws as an
    /// empty dot. Only a row caught mid-way is settled, as a step is.
    private static func storedPlanStatus(_ value: JSONValue?) -> WorkStatus {
        switch parse(value) {
        case .inProgress: return .stopped
        case let status?: return status
        case nil: return .pending
        }
    }

    // MARK: - Reasoning sentences

    /// JavaScript's `\s`, spelled out: ICU's `\s` leaves out U+000B and U+FEFF, which the web's
    /// `replace(/\s+/g, ' ')` and `trim()` both remove.
    private static let jsWhitespace =
        "[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]"
    private static let whitespaceRun = try! NSRegularExpression(pattern: jsWhitespace + "+")
    private static let edges = try! NSRegularExpression(
        pattern: "^" + jsWhitespace + "+|" + jsWhitespace + "+$")

    /// `text.replace(/\s+/g, ' ').trim()`.
    static func collapsingWhitespace(_ text: String) -> String {
        let collapsed = whitespaceRun.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: " ")
        return edges.stringByReplacingMatches(
            in: collapsed, range: NSRange(location: 0, length: (collapsed as NSString).length),
            withTemplate: "")
    }

    private static let closedThink = try! NSRegularExpression(
        pattern: "<think>([\\s\\S]*?)</think>")
    private static let trailingThink = try! NSRegularExpression(pattern: "<think>([\\s\\S]*)$")

    /// The reasoner's points: every `<think>` sentence, plus one still open at the very end.
    ///
    /// A port of `extractPoints` (`src/tools/reasoning.js`). Only `<think>`, because that is the
    /// one wrapper the provider writes reasoning under; the wider set `StreamContent` hides from
    /// the answer belongs to model output and is never part of the web's record.
    static func reasoningPoints(in raw: String) -> [String] {
        let ns = raw as NSString
        var points: [String] = []
        var lastIndex = 0
        for match in closedThink.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let text = collapsingWhitespace(ns.substring(with: match.range(at: 1)))
            if !text.isEmpty { points.append(text) }
            lastIndex = match.range.location + match.range.length
        }
        let rest = ns.substring(from: lastIndex)
        let restNS = rest as NSString
        if let open = trailingThink.firstMatch(
            in: rest, range: NSRange(location: 0, length: restNS.length)) {
            let text = collapsingWhitespace(restNS.substring(with: open.range(at: 1)))
            if !text.isEmpty { points.append(text) }
        }
        return points
    }

    // MARK: - The plan block

    private static let planBlock = try! NSRegularExpression(pattern: "<plan>([\\s\\S]*?)</plan>")

    /// The first `<plan>` block's tasks, every key the model wrote kept.
    ///
    /// A port of `parsePlanTasks` (`src/lib/streamManager.js`): the first block only, its JSON an
    /// object whose `tasks` is a non-empty array; each task copied, its `subtasks` copied or, when
    /// absent, an empty list. A `subtasks` that is present but not a list is a plan the web
    /// rejects outright (its `.map` throws), so it is rejected here too. Returns nil for no plan.
    static func planTasks(in raw: String) -> [[String: JSONValue]]? {
        let ns = raw as NSString
        guard let match = planBlock.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
              let parsed = JSONValue.decode(from: ns.substring(with: match.range(at: 1))),
              case .array(let tasks)? = parsed["tasks"], !tasks.isEmpty
        else { return nil }

        var result: [[String: JSONValue]] = []
        for task in tasks {
            // Spreading anything but an object yields no keys. (A string would spread its
            // characters; the model has never been seen to write one, and it would render as
            // an untitled task either way.)
            var object: [String: JSONValue] = [:]
            if case .object(let fields) = task { object = fields }
            switch object["subtasks"] {
            case .array(let subtasks):
                object["subtasks"] = .array(subtasks.map { sub in
                    if case .object = sub { return sub }
                    return .object([:])
                })
            case nil, .null?, .bool(false)?, .number(0)?, .string("")?:
                object["subtasks"] = .array([])
            default:
                return nil
            }
            result.append(object)
        }
        return result
    }
}
