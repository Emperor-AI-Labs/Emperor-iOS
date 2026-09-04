import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in Foundation on Apple platforms but in FoundationNetworking on Linux,
// where the core package is compiled for tests.
import FoundationNetworking
#endif

/// A file the model should read for this turn.
///
/// The server accepts either a bare filename string or an object with a folder, and defaults
/// the folder to the storage root. We always send the object form so files in sub-folders
/// resolve correctly.
struct ChatAttachment: Codable, Equatable {
    var name: String
    var folderName: String?

    /// The same attachment as an untyped value, for embedding on a message.
    ///
    /// Attachments must travel in **two** places, which is what the web client does: the
    /// top-level array and the last message are read by different passes, so both must carry
    /// them or the model sees an incomplete set. Putting them on the user turn also keeps files
    /// in scope on later turns, since prior user messages are re-walked.
    ///
    /// - Important: send both. Omitting the per-message copy is not an optimisation.
    var jsonValue: JSONValue {
        var object: [String: JSONValue] = ["name": .string(name)]
        if let folderName, !folderName.isEmpty {
            object["folderName"] = .string(folderName)
        }
        return .object(object)
    }

    /// The reverse, for reading attachments back off a stored turn.
    ///
    /// Needed when a question is edited and re-answered: the documents the original asked about
    /// have to travel with it, or the edit silently changes the question by more than its words.
    ///
    /// Tolerant of **both** wire shapes, because the server accepts both and a conversation may
    /// hold turns written by the web client: a bare string is a filename at the storage root, an
    /// object carries its folder. Anything else is skipped rather than guessed at.
    static func list(from values: [JSONValue]?) -> [ChatAttachment] {
        (values ?? []).compactMap { value in
            switch value {
            case .string(let name):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : ChatAttachment(name: trimmed)
            case .object(let object):
                guard case .string(let name)? = object["name"] else { return nil }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                var folder: String?
                if case .string(let raw)? = object["folderName"], !raw.isEmpty { folder = raw }
                return ChatAttachment(name: trimmed, folderName: folder)
            default:
                return nil
            }
        }
    }
}

struct ChatRequest: Encodable {
    var messages: [ChatMessage]
    var userId: String
    var chatId: String
    var model: String?
    var role: String?
    var searchMode: String?
    var attachments: [ChatAttachment]?
    var source: String?
}

/// Everything the reasoning panel needs, as of this moment in the stream.
struct ReasoningSnapshot: Equatable, Sendable {
    var plan: [PlanRow] = []
    var workLog: [WorkLogEntry] = []
    var reasoning: [String] = []

    var isEmpty: Bool { plan.isEmpty && workLog.isEmpty && reasoning.isEmpty }
    var stepCount: Int {
        workLog.reduce(0) { total, entry in
            if case .group(let group) = entry { return total + group.steps.count }
            return total
        }
    }
}

/// What the caller learns while a turn streams.
enum ChatTurnEvent {
    case status(String)
    /// A concurrent run was refused; the payload explains it and belongs outside the transcript.
    case busy(String)
    /// Full accumulated answer, re-derived. Not a delta — a rollback can shorten it.
    case content(StreamContent)
    case usage(JSONValue)
    /// Plan and work-log state, recomputed as the run proceeds.
    case progress(ReasoningSnapshot)
}

/// The chat operations a view model needs.
///
/// Exists so `ChatViewModel` can be exercised without a server. Turn state is where the
/// genuinely fiddly behaviour lives — rejoining a run that continued while the app was
/// backgrounded, handling a refused second send, telling a truncated answer from a finished
/// one — and none of that should need a device to verify.
protocol ChatProviding: Sendable {
    func messages(chatID: String) async throws -> [ChatMessage]
    func streamStatus(chatID: String) async throws -> StreamStatus
    func send(
        history: [ChatMessage],
        chatID: String,
        model: ChatModel,
        role: ChatRole?,
        attachments: [ChatAttachment]?,
        webSearch: Bool
    ) async throws -> AsyncThrowingStream<ChatTurnEvent, Error>
}

/// The conversation list, kept separate from `ChatProviding`.
///
/// Listing chats and running a turn are needed by different screens and faked independently,
/// so folding `chats()` into `ChatProviding` would force every stand-in for a *turn* to
/// implement a method about the *list*.
protocol ChatListProviding: Sendable {
    func chats() async throws -> [ChatSummary]
}

struct ChatService: ChatProviding, ChatListProviding {
    let client: APIClient

    // MARK: - History

    func chats() async throws -> [ChatSummary] {
        try await withRetry {
            let request = try await client.makeRequest("GET", "/chats")
            return try await client.send(request, as: ChatListResponse.self).chats
        }
    }

    func messages(chatID: String) async throws -> [ChatMessage] {
        let request = try await client.makeRequest("GET", "/messages", query: ["chatId": chatID])
        let all = try await client.send(request, as: MessagesResponse.self).messages
        // The in-flight checkpoint row is a live partial, not a finished turn. It is deleted
        // on a clean finish, so seeing it means a run is genuinely streaming right now.
        return all.filter { $0.isTyping != true }
    }

