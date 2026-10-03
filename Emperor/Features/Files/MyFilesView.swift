import SwiftUI
import PhotosUI

/// My Files — the document library as a place of its own.
///
/// The web's "My Files" row opens a page (`src/pages/MyFilesPage.jsx`) rather than the drawer,
/// because the drawer exists to pick documents while doing something else and the page exists to
/// manage them. This is that split on the phone: `FileLibraryView` stays the composer's picker,
/// and this is where documents are browsed, opened, renamed, starred, shared, moved, deleted and
/// added. Everything it decides is `MyFilesViewModel`'s; this file lays it out.
///
/// Folders are pushed rather than expanded in place. A phone shows one folder at a time, and the
/// back button is the breadcrumb.
struct MyFilesView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var model: MyFilesViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    LibraryScreen(model: model, path: "")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("My Files")
            // On the root rather than inside the screen, so it is there in every state —
            // including the spinner before the first load returns. Presented from More, so iOS
            // gives it no back button; see `MoreView`.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: FolderRoute.self) { route in
                if let model {
                    LibraryScreen(model: model, path: route.path)
                }
            }
            .task {
                guard model == nil else { return }
                let created = MyFilesViewModel(
                    service: session.files, manager: session.fileManagement)
                model = created
                await created.load()
            }
        }
    }
}

/// A pushed folder, by its path.
struct FolderRoute: Hashable {
    let path: String
}

