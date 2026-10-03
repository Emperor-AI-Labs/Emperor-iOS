import Foundation

/// What a background upload should do with one chunk's response.
///
/// The background path used to know two answers — it landed, or try again later — and to treat
/// every non-2xx as the second. That was right while the only failures were the network's. It
/// stopped being right when the platform began refusing uploads on purpose: an account with no
/// plan, a month's uploads used, storage full. Each of those answers the same way however often
/// it is asked, so "try again later" became an upload re-sent on every launch, forever, with the
/// person never told why their document did not arrive.
enum ChunkOutcome: Equatable, Sendable {
    /// The chunk is on the server.
    case delivered
    /// Worth trying again — the network, the server having a bad moment, the hourly ceiling.
    case retryLater
    /// The server declined and will keep declining. Stop, discard, and say this.
    case refused(message: String)

    static func classify(transportFailed: Bool, status: Int?, body: Data) -> ChunkOutcome {
        guard !transportFailed, let status else { return .retryLater }
        if (200..<300).contains(status) { return .delivered }

        if let refusal = Refusal.parse(status: status, body: body) {
            // The hourly ceiling lifts by itself; everything else needs the account to change.
            return refusal.clearsByItself
                ? .retryLater : .refused(message: DisplayText.message(for: refusal))
        }

        switch status {
        // A spent token is not the document's fault: it is re-sent once the person signs in
        // again, which is when `resume()` next runs with a working credential.
        case 401: return .retryLater
        case 408, 429: return .retryLater
        case 500...: return .retryLater
        default:
            // Any other 4xx is the server saying no to this request as built — a file over the
            // per-file cap, a malformed chunk. Repeating it cannot help.
            let decoded = try? JSONDecoder().decode(APIErrorBody.self, from: body)
            let message = decoded?.error.flatMap { $0.isEmpty ? nil : $0 }
                ?? "The server would not accept this document (status \(status))."
            return .refused(message: message)
        }
    }
}
