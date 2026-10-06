import Foundation
import XCTest
@testable import EmperorCore

/// A screen's task cancelled while its read is on the way — a tab switched away and back, or an
/// iPad's Cases tab coming forward as the Calendar replaces the case beside the docket — must not
/// cost the screen its answer.
///
/// Each read here is held at a gate until the asking task has been cancelled, and then answers as
/// `URLSession` does for a request whose task was cancelled: with a cancellation. A read the
/// screen could cancel therefore fails these tests; one that runs to its end passes.
final class UncancelledReadTests: XCTestCase {

    // MARK: - The read itself

    /// The caller is cancelled, the read finishes, and the caller gets its answer.
    func testACancelledCallerStillGetsTheAnswer() async throws {
        let gate = ReadGate()
        let caller = Task {
            try await uncancelledRead { () async throws -> String in
                try await gate.pass()
                return "answer"
            }
        }
        await gate.waitForArrival()
        caller.cancel()
        gate.open()
        let answer = try await caller.value
        XCTAssertEqual(answer, "answer")
    }

    /// The read's own failure still reaches the caller — only the caller's cancellation is kept
    /// away from it.
    func testTheReadsOwnFailureStillReachesTheCaller() async {
        do {
            _ = try await uncancelledRead { () async throws -> String in
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("a failed read must fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    // MARK: - A matter

    /// The case's screen is cancelled mid-read and the matter still shows — not "Could not load",
    /// and not a spinner left on `.idle` with nothing coming.
    func testAMatterWhoseScreenIsCancelledMidReadStillLoads() async {
        await onMain {
            let service = GatedCases()
            let model = CaseDetailViewModel(caseID: "case1", service: service)
            let screen = Task { await model.load() }
            await service.gate.waitForArrival()
            screen.cancel()
            service.gate.open()
            await screen.value

            XCTAssertEqual(model.state, .loaded, "the read was abandoned with the screen's task")
            XCTAssertEqual(model.legalCase?.id, "case1")
        }
    }

    /// The screen comes back while the first read is still out — sees it loading, asks nothing —
    /// and the first read's answer is what it shows. This is the order that left the matter on a
    /// spinner: the abandoned read went back to idle only after the screen had looked.
    func testAScreenThatComesBackMidReadGetsTheFirstReadsAnswer() async {
        await onMain {
            let service = GatedCases()
            let model = CaseDetailViewModel(caseID: "case1", service: service)
            let first = Task { await model.load() }
            await service.gate.waitForArrival()
            first.cancel()

            // What `CaseDetailView`'s task does on the screen's next appearance.
            XCTAssertEqual(model.state, .loading)
            if model.state == .idle { await model.load() }

            service.gate.open()
            await first.value
            XCTAssertEqual(model.state, .loaded)
            XCTAssertNotNil(model.legalCase)
        }
    }

    // MARK: - A conversation

    /// The conversation's screen is cancelled mid-read and the history still loads whole, so the
    /// composer is open — not shut on "cancelled" over a conversation that was fine.
    func testAConversationWhoseScreenIsCancelledMidReadStillLoadsWhole() async {
        await onMain {
            let service = GatedChat()
            let model = ChatViewModel(chatID: "c1", service: service)
            let screen = Task { await model.load() }
            await service.gate.waitForArrival()
            screen.cancel()
            service.gate.open()
            await screen.value

            XCTAssertEqual(model.messages.count, 2, "the history was abandoned with the screen's task")
            XCTAssertTrue(model.historyIsIntact, "a whole history must leave the composer open")
            XCTAssertNil(model.errorMessage)
        }
    }
}

// MARK: - Fakes

private func onMain(_ body: @MainActor () async -> Void) async {
    await body()
}

/// Holds a read until opened, then answers as `URLSession` does for a cancelled request.
private final class ReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private var arrived = false

    /// Waits for `open()`, then throws if the task that called this has been cancelled.
    func pass() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isOpenNow: Bool = lock.withLock {
                arrived = true
                if !isOpen { waiting = continuation }
                return isOpen
            }
            if isOpenNow { continuation.resume() }
        }
        try Task.checkCancellation()
    }

    func open() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            isOpen = true
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }

    private var hasArrived: Bool { lock.withLock { arrived } }

    /// Returns once a read is waiting at the gate.
    func waitForArrival() async {
        for _ in 0..<10_000 {
            if hasArrived { return }
            await Task.yield()
        }
        XCTFail("no read reached the gate")
    }
}

private final class GatedCases: CaseProviding, @unchecked Sendable {
    let gate = ReadGate()

    func caseDetail(id: String) async throws -> CaseDetail {
        try await gate.pass()
        let legalCase = try JSONDecoder().decode(
            LegalCase.self, from: Data(#"{"id":"\#(id)","title":"Bakshi v. State"}"#.utf8))
        return CaseDetail(legalCase: legalCase, events: [], items: [])
    }

    func cases() async throws -> [LegalCase] { [] }
    func causeList() async throws -> [CauseListing] { [] }
    func addNote(caseID: String, title: String?, body: String) async throws {}
    func addTask(caseID: String, title: String, dueDate: Date?) async throws {}
    func orderDocument(for item: CaseItem, in legalCase: LegalCase) async throws -> Data { Data() }
}

private final class GatedChat: ChatProviding, @unchecked Sendable {
    let gate = ReadGate()

    func messages(chatID: String) async throws -> [ChatMessage] {
        try await gate.pass()
        return [
            ChatMessage(role: .user, content: "Is the suit barred?"),
            ChatMessage(role: .assistant, content: "Yes, under Article 58."),
        ]
    }

    func streamStatus(chatID: String) async throws -> StreamStatus { StreamStatus(active: false) }

    func send(
        history: [ChatMessage], chatID: String, model: ChatModel, role: ChatRole?,
        attachments: [ChatAttachment]?, webSearch: Bool
    ) async throws -> AsyncThrowingStream<ChatTurnEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