/// One screen of the library: the top level with its three views, or a single folder.
///
/// The same type for both so a document behaves identically wherever it is listed — the same
/// swipe, the same menu, the same confirmation — and so the presentation state for each
/// (what is being renamed, moved, previewed) belongs to the screen showing it.
private struct LibraryScreen: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let model: MyFilesViewModel
    /// `""` for the top level.
    let path: String

    @State private var folderQuery = ""
    @State private var previewing: Previewing?
    @State private var renamingFile: FileNode.StoredFile?
    @State private var renamingFolder: FolderSummary?
    @State private var renameText = ""
    @State private var moving: Moving?
    @State private var isNamingFolder = false
    @State private var newFolderName = ""
    @State private var isImporting = false
    @State private var isPickingPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var duplicateReview: DuplicateReview?
    @State private var uploadError: String?

    /// `FileNode.StoredFile` has no identity of its own, and inventing one for a wire type would
    /// be worse than wrapping it.
    private struct Previewing: Identifiable {
        let id = UUID()
        let file: FileNode.StoredFile
    }

    private struct Moving: Identifiable {
        let id = UUID()
        let file: FileNode.StoredFile
    }

    private var isRoot: Bool { path.isEmpty }

    private var title: String {
        isRoot ? "My Files" : (model.folder(at: path)?.displayName ?? DisplayText.fileName(
            String(path.split(separator: "/").last ?? "")))
    }

    private var uploadFolder: String { MyFilesViewModel.uploadDestination(for: path) }

    var body: some View {
        alerts(presentations(chrome(content)))
    }

    /// Split into three so no single expression carries every modifier: a chain this long is
    /// where the type checker gives up.
    private func chrome<V: View>(_ view: V) -> some View {
        view
            .background(theme.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    addMenu
                }
            }
            .safeAreaInset(edge: .top) {
                UploadsInFlightBanner()
            }
            .overlay(alignment: .bottom) {
                if let notice = model.actionNotice {
                    ActionNoticeToast(notice: notice) { model.dismissActionNotice() }
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.actionNotice)
            // Posted once the server reports an upload readable. The document is not in the
            // library until then, and this screen may have been open the whole time.
            .onReceive(NotificationCenter.default.publisher(for: .emperorUploadDidFinish)) { _ in
                Task { await model.uploadDidFinish() }
            }
    }

    private func presentations<V: View>(_ view: V) -> some View {
        view
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: LibraryUploadFlow.importableTypes,
                allowsMultipleSelection: true
            ) { outcome in
                guard case .success(let urls) = outcome else { return }
                let picked = urls.map { PickedDocument(url: $0, fileName: $0.lastPathComponent) }
                Task { await add(picked) }
            }
            .photosPicker(
                isPresented: $isPickingPhotos,
                selection: $photoSelection,
                maxSelectionCount: 20,
                matching: .images)
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                photoSelection = []
                Task { await addPhotos(items) }
            }
            .sheet(item: $duplicateReview) { review in
                DuplicateReviewSheet(
                    items: review.items,
                    cleared: review.cleared,
                    onConfirm: { chosen in
                        Task { uploadError = await LibraryUploadFlow.upload(chosen, into: review.folder) }
                    })
            }
            .sheet(item: $previewing) { item in
                // No citation brought us here, so there is no mark and no page to land on —
                // the viewer opens at the top. PDFs render directly; Word documents go through
                // the server's conversion, which the viewer says out loud.
                SourceDocumentView(
                    attachment: item.file.attachment,
                    mention: AnnexureMention(
                        fileName: item.file.name, mark: "", startPage: nil, endPage: nil))
            }
            .sheet(item: $moving) { item in
                MoveDocumentSheet(
                    file: item.file,
                    destinations: model.moveDestinations(for: item.file)
                ) { destination in
                    Task { await model.move(item.file, to: destination) }
                }
            }
            .sheet(item: Binding(
                get: { model.sharing },
                set: { if $0 == nil { model.sharing = nil } }
            )) { shared in
                shareSheet(for: shared)
            }
    }

    private func alerts<V: View>(_ view: V) -> some View {
        view
            .alert(deletionTitle, isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { if !$0 { model.cancelDeletion() } }
            )) {
                // Captured here, synchronously: the alert clears its binding after this action
                // runs, which would empty `pendingDeletion` before the task could read it.
                let plan = model.pendingDeletion
                Button(plan?.confirmLabel ?? "Delete", role: .destructive) {
                    if let plan {
                        Task { await model.confirm(plan) }
                    }
                }
                Button("Cancel", role: .cancel) { model.cancelDeletion() }
            } message: {
                Text(model.pendingDeletion?.message ?? "")
            }
            .alert(renameTitle, isPresented: Binding(
                get: { renamingFile != nil || renamingFolder != nil },
                set: { if !$0 { renamingFile = nil; renamingFolder = nil } }
            )) {
                TextField("Name", text: $renameText)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {
                    renamingFile = nil
                    renamingFolder = nil
                }
                Button("Rename") {
                    let name = renameText
                    if let file = renamingFile {
                        Task { await model.rename(file, to: name) }
                    } else if let folder = renamingFolder {
                        Task { await model.renameFolder(folder, to: name) }
                    }
                    renamingFile = nil
                    renamingFolder = nil
                }
            } message: {
                Text(renameHint)
            }
            .alert("New folder", isPresented: $isNamingFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) { newFolderName = "" }
                // No `.disabled` here: alert buttons do not reliably honour it. The view model
                // refuses an uncreatable name and says why, which is the tested path.
                Button("Create") {
                    let name = newFolderName
                    newFolderName = ""
                    Task { await model.createFolder(named: name, in: path) }
                }
            } message: {
                Text(folderNameHint)
            }
            .alert("Couldn't do that", isPresented: Binding(
                get: { model.actionError != nil || uploadError != nil },
                set: { if !$0 { model.actionError = nil; uploadError = nil } }
            )) {
                Button("OK") {
                    model.actionError = nil
                    uploadError = nil
                }
            } message: {
                Text(model.actionError ?? uploadError ?? "")
            }
    }

    private var deletionTitle: String { model.pendingDeletion?.title ?? "Delete" }

    private var renameTitle: String { renamingFolder == nil ? "Rename document" : "Rename folder" }

    /// Said before the fact rather than after: the file type is not negotiable, and discovering
    /// that only from the result reads as the app ignoring you.
    private var renameHint: String {
        renamingFolder == nil
            ? "The file type stays the same, whatever you type."
            : "Letters, numbers, dots and dashes. Anything else becomes an underscore."
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isRoot {
            rootContent
        } else {
            folderContent
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        @Bindable var bindable = model

        VStack(spacing: 0) {
            Picker("View", selection: $bindable.section) {
                ForEach(MyFilesViewModel.Section.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            ListStateView(
                presentation: model.presentation(for: model.section),
                retry: { await model.load() }
            ) {
                switch model.section {
                case .recent: recentList
                case .favorites: favoritesList
                case .folders: foldersList(at: "", query: model.query)
                }
            } empty: {
                if model.showsNoSearchResults(in: model.section) {
                    ContentUnavailableView.search(text: model.query)
                } else {
                    emptyView(model.emptyCopy(for: model.section))
                }
            }
        }
        .searchable(text: $bindable.query, prompt: "Search your documents")
    }

    @ViewBuilder
    private var folderContent: some View {
        ListStateView(
            presentation: model.presentation(forFolder: path),
            retry: { await model.load() }
        ) {
            foldersList(at: path, query: folderQuery)
        } empty: {
            emptyView(model.emptyCopy(forFolder: path))
        }
        .searchable(text: $folderQuery, prompt: "Search in \(title)")
    }

    private func emptyView(_ copy: MyFilesViewModel.EmptyCopy) -> some View {
        ContentUnavailableView(
            copy.title,
            systemImage: copy.systemImage,
            description: Text(copy.message))
    }

    // MARK: - Lists

    private var recentList: some View {
        let recent = model.recent
        return List {
            Section {
                ForEach(recent.files, id: \.path) { file in
                    documentRow(file, location: FileBrowser.location(of: file), date: model.dateLabel(for: file))
                }
            } footer: {
                recentFooter(recent)
            }
            .listRowBackground(theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .refreshable { await model.load() }
    }

    /// The cap and the undated, both stated — a truncated or mis-ordered list that looks
    /// complete is the thing this footer exists to prevent.
    @ViewBuilder
    private func recentFooter(_ recent: RecentFiles) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = recent.undatedNote {
                Text(note)
            }
            if let note = recent.truncationNote {
                Text(note)
            }
        }
        .font(.brand(.caption))
        .foregroundStyle(theme.textSecondary)
    }

    private var favoritesList: some View {
        List {
            Section {
                ForEach(model.favorites, id: \.path) { file in
                    documentRow(file, location: FileBrowser.location(of: file))
                }
            }
            .listRowBackground(theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .refreshable { await model.load() }
    }

    /// A folder's contents, or — while a search is typed — everything beneath it that matches.
    @ViewBuilder
    private func foldersList(at path: String, query: String) -> some View {
        let isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isSearching {
            let results = model.searchResults(under: path, matching: query)
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    if !results.folders.isEmpty {
                        Section {
                            ForEach(results.folders) { folderRow($0) }
                        } header: {
                            SectionHeader(title: "Folders", detail: "\(results.folders.count)")
                        }
                        .listRowBackground(theme.surface)
                    }
                    if !results.files.isEmpty {
                        Section {
                            ForEach(results.files, id: \.path) { file in
                                documentRow(file, location: FileBrowser.location(of: file))
                            }
                        } header: {
                            SectionHeader(title: "Documents", detail: "\(results.files.count)")
                        }
                        .listRowBackground(theme.surface)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(theme.canvas)
            }
        } else if let listing = model.listing(at: path) {
            List {
                if !listing.folders.isEmpty {
                    Section {
                        ForEach(listing.folders) { folderRow($0) }
                    } header: {
                        SectionHeader(title: "Folders", detail: "\(listing.folders.count)")
                    }
                    .listRowBackground(theme.surface)
                }
                if !listing.files.isEmpty {
                    Section {
                        ForEach(listing.files, id: \.path) { file in
                            documentRow(file)
                        }
                    } header: {
                        // At the top level these are the documents filed in no folder. The web
                        // shows them only under Recent; listing them here keeps them reachable.
                        SectionHeader(
                            title: path.isEmpty ? "Not in a folder" : "Documents",
                            detail: "\(listing.files.count)")
                    }
                    .listRowBackground(theme.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .refreshable { await model.load() }
        }
    }

    // MARK: - Rows

    private func folderRow(_ folder: FolderSummary) -> some View {
        NavigationLink(value: FolderRoute(path: folder.path)) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.brand(.title3))
                    .foregroundStyle(theme.warning)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.displayName)
                        .lineLimit(2)
                        .foregroundStyle(theme.textPrimary)
                    Text(folder.contentsSummary)
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: 0)
                if model.isBusy(folder.path) {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .accessibilityHint("Opens the folder")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // A plain button tinted as danger, not `role: .destructive`: the row must stay put
            // until the confirmation is answered and the library has been re-read.
            Button {
                model.requestDeletion(of: folder)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(theme.danger)
            Button {
                renameText = folder.name
                renamingFolder = folder
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(theme.accent)
        }
        .contextMenu {
            Button {
                renameText = folder.name
                renamingFolder = folder
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                model.requestDeletion(of: folder)
            } label: {
                Label("Delete folder", systemImage: "trash")
            }
        }
        .disabled(model.isWorking)
    }

    private func documentRow(
        _ file: FileNode.StoredFile, location: String? = nil, date: String? = nil
    ) -> some View {
        Button {
            previewing = Previewing(file: file)
        } label: {
            DocumentRowLabel(
                file: file, location: location, date: date, isBusy: model.isBusy(file.path))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the document")
        .swipeActions(edge: .leading) {
            Button {
                Task { await model.toggleFavorite(file) }
            } label: {
                Label(
                    file.favorite == true ? "Unstar" : "Star",
                    systemImage: file.favorite == true ? "star.slash" : "star")
            }
            .tint(theme.warning)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                model.requestDeletion(of: file)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(theme.danger)
            Button {
                Task { await model.prepareShare(file) }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(theme.accent)
        }
        .contextMenu {
            // The same actions again, reachable without knowing swipes exist — and the only
            // route for anyone using VoiceOver or Switch Control.
            Button {
                previewing = Previewing(file: file)
            } label: {
                Label("Open", systemImage: "doc.text.magnifyingglass")
            }
            Button {
                Task { await model.prepareShare(file) }
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button {
                Task { await model.toggleFavorite(file) }
            } label: {
                Label(
                    file.favorite == true ? "Remove star" : "Star",
                    systemImage: file.favorite == true ? "star.slash" : "star")
            }
            Divider()
            Button {
                renameText = file.name
                renamingFile = file
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                moving = Moving(file: file)
            } label: {
                Label("Move to…", systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) {
                model.requestDeletion(of: file)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .disabled(model.isWorking)
    }

    // MARK: - Adding

    private var addMenu: some View {
        Menu {
            // Named, because at the top level the answer is not obvious: a document is never
            // filed loose at the root, so it goes to the same folder the attach picker uses.
            Section("Upload to \(DisplayText.fileName(uploadFolder))") {
                Button {
                    isImporting = true
                } label: {
                    Label("From Files", systemImage: "doc.badge.plus")
                }
                Button {
                    isPickingPhotos = true
                } label: {
                    Label("From Photos", systemImage: "photo.badge.plus")
                }
            }
            Button {
                isNamingFolder = true
            } label: {
                Label(isRoot ? "New folder" : "New folder here", systemImage: "folder.badge.plus")
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .disabled(model.isWorking)
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

    private func add(_ picked: [PickedDocument]) async {
        if let refusal = LibraryUpload.refusal(for: picked.map(\.fileName)) {
            uploadError = refusal
        }
        let accepted = picked.filter { LibraryUpload.isAccepted(fileName: $0.fileName) }
        guard !accepted.isEmpty else { return }
        let folder = uploadFolder
        if let review = await LibraryUploadFlow.review(
            accepted, into: folder, duplicates: session.duplicates) {
            duplicateReview = review
        } else if let failure = await LibraryUploadFlow.upload(
            accepted.map { ($0.url, $0.fileName) }, into: folder) {
            uploadError = failure
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        let converted = await LibraryUploadFlow.documents(from: items)
        if converted.unreadable > 0 {
            uploadError = converted.unreadable == 1
                ? "One photo could not be read, so it was not added."
                : "\(converted.unreadable) photos could not be read, so they were not added."
        }
        guard !converted.documents.isEmpty else { return }
        await add(converted.documents)
    }

    // MARK: - Sharing

    @ViewBuilder
    private func shareSheet(for shared: SharedDocument) -> some View {
        if let url = ShareableFile.url(for: shared.data, named: shared.fileName) {
            ActivityView(url: url) { model.sharing = nil }
                .presentationDetents([.medium, .large])
        } else {
            ContentUnavailableView(
                "Could not prepare that document",
                systemImage: "exclamationmark.triangle",
                description: Text("There was no room to save a copy to share. Free some space and try again."))
        }
    }
}

/// Choosing where a document goes.
///
/// Every folder in the library, parents above their children and indented under them, minus the
/// one the document is already in. The top level is not offered: the web does not file a loose
/// document at the root, and one there is invisible in its My Files view.
private struct MoveDocumentSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let file: FileNode.StoredFile
    let destinations: [FolderSummary]
    let onChoose: (FolderSummary) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if destinations.isEmpty {
                    ContentUnavailableView(
                        "Nowhere else to put it",
                        systemImage: "folder",
                        description: Text("Create another folder first, then move the document into it."))
                } else {
                    List {
                        Section {
                            ForEach(destinations) { folder in
                                Button {
                                    onChoose(folder)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(theme.warning)
                                            .accessibilityHidden(true)
                                        Text(folder.displayName)
                                            .foregroundStyle(theme.textPrimary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.leading, CGFloat(depth(of: folder)) * 16)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(folder.breadcrumb)
                            }
                        } header: {
                            SectionHeader(title: "Move \(DisplayText.fileName(file.name)) to")
                        }
                        .listRowBackground(theme.surface)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(theme.canvas)
            .navigationTitle("Move to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func depth(of folder: FolderSummary) -> Int {
        max(0, folder.path.split(separator: "/").count - 1)
    }
}
