import Foundation

/// A folder as the file browser lists it, carrying the counts that deleting it has to state.
///
/// The counts are taken from the tree `/user-files` returned, all the way down, because
/// `delete-folder` is recursive: it walks every descendant out of the index and removes the whole
/// subtree (`sync-server.js:14582-14640`). A confirmation that counted only the top level would
/// understate what goes, which is the one number it exists to get right.
struct FolderSummary: Equatable, Identifiable, Sendable {
    let name: String
    /// Relative to the storage root and `/`-joined, exactly as `/user-files` reports it. This is
    /// the value every folder route takes, so it is never rebuilt from the display name.
    let path: String
    let created: Date?
    /// Every document under this folder, at any depth.
    let documentCount: Int
    /// Every folder under this folder, at any depth.
    let subfolderCount: Int
    /// Folders directly inside this one — what the row's subtitle counts, as the web's card does
    /// (`src/pages/MyFilesPage.jsx:358-360`).
    let childFolderCount: Int

    var id: String { path }

    /// The name as a person wrote it. Display only; see `DisplayText.fileName`.
    var displayName: String { DisplayText.fileName(name) }

    /// Where the folder sits, written out — "Bakshi / 2025 / Writs" — for a list that shows
    /// folders from several levels at once and has to tell two "2025"s apart.
    var breadcrumb: String {
        path.split(separator: "/").map { DisplayText.fileName(String($0)) }.joined(separator: " / ")
    }

    /// "12 documents · 3 folders", or "Empty".
    var contentsSummary: String {
        guard documentCount > 0 || childFolderCount > 0 else { return "Empty" }
        var parts = [FileBrowser.count(documentCount, "document")]
        if childFolderCount > 0 { parts.append(FileBrowser.count(childFolderCount, "folder")) }
        return parts.joined(separator: " · ")
    }
}

/// One folder's contents, in the order the web lists them.
struct FolderListing: Equatable, Sendable {
    let path: String
    var folders: [FolderSummary]
    var files: [FileNode.StoredFile]

    var isEmpty: Bool { folders.isEmpty && files.isEmpty }
}

/// The Recent view: newest first, capped, and honest about both the cap and the undated.
struct RecentFiles: Equatable, Sendable {
    var files: [FileNode.StoredFile]
    /// How many files matched before the cap. Stated on screen when it exceeds `files.count`,
    /// because a truncated list that looks complete is the same lie as a mis-sorted one
    /// (`src/pages/MyFilesPage.jsx:47-51`).
    var totalMatched: Int
    /// Files among `files` with no usable date. They cannot be placed in date order, so they are
    /// listed last, by name, and called out rather than interleaved at an arbitrary point.
    var undatedCount: Int

    var isTruncated: Bool { totalMatched > files.count }

    /// Why the last rows are where they are, when any of them has no date.
    var undatedNote: String? {
        switch undatedCount {
        case 0: return nil
        case 1: return "One document has no date, so it is listed last, by name."
        default: return "\(undatedCount) documents have no date, so they are listed last, by name."
        }
    }

    /// That the list stops short, and how to reach the rest.
    var truncationNote: String? {
        guard isTruncated else { return nil }
        return "Showing the \(files.count) most recent of \(totalMatched). Search, or open the "
            + "folder, to reach the rest."
    }
}

/// What a search inside a folder found: matching folders, and documents with where they live.
struct LibrarySearchResults: Equatable, Sendable {
    var folders: [FolderSummary]
    var files: [FileNode.StoredFile]

    var isEmpty: Bool { folders.isEmpty && files.isEmpty }
}

/// Reading the document tree for browsing, as distinct from picking.
///
/// `FileService.allFiles` flattens folders away, which is right for the attach picker and wrong
/// here: an empty folder is still a folder someone made, and a sub-folder is how a matter is
/// organised. Everything in this type is a pure function of the tree `/user-files` returned, so
/// the browser re-derives what it shows after every refetch rather than patching a copy.
enum FileBrowser {

    /// Recent is a scan surface, not an archive. The web caps it at fifty and says so
    /// (`RECENT_LIMIT`, `src/pages/MyFilesPage.jsx:52`).
    static let recentLimit = 50

    // MARK: - Walking

    /// The children of the folder at `path`, or the top level for the root.
    ///
    /// `nil` means **the folder is not in the tree** — deleted or renamed from another device, or
    /// on the web — which a screen showing that folder has to say rather than render as empty.
    static func children(at path: String, in tree: [FileNode]) -> [FileNode]? {
        let target = normalized(path)
        guard !target.isEmpty else { return tree }
        for node in tree {
            guard case .folder(let folder) = node else { continue }
            if folder.path == target { return folder.files ?? [] }
            if target.hasPrefix(folder.path + "/"),
               let found = children(at: target, in: folder.files ?? []) {
                return found
            }
        }
        return nil
    }

