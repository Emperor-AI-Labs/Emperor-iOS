import Foundation

/// One observable thing that happened while consuming the chat byte stream.
enum ChatStreamEvent: Equatable {
    /// Transient progress ("Reading: sale_deed.pdf"). Replaces any previous status.
    case status(String)
    /// The server refused to start a second run on a chat that is already generating.
    /// Everything after this point is an explanation, not part of the answer.
    case busy
    /// The accumulated answer changed. Carries the full raw buffer, not a delta —
    /// `<truncate:N/>` can retroactively shorten it, so deltas would be unsound.
    case content(String)
    /// Final token accounting, written once immediately before the response ends.
    case usage(JSONValue)
    /// A round was rolled back to this UTF-16 offset. Emitted before the `.content` that
    /// reflects it, so a listener can mark work as superseded rather than lose the fact that
    /// it happened.
    case rolledBack(offset: Int)
}

/// Parses the `/chat` response body.
///
/// The endpoint is **not** SSE despite streaming: it is `text/plain; charset=utf-8` with
/// `Transfer-Encoding: chunked`, carrying prose with pseudo-XML control tags interleaved
/// directly into the text. There is no framing and no terminator — end-of-body is the only
/// completion signal, so a truncated stream is indistinguishable from a finished one at this
/// layer. Callers must confirm completeness via `GET /stream-status`.
///
/// This mirrors the two-layer split the web client uses (`src/lib/api.js:124-140` and
/// `src/lib/streamManager.js:289-299` in the emperor-ai repo), because the layering is
/// load-bearing: `<status>` tags are stripped *before* content accumulates, so a
/// `<truncate:N/>` offset — which the server computes in JavaScript, over the
/// already-status-stripped string — lines up only if we strip in the same order.
final class ChatStreamParser {
    /// Accumulated answer: status tags removed, truncations applied.
    private(set) var raw = ""
    /// Set once the server refuses a concurrent run; suppresses further content.
    private(set) var isBusy = false
    /// The refusal explanation, accumulated after `isBusy` is set.
    private(set) var busyNotice = ""

    /// Transport-layer holdback for a `<status>` tag split across chunk boundaries.
    private var buffer = ""
    private var decoder = IncrementalUTF8Decoder()

    private static let statusRegex = try! NSRegularExpression(
        pattern: "<status>(.*?)</status>", options: [])
    private static let truncateRegex = try! NSRegularExpression(
        pattern: "<truncate:(\\d+)/>", options: [])
    private static let usageRegex = try! NSRegularExpression(
        pattern: "<usage>([\\s\\S]*?)</usage>", options: [])
    /// Complete reasoning blocks, for offset translation only — see `rawOffset(forContentOffset:)`.
    private static let reasoningRegex = try! NSRegularExpression(
        pattern: "<think>[\\s\\S]*?</think>", options: [])

    /// The literal the server sends when a run is already in flight for this chat
    /// (sync-server.js:7273). It arrives as a `<status>` tag, ahead of its own explanation.
    ///
    /// Detect the busy case by this text, never by status code — the server deliberately
    /// answers 200 so that the explanation streams into the transcript position rather than
    /// being discarded as an error body.
    private static let busyMarker = "Still drafting your earlier request"

    // MARK: - Input

    func consume(_ data: Data) -> [ChatStreamEvent] {
        consume(text: decoder.decode(data))
    }

    func consume(text: String) -> [ChatStreamEvent] {
        guard !text.isEmpty else { return [] }
        var events: [ChatStreamEvent] = []
        buffer += text

        // Layer 1: lift every complete <status> tag out of the byte stream.
        for status in extractStatuses() {
            if status.contains(Self.busyMarker) {
                isBusy = true
                events.append(.busy)
            } else {
                events.append(.status(status))
            }
        }

        // Hold back a trailing partial tag so it never reaches the transcript.
        let emit = splitHoldback()
        guard !emit.isEmpty else { return events }

        if isBusy {
            // Past the refusal marker every byte is explanation. It must not touch the answer.
            busyNotice += emit
            return events
        }

        events.append(contentsOf: accumulate(emit))
        return events
    }