    /// Authoritative completeness check.
    ///
    /// An aborted run ends its response cleanly with no error bytes, so a truncated answer
    /// looks exactly like a finished one at the transport layer. After any stream ends,
    /// confirm with this before treating the answer as complete.
    func streamStatus(chatID: String) async throws -> StreamStatus {
        let request = try await client.makeRequest("GET", "/stream-status", query: ["chatId": chatID])
        // This route answers 200 even for errors, so decode before inspecting the status code.
        let (data, _) = try await client.perform(request)
        do {
            return try JSONDecoder().decode(StreamStatus.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    // MARK: - Sending a turn

    /// Streams one conversational turn.
    ///
    /// - Important: `/chat` is **destructive to history**. The server persists exactly
    ///   `messages + answer`, deleting every other message on the chat first, so anything
    ///   omitted from `history` is deleted server-side. Always pass the full conversation.
    ///
    /// The run is not tied to the socket: disconnecting does not cancel generation, and the
    /// server keeps checkpointing to the database. A dropped connection should therefore be
    /// recovered with `streamStatus(chatID:)` rather than by re-sending.
    func send(
        history: [ChatMessage],
        chatID: String,
        model: ChatModel = .default,
        role: ChatRole? = .default,
        attachments: [ChatAttachment]? = nil,
        webSearch: Bool = false
    ) async throws -> AsyncThrowingStream<ChatTurnEvent, Error> {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }

        let payload = ChatRequest(
            messages: history,
            userId: credentials.userIDString,
            chatId: chatID,
            model: model.rawValue,
            // A nil here omits the key, which is the only safe way to take the server's
            // default: `getLeadingIdentity` defaults on `undefined` only, so an empty string
            // or null would be spliced into the system prompt verbatim.
            role: role?.wireValue,
            // Only the literal "web" is meaningful. Note the server also auto-triggers web
            // search on keywords in the message, so this cannot fully opt out.
            searchMode: webSearch ? "web" : nil,
            attachments: attachments,
            source: "chat")

        var request = try await client.makeRequest("POST", "/chat", body: payload)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")

        let bytes = ByteStream.open(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                let parser = ChatStreamParser()
                let tracker = ReasoningTracker()
                do {
                    for try await chunk in bytes {
                        for event in parser.consume(chunk) {
                            emit(event, parser: parser, tracker: tracker, to: continuation)
                        }
                    }
                    for event in parser.finish() {
                        emit(event, parser: parser, tracker: tracker, to: continuation)
                    }
                    // A clean end of body means anything still running did come back — the
                    // model went on to write the answer.
                    tracker.finish(ended: .completed)
                    continuation.yield(.progress(snapshot(of: tracker)))
                    continuation.finish()
                } catch {
                    // Cancelled or failed: we genuinely do not know whether in-flight calls
                    // returned, so they are reported unfinished rather than ticked off.
                    tracker.finish(ended: .stopped)
                    continuation.yield(.progress(snapshot(of: tracker)))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func snapshot(of tracker: ReasoningTracker) -> ReasoningSnapshot {
        ReasoningSnapshot(
            plan: tracker.plan, workLog: tracker.workLog, reasoning: tracker.reasoning)
    }

    private func emit(
        _ event: ChatStreamEvent,
        parser: ChatStreamParser,
        tracker: ReasoningTracker,
        to continuation: AsyncThrowingStream<ChatTurnEvent, Error>.Continuation
    ) {
        // The tracker sees every raw event, including rollbacks, which the transcript-level
        // event stream deliberately does not expose.
        tracker.consume(event)

        switch event {
        case .status(let text):
            continuation.yield(.status(text))
            continuation.yield(.progress(snapshot(of: tracker)))
        case .busy:
            continuation.yield(.busy(parser.busyNotice))
        case .content(let raw):
            let content = StreamContent.parse(raw)
            continuation.yield(.content(content))
            // Reasoning sentences arrive inside the content stream, so the snapshot has to be
            // refreshed here too rather than only on status events.
            var snapshot = snapshot(of: tracker)
            snapshot.reasoning = content.reasoning
            continuation.yield(.progress(snapshot))
        case .usage(let usage):
            continuation.yield(.usage(usage))
        case .rolledBack:
            continuation.yield(.progress(snapshot(of: tracker)))
        }
    }
}

// MARK: - Byte streaming

/// Bridges `URLSession`'s delegate callbacks to an `AsyncThrowingStream` of `Data` chunks.
///
/// `URLSession.bytes(for:)` would be simpler but yields one `UInt8` at a time, which means an
/// async suspension per byte — unacceptable for a draft that runs to tens of kilobytes.
enum ByteStream {
    static func open(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let delegate = Delegate(continuation: continuation)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = request.timeoutInterval
            config.timeoutIntervalForResource = request.timeoutInterval
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation
        /// Non-2xx bodies are JSON errors, not stream content, so they are collected whole.
        private var errorBody = Data()
        private var isErrorResponse = false

        init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask,
            didReceive response: URLResponse
        ) async -> URLSession.ResponseDisposition {
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                isErrorResponse = true
            }
            return .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if isErrorResponse {
                errorBody.append(data)
            } else {
                continuation.yield(data)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            defer { session.finishTasksAndInvalidate() }

            if let error {
                continuation.finish(throwing: APIError.transport(error.localizedDescription))
                return
            }
            if isErrorResponse {
                let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
                let decoded = try? JSONDecoder().decode(APIErrorBody.self, from: errorBody)
                let message = decoded?.error ?? "The server returned status \(status)."
                continuation.finish(
                    throwing: status == 401
                        ? APIError.invalidCredentials
                        : APIError.server(status: status, message: message))
                return
            }
            // No sentinel and no terminator: end-of-body is the only completion signal.
            continuation.finish()
        }
    }
}