    /// The folder at `path` itself, summarised. `nil` for the root, which is not a folder.
    static func folder(at path: String, in tree: [FileNode]) -> FolderSummary? {
        let target = normalized(path)
        guard !target.isEmpty else { return nil }
        return allFolders(in: tree).first { $0.path == target }
    }

    static func listing(at path: String, in tree: [FileNode]) -> FolderListing? {
        guard let nodes = children(at: path, in: tree) else { return nil }
        var folders: [FolderSummary] = []
        var files: [FileNode.StoredFile] = []
        for node in nodes {
            switch node {
            case .folder(let folder): folders.append(summary(of: folder))
            case .file(let file): files.append(file)
            }
        }
        return FolderListing(
            path: normalized(path),
            folders: sortedFolders(folders),
            files: sortedByName(files))
    }

    static func summary(of folder: FileNode.Folder) -> FolderSummary {
        let children = folder.files ?? []
        return FolderSummary(
            name: folder.name,
            path: folder.path,
            created: WireDate.parse(folder.created),
            documentCount: documentCount(in: children),
            subfolderCount: subfolderCount(in: children),
            childFolderCount: children.reduce(0) { count, node in
                if case .folder = node { return count + 1 }
                return count
            })
    }

    /// Every folder in the tree, parents before their children and siblings in browse order —
    /// the shape a "Move to…" list reads naturally in.
    static func allFolders(in tree: [FileNode]) -> [FolderSummary] {
        var out: [FolderSummary] = []
        func walk(_ nodes: [FileNode]) {
            let folders = nodes.compactMap { node -> FileNode.Folder? in
                if case .folder(let folder) = node { return folder }
                return nil
            }
            let ordered = sortedFolders(folders.map(summary(of:)))
            for summary in ordered {
                out.append(summary)
                if let folder = folders.first(where: { $0.path == summary.path }) {
                    walk(folder.files ?? [])
                }
            }
        }
        walk(tree)
        return out
    }

    /// Every document under `path`, at any depth.
    static func files(under path: String, in tree: [FileNode]) -> [FileNode.StoredFile] {
        FileService.allFiles(in: children(at: path, in: tree) ?? [])
    }

    static func documentCount(in nodes: [FileNode]) -> Int {
        nodes.reduce(0) { count, node in
            switch node {
            case .file: return count + 1
            case .folder(let folder): return count + documentCount(in: folder.files ?? [])
            }
        }
    }

    static func subfolderCount(in nodes: [FileNode]) -> Int {
        nodes.reduce(0) { count, node in
            guard case .folder(let folder) = node else { return count }
            return count + 1 + subfolderCount(in: folder.files ?? [])
        }
    }

    // MARK: - The three views

