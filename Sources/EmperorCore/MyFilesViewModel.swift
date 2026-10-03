import Foundation
#if canImport(Darwin)
import Observation
#endif

/// A document's bytes, fetched to hand to the share sheet.
struct SharedDocument: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// The on-disk name, which is what the receiving app should see: it carries the extension,
    /// and it is the name the document is cited by.
    let fileName: String
    let data: Data
}

/// The document library as a place to manage documents, rather than a picker.
///
/// The web gave My Files a page of its own (`src/pages/MyFilesPage.jsx`, the sidebar's "My Files"
/// row, `src/shell/Sidebar.jsx:259`) so the drawer could stay a picker. This is that page:
/// browse the folders, read a document, rename it, star it, share it, move it, delete it, and put
/// new ones into the folder you are looking at. The attach picker (`FileLibraryViewModel`) is
/// unchanged and still lives behind the composer's plus.
///
/// Three views, the web's three live ones and in its order — Recent, the folders, Favorites
/// (`TABS`, `src/pages/MyFilesPage.jsx:41-49`). The web also lists "Shared Files" and "Linked
/// Accounts", both of which it marks as not built; a phone has no room for a tab that only says
/// so, and they are left out.
///
/// Every edit is followed by a refetch rather than a local patch, with one exception — a star,
/// whose response states the stored value exactly. `delete-file` and `delete-folder` succeed on a
/// path that is not there, so "it worked" is never evidence of what the library now holds.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class MyFilesViewModel {

    enum Section: String, CaseIterable, Identifiable, Sendable {
        case recent, folders, favorites

        var id: String { rawValue }

        /// The web's labels, except that its "My Files" tab is "Folders" here: the whole screen
        /// is already called My Files, and a tab of the same name inside it reads as a mistake.
        var title: String {
            switch self {
            case .recent: return "Recent"
            case .folders: return "Folders"
            case .favorites: return "Favorites"
            }
        }
    }

    /// What an empty list says. Separate from failure, always — see `LoadState`.
    struct EmptyCopy: Equatable, Sendable {
        let title: String
        let message: String
        let systemImage: String
    }

    private(set) var tree: [FileNode] = []
    private(set) var state: LoadState = .idle

    /// Recent first, as on the web: it answers "where is the thing I just uploaded", which is the
    /// commonest reason to open this screen.
    var section: Section = .recent
    /// Follows the user between sections, as the web's single search box does, so "where did I
    /// put that" can be answered by switching sections rather than retyping.
    var query = ""

    /// The item an edit is running against, so one row shows it rather than the whole list.
    /// The empty string means an edit with no single row, such as creating a folder.
    private(set) var busyID: String?
    var actionError: String?
    var actionNotice: String?

    /// Non-nil while a confirmation is on screen. Only `confirmDeletion` acts on it.
    var pendingDeletion: FileDeletion?
    /// Non-nil once a document's bytes have arrived for the share sheet.
    var sharing: SharedDocument?

    private let service: any FileProviding
    private let manager: any FileManaging
    private let now: @Sendable () -> Date

    init(
        service: any FileProviding,
        manager: any FileManaging,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.manager = manager
        self.now = now
    }

    // MARK: - Loading

    func load() async {
        state = .loading
        do {
            tree = try await service.tree()
            state = .loaded
        } catch {
            // The tree on screen is kept: a refresh that fails over content shows it with a
            // banner rather than blanking it (`ListPresentation.showsStaleBanner`).
            state = .failed(LoadFailure(error))
        }
    }

    /// Refetches after an edit without flashing the loading state over a list in use.
    private func reload() async {
        do {
            tree = try await service.tree()
            state = .loaded
        } catch {
            // The edit itself succeeded; only the refresh failed. Overwriting the success
            // notice with a load error would say the wrong thing about what just happened.
            actionError = actionError ?? DisplayText.message(for: error)
        }
    }

    var isLoading: Bool { state.isLoading }
    var hasLoaded: Bool { state.hasLoaded }

    // MARK: - What is on screen

    var recent: RecentFiles { FileBrowser.recent(in: tree, matching: query) }

    var favorites: [FileNode.StoredFile] { FileBrowser.favorites(in: tree, matching: query) }

    /// `nil` when the folder is no longer in the library.
    func listing(at path: String) -> FolderListing? {
        FileBrowser.listing(at: path, in: tree)
    }

    func folder(at path: String) -> FolderSummary? {
        FileBrowser.folder(at: path, in: tree)
    }

    func searchResults(under path: String, matching text: String) -> LibrarySearchResults {
        FileBrowser.search(text, under: path, in: tree)
    }

    /// Every folder a document could be moved into, other than the one it is in.
    ///
    /// The storage root is not offered. The web will not put a loose document there either —
    /// its upload dialog asks for a folder first (`src/components/upload/UploadModal.jsx:493`) —
    /// and a document at the root is invisible in its My Files view.
    func moveDestinations(for file: FileNode.StoredFile) -> [FolderSummary] {
        FileBrowser.allFolders(in: tree).filter { $0.path != file.folderPath }
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// For a section's list. `isEmpty` is the *visible* list, so a search that matches nothing
    /// reaches the empty branch, where `emptyCopy` tells it apart from an empty library.
    func presentation(for section: Section) -> ListPresentation {
        let isEmpty: Bool
        switch section {
        case .recent: isEmpty = recent.files.isEmpty
        case .favorites: isEmpty = favorites.isEmpty
        case .folders: isEmpty = listing(at: "")?.isEmpty ?? true
        }
        return ListPresentation(state: state, isEmpty: isEmpty)
    }

    func presentation(forFolder path: String) -> ListPresentation {
        ListPresentation(state: state, isEmpty: listing(at: path)?.isEmpty ?? true)
    }

    /// The library holds documents but the search matched none of them — a different sentence
    /// from having none at all.
    func showsNoSearchResults(in section: Section) -> Bool {
        guard isSearching else { return false }
        switch section {
        case .recent: return !FileService.allFiles(in: tree).isEmpty && recent.files.isEmpty
        case .favorites: return FileBrowser.hasFavorites(in: tree) && favorites.isEmpty
        case .folders: return false
        }
    }

    func emptyCopy(for section: Section) -> EmptyCopy {
        switch section {
        case .recent:
            return EmptyCopy(
                title: "No documents yet",
                message: "Documents you upload will show up here, newest first, whichever folder they land in.",
                systemImage: "clock")
        case .favorites:
            return EmptyCopy(
                title: "Nothing starred yet",
                message: "Star a document to keep it here. Stars are saved to your account, so they follow you to the web.",
                systemImage: "star")
        case .folders:
            return EmptyCopy(
                title: "No folders yet",
                message: "Create a folder for a matter, then upload its documents into it.",
                systemImage: "folder")
        }
    }

    /// What a folder's own screen says when it has nothing to list.
    func emptyCopy(forFolder path: String) -> EmptyCopy {
        guard listing(at: path) != nil else {
            // Not "empty": the folder is gone. Renamed or deleted on the web, or on another
            // phone, between the list being drawn and this screen being opened.
            return EmptyCopy(
                title: "This folder is no longer here",
                message: "It may have been renamed or deleted on another device. Go back to see your library as it is now.",
                systemImage: "folder.badge.questionmark")
        }
        return EmptyCopy(
            title: "This folder is empty",
            message: "Upload documents into it, or create a folder inside it.",
            systemImage: "folder")
    }

    /// "Today", "Yesterday" or the date a document last changed, for the flat lists where that
    /// is the order. `nil` when the server sent no usable date — never a guess.
    func dateLabel(for file: FileNode.StoredFile) -> String? {
        WireDate.parse(file.modified).map { FileBrowser.dayLabel(for: $0, now: now()) }
    }

    // MARK: - Uploading

    /// Where a document picked on a given screen is filed.
    ///
    /// Inside a folder, into that folder. At the top level, into the same fixed folder the attach
    /// picker uses: the web will not put a loose document at the root
    /// (`src/components/upload/UploadModal.jsx:493`), and asking for a folder at the point of
    /// upload is one more reason not to bother.
    nonisolated static func uploadDestination(for path: String) -> String {
        let folder = FileBrowser.normalized(path)
        return folder.isEmpty ? FileLibraryViewModel.uploadFolder : folder
    }

    /// Re-read once an upload reports its document readable. Not before: a 200 on the last chunk
    /// means the bytes arrived, not that the document exists yet.
    func uploadDidFinish() async { await reload() }

    // MARK: - Editing documents

    func isBusy(_ id: String) -> Bool { busyID == id }
    var isWorking: Bool { busyID != nil }

    /// - Important: the name typed is a **request**. The server keeps the original extension and
    ///   sanitises the rest, so what is shown afterwards is the name it echoed (`FileEditWording`).
    func rename(_ file: FileNode.StoredFile, to newName: String) async {
        let requested = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty, requested != file.name else { return }
        await perform(on: file.path) { manager in
            let result = try await manager.rename(
                name: file.name, in: file.folderPath, to: requested)
            return FileEditWording.renamed(result, requested: requested)
        }
        await reload()
    }

    /// Stars or unstars a document, always sending the state wanted.
    ///
    /// - Important: `favorite-file` stars anything that is not an explicit `false`
    ///   (`sync-server.js:14682`), so the value is computed and sent every time — never omitted
    ///   to mean "toggle". The response is the state read back out of the database, and that is
    ///   what is shown. Applied in place: the tree walk is expensive and the answer is exact.
    func toggleFavorite(_ file: FileNode.StoredFile) async {
        let wanted = !(file.favorite ?? false)
        await perform(on: file.path) { [weak self] manager in
            let stored = try await manager.setFavorite(
                wanted, name: file.name, folderName: file.folderPath)
            if let self {
                self.tree = MyFilesViewModel.settingFavorite(stored, at: file.path, in: self.tree)
            }
            return nil
        }
    }

    func move(_ file: FileNode.StoredFile, to destination: FolderSummary) async {
        guard destination.path != file.folderPath else { return }
        await perform(on: file.path) { manager in
            try await manager.move(name: file.name, from: file.folderPath, to: destination.path)
            return "Moved \(DisplayText.fileName(file.name)) to \(destination.displayName)."
        }
        await reload()
    }

    /// Fetches the document's bytes for the share sheet.
    func prepareShare(_ file: FileNode.StoredFile) async {
        await perform(on: file.path) { [weak self] _ in
            guard let self else { return nil }
            let data = try await self.service.fileData(name: file.name, folderName: file.folderPath)
            guard !data.isEmpty else {
                throw APIError.server(status: 200, message: "That document arrived empty, so there is nothing to share.")
            }
            self.sharing = SharedDocument(fileName: file.name, data: data)
            return nil
        }
    }

    // MARK: - Folders

    /// - Important: rejects a name that would sanitise away to nothing before sending it —
    ///   see `FolderName.isCreatable`.
    func createFolder(named name: String, in parent: String) async {
        guard FolderName.isCreatable(name) else {
            actionError = "That folder name has no letters or numbers in it."
            return
        }
        let base = FileBrowser.normalized(parent)
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = base.isEmpty ? typed : "\(base)/\(typed)"
        await perform(on: "") { manager in
            try await manager.createFolder(named: path)
            return FileEditWording.folderCreated(typed: typed)
        }
        await reload()
    }

    func renameFolder(_ folder: FolderSummary, to newName: String) async {
        let requested = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty, requested != folder.name else { return }
        guard FolderName.isUsableLeaf(requested) else {
            actionError = requested.contains("/")
                ? "A folder name cannot contain a slash. To put it inside another folder, create a folder there instead."
                : "That folder name has no letters or numbers in it."
            return
        }
        await perform(on: folder.path) { manager in
            let newPath = try await manager.renameFolder(at: folder.path, to: requested)
            return FileEditWording.folderRenamed(to: newPath, requested: requested)
        }
        await reload()
    }

    // MARK: - Deleting

    func requestDeletion(of file: FileNode.StoredFile) {
        pendingDeletion = FileDeletion(file: file)
    }

    /// Builds the confirmation from the tree as it is now, so the count it states is current.
    func requestDeletion(of folder: FolderSummary) {
        let live = FileBrowser.folder(at: folder.path, in: tree) ?? folder
        pendingDeletion = FileDeletion(folder: live)
    }

    func cancelDeletion() { pendingDeletion = nil }

    /// Deletes what the confirmation named, then re-reads the library.
    ///
    /// - Important: the refetch is unconditional. Both delete routes answer 200 for a path that
    ///   is not there, so success says nothing about what the library holds; and after a failure
    ///   the library may still have changed under a folder deletion that stopped part-way.
    func confirmDeletion() async {
        guard let plan = pendingDeletion else { return }
        await confirm(plan)
    }

    /// Deletes what a confirmation named.
    ///
    /// Takes the plan rather than reading `pendingDeletion` because of the order an alert works
    /// in: the destructive button's action runs, *then* the alert's binding is cleared — which
    /// clears `pendingDeletion` before a `Task` started by that action has had a chance to read
    /// it. The screen captures the plan synchronously and hands it here.
    func confirm(_ plan: FileDeletion) async {
        pendingDeletion = nil

        switch plan.target {
        case .file(let file):
            await perform(on: file.path) { manager in
                try await manager.delete(name: file.name, folderName: file.folderPath)
                return plan.doneNotice
            }
        case .folder(let folder):
            // Checked again here, not only when the plan was built: this is the last point
            // before a recursive deletion is sent, and the root must never reach it.
            guard !FileBrowser.normalized(folder.path).isEmpty else { return }
            await perform(on: folder.path) { manager in
                try await manager.deleteFolder(named: folder.path)
                return plan.doneNotice
            }
        }
        await reload()
    }

    // MARK: - Announcements

    func dismissActionNotice() { actionNotice = nil }

    private func perform(
        on id: String, _ body: (any FileManaging) async throws -> String?
    ) async {
        guard busyID == nil else { return }
        busyID = id
        actionError = nil
        actionNotice = nil
        defer { busyID = nil }

        do {
            actionNotice = try await body(manager)
        } catch {
            actionError = DisplayText.message(for: error)
        }
    }

    /// The tree with one document's star set to what the server stored.
    static func settingFavorite(_ value: Bool, at path: String, in nodes: [FileNode]) -> [FileNode] {
        nodes.map { node in
            switch node {
            case .file(var file):
                if file.path == path { file.favorite = value }
                return .file(file)
            case .folder(var folder):
                if path.hasPrefix(folder.path + "/") {
                    folder.files = settingFavorite(value, at: path, in: folder.files ?? [])
                }
                return .folder(folder)
            }
        }
    }
}
