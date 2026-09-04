import SwiftUI

/// Picks documents from the DMS to attach to a turn.
///
/// Presented as a sheet from the composer rather than as a tab: on a phone, attaching a file
/// is nearly always something you do *while* asking a question, not a separate errand.
struct FileLibraryView: View {
    @Environment(\.theme) private var theme
    /// Files already attached, so they can be shown as selected and toggled off.
    let alreadyAttached: [ChatAttachment]
    let onAttach: ([ChatAttachment]) -> Void

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var model: FileLibraryViewModel?
    @State private var isDigitising = false
    @State private var isImporting = false
    @State private var renaming: FileNode.StoredFile?
    @State private var renameText = ""
    @State private var isNamingFolder = false
    @State private var newFolderName = ""
    /// Non-nil while the user is being asked about documents the library already holds.
    @State private var duplicateReview: DuplicateReview?
    /// The document being read rather than attached.
    @State private var previewing: Previewing?

    /// `FileNode.StoredFile` is not `Identifiable`, and giving it an identity here would be
    /// inventing one for a wire type that has no stable id of its own.
    private struct Previewing: Identifiable {
        let id = UUID()
        let file: FileNode.StoredFile
    }

    /// The picked files, split into the ones worth asking about and the ones that are not.
    private struct DuplicateReview: Identifiable {
        let id = UUID()
        var items: [DuplicateReviewSheet.Item]
        var cleared: [(url: URL, fileName: String)]
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            isImporting = true
                        } label: {
                            Label("Add from Files", systemImage: "folder.badge.plus")
                        }
                        Button {
                            isDigitising = true
                        } label: {
                            Label("Digitise or translate", systemImage: "doc.viewfinder")
                        }
                        if model?.canManage == true {
                            Divider()
                            Button {
                                isNamingFolder = true
                            } label: {
                                Label("New folder", systemImage: "folder.badge.plus")
                            }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(model?.isUploading == true)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Attach") {
                        onAttach(model?.chosenAttachments ?? [])
                        dismiss()
                    }
                    .disabled(!(model?.canAttach ?? false))
                }
            }
            .sheet(isPresented: $isDigitising) {
                OCRView()
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.pdf, .plainText, .rtf, .image],
                allowsMultipleSelection: true
            ) { outcome in
                guard case .success(let urls) = outcome else { return }
                Task { await review(urls) }
            }
            .sheet(item: $previewing) { item in
                // No citation brought us here, so there is no mark and no page to land on —
                // the viewer opens at the top.
                SourceDocumentView(
                    attachment: item.file.attachment,
                    mention: AnnexureMention(
                        fileName: item.file.name, mark: "", startPage: nil, endPage: nil))
            }
            .sheet(item: $duplicateReview) { review in
                DuplicateReviewSheet(
                    items: review.items,
                    cleared: review.cleared,
                    onConfirm: { chosen in Task { await upload(chosen) } })
            }
            // Posted once the server reports an upload readable. The document is not in the
            // list until then, and this screen may have been open the whole time.
            .onReceive(NotificationCenter.default.publisher(for: .emperorUploadDidFinish)) { _ in
                Task { await model?.load() }
            }
            .task {
                guard model == nil else { return }
                let created = FileLibraryViewModel(
                    service: session.files,
                    alreadyAttached: alreadyAttached,
                    uploads: session.uploads,
                    manager: session.fileManagement)
                model = created
                await created.load()
            }
        }
    }

    // MARK: - Uploading

    /// Asks the server whether any of these are already filed, then either prompts or uploads.
    ///
    /// **Every failure path here uploads.** A 401, an offline phone, a file that will not hash,
    /// a server that answers with something unexpected — none of them are reasons to refuse a
    /// document the user has explicitly chosen. The check is a courtesy that prevents a
    /// duplicate; treating its absence as a blocker would turn an expired token into "this app
    /// will not take my documents any more", which is far worse than the mess it avoids. The
    /// server also dedupes on arrival regardless, so nothing is lost but the prompt.
    private func review(_ urls: [URL]) async {
        var hashes: [(url: URL, fileName: String, hash: String?)] = []
        for url in urls {
            // A picker URL is security-scoped and must be opened before reading. Hashing
            // happens inside this window; the copy the uploader takes does too.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            hashes.append((url, url.lastPathComponent, FileHash.sha256(of: url)))
        }

        let checkable = hashes.compactMap { entry in
            entry.hash.map { (name: entry.fileName, hash: $0) }
        }
        let results = (try? await session.duplicates.check(
            files: checkable, targetFolder: FileLibraryViewModel.uploadFolder)) ?? []

        // Index by hash rather than by position: the server caps the batch, and matching a
        // short answer up by index would attribute one file's verdict to another.
        var byHash: [String: DuplicateCheck.Result] = [:]
        for result in results {
            if let hash = result.hash, byHash[hash] == nil { byHash[hash] = result }
        }

        var flagged: [DuplicateReviewSheet.Item] = []
        var cleared: [(url: URL, fileName: String)] = []
        for entry in hashes {
            let decision = entry.hash
                .flatMap { byHash[$0] }
                .map(DuplicateCheck.decision(for:)) ?? .upload
            if case .upload = decision {
                cleared.append((entry.url, entry.fileName))
            } else {
                flagged.append(
                    DuplicateReviewSheet.Item(
                        url: entry.url, fileName: entry.fileName, decision: decision,
                        // Off by default — see `DuplicateReviewSheet`.
                        upload: false))
            }
        }

        if flagged.isEmpty {
            await upload(cleared)
        } else {
            duplicateReview = DuplicateReview(items: flagged, cleared: cleared)
        }
    }

    private func upload(_ files: [(url: URL, fileName: String)]) async {
        for file in files {
            let scoped = file.url.startAccessingSecurityScopedResource()
            defer { if scoped { file.url.stopAccessingSecurityScopedResource() } }
            do {
                try await BackgroundUploader.shared.start(
                    source: file.url,
                    fileName: file.fileName,
                    folderName: FileLibraryViewModel.uploadFolder)
            } catch {
                model?.uploadError = DisplayText.message(for: error)
            }
        }
    }

    @ViewBuilder
    private func content(_ model: FileLibraryViewModel) -> some View {
        @Bindable var bindable = model

        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            list(model)
        } empty: {
            // A query matching nothing is a third thing again: the library is not empty and
            // the load did not fail — the search simply found no match. It belongs here
            // rather than in the content closure, because `presentation.isEmpty` is computed
            // from the *filtered* list, so a search matching nothing already satisfies
            // `showsEmptyState` and content is never rendered.
            if model.showsNoSearchResults {
                ContentUnavailableView.search(text: model.query)
            } else {
                ContentUnavailableView(
                    "No documents yet",
                    systemImage: "folder",
                    description: Text("Scan a paperbook to add your first document."))
            }
        }
        .searchable(text: $bindable.query, prompt: "Search documents and matters")
        .refreshable { await model.load() }
        .safeAreaInset(edge: .top) {
            // Background transfers first: these survive the app closing, so this list is read
            // from disk rather than from anything this screen started. Reopening the app
            // mid-upload shows it still going, which is the point of the whole feature.
            let background = BackgroundUploader.shared.inFlight
            if !background.isEmpty || model.isUploading {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(background) { upload in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Uploading \(upload.fileName)")
                                .font(.brand(.caption))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                            ProgressView(value: upload.progress)
                        }
                        // Said plainly, because it is the reassurance that makes someone
                        // willing to put the phone in a pocket at a registry counter.
                        .accessibilityLabel(
                            "Uploading \(upload.fileName), \(Int(upload.progress * 100)) percent. "
                            + "This continues if you leave the app.")
                    }
                    if model.isUploading {
                        // Ingestion runs after the upload's 200, so this stays up until the
                        // server reports the file readable — not until the bytes land.
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.uploadProgress < 1
                                 ? "Uploading…"
                                 : "Reading the document…")
                                .font(.brand(.caption))
                                .foregroundStyle(theme.textSecondary)
                            ProgressView(value: model.uploadProgress)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(theme.surface)
            }
        }
        .alert("Could not add that document", isPresented: Binding(
            get: { model.uploadError != nil },
            set: { if !$0 { model.uploadError = nil } }
        )) {
            Button("OK") { model.uploadError = nil }
        } message: {
            Text(model.uploadError ?? "")
        }
        .alert("Couldn't do that", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .alert("Rename document", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let file = renaming {
                    let name = renameText
                    Task { await model.rename(file, to: name) }
                }
                renaming = nil
            }
        } message: {
            // Said before the fact rather than after: the file type is not negotiable, and
            // discovering that only from the result reads as the app ignoring you.
            Text("The file type stays the same, whatever you type.")
        }
        .alert("New folder", isPresented: $isNamingFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            // No `.disabled` here: alert buttons do not reliably honour it, and a Create that
            // silently does nothing is worse than one that explains itself. The view model
            // refuses an uncreatable name and says why, which is the tested path.
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await model.createFolder(named: name) }
            }
        } message: {
            Text(folderNameHint)
        }
    }

    /// What the folder will really be called, warned about only when it differs.
    private var folderNameHint: String {
        let typed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = FolderName.preview(newFolderName)
        guard !typed.isEmpty, actual != typed else {
            return "Letters, numbers, dots and dashes. Anything else becomes an underscore."
        }
        return "This will be saved as \(actual)."
    }

    private func list(_ model: FileLibraryViewModel) -> some View {
        List {
            ForEach(model.grouped) { group in
                Section {
                    ForEach(group.files, id: \.path) { file in
                        row(for: file, in: model)
                    }
                } header: {
                    sectionHeader(group)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .overlay(alignment: .bottom) {
            if let notice = model.actionNotice {
                Text(notice)
                    .font(.brand(.footnote))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(theme.surfaceElevated, in: Capsule())
                    .foregroundStyle(theme.textPrimary)
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 12)
                    .transition(.opacity)
                    .onTapGesture { model.dismissActionNotice() }
                    .task(id: notice) {
                        // Long enough to read a sentence about a filename, then out of the way.
                        try? await Task.sleep(for: .seconds(4))
                        model.dismissActionNotice()
                    }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.actionNotice)
    }

    /// - Note: this header carried an overflow menu whose only item was "Delete folder".
    ///   With deletion held back it has nothing to offer, so it is a plain label again —
    ///   `rename-folder` is not a route this client calls.
    private func sectionHeader(_ group: FileLibraryViewModel.FolderGroup) -> some View {
        Text(group.title)
    }

    private func row(for file: FileNode.StoredFile, in model: FileLibraryViewModel) -> some View {
        Button {
            model.toggle(file)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: model.isSelected(file) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.isSelected(file) ? theme.accent : theme.textSecondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(DisplayText.fileName(file.name))
                        .lineLimit(2)
                        .foregroundStyle(file.isReadable ? theme.textPrimary : theme.textSecondary)
                    statusLine(for: file)
                }

                Spacer(minLength: 0)

                if file.favorite == true {
                    Image(systemName: "star.fill")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.warning)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A file still being read cannot answer questions yet, so it cannot be attached.
        .disabled(!file.isReadable)
        .swipeActions(edge: .trailing) {
            if model.canManage {
                Button {
                    renaming = file
                    renameText = file.name
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(theme.accent)
            }
        }
        .swipeActions(edge: .leading) {
            if model.canManage {
                Button {
                    Task { await model.toggleFavorite(file) }
                } label: {
                    Label(
                        file.favorite == true ? "Unstar" : "Star",
                        systemImage: file.favorite == true ? "star.slash" : "star")
                }
                .tint(theme.warning)
            }
        }
        .contextMenu {
            // Tapping a row selects it for attaching — this screen is a picker first — so
            // reading a document needs its own way in. Without it a `.docx` is listed,
            // attachable and unopenable, which is the hole office preview exists to close.
            Button {
                previewing = Previewing(file: file)
            } label: {
                Label("Preview", systemImage: "doc.text.magnifyingglass")
            }

            if model.canManage {
                // The same actions again, reachable without knowing swipes exist — and the
                // only route for anyone using VoiceOver or Switch Control.
                Button {
                    renaming = file
                    renameText = file.name
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    Task { await model.toggleFavorite(file) }
                } label: {
                    Label(
                        file.favorite == true ? "Remove star" : "Star",
                        systemImage: file.favorite == true ? "star.slash" : "star")
                }
            }
        }
    }

    @ViewBuilder
    private func statusLine(for file: FileNode.StoredFile) -> some View {
        switch file.state {
        case .ready:
            if let size = file.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
            }
        case .scanned:
            // Worth saying plainly: this is usable, just by a different route.
            Label("Scanned — read as images", systemImage: "eye")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textSecondary)
        case .inProgress(let message):
            Label(message, systemImage: "clock")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        case .failed(let reason):
            Label(
                reason.replacingOccurrences(of: "ERROR: ", with: ""),
                systemImage: "exclamationmark.triangle")
                .font(.brand(.caption2))
                .foregroundStyle(theme.danger)
                .lineLimit(2)
        }
    }
}
