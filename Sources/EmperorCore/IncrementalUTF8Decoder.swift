import Foundation

/// Decodes a byte stream to text without ever splitting a multi-byte UTF-8 sequence.
///
/// The chat endpoint streams `text/plain; charset=utf-8` in chunks whose boundaries fall
/// wherever the network put them — routinely mid-character for Devanagari, ₹, em-dashes and
/// the U+2026 ellipsis the server's heartbeat uses. Decoding each chunk independently would
/// turn those into replacement characters, so we hold back a trailing partial sequence
/// (never more than 3 bytes) until its remaining bytes arrive.
struct IncrementalUTF8Decoder {
    private var pending = Data()

    /// Decodes as much of `data` as forms complete UTF-8, retaining any trailing partial
    /// sequence for the next call.
    mutating func decode(_ data: Data) -> String {
        pending.append(data)

        // Walk back at most 3 bytes looking for a prefix that decodes cleanly. A UTF-8
        // sequence is at most 4 bytes, so a longer walk-back means genuinely invalid input
        // rather than a split character.
        //
        // `prefix`/`dropFirst` are count-based, but `suffix(from:)` is *index*-based, and a
        // Data sliced from another Data inherits the parent's non-zero start index — mixing
        // the two reads out of bounds on the next call. Re-wrapping in `Data` rebases.
        for backoff in 0...min(3, pending.count) {
            let cut = pending.count - backoff
            if let text = String(data: pending.prefix(cut), encoding: .utf8) {
                pending = Data(pending.dropFirst(cut))
                return text
            }
        }

        // Genuinely malformed rather than merely split. Decode lossily rather than retaining
        // it, so one bad byte cannot make the buffer grow without bound.
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return text
    }

    /// Flushes anything still held back at end-of-stream. A non-empty result here means the
    /// stream ended mid-character, so we decode lossily rather than silently dropping bytes.
    mutating func flush() -> String {
        guard !pending.isEmpty else { return "" }
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return text
    }
}
