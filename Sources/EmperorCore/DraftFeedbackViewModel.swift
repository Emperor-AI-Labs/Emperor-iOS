import Foundation
#if canImport(Darwin)
import Observation
#endif

/// What a feedback sheet is about: a drafted document or table, or an answer with no draft.
struct DraftFeedbackTarget: Equatable, Sendable {
    /// "document", "table" or "answer" — the word in "Feedback on this …", as the web words it.
    let subject: String
    let title: String
    let chatID: String?
    /// The draft's HTML, sent with the feedback; nil for an answer with no draft.
    let docHTML: String?

    /// A draft opened full screen.
    static func artifact(_ artifact: StreamArtifact, chatID: String?) -> DraftFeedbackTarget {
        DraftFeedbackTarget(
            subject: artifact.kind == .table ? "table" : "document",
            title: artifact.title,
            chatID: chatID,
            docHTML: html(of: artifact))
    }

    /// An answer in the transcript. When it carries a draft, the feedback is about that draft —
    /// the first one, as the web's canvas card rates the draft it shows — and the draft's text
    /// goes with it. An answer with none sends only its conversation id.
    static func answer(_ content: StreamContent, chatID: String?) -> DraftFeedbackTarget {
        if let first = content.artifacts.first {
            return artifact(first, chatID: chatID)
        }
        return DraftFeedbackTarget(subject: "answer", title: "", chatID: chatID, docHTML: nil)
    }

    /// HTML as the web stores it: a Markdown table or chronology is converted, as it is for Word.
    static func html(of artifact: StreamArtifact) -> String {
        artifact.format == .html ? artifact.body : MarkdownHTML.html(from: artifact.body)
    }
}

/// The feedback sheet: thumbs up or down, any of six categories, a comment — the web's
/// `DraftFeedbackButton` modal.
///
/// The rule is the route's: a rating or a comment, either will do. A failed send keeps the sheet
/// and everything in it, with the reason, as the web's modal stays open — the note is not lost.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class DraftFeedbackViewModel {
    let target: DraftFeedbackTarget

    private(set) var rating: DraftFeedbackRating?
    private(set) var categories: [DraftFeedbackCategory] = []
    var comment = "" {
        didSet { if error != nil, comment != oldValue { error = nil } }
    }
    private(set) var isSending = false
    private(set) var isSent = false
    private(set) var error: String?

    private let service: any FeedbackProviding

    init(target: DraftFeedbackTarget, rating: DraftFeedbackRating? = nil, service: any FeedbackProviding) {
        self.target = target
        self.rating = rating
        self.service = service
    }

    // MARK: Words

    /// "Feedback on this document" — the web's dialog title.
    var title: String { "Feedback on this \(target.subject)" }

    /// The web's comment placeholder.
    static let commentPrompt = "What should we fix?"
    static let sentMessage = "Thanks — your feedback was sent."
    static let failedMessage = "Could not send your feedback. Please try again."

    /// Said under the comment, before the tap: exactly what leaves the phone.
    var privacyNote: String {
        target.docHTML == nil
            ? "The answer itself is not sent — only this conversation's id, so a reviewer can find it."
            : "The \(target.subject)'s text is sent with your feedback, so a reviewer sees exactly what you rated."
    }

    var remainingCharacters: Int { FeedbackService.commentLimit - comment.count }

    // MARK: Choosing

    /// The web's rating buttons: tapping the chosen one again clears it.
    func toggle(_ value: DraftFeedbackRating) {
        rating = rating == value ? nil : value
        error = nil
    }

    func isSelected(_ category: DraftFeedbackCategory) -> Bool { categories.contains(category) }

    /// Multi-select, kept in the order the chips are shown.
    func toggle(_ category: DraftFeedbackCategory) {
        let chosen = isSelected(category)
            ? categories.filter { $0 != category }
            : categories + [category]
        categories = DraftFeedbackCategory.allCases.filter(chosen.contains)
    }

    var feedback: DraftFeedback {
        DraftFeedback(
            chatID: target.chatID, documentID: nil, documentTitle: target.title,
            rating: rating, categories: categories, comment: comment, docHTML: target.docHTML)
    }

    var canSend: Bool { feedback.canSubmit && !isSending && !isSent }

    // MARK: Sending

    /// Sends it. True once the server has stored it.
    @discardableResult
    func send() async -> Bool {
        guard canSend else { return false }
        isSending = true
        error = nil
        defer { isSending = false }
        do {
            try await service.send(feedback)
            isSent = true
            return true
        } catch let failure as APIError {
            error = failure.errorDescription ?? Self.failedMessage
        } catch {
            self.error = Self.failedMessage
        }
        return false
    }
}
