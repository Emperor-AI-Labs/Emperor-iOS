import XCTest
@testable import EmperorCore

/// The fixture `scripts/generate-worklog-fixtures.mjs` writes: recorded `/chat` responses run
/// through the web's own `startStream`, and what the web stored for each.
struct WorkLogFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let about: String
        let ended: String
        /// The reads the client received, in order — bytes exactly as `/chat` wrote them.
        let chunks: [String]
        /// `fullContent`, trimmed: what `finalizeChatRun` stores as the answer.
        let serverContent: String
        /// `reasoning`, `workflowTasks` and `workLog` as the web persisted them.
        let stored: [String: JSONValue]

        var endedStatus: WorkStatus { ended == "completed" ? .completed : .stopped }
        var seconds: Int { stored["reasoning"]?["seconds"]?.intValue ?? 0 }
    }

    let cases: [Case]
    /// A `GET /messages` response, exactly as the route serialises it.
    let messagesBody: String
    let appTurnCase: String
    let appQuestionID: String

    static let shared: WorkLogFixture = {
        do {
            return try JSONDecoder().decode(WorkLogFixture.self, from: Data(WorkLogGolden.json.utf8))
        } catch {
            fatalError("WorkLogGolden.json does not decode: \(error)")
        }
    }()

    static func named(_ name: String) -> Case {
        guard let found = shared.cases.first(where: { $0.name == name }) else {
            fatalError("no fixture case \(name)")
        }
        return found
    }

    /// The case replayed through this client's parser and tracker, exactly as `ChatService` drives
    /// them, and settled the way the stream ended.
    static func replay(_ fixture: Case) -> ReasoningSnapshot {
        let parser = ChatStreamParser()
        let tracker = ReasoningTracker()
        for chunk in fixture.chunks {
            for event in parser.consume(text: chunk) { tracker.consume(event) }
        }
        for event in parser.finish() { tracker.consume(event) }
        tracker.finish(ended: fixture.endedStatus)
        return ReasoningSnapshot(plan: tracker.plan, workLog: tracker.workLog, reasoning: tracker.reasoning)
    }
}

/// What the panel shows, without identities or stream offsets — the two sides are compared on
/// this, because a stored log has neither.
struct PanelShape: Equatable, CustomStringConvertible {
    var plan: [String]
    var log: [String]
    var reasoning: [String]

    init(_ snapshot: ReasoningSnapshot) {
        plan = snapshot.plan.flatMap { task in
            ["\(task.title) [\(task.status)]"] + task.subtasks.map { "  \($0.title) [\($0.status)]" }
        }
        log = snapshot.workLog.flatMap { entry -> [String] in
            switch entry {
            case .note(_, let text, _):
                return ["note: \(text)"]
            case .group(let group):
                return ["round [\(group.status)]"] + group.steps.map { "  \($0.label) [\($0.status)]" }
            }
        }
        reasoning = snapshot.reasoning
    }

    var description: String { (plan + log + reasoning).joined(separator: "\n") }
}

/// Pins the stored panel to the web's real output, in both directions: what the web stored is
/// read back as exactly the panel this client draws for the same stream, and what this client
/// stores for a stream is exactly what the web stored for it.
final class WorkLogGoldenTests: XCTestCase {

    private var completedCases: [WorkLogFixture.Case] {
        WorkLogFixture.shared.cases.filter { $0.ended == "completed" }
    }

    func testTheFixtureCoversWhatItClaimsTo() {
        let names = WorkLogFixture.shared.cases.map(\.name)
        XCTAssertEqual(names, ["research", "rollback", "plan-only", "direct", "stopped"])
        let rollback = WorkLogFixture.named("rollback")
        XCTAssertTrue(rollback.chunks.contains { $0.hasPrefix("<truncate:") },
                      "the rollback case must actually roll back")
        let research = WorkLogFixture.named("research")
        XCTAssertTrue(research.chunks.contains { $0.hasSuffix("</sta") },
                      "a status must straddle two reads")
    }

    // MARK: - Web → phone

    /// Reading what the web stored gives the panel this client would have drawn itself.
    func testStoredLogsReadBackAsTheTrackersOwnPanel() throws {
        for fixture in completedCases {
            let live = WorkLogFixture.replay(fixture)
            guard let stored = WorkLogWire.snapshot(from: fixture.stored) else {
                XCTAssertTrue(live.isEmpty, "\(fixture.name): the web stored nothing worth drawing")
                continue
            }
            XCTAssertEqual(PanelShape(stored), PanelShape(live), fixture.name)
        }
    }