    /// Flushes held-back bytes at end-of-stream.
    ///
    /// The web client omits this, so a stream ending mid-tag silently loses its tail there.
    /// We flush instead: partial tags are stripped at render time anyway.
    func finish() -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        let tail = decoder.flush() + buffer
        buffer = ""
        guard !tail.isEmpty else { return events }
        if isBusy {
            busyNotice += tail
        } else {
            events.append(contentsOf: accumulate(tail))
        }
        return events
    }

    // MARK: - Layer 1: status extraction

    private func extractStatuses() -> [String] {
        let ns = buffer as NSString
        let matches = Self.statusRegex.matches(
            in: buffer, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        let statuses = matches.map { ns.substring(with: $0.range(at: 1)) }
        // Remove back-to-front so earlier ranges stay valid.
        let mutable = NSMutableString(string: buffer)
        for match in matches.reversed() {
            mutable.deleteCharacters(in: match.range)
        }
        buffer = mutable as String
        return statuses
    }

    /// Splits `buffer` into (text safe to emit, text retained for the next chunk).
    ///
    /// Retains any trailing run that could still become a `<status>` tag. The web client only
    /// checks for the full literal `"<status"`, so a boundary falling inside it — `"<sta"` +
    /// `"tus>"` — leaks the fragment into the visible answer there. We hold back on any proper
    /// prefix of `"<status>"`, which costs at most 8 characters of latency.
    private func splitHoldback() -> String {
        let openTag = "<status>"

        // A complete opening tag still awaiting its close: hold from there.
        if let open = buffer.range(of: openTag, options: .backwards),
           buffer.range(of: "</status>", range: open.upperBound..<buffer.endIndex) == nil {
            let emit = String(buffer[buffer.startIndex..<open.lowerBound])
            buffer = String(buffer[open.lowerBound...])
            return emit
        }

        // A truncated opening tag at the very end: "<", "<s", … "<status".
        for length in stride(from: min(openTag.count - 1, buffer.count), through: 1, by: -1) {
            let candidate = String(buffer.suffix(length))
            if openTag.hasPrefix(candidate) {
                let emit = String(buffer.dropLast(length))
                buffer = candidate
                return emit
            }
        }

        let emit = buffer
        buffer = ""
        return emit
    }

    // MARK: - Layer 2: accumulation, rollback, usage

    private func accumulate(_ chunk: String) -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        raw += chunk

        if let usage = extractUsage() {
            events.append(.usage(usage))
        }
        // Loop: keeping the tail means a chunk can carry more than one rollback. Bounded so a
        // malformed marker can never spin.
        var rollbacks = 0
        while rollbacks < 16, let offset = applyTruncate() {
            events.append(.rolledBack(offset: offset))
            rollbacks += 1
        }
        events.append(.content(raw))
        return events
    }

    /// Applies a server-issued rollback.
    ///
    /// `<truncate:N/>` means a generation round turned out to be a connection failure or a
    /// fabricated-looking response, and is being retried — discard everything from offset N
    /// on, marker included, so the retry appends cleanly. Without this a retried round
    /// double-renders.
    ///
    /// N is a **UTF-16 offset**, because the server computes it with JavaScript's `.length`
    /// over the same string. `NSRange` is UTF-16 too, so slicing through `NSString` is exact;
    /// using Swift `Character` offsets would drift on any emoji or non-BMP character.
    /// - Returns: the offset rolled back to, or nil if no rollback was present.
    @discardableResult
    private func applyTruncate() -> Int? {
        let ns = raw as NSString
        guard let match = Self.truncateRegex.firstMatch(
            in: raw, options: [], range: NSRange(location: 0, length: ns.length))
        else { return nil }

        let digits = ns.substring(with: match.range(at: 1))
        guard let offset = Int(digits) else { return nil }

        // N indexes the server's content-only string, not ours. Translate first.
        let target = rawOffset(forContentOffset: max(offset, 0))

        // Clamp to the marker's own position rather than to the buffer length. The marker sits
        // at or after the cut by construction, so clamping this way always removes it —
        // whereas clamping to length (as the web client's `slice(0, N)` does) leaves a stray
        // `<truncate:N/>` rendering as prose if N ever overruns.
        let cut = min(target, match.range.location)

        // Keep whatever followed the marker. Everything after it is the retry's real content,
        // which the server means to keep — so discarding to end-of-buffer deletes the new answer
        // whenever the marker and the retry arrive in the same delivered chunk. The server
        // sleeps before retrying, which makes that rare rather than impossible: a proxy or the
        // OS can still coalesce them. The web client has this bug (`streamManager.js:294-296`).
        let afterMarker = match.range.location + match.range.length
        let tail = afterMarker < ns.length ? ns.substring(from: afterMarker) : ""
        raw = ns.substring(to: cut) + tail
        return cut
    }

    /// Translates a server content offset into an offset into `raw`.
    ///
    /// The two are different coordinate systems. The server computes `N` as `fullContent.length`
    /// (`OpenRouterProvider.js:528`), and `fullContent` is appended to **only** by content deltas
    /// (`:642`, `:646`) and error strings — it never receives the `<think>` blocks the provider
    /// writes alongside them (`:616`). Our `raw` carries those blocks, because the reasoning
    /// panel downstream is built from them.
    ///
    /// So `raw` is longer than the string `N` measures, by the width of every `<think>` block
    /// emitted so far. Slicing `raw` at `N` directly would cut **earlier** than the server meant
    /// and delete real answer text — silently, and only on a reasoning model.
    ///
    /// `<status>` needs no accounting here: layer 1 removed it before `raw` ever saw it. Nor
    /// does `<usage>`: `extractUsage()` lifts it out ahead of this call, and the server writes it
    /// once at the very end, after any rollback could occur.
    private func rawOffset(forContentOffset offset: Int) -> Int {
        let ns = raw as NSString
        var remainingContent = offset
        var position = 0

        for span in reasoningSpans() {
            let contentBefore = span.location - position
            if remainingContent <= contentBefore { return position + remainingContent }
            remainingContent -= contentBefore
            position = span.location + span.length
        }
        return min(position + remainingContent, ns.length)
    }

    /// Every complete `<think>…</think>` span in `raw`, ascending.
    ///
    /// Only `<think>` — that is the wrapper the *server* writes reasoning under, and therefore
    /// the only thing systematically absent from the string its offsets measure. The wider set
    /// `StreamContent` strips defensively (`<thinking>`, `<scratchpad>`, …) belongs to upstream
    /// models and travels inside content, so it is counted by the server too.
    private func reasoningSpans() -> [NSRange] {
        let ns = raw as NSString
        return Self.reasoningRegex
            .matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length))
            .map(\.range)
    }

    private func extractUsage() -> JSONValue? {
        let ns = raw as NSString
        guard let match = Self.usageRegex.firstMatch(
            in: raw, options: [], range: NSRange(location: 0, length: ns.length))
        else { return nil }

        let body = ns.substring(with: match.range(at: 1))
        raw = ns.replacingCharacters(in: match.range, with: "")
        return JSONValue.decode(from: body)
    }
}
