import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Observation
#endif

// MARK: - The link

/// A link to a conversation someone has shared — the web's read-only `/share/:shareId` page.
///
/// Three spellings lead to the same conversation:
///
/// - `emperor://share/<id>` (and `emperor:share/<id>`), the app's own scheme;
/// - `https://<the web app's host>/share/<id>`, the link the web hands out. It reaches the app
///   only as a Universal Link, which needs the associated-domains entitlement this build does not
///   carry (README, "Shared conversations"); it is read here so that it works the day it does.
///
/// Only the host this build talks to is accepted (`webHosts(for:)`): a share id belongs to one
/// deployment, so a development link opened in a production build would name nothing there.
///
/// Like every `emperor://` link (`EmperorLink`), this only **navigates**. Opening a shared
/// conversation reads it; nothing is written, and no account is involved.
enum SharedChatLink {
    /// The id in `url`, or `nil` when `url` is not a shared-conversation link this build reads.
    static func shareID(in url: URL, webHosts: Set<String>) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased()
        else { return nil }

        let segments: [String]
        switch scheme {
        case EmperorLink.scheme:
            // `emperor://share/<id>` puts `share` in the host; `emperor:share/<id>` has no host.
            let joined = [components.host ?? "", components.path].joined(separator: "/")
            segments = joined.split(separator: "/").map(String.init)
        case "https":
            guard let host = components.host?.lowercased(), webHosts.contains(host) else {
                return nil
            }
            segments = components.path.split(separator: "/").map(String.init)
        default:
            return nil
        }

        guard segments.count == 2, segments[0].lowercased() == "share",
              isValidID(segments[1])
        else { return nil }
        return segments[1]
    }

    /// The web hosts whose `/share/` links this build opens: the one its API lives on.
    static func webHosts(for environment: APIEnvironment) -> Set<String> {
        guard let host = environment.baseURL.host?.lowercased() else { return [] }
        return [host]
    }

    /// The app's own link to a shared conversation.
    static func url(for shareID: String) -> URL? {
        guard isValidID(shareID) else { return nil }
        return URL(string: "\(EmperorLink.scheme)://share/\(shareID)")
    }

    /// Letters, digits, `-` and `_`, up to 64 of them. The platform makes its ids from letters
    /// and digits; anything else — a slash, a `?`, a `..` — would address something other than
    /// a shared conversation once it is put into a path, so it is not a share id.
    static func isValidID(_ raw: String) -> Bool {
        guard (1...64).contains(raw.count) else { return false }
        return raw.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
    }
}

// MARK: - The conversation

/// One turn of a shared conversation, ready to draw.
struct SharedChatEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The question as it was asked, and the documents it carried, by name.
        case question(text: String, attachments: [String])
        /// The answer, its control tags already removed (`StreamContent`).
        case answer(StreamContent)
    }

    /// The turn's position in the conversation.
    let id: Int
    let kind: Kind
}

/// A shared conversation as `GET /shared-chat/:shareId` returns it: `{id, title, role,
/// updated_at, messages}`, the messages exactly as the conversation stores them.
///
/// Decoded straight into what the screen draws, so nothing account-shaped — the stored message
/// keys, the work log — travels further than this initialiser.
struct SharedConversation: Decodable, Equatable, Sendable {
    /// The conversation's title, or a plain stand-in when it has none.
    var title: String
    /// The role the conversation was asked in, as the wire carries it (`ChatRole`'s raw value).
    var role: String?
    /// SQLite's `CURRENT_TIMESTAMP`, zoneless UTC.
    var updatedAtRaw: String?
    var entries: [SharedChatEntry]

    static let untitled = "Shared conversation"

    init(title: String, role: String?, updatedAtRaw: String?, entries: [SharedChatEntry]) {
        self.title = title
        self.role = role
        self.updatedAtRaw = updatedAtRaw
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case title, role, messages
        case updatedAtRaw = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawTitle = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        let trimmedTitle = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = trimmedTitle.isEmpty ? Self.untitled : trimmedTitle
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? nil
        updatedAtRaw = (try? c.decodeIfPresent(String.self, forKey: .updatedAtRaw)) ?? nil

        // An array, as the server sends it. The web page also accepts the array as a JSON
        // string, so this does too. One unreadable message costs only itself.
        var messages: [ChatMessage] = []
        if let list = try? c.decode([LossyMessage].self, forKey: .messages) {
            messages = list.compactMap(\.message)
        } else if let text = try? c.decode(String.self, forKey: .messages),
                  let list = try? JSONDecoder().decode([LossyMessage].self, from: Data(text.utf8)) {
            messages = list.compactMap(\.message)
        }
        entries = Self.entries(from: messages)
    }

    private struct LossyMessage: Decodable {
        let message: ChatMessage?
        init(from decoder: Decoder) throws {
            message = try? ChatMessage(from: decoder)
        }
    }

