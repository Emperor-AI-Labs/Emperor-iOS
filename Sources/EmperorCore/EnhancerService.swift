import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Rewrites a rough prompt into a clearer one.
///
/// Separate from `ChatProviding` because it is the one call the composer makes that is not a
/// turn, and every screen that fakes a *turn* should not have to fake a *rewrite*.
protocol PromptEnhancing: Sendable {
    /// Streams the rewrite. Each element is the **accumulated** text so far, not a delta.
    func enhance(
        prompt: String, attachments: [ChatAttachment]
    ) async throws -> AsyncThrowingStream<String, Error>
}

struct EnhancerService: PromptEnhancing {
    let client: APIClient

    /// The hard ceiling on one rewrite, client-side.
    ///
    /// The server has its own 15s timer, but it starts at the *generation* call — the context
    /// build before it (document metadata, an embedding, a vector query) is outside it, and a
    /// multi-document attachment set plus ordinary tunnel latency adds several seconds on top.
    /// The platform learned this the hard way: a 20s client ceiling aborted a healthy
    /// eight-document run that would have finished. 30s leaves real headroom instead of
    /// racing the server's own timer.
    ///
    /// It cannot simply be left to the server, either. The server's guarantee that it always
    /// ends the response is only as good as the network delivering that end — a stalled proxy
    /// leaves the composer saying "Enhancing…" forever with no way out.
    static let timeout: TimeInterval = 30

    private struct Payload: Encodable {
        let prompt: String
        let userId: String
        let attachments: [ChatAttachment]
    }

    /// - Important: **failure here is indistinguishable from success at the transport layer.**
    ///   Every error path on the server — OpenRouter down, its 15s abort, a mid-stream break —
    ///   ends the response with `200` and whatever had been written so far, which may be
    ///   nothing or may be half a sentence. There is no error envelope and no terminator. So
    ///   an empty result means "no rewrite", never "an empty rewrite", and a caller must not
    ///   treat a short result as final proof of anything. `PromptEnhancerViewModel` is where
    ///   that rule is enforced; do not stream this straight into a text field.
    func enhance(
        prompt: String, attachments: [ChatAttachment] = []
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        // The one genuine 400. Guarded here so an accidental blank never costs a round trip.
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.server(status: 400, message: "Missing prompt")
        }

        var request = try await client.makeRequest(
            "POST", "/enhance-prompt",
            body: Payload(
                prompt: prompt,
                userId: credentials.userIDString,
                // Grounding is only attempted when BOTH a userId and a non-empty array are
                // present; either missing and the model sees the bare prompt.
                attachments: attachments))
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeout

        let bytes = ByteStream.open(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = IncrementalUTF8Decoder()
                var accumulated = ""
                do {
                    for try await chunk in bytes {
                        let text = decoder.decode(chunk)
                        guard !text.isEmpty else { continue }
                        accumulated += text
                        continuation.yield(accumulated)
                    }
                    let tail = decoder.flush()
                    if !tail.isEmpty {
                        accumulated += tail
                        continuation.yield(accumulated)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
