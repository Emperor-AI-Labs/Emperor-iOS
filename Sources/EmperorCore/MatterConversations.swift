import Foundation

// A matter's own conversations and the files they read (docs/projects.md, "Ask Emperor").
//
// A conversation asked from a matter carries the matter's id on every turn, reads only that
// matter's documents, and is listed in the matter rather than in History. These are the pieces
// the core needs for that: the rows `GET /project` lists under `chats`, and the matter's storage
// tree flattened into the `{folderName, fileName}` pairs a turn and the chronology reader name a
// document by.

/// One of a matter's conversations, as `GET /project` lists it under `chats`.
///
/// `updated_at` is the chat's own (zoneless SQLite); `linked_at` is set when the chat was put in
/// the matter the older way, through a link row, and is `null` otherwise.
struct ProjectChatRow: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String?
    var updatedAtRaw: String?
    var linkedAtRaw: String?

    init(id: String, title: String? = nil, updatedAtRaw: String? = nil, linkedAtRaw: String? = nil) {
        self.id = id
        self.title = title
        self.updatedAtRaw = updatedAtRaw
        self.linkedAtRaw = linkedAtRaw
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeFlexibleString(forKey: .id) ?? ""
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        updatedAtRaw = try? c.decodeIfPresent(String.self, forKey: .updatedAtRaw)
        linkedAtRaw = try? c.decodeIfPresent(String.self, forKey: .linkedAtRaw)
    }

    enum CodingKeys: String, CodingKey {
        case id, title
        case updatedAtRaw = "updated_at"
        case linkedAtRaw = "linked_at"
    }

    /// When the conversation last moved: its own update, else when it joined the matter.
    var lastActivity: Date? { WireDate.parseAny(updatedAtRaw) ?? WireDate.parseAny(linkedAtRaw) }

    /// The title to show. A chat the server made before its first question is stored as
    /// "New Chat", and a few older ones as "Untitled …" — those read as "New conversation", as
    /// the web's matter rail does.
    var displayTitle: String {
        Self.isPlaceholderTitle(title) ? "New conversation" : (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The web's `isPlaceholderTitle`: empty, "New chat", "AI chat", "Untitled", "Untitled chat",
    /// "Untitled session" or "Untitled conversation", in any case.
    static func isPlaceholderTitle(_ title: String?) -> Bool {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let placeholders: Set<String> = [
            "", "new chat", "ai chat", "untitled", "untitled chat", "untitled session", "untitled conversation",
        ]
        return placeholders.contains(trimmed)
    }

    /// Newest first, by `lastActivity`; a row with no parseable time goes last. Stable for ties.
    static func newestFirst(_ rows: [ProjectChatRow]) -> [ProjectChatRow] {
        rows.enumerated().sorted { a, b in
            let ta = a.element.lastActivity?.timeIntervalSince1970 ?? 0
            let tb = b.element.lastActivity?.timeIntervalSince1970 ?? 0
            return ta == tb ? a.offset < b.offset : ta > tb
        }.map(\.element)
    }
}

/// One document in a matter's own storage, as the conversation picker and the chronology reader
/// name it.
struct MatterFile: Equatable, Identifiable, Hashable, Sendable {
    /// `<folderName>/<name>` — unique within the matter.
    let key: String
    let name: String
    /// The folder relative to the user's root: `_projects/<id>/Pleadings`.
    let folderName: String
    /// The folder inside the matter (`Pleadings`), or empty for a file at the matter's root.
    let sub: String
    /// Read and indexed, so a turn or the chronology reader can use it.
    let isReady: Bool
    /// The server's status line, for a file that is not ready.
    let status: String

    var id: String { key }

    /// The same document, as a turn attaches it.
    var attachment: ChatAttachment { ChatAttachment(name: name, folderName: folderName) }

    /// "still processing" or "could not be read", for a file that cannot be chosen yet.
    var notReadyLine: String? {
        guard !isReady else { return nil }
        return status.uppercased().hasPrefix("ERROR") ? "could not be read" : "still processing"
    }

    /// The matter's storage folder, relative to the user's root.
    static func root(projectID: String) -> String { "_projects/\(projectID)" }

    /// The matter's tree as one flat list, folders first, as the web's `flattenFiles` does.
    ///
    /// `path` is relative to the user's root (`_projects/<id>/Pleadings/Plaint.pdf`), so the
    /// folder a file sits in is everything before its last `/`; a path with none is at the
    /// matter's root.
    static func flatten(_ tree: [FileNode], projectID: String) -> [MatterFile] {
        let root = Self.root(projectID: projectID)
        var out: [MatterFile] = []
        func walk(_ nodes: [FileNode]) {
            for node in nodes {
                switch node {
                case .folder(let folder):
                    walk(folder.files ?? [])
                case .file(let file):
                    let path = file.path.isEmpty ? file.name : file.path
                    let folderName: String
                    if let cut = path.lastIndex(of: "/"), cut > path.startIndex {
                        folderName = String(path[..<cut])
                    } else {
                        folderName = root
                    }
                    let sub = folderName.hasPrefix(root + "/") ? String(folderName.dropFirst(root.count + 1)) : ""
                    let status = file.status ?? ""
                    out.append(MatterFile(
                        key: "\(folderName)/\(file.name)", name: file.name, folderName: folderName, sub: sub,
                        isReady: status == "ready" || status == "scanned", status: status))
                }
            }
        }
        walk(tree)
        return out
    }
}
