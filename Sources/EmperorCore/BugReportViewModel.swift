import Foundation
#if canImport(Darwin)
import Observation
#endif

/// "Report a bug": what happened, optional screenshots, and the screen it was sent from.
///
/// As the web's dialog: the description is required, at most twelve files go with one report,
/// and a failed send keeps everything on screen with the reason — the person has just written the
/// only account of a bug the team will get, and losing it to a dropped connection loses that.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class BugReportViewModel {
    var description = "" {
        didSet { if error != nil, description != oldValue { error = nil } }
    }
    private(set) var attachments: [SupportAttachment] = []
    private(set) var isSending = false
    private(set) var isSent = false
    private(set) var error: String?

    /// Where the report was made from, sent as the web sends its page's path.
    let pageURL: String

    private let service: any SupportFeedbackProviding

    /// - Parameter screen: the screen the report is made from, e.g. "You".
    init(screen: String, service: any SupportFeedbackProviding) {
        self.pageURL = "ios/\(screen)"
        self.service = service
    }

    var maxAttachments: Int { SupportFeedbackService.maxAttachments }
    var remainingSlots: Int { max(0, maxAttachments - attachments.count) }
    var canAddAttachments: Bool { remainingSlots > 0 && !isSending }
    var canSend: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending && !isSent
    }

    static let sentTitle = "Thank you!"
    static let sentMessage = "Your report reached the team."

    /// Adds what fits; the rest is dropped, as the web's dialog drops it.
    func add(_ incoming: [SupportAttachment]) {
        attachments.append(contentsOf: incoming.prefix(remainingSlots))
    }

    func remove(_ id: SupportAttachment.ID) {
        attachments.removeAll { $0.id == id }
    }

    /// Adds JPEG screenshots, named as the web names a pasted one: `screenshot-1.jpg`, counting
    /// on from what is already attached.
    func addScreenshots(_ jpegs: [Data]) {
        let start = attachments.count
        add(jpegs.enumerated().map { offset, data in
            SupportAttachment(name: "screenshot-\(start + offset + 1).jpg", contentType: "image/jpeg", data: data)
        })
    }

    /// Sends the report. True once it has reached the team.
    @discardableResult
    func send() async -> Bool {
        guard canSend else { return false }
        isSending = true
        error = nil
        defer { isSending = false }
        do {
            try await service.submit(
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: .bug, pageURL: pageURL, attachments: attachments)
            isSent = true
            return true
        } catch let failure as APIError {
            error = failure.errorDescription ?? SupportFeedbackService.failedMessage
        } catch {
            self.error = SupportFeedbackService.failedMessage
        }
        return false
    }
}