    /// Newest first, by the file's `modified` time.
    ///
    /// `modified` is the one honest timestamp a file entry carries — `/user-files` builds a file
    /// with `modified: stats.mtime` and no `created` at all (`sync-server.js:14362-14371`), and
    /// the web sorts Recent on it for that reason (`fileTime`, `src/pages/MyFilesPage.jsx:79-82`).
    /// A file with no parseable date is never placed by guesswork: it sinks below every dated
    /// file and is ordered by name among its kind.
    static func recent(
        in tree: [FileNode], matching query: String = "", limit: Int = recentLimit
    ) -> RecentFiles {
        let all = FileService.allFiles(in: tree)
        let matched = matches(query, all)
        let dated = matched.map { (file: $0, time: WireDate.parse($0.modified)) }
        let sorted = dated.sorted { a, b in
            switch (a.time, b.time) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return nameOrder(a.file, b.file)
            }
        }
        let shown = Array(sorted.prefix(max(0, limit)))
        return RecentFiles(
            files: shown.map(\.file),
            totalMatched: matched.count,
            undatedCount: shown.filter { $0.time == nil }.count)
    }

    /// Everything starred, grouped by where it lives and then by name — the web's order
    /// (`src/pages/MyFilesPage.jsx:636`), so a matter's starred papers sit together.
    static func favorites(in tree: [FileNode], matching query: String = "") -> [FileNode.StoredFile] {
        let starred = FileService.allFiles(in: tree).filter { $0.favorite == true }
        return matches(query, starred).sorted { a, b in
            let folderOrder = a.folderPath.localizedStandardCompare(b.folderPath)
            if folderOrder != .orderedSame { return folderOrder == .orderedAscending }
            return nameOrder(a, b)
        }
    }

    /// Whether anything at all is starred, so an empty Favorites can tell "nothing starred" from
    /// "nothing starred matches".
    static func hasFavorites(in tree: [FileNode]) -> Bool {
        FileService.allFiles(in: tree).contains { $0.favorite == true }
    }

    /// A search inside one folder reaches everything beneath it, not only what is on screen.
    ///
    /// On the web the search box filters each open folder card in place. A phone shows one folder
    /// at a time, so filtering in place would hide a document one level down from the person
    /// looking for it — the search therefore covers the subtree, and each document row carries
    /// its folder so a hit two levels down is still recognisable.
    static func search(_ query: String, under path: String, in tree: [FileNode]) -> LibrarySearchResults {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let nodes = children(at: path, in: tree)
        else { return LibrarySearchResults(folders: [], files: []) }
        let needle = searchKey(query)
        let base = normalized(path)
        let folders = allFolders(in: nodes).filter { searchKey($0.name).contains(needle) }
        // Matched on the path *below* this folder. Matching the full path would make a search
        // for the folder's own name — the matter, typically — return every document in it.
        let prefix = base + "/"
        let files = FileService.allFiles(in: nodes).filter { file in
            let relative = !base.isEmpty && file.path.hasPrefix(prefix)
                ? String(file.path.dropFirst(prefix.count))
                : file.path
            return searchKey(relative).contains(needle)
        }.sorted { a, b in
            let folderOrder = a.folderPath.localizedStandardCompare(b.folderPath)
            if folderOrder != .orderedSame { return folderOrder == .orderedAscending }
            return nameOrder(a, b)
        }
        return LibrarySearchResults(folders: folders, files: files)
    }

    // MARK: - Ordering

    /// Folders newest first, then by name — the order the web's store gives every level of the
    /// tree (`decorateFolders`, `src/lib/store.js:202-207`).
    static func sortedFolders(_ folders: [FolderSummary]) -> [FolderSummary] {
        folders.sorted { a, b in
            switch (a.created, b.created) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.path < b.path : order == .orderedAscending
            }
        }
    }

    /// Documents by name.
    ///
    /// The web falls through to `localeCompare` here, which orders "Annexure_10" before
    /// "Annexure_2". This uses the system's numeric-aware comparison instead, because a bundle's
    /// annexures are numbered and a practitioner scanning for A-2 looks after A-1, not after A-19.
    static func sortedByName(_ files: [FileNode.StoredFile]) -> [FileNode.StoredFile] {
        files.sorted(by: nameOrder)
    }

    private static func nameOrder(_ a: FileNode.StoredFile, _ b: FileNode.StoredFile) -> Bool {
        let order = a.name.localizedStandardCompare(b.name)
        return order == .orderedSame ? a.path < b.path : order == .orderedAscending
    }

    // MARK: - Wording

    /// Where a document lives, for a flat list where the folder is not otherwise on screen.
    ///
    /// Recent and Favorites are flat by design, so the folder has to travel with the row or the
    /// document loses its context (`src/pages/MyFilesPage.jsx:315-318`).
    static func location(of file: FileNode.StoredFile) -> String {
        let folder = file.folderPath
        guard !folder.isEmpty else { return "My Files" }
        return folder.split(separator: "/").map { DisplayText.fileName(String($0)) }
            .joined(separator: " / ")
    }

    /// "Today", "Yesterday", or the date — in India.
    ///
    /// Relative wording earns its place only while it is shorter and clearer than the date
    /// (`relDay`, `src/pages/MyFilesPage.jsx:90-96`); past yesterday, "5 days ago" makes the
    /// reader do subtraction to recover the date they wanted. The day is India's, as every date
    /// in this product is.
    static func dayLabel(for date: Date, now: Date = Date()) -> String {
        let key = WireDate.dayKey(date)
        if key == WireDate.dayKey(now) { return "Today" }
        if key == WireDate.dayKey(now.addingTimeInterval(-86_400)) { return "Yesterday" }
        return shortDate(date)
    }

    /// The web's `fmtDate`: `en-IN`, day / short month / year, in India — "3 Oct 2026".
    ///
    /// The month names are spelled out rather than taken from a `DateFormatter`, because `en-IN`
    /// abbreviates September as "Sept" and the formatters on the two platforms this builds for do
    /// not agree about that. `FileDateGoldenTests` holds this to the platform's own output.
    static func shortDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WireDate.india
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              (1...12).contains(month)
        else { return "" }
        return "\(day) \(monthNames[month - 1]) \(year)"
    }

    private static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec",
    ]

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    // MARK: - Plumbing

    /// Strips the separators a caller might add. `/user-files` never sends them, but a path that
    /// has been round-tripped through a screen should still find its folder.
    static func normalized(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .joined(separator: "/")
    }

    /// Case-insensitive, and blind to the difference between a space and an underscore, because
    /// names are underscore-sanitised on disk and a person types spaces. The same rule as
    /// `FileService.search`, which matches on the whole path so a matter's name finds its papers.
    private static func matches(_ query: String, _ files: [FileNode.StoredFile]) -> [FileNode.StoredFile] {
        FileService.search(query, in: files)
    }

    private static func searchKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }
}