    func testTheResearchRunReadsBackInFull() throws {
        let stored = try XCTUnwrap(WorkLogWire.snapshot(from: WorkLogFixture.named("research").stored))
        XCTAssertEqual(stored.stepCount, 4)
        XCTAssertEqual(stored.plan.map(\.title), ["Read the record", "Test the notice"])
        XCTAssertEqual(stored.reasoning[1],
                       "I need the lease terms first, then the notice itself, and how it was served.",
                       "the reasoner collapses whitespace inside a sentence")
        guard case .note(_, let tail, _)? = stored.workLog.dropFirst(2).first else {
            return XCTFail("the second note is missing")
        }
        XCTAssertTrue(tail.hasSuffix("whether the arrears were ever tendered."),
                      "a long note keeps its tail — the lead-in to the next round")
    }

    /// The round written just before a rolled-back round begins is struck out, as the web strikes
    /// it out — and never wears the tick.
    func testSupersededStepsReadBackSuperseded() throws {
        let stored = try XCTUnwrap(WorkLogWire.snapshot(from: WorkLogFixture.named("rollback").stored))
        let rounds = stored.workLog.compactMap { entry -> WorkGroup? in
            if case .group(let group) = entry { return group } else { return nil }
        }
        XCTAssertEqual(rounds.map(\.status), [.completed, .superseded])
        XCTAssertEqual(rounds.last?.steps.map(\.status), [.superseded, .superseded])
    }

    /// A stopped run's calls read back stopped; the web's plan reads back as the web stored it.
    func testAStoppedRunReadsBackStopped() throws {
        let fixture = WorkLogFixture.named("stopped")
        let stored = try XCTUnwrap(WorkLogWire.snapshot(from: fixture.stored))
        let live = WorkLogFixture.replay(fixture)
        XCTAssertEqual(PanelShape(stored).log, PanelShape(live).log)
        XCTAssertEqual(PanelShape(stored).reasoning, PanelShape(live).reasoning)
        XCTAssertTrue(stored.workLog.allSatisfy { entry in
            if case .group(let group) = entry {
                return group.status == .stopped && group.steps.allSatisfy { $0.status == .stopped }
            }
            return true
        })
    }

    // MARK: - Phone → web

    /// What this client stores for a stream is exactly what the web stored for the same stream —
    /// every key, every status, the model's own plan fields, the reasoner's points and seconds.
    func testThisClientStoresWhatTheWebStores() {
        for fixture in completedCases {
            let fields = WorkLogWire.fields(
                for: WorkLogFixture.replay(fixture), seconds: fixture.seconds, ended: .completed)
            XCTAssertEqual(fields, fixture.stored, fixture.name)
        }
    }

    /// The one place the two deliberately differ. On a stop the web still runs
    /// `completePlanTasks`, ticking every plan row; this client keeps the rows the run never
    /// reached pending and stops the one it was on. Everything else matches.
    func testAStoppedRunDiffersOnlyInItsPlan() {
        let fixture = WorkLogFixture.named("stopped")
        let fields = WorkLogWire.fields(
            for: WorkLogFixture.replay(fixture), seconds: fixture.seconds, ended: .stopped)
        XCTAssertEqual(fields["workLog"], fixture.stored["workLog"])
        XCTAssertEqual(fields["reasoning"], fixture.stored["reasoning"])

        let statuses = { (value: JSONValue?) -> [String] in
            guard case .array(let tasks)? = value else { return [] }
            return tasks.flatMap { task -> [String] in
                guard case .array(let subtasks)? = task["subtasks"] else { return [] }
                return [task["status"]?.stringValue ?? "?"] + subtasks.map { $0["status"]?.stringValue ?? "?" }
            }
        }
        XCTAssertEqual(statuses(fixture.stored["workflowTasks"]), ["completed", "completed", "completed"])
        XCTAssertEqual(statuses(fields["workflowTasks"]), ["stopped", "completed", "stopped"])
    }

    /// Reading a stored log and writing it again changes nothing.
    func testAStoredLogSurvivesBeingReadAndWritten() throws {
        for fixture in completedCases {
            guard let snapshot = WorkLogWire.snapshot(from: fixture.stored) else { continue }
            let rewritten = WorkLogWire.fields(for: snapshot, seconds: fixture.seconds, ended: .completed)
            XCTAssertEqual(rewritten, fixture.stored, fixture.name)
        }
    }
}