    /// The turns worth drawing, in order.
    ///
    /// A system message is not part of the exchange and is left out; so is a turn with nothing
    /// to show — an answer that never arrived, say. An answer's citations are left out too: they
    /// open documents in the library of whoever asked, which the reader of a shared link cannot
    /// open. The answer's own words, its References and its drafts are all there.
    static func entries(from messages: [ChatMessage]) -> [SharedChatEntry] {
        var entries: [SharedChatEntry] = []
        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let files = attachmentNames(from: message.attachments)
                guard !text.isEmpty || !files.isEmpty else { continue }
                entries.append(SharedChatEntry(
                    id: entries.count, kind: .question(text: text, attachments: files)))
            case .assistant:
                var content = StreamContent.parse(message.content)
                content.mentions = []
                guard !content.prose.isEmpty || !content.artifacts.isEmpty
                        || !content.errors.isEmpty || content.wasInterrupted
                else { continue }
                entries.append(SharedChatEntry(id: entries.count, kind: .answer(content)))
            }
        }
        return entries
    }

    /// The names of the documents a question carried, read as the web page reads them: a bare
    /// string is the name; an object's `name`, else its `filename`, else "Document".
    static func attachmentNames(from values: [JSONValue]?) -> [String] {
        (values ?? []).compactMap { value in
            switch value {
            case .string(let name):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case .object(let object):
                for key in ["name", "filename"] {
                    if case .string(let name)? = object[key] {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return trimmed }
                    }
                }
                return "Document"
            default:
                return nil
            }
        }
    }

    // MARK: Display

    /// The role, as the app names it — "Arbitrator or Judge" for `Judicial Officer` — or as the
    /// wire carries it when this build does not know it. `nil` when there is none.
    var roleLabel: String? {
        guard let raw = role?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return ChatRole(rawValue: raw)?.label ?? raw
    }

    var updatedAt: Date? { WireDate.parse(updatedAtRaw) }

    /// "17 October 2026, 3:42 pm IST" — the web page's date, in India's time, as it says.
    var updatedLabel: String? {
        updatedAt.map { Self.istFormatter.string(from: $0) + " IST" }
    }

    nonisolated(unsafe) private static let istFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = WireDate.india
        f.dateFormat = "d MMMM yyyy, h:mm a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()
}

// MARK: - The service

protocol SharedChatProviding: Sendable {
    func sharedChat(id: String) async throws -> SharedConversation
}

/// `GET /shared-chat/:shareId` — a conversation its owner has shared, read the way the web's
/// `/share/:shareId` page reads it.
///
/// The page is public on the web and needs no sign-in, and so does this: the request carries no
/// token and no `userId`, signed in or not. A shared conversation is read as anyone holding the
/// link would read it, and the reader's account has no part in it.
///
/// Creating a link (`POST /share-chat`) is not here — see README, "Built and deliberately held
/// back".
struct SharedChatService: SharedChatProviding {
    let client: APIClient

    func sharedChat(id: String) async throws -> SharedConversation {
        guard SharedChatLink.isValidID(id) else {
            throw APIError.server(status: 404, message: "Shared chat not found")
        }
        return try await withRetry {
            var request = try await client.makeRequest(
                "GET", "/shared-chat/\(id)", requiresAuth: false)
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "X-Auth-Token")
            return try await client.send(request, as: SharedConversation.self)
        }
    }
}

// MARK: - Links waiting to be shown

/// A shared conversation the app has been asked to show, waiting for the screen that shows it.
///
/// Not part of `AppNavigator`, deliberately. The navigator belongs to the signed-in tab view and
/// is thrown away at sign-out; a shared conversation needs no account, so its link is shown over
/// whatever the app is showing — the sign-in screen included, as the web shows it to anyone. The
/// only thing it waits for is the first-launch disclaimer, and for any sheet already up to close.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class SharedChatRequests {
    /// The share id waiting to be shown, not yet taken.
    private(set) var pending: String?
    /// Counts requests, so the same link opened twice is still a change to observe.
    private(set) var requestCount = 0

    init() {}

    /// Asks for the conversation behind `shareID`. An id that is not one is ignored. The latest
    /// request wins.
    func open(_ shareID: String) {
        guard SharedChatLink.isValidID(shareID) else { return }
        pending = shareID
        requestCount += 1
    }

    /// The waiting id, once. Taking it clears it.
    func take() -> String? {
        defer { pending = nil }
        return pending
    }
}

// MARK: - The screen's state

/// The read-only view of a shared conversation: its title, the role it was asked in, when it was
/// last updated, and every question and answer.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class SharedChatViewModel {
    let shareID: String
    private let service: any SharedChatProviding

    private(set) var state: LoadState = .idle
    private(set) var conversation: SharedConversation?
    /// The link leads nowhere — never shared, or the conversation is gone. Not worth retrying.
    private(set) var isNotFound = false

    static let notFoundTitle = "Conversation not found"
    static let notFoundMessage =
        "This link does not lead to a shared conversation. It may be mistyped, or the "
        + "conversation may no longer exist."

    init(shareID: String, service: any SharedChatProviding) {
        self.shareID = shareID
        self.service = service
    }

    func load() async {
        guard !state.isLoading else { return }
        state = .loading
        do {
            conversation = try await service.sharedChat(id: shareID)
            isNotFound = false
            state = .loaded
        } catch {
            if case APIError.server(let status, _) = error, status == 404 {
                isNotFound = true
                var failure = LoadFailure(error)
                failure.message = Self.notFoundMessage
                state = .failed(failure)
            } else {
                isNotFound = false
                state = .failed(LoadFailure(error))
            }
        }
    }

    /// Whether the conversation holds anything to read.
    var isEmpty: Bool { conversation?.entries.isEmpty ?? true }
}
