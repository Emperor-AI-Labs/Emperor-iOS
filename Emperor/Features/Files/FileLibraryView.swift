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
    /// Choosing where an upload goes, before the documents are picked.
    @State private var isChoosingDestination = false
    /// The folder the next picked documents go into. Set by the destination sheet, read by the
    /// file importer that opens once that sheet is gone.
    @State private var uploadDestination: String?
    @State private var startImportAfterChoosing = false
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
                // One slot on the right, holding whichever action the selection has made
                // current. Cancel keeps the left to itself: it used to share it with the add
                // menu, which sat a few points from the button that throws the picking away.
                //
                // Add and Attach are never both the thing to do. This screen is a picker first,
                // so a selection means the picking is finished and adding is the previous
                // question; with nothing selected there is nothing to attach and a disabled
                // Attach only says so after it has taken the space.
                ToolbarItem(placement: .confirmationAction) {
                    if model?.canAttach == true {
                        Button("Attach") {
                            onAttach(model?.chosenAttachments ?? [])
                            dismiss()
                        }
                    } else {
                        addMenu
                    }
                }
            }
            .sheet(isPresented: $isDigitising) {
                OCRView()
            }
            .sheet(isPresented: $isChoosingDestination, onDismiss: {
                if startImportAfterChoosing {
                    startImportAfterChoosing = false
                    isImporting = true
                }
            }) {
                UploadDestinationSheet(
                    destinations: model?.uploadDestinations ?? [FileLibraryViewModel.uploadFolder],
                    initial: uploadDestination ?? FileLibraryViewModel.uploadFolder,
                    createFolder: { name in await model?.createFolder(named: name) },
                    onChoose: { folder in
                        uploadDestination = folder
                        startImportAfterChoosing = true
                    })
            }
            .fileImporter(
                isPresented: $isImporting,
                // The library's own types, shared with My Files. This used to accept any
                // image, and a HEIC photo uploaded, was stored, and never appeared in any list.
                allowedContentTypes: LibraryUploadFlow.importableTypes,
                allowsMultipleSelection: true
            ) { outcome in
                guard case .success(let urls) = outcome else { return }
                let picked = urls.map { PickedDocument(url: $0, fileName: $0.lastPathComponent) }
                Task { await add(picked) }
            }
            .sheet(item: $previewing) { item in
                // No citation brought us here, so there is no mark and no page to land on —
                // the viewer opens at the top.
                SourceDocumentView(
                    attachment: item.file.attachment,
                    mention: AnnexureMention(
                        fileName: item.file.name, mark: "", startPage: nil, endPage: nil),
                    isCitation: false)
            }
            .sheet(item: $duplicateReview) { review in
                DuplicateReviewSheet(
                    items: review.items,
                    cleared: review.cleared,
                    onConfirm: { chosen in
                        Task {
                            model?.uploadError = await LibraryUploadFlow.upload(
                                chosen, into: review.folder)
                        }
                    })
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

    /// Putting documents *into* the library, as against picking from it: an import, a scan, and
    /// a folder for anyone who can manage the library.
    private var addMenu: some View {
        Menu {
            Button {
                isChoosingDestination = true
            } label: {
                Label("Upload documents", systemImage: "square.and.arrow.up")
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

    // MARK: - Uploading

    /// Asks before uploading anything the library already holds, then uploads. The rules —
    /// including that every failure of the check still uploads — are `LibraryUploadFlow`'s,
    /// shared with My Files.
    private func add(_ picked: [PickedDocument]) async {
        if let refusal = LibraryUpload.refusal(for: picked.map(\.fileName)) {
            model?.uploadError = refusal
        }
        let accepted = picked.filter { LibraryUpload.isAccepted(fileName: $0.fileName) }
        guard !accepted.isEmpty else { return }
        let folder = uploadDestination ?? FileLibraryViewModel.uploadFolder
        if let review = await LibraryUploadFlow.review(
            accepted, into: folder, duplicates: session.duplicates) {
            duplicateReview = review
        } else if let failure = await LibraryUploadFlow.upload(
            accepted.map { ($0.url, $0.fileName) }, into: folder) {
            model?.uploadError = failure
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
                NoResultsView(query: model.query)
            } else {
                EmptyStateView(
                    "No documents yet",
                    systemImage: "folder",
                    message: "Scan a paperbook to add your first document.")
            }
        }
        .searchable(text: $bindable.query, prompt: "Search documents and matters")
        .refreshable { await model.load() }
        .safeAreaInset(edge: .top) {
            // Background transfers first: these survive the app closing, so this list is read
            // from disk rather than from anything this screen started.
            UploadsInFlightBanner(foregroundProgress: model.isUploading ? model.uploadProgress : nil)
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
            // Adding sits above the folders, always: the toolbar's right slot becomes Attach as
            // soon as anything is chosen, and a document that is not in the library yet must
            // still be uploadable from the screen that asks for it.
            Section {
                HStack(spacing: Spacing.sm) {
                    Button {
                        isChoosingDestination = true
                    } label: {
                        Label("Upload", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isUploading)

                    if model.canManage {
                        Button {
                            isNamingFolder = true
                        } label: {
                            Label("New folder", systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .tint(theme.accentText)
                .padding(.top, Spacing.sm)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                ForEach(model.folderRows) { group in
                    folderRow(group, in: model)
                    if model.isExpanded(group.folder) {
                        let indent = CGFloat(group.depth) * 20 + 20
                        if group.files.isEmpty && !group.hasSubfolders {
                            Text("No documents in this folder yet.")
                                .font(.brand(.footnote))
                                .foregroundStyle(theme.textTertiary)
                                .padding(.leading, indent + 16)
                        } else {
                            ForEach(group.files, id: \.path) { file in
                                row(for: file, in: model)
                                    .padding(.leading, indent)
                            }
                        }
                    }
                }
            } header: {
                if model.isSearching {
                    SectionHeader(title: "Matches")
                } else {
                    FolderSortHeader(
                        title: "Folders", sort: model.folderSort,
                        onSort: { model.folderSort = $0 })
                }
            }
            .listRowBackground(theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.groupedBackground)
        .animation(.easeOut(duration: 0.2), value: model.expanded)
        .overlay(alignment: .bottom) {
            if let notice = model.actionNotice {
                ActionNoticeToast(notice: notice) { model.dismissActionNotice() }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.actionNotice)
    }

    /// A folder as a file browser draws one: a chevron that opens and closes it, its name and
    /// how many documents it holds, and a checkbox that chooses everything inside.
    ///
    /// Deleting and renaming folders live in My Files, where the confirmation can say what goes
    /// with a folder. The picker stays a picker.
    private func folderRow(
        _ group: FileLibraryViewModel.FolderGroup, in model: FileLibraryViewModel
    ) -> some View {
        let open = model.isExpanded(group.folder)
        let selection = model.selection(in: group)
        let count = group.coveredFiles.count
        return HStack(spacing: Spacing.sm) {
            Button {
                model.toggleExpanded(group.folder)
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 14)
                    Image(systemName: open ? "folder.fill" : "folder")
                        .foregroundStyle(theme.accentText)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(.brand(.body, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(2)
                        Text(count == 1 ? "1 document" : "\(count) documents")
                            .font(.brand(.footnote))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(group.depth) * 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(group.title), \(count) documents")
            .accessibilityValue(open ? "Open" : "Closed")
            .accessibilityHint(open ? "Closes the folder" : "Opens the folder")

            if group.coveredFiles.contains(where: \.isReadable) {
                Button {
                    model.toggleAll(in: group)
                } label: {
                    Image(systemName: selection == .all
                          ? "checkmark.circle.fill"
                          : selection == .some ? "minus.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(selection == .none ? theme.textTertiary : theme.accentText)
                        .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(selection == .all
                                    ? "Release every document in \(group.title)"
                                    : "Choose every document in \(group.title)")
            }
        }
        .contextMenu {
            Button {
                uploadDestination = group.folder.isEmpty ? FileLibraryViewModel.uploadFolder : group.folder
                isImporting = true
            } label: {
                Label("Upload to this folder", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func row(for file: FileNode.StoredFile, in model: FileLibraryViewModel) -> some View {
        Button {
            model.toggle(file)
        } label: {
            DocumentRowLabel(file: file, leading: .selection(model.isSelected(file)))
        }
        .buttonStyle(.plain)
        // A file still being read cannot answer questions yet, so it cannot be attached.
        .disabled(!file.isReadable)
        // Chosen or not, as VoiceOver's own "Selected" — the leading mark says it to the eye.
        .accessibilityAddTraits(model.isSelected(file) ? [.isSelected] : [])
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
}
