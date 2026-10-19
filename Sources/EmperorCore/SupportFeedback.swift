import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// "Report a bug" — the web's Help menu → Report a bug (`src/shell/BugReportModal.jsx`). It writes
// to the same support inbox as the web's feedback panel, tagged `kind: bug`, so a report from the
// phone lands where the team already triages the web's. Distinct from `FeedbackService`, which
// reports one *answer* to `/draft-feedback`; this reports the app.

/// Which inbox tab a report is filed under. The server keeps a closed set and files anything it
/// does not recognise as feedback, so the wire value is decided here, never passed through.
enum SupportFeedbackKind: String, Equatable, Sendable {
    case bug
    case feedback

    /// `bug` stays `bug`; anything else is `feedback` — the coercion the web and the server
    /// both apply.
    init(wire: String?) {
        self = wire == SupportFeedbackKind.bug.rawValue ? .bug : .feedback
    }
}

/// A file sent with a report — on this client, a screenshot.
struct SupportAttachment: Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var contentType: String
    var data: Data

    init(id: UUID = UUID(), name: String, contentType: String, data: Data) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.data = data
    }
}

/// The multipart body for `POST /support-feedback`, as the web's `submitSupportFeedback` builds
/// its `FormData`: `description`, `userId`, `kind`, `pageUrl`, then each file as `file_0`,
/// `file_1`, … with its own name.
enum SupportFeedbackBody {
    struct Fields: Equatable, Sendable {
        var description: String
        /// The signed-in account's id, or `guest`, as the web sends it — beside the bearer token,
        /// as on every request.
        var userID: String
        var kind: SupportFeedbackKind
        /// Where the report was made from — the web sends the page's path; this client sends the
        /// screen's name.
        var pageURL: String

        var formFields: [(String, String)] {
            [("description", description), ("userId", userID), ("kind", kind.rawValue), ("pageUrl", pageURL)]
        }
    }

    static func contentType(boundary: String) -> String { MultipartChunk.contentType(boundary: boundary) }

    static func body(fields: Fields, attachments: [SupportAttachment], boundary: String) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in fields.formFields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        for (index, file) in attachments.enumerated() {
            // A part is read as a file only when it carries a non-empty `filename`, so every one
            // is given a name.
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"file_\(index)\"; filename=\"\(filename(file.name, index: index))\"\r\n")
            append("Content-Type: \(file.contentType)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }

    /// A name that cannot break the part's header: no quotes, no line breaks, never empty — the
    /// web's fallback, `attachment_<n>`, when nothing is left.
    static func filename(_ raw: String, index: Int) -> String {
        let cleaned = raw.unicodeScalars
            .map { scalar -> String in
                switch scalar {
                case "\"", "\r", "\n", "\\": return "_"
                default: return String(scalar)
                }
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "attachment_\(index)" : cleaned
    }
}

protocol SupportFeedbackProviding: Sendable {
    /// Files a report. Returns the inbox row's id when the server gives one.
    @discardableResult
    func submit(
        description: String, kind: SupportFeedbackKind, pageURL: String,
        attachments: [SupportAttachment]
    ) async throws -> Int?
}

/// `POST /support-feedback`, as multipart.
///
/// Limits, as the platform sets them: the web's dialog takes at most twelve files, and the
/// server refuses a request body over 60 MB as a whole (413). A description is required — an
/// empty one is a 400. All three are checked here first, so a report that cannot be accepted is
/// never sent. Never retried: a report that reached the server is filed, and a second would file
/// it twice.
struct SupportFeedbackService: SupportFeedbackProviding {
    let client: APIClient
    var newBoundary: @Sendable () -> String = { MultipartChunk.boundary() }

    static let maxAttachments = 12
    /// The server's whole-body ceiling, less room for the fields and part headers.
    static let maxAttachmentBytes = 60 * 1024 * 1024 - 256 * 1024

    static let emptyMessage = "Describe what happened before sending."
    static let tooManyMessage = "At most \(maxAttachments) screenshots can go with one report."
    static let tooLargeMessage =
        "These screenshots are too large to send together. Remove some and try again."
    static let failedMessage = "Could not send — please try again."

    /// Why a report cannot be sent as it stands, or `nil` when it can.
    static func refusal(description: String, attachments: [SupportAttachment]) -> String? {
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return emptyMessage }
        if attachments.count > maxAttachments { return tooManyMessage }
        if attachments.reduce(0, { $0 + $1.data.count }) > maxAttachmentBytes { return tooLargeMessage }
        return nil
    }

    @discardableResult
    func submit(
        description: String, kind: SupportFeedbackKind, pageURL: String,
        attachments: [SupportAttachment]
    ) async throws -> Int? {
        if let refusal = Self.refusal(description: description, attachments: attachments) {
            throw APIError.server(status: 400, message: refusal)
        }
        let userID = await client.currentCredentials()?.userIDString ?? "guest"
        let boundary = newBoundary()
        var request = try await client.makeRequest("POST", "/support-feedback")
        request.setValue(SupportFeedbackBody.contentType(boundary: boundary), forHTTPHeaderField: "Content-Type")
        request.httpBody = SupportFeedbackBody.body(
            fields: .init(
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                userID: userID, kind: kind, pageURL: pageURL),
            attachments: attachments, boundary: boundary)

        let (data, http) = try await client.perform(request)
        let answer = try? JSONDecoder().decode(Answer.self, from: data)
        if (200..<300).contains(http.statusCode), answer?.success == true {
            return answer?.id
        }
        throw Self.failure(status: http.statusCode, answer: answer, body: data)
    }

    static func failure(status: Int, answer: Answer?, body: Data) -> APIError {
        if status == 413 { return .server(status: 413, message: tooLargeMessage) }
        if let message = answer?.error?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return .server(status: status, message: message)
        }
        if (200..<300).contains(status) { return .server(status: status, message: failedMessage) }
        return APIError.classify(status: status, body: body)
    }

    struct Answer: Decodable, Sendable {
        var success: Bool?
        var id: Int?
        var error: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            success = try? c.decodeIfPresent(Bool.self, forKey: .success)
            id = try? c.decodeIfPresent(Int.self, forKey: .id)
            error = try? c.decodeIfPresent(String.self, forKey: .error)
        }

        enum CodingKeys: String, CodingKey { case success, id, error }
    }
}
