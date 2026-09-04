import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Picking documents from the DMS to attach to a turn.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class FileLibraryViewModel {
    /// A matter's worth of documents. A struct rather than a tuple so the list can key on it
    /// directly.
    struct FolderGroup: Identifiable, Equatable {
        let folder: String
        let files: [FileNode.StoredFile]

        var id: String { folder }

        /// "Unfiled" rather than a blank heading: loose files at the storage root have an
        /// empty folder path, and an untitled section reads as a rendering fault.
        var title: String {
            folder.isEmpty ? "Unfiled" : DisplayText.fileName(folder)
        }
    }

    private(set) var files: [FileNode.StoredFile] = []
    private(set) var state: LoadState = .idle
    var selected: Set<String> = []
    var query = ""

    /// Files already on the turn, so the sheet opens showing them as selected.
    private let alreadyAttached: [ChatAttachment]
    private let service: any FileProviding
    private let uploads: (any UploadProviding)?
    /// Absent when this is only a picker. Editing is offered only where it was asked for.
    private let manager: (any FileManaging)?

    /// Where a document chosen from Files is filed. A fixed folder rather than a prompt: the
    /// document can be moved on the web, and one more decision at the point of upload is one
    /// more reason not to bother.
    static let uploadFolder = "Uploads"

    private(set) var isUploading = false
    private(set) var uploadProgress: Double = 0
    var uploadError: String?

    /// Which file an edit is running against, so one row spins rather than the whole list.
    private(set) var busyPath: String?
    var actionError: String?
    var actionNotice: String?

    var canManage: Bool { manager != nil }

    init(
        service: any FileProviding,
        alreadyAttached: [ChatAttachment] = [],
        uploads: (any UploadProviding)? = nil,
        manager: (any FileManaging)? = nil
    ) {
        self.service = service
        self.alreadyAttached = alreadyAttached
        self.uploads = uploads
        self.manager = manager
    }

    /// Puts a document from Files into the library.
    ///
    /// Until this existed the **camera was the only way in** — an advocate with a PDF in Files,
    /// iCloud Drive or an email attachment could not get it into their library at all, and so
    /// could not ask about it. The OCR screen's picker does not count: it posts to
    /// `/ocr-translate`, which never writes to the DMS.
    func upload(data: Data, fileName: String) async {
        guard let uploads, !isUploading else { return }
        isUploading = true
        uploadProgress = 0
        uploadError = nil
        defer { isUploading = false }

        do {
            for try await event in uploads.upload(
                data: data, fileName: fileName, folderName: Self.uploadFolder
            ) {
                switch event {
                case .progress(let sent, let total):
                    uploadProgress = total > 0 ? Double(sent) / Double(total) : 0
                case .processing:
                    uploadProgress = 1
                case .finished(let state):
                    // A 200 on the last chunk means "bytes received", not "file ready" — so the
                    // library is only re-read once ingestion reports the file usable.
                    if state.isUsable {
                        await load()
                    } else if case .failed(let reason) = state {
                        uploadError = reason
                    }
                }
            }
        } catch {
            uploadError = DisplayText.message(for: error)
        }
    }

    // MARK: - Presentation state

    var visible: [FileNode.StoredFile] {
        FileService.search(query, in: files)
    }

    /// Grouped by matter, because that is how a practitioner thinks about a file — not as a
    /// flat list of names.
    var grouped: [FolderGroup] {
        Dictionary(grouping: visible, by: \.folderPath)
            .map { FolderGroup(folder: $0.key, files: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
    }

    /// The three-way distinction every list screen owes the user. See `LoadState`.
    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: files.isEmpty)
    }

    var isLoading: Bool { state.isLoading }
    var failure: LoadFailure? { state.failure }

    /// The library has documents but the query matches none of them — a different message
    /// from having no documents at all.
    var showsNoSearchResults: Bool { !files.isEmpty && visible.isEmpty }

    var canAttach: Bool { !selected.isEmpty }

    // MARK: - Selection

    func toggle(_ file: FileNode.StoredFile) {
        // A file still being read cannot answer questions yet, so it cannot be attached.
        guard file.isReadable else { return }
        if selected.contains(file.path) {
            selected.remove(file.path)
        } else {
            selected.insert(file.path)
        }
    }

    func isSelected(_ file: FileNode.StoredFile) -> Bool {
        selected.contains(file.path)
    }

    /// What to hand back to the composer when "Attach" is tapped.
    var chosenAttachments: [ChatAttachment] {
        files.filter { selected.contains($0.path) }.map(\.attachment)
    }

    // MARK: - Loading

    func load() async {
        state = .loading
        do {
            let tree = try await service.tree()
            files = FileService.allFiles(in: tree)
            reconcileSelection()
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    // MARK: - Editing

    /// Removes a document and everything derived from it.
    ///
    /// - Important: the tree is refetched rather than patched. `delete-file` guards on
    ///   existence and answers 200 either way, so "it worked" is not evidence the file was
    ///   there — the only way to know what the library now holds is to ask.
    func delete(_ file: FileNode.StoredFile) async {
        await perform(on: file.path) { manager in
            try await manager.delete(name: file.name, folderName: file.folderPath)
            return "\(DisplayText.fileName(file.name)) was deleted."
        }
        await reload()
    }

    /// - Important: the name the user typed is a **request**. The server force-preserves the
    ///   original extension and replaces every character outside `[A-Za-z0-9._-]`, so the
    ///   result is read back from the response. Annexure citations match on the exact on-disk
    ///   name, which is why showing the requested one instead would break retrieval quietly.
    func rename(_ file: FileNode.StoredFile, to newName: String) async {
        let requested = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty, requested != file.name else { return }

        await perform(on: file.path) { manager in
            let result = try await manager.rename(
                name: file.name, in: file.folderPath, to: requested)
            var notice = "Renamed to \(DisplayText.fileName(result.fileName))."
            if result.fileName != requested {
                // Said out loud: silently filing it under a different name is how someone
                // later cannot find their own document.
                notice = "Saved as \(result.fileName) — the original file type is kept."
            }
            if result.searchIndexStale {
                // Disk and database moved; the search index did not. The symptom is the
                // assistant no longer finding a document that is plainly in the list.
                notice += " Search may not find it under the new name yet."
            }
            return notice
        }
        await reload()
    }

    /// Stars or unstars a document.
    ///
    /// The returned value is what the server read back out of the database, not what was
    /// asked for, and that is what is shown. Applied in place rather than by refetching — the
    /// tree walk is expensive and a star is the one edit whose result the response states
    /// exactly.
    func toggleFavorite(_ file: FileNode.StoredFile) async {
        let wanted = !(file.favorite ?? false)
        await perform(on: file.path) { [weak self] manager in
            let stored = try await manager.setFavorite(
                wanted, name: file.name, folderName: file.folderPath)
            if let index = self?.files.firstIndex(where: { $0.path == file.path }) {
                self?.files[index].favorite = stored
            }
            return nil
        }
    }

    /// - Important: rejects a name that would sanitise away to nothing before sending it.
    ///   `create-folder` mkdirs the storage root for `"."` or `"///"` and reports success, so
    ///   the user would see no new folder, no error, and nothing to correct.
    func createFolder(named name: String) async {
        guard FolderName.isCreatable(name) else {
            actionError = "That folder name has no letters or numbers in it."
            return
        }
        await perform(on: nil) { manager in
            try await manager.createFolder(named: name)
            let actual = FolderName.preview(name)
            return actual == name.trimmingCharacters(in: .whitespacesAndNewlines)
                ? "\(actual) was created."
                // Spaces and punctuation become underscores on disk. Showing the real name
                // stops the folder appearing to be missing.
                : "Created as \(actual)."
        }
        await reload()
    }

    /// - Important: recursive and immediate. Every document inside goes with it, along with
    ///   its extracted text and search vectors. The caller is expected to have confirmed.
    func deleteFolder(named path: String) async {
        await perform(on: nil) { manager in
            try await manager.deleteFolder(named: path)
            return "\(DisplayText.fileName(path)) and everything in it was deleted."
        }
        await reload()
    }

    /// How many documents a folder deletion would take with it, so the confirmation can say so
    /// rather than asking someone to guess.
    func fileCount(inFolder folder: String) -> Int {
        files.filter { $0.folderPath == folder || $0.folderPath.hasPrefix(folder + "/") }.count
    }

    func dismissActionNotice() { actionNotice = nil }

    private func perform(
        on path: String?, _ body: (any FileManaging) async throws -> String?
    ) async {
        guard let manager, busyPath == nil else { return }
        busyPath = path ?? ""
        actionError = nil
        actionNotice = nil
        defer { busyPath = nil }

        do {
            actionNotice = try await body(manager)
        } catch {
            actionError = DisplayText.message(for: error)
        }
    }

    /// Refetches without dropping the current selection or flashing the loading state.
    ///
    /// A full `.loading` here would blank a list the user is in the middle of using, and the
    /// selection is theirs rather than the server's — it must survive an edit to an unrelated
    /// file.
    private func reload() async {
        let keep = selected
        do {
            let tree = try await service.tree()
            files = FileService.allFiles(in: tree)
            // A file that was renamed or deleted is no longer selectable under its old path.
            selected = keep.intersection(Set(files.map(\.path)))
            state = .loaded
        } catch {
            // The edit itself succeeded; only the refresh failed. Overwriting the success
            // notice with a load error would say the wrong thing about what just happened.
            actionError = actionError ?? DisplayText.message(for: error)
        }
    }

    /// Marks the files the turn already carries as selected.
    ///
    /// Matching is on the composed `folder/name` path because the platform treats
    /// `{name, folderName}` as identity — the same filename in two matters is two different
    /// documents, and selecting both because their names agree would attach the wrong one.
    private func reconcileSelection() {
        let attachedPaths = Set(alreadyAttached.map { attachment -> String in
            let folder = attachment.folderName ?? ""
            return folder.isEmpty ? attachment.name : "\(folder)/\(attachment.name)"
        })
        selected = Set(files.map(\.path).filter { attachedPaths.contains($0) })
    }
}
