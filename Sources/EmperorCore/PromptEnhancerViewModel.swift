import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Owns the composer's text and the "rewrite this for me" flow over it.
///
/// The text lives here rather than in the view because every interesting rule about it is a
/// rule about *ownership*: while a rewrite streams, the box holds our text, not the user's,
/// and the difference decides whether a failure restores or leaves well alone. That is not
/// something to work out inside a `@State` binding.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class PromptEnhancerViewModel {
    /// The composer's contents. Bound directly to the text field.
    var text: String = "" {
        didSet {
            guard !isApplying, text != oldValue else { return }
            userEdited()
        }
    }

    private(set) var isEnhancing = false
    /// Whether reverting to the pre-rewrite text still makes sense.
    private(set) var canUndo = false
    /// Set when a rewrite did not produce anything usable. Cleared on the next attempt.
    private(set) var failureNotice: String?
    /// The rewrite split at its `{{PLACEHOLDER}}` tokens, when it has any.
    ///
    /// Non-nil is the signal to offer the fill-in-the-blanks sheet. It survives a user edit
    /// only until they change the text — after that the segments no longer describe the box.
    private(set) var template: PromptTemplate?

    /// Files the rewrite should be grounded in. The server only builds document context when
    /// this is non-empty; otherwise the model sees the bare prompt and is told, in its own
    /// system prompt, not to invent one.
    var attachments: [ChatAttachment] = []

    private let service: PromptEnhancing

    /// What the box held before the rewrite, for revert and for rollback.
    private var original = ""
    /// The last value *we* wrote. Nil until the first chunk lands.
    private var lastApplied: String?
    /// The finished rewrite, which is what "has the user edited away from it" is measured
    /// against — not `original`.
    private var enhanced = ""
    /// Set while we are the one writing, so `didSet` can tell our writes from the user's.
    private var isApplying = false

    #if canImport(Darwin)
    @ObservationIgnored private var task: Task<Void, Never>?
    #else
    private var task: Task<Void, Never>?
    #endif

    init(service: PromptEnhancing, text: String = "") {
        self.service = service
        self.text = text
    }

    var canEnhance: Bool {
        !isEnhancing && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Running a rewrite

    func enhance() {
        guard canEnhance else { return }
        task?.cancel()
        task = Task { await run() }
    }

    /// The same run, awaitable. Tests drive this directly rather than racing a detached task.
    func run() async {
        guard canEnhance else { return }
        let startText = text
        original = startText
        lastApplied = nil
        enhanced = ""
        template = nil
        canUndo = false
        failureNotice = nil
        isEnhancing = true
        defer { isEnhancing = false }

        do {
            let stream = try await service.enhance(prompt: startText, attachments: attachments)
            for try await accumulated in stream {
                // If the box no longer holds what we last wrote — or, before our first chunk,
                // the untouched original — the user typed while we were streaming. Their edit
                // wins: stop writing and leave the run to finish into nothing.
                guard text == (lastApplied ?? startText) else { return }
                apply(accumulated)
            }
        } catch {
            // Every server-side failure arrives as a clean, short body rather than an error,
            // so this only fires for transport problems and the client timeout. Both are
            // handled the same way as an empty result.
            rollback(notice: DisplayText.message(for: error))
            return
        }

        finish()
    }

    private func apply(_ value: String) {
        isApplying = true
        text = value
        isApplying = false
        lastApplied = value
    }

    private func finish() {
        guard let applied = lastApplied, !applied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            // Nothing arrived. The server answers 200 with an empty body on every one of its
            // own error paths, so this is a failure wearing a success's clothes — and the
            // composer still holds the original, because we never wrote to it.
            rollback(notice: Copy.emptyResult)
            return
        }
        // A late user edit between the last chunk and here means the box is theirs again.
        guard text == applied else { return }

        enhanced = applied
        canUndo = true
        let parsed = PromptTemplate.parse(applied)
        template = parsed.hasPlaceholders ? parsed : nil
    }

    /// Puts the user's own words back, if the box still holds ours.
    ///
    /// - Important: leaving partial text in place is not the safe option. Once a chunk has
    ///   landed, what is in the box is *ours* — a visibly truncated half-sentence the user
    ///   never wrote. "Leave it as the user left it" only holds before the first chunk.
    private func rollback(notice: String) {
        if let applied = lastApplied, text == applied {
            apply(original)
        }
        lastApplied = nil
        canUndo = false
        template = nil
        failureNotice = notice
    }

    // MARK: - Undo

    func undo() {
        guard canUndo else { return }
        apply(original)
        lastApplied = nil
        canUndo = false
        template = nil
    }

    /// Replaces the composer with the template's blanks filled in.
    func applyFilled(_ values: [String: String]) {
        guard let template else { return }
        apply(template.filled(with: values))
        // The text no longer matches the segments once it is filled, and offering to fill it
        // again would show the answers back as prompts.
        self.template = nil
    }

    func dismissTemplate() { template = nil }

    func dismissFailure() { failureNotice = nil }

    // MARK: - Reacting to the user's own typing

    private func userEdited() {
        failureNotice = nil
        guard canUndo else {
            if template != nil { template = nil }
            return
        }
        // Fixing one wrong word should not throw away the revert; rewriting the thing should.
        if PromptEnhancerViewModel.editDistanceRatio(text, enhanced) > Copy.undoInvalidateThreshold {
            canUndo = false
            template = nil
        }
    }

    /// Clears the composer after a send.
    func clear() {
        apply("")
        lastApplied = nil
        canUndo = false
        template = nil
        failureNotice = nil
    }

    // MARK: - Distance

    /// How different two strings are, from 0 (identical) to 1.
    ///
    /// Levenshtein rather than a length comparison: retyping the same number of characters
    /// with entirely different words is a different prompt, and a length check would call it
    /// unchanged. Capped so a long paste cannot make this expensive — anything that differs
    /// within the first few thousand characters already qualifies.
    nonisolated static func editDistanceRatio(_ a: String, _ b: String) -> Double {
        let maximum = max(a.count, b.count)
        guard maximum > 0 else { return 0 }
        let cap = 4000
        let first = Array(a.prefix(cap))
        let second = Array(b.prefix(cap))
        guard !first.isEmpty else { return Double(second.count) / Double(maximum) }
        guard !second.isEmpty else { return Double(first.count) / Double(maximum) }

        var previous = Array(0...second.count)
        var current = [Int](repeating: 0, count: second.count + 1)
        for i in 1...first.count {
            current[0] = i
            for j in 1...second.count {
                current[j] = first[i - 1] == second[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return Double(previous[second.count]) / Double(maximum)
    }

    enum Copy {
        static let undoInvalidateThreshold = 0.3
        static let emptyResult = "Couldn't rewrite that just now. Your text is unchanged."
        static let button = "Rewrite this prompt"
        static let running = "Rewriting…"
        static let undoButton = "Use my original wording"
        static let fillTitle = "Fill in the blanks"
        static let fillFooter =
            "Anything you leave blank is sent as-is, so the assistant knows to ask for it."
    }
}
