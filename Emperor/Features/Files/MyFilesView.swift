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
/// It opens on the folders, drawn as a file manager draws them — a grid of folder tiles — and a
/// tile opens its folder. Folders are pushed rather than expanded in place: a phone shows one
/// folder at a time, and the back button is the breadcrumb.
struct MyFilesView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var model: MyFilesViewModel?
    /// The folders opened, deepest last.
    ///
    /// Bound rather than built from `NavigationLink`s, because the tiles that open folders sit
    /// together in one row of a `List` (see `LibraryScreen.folderGrid`), and a list row holding
    /// several links is one where a tap can fire the wrong one, or all of them. Plain buttons
    /// that append here each answer only their own tap.
    @State private var openFolders: [FolderRoute] = []

    /// A document to open on arrival — a tapped search result (`SpotlightRouting`): its folders
    /// are opened on the way down, and it is previewed.
    private let opening: DocumentRoute?
    /// How Done closes the screen when it was not presented by SwiftUI — see `TopPresenter`.
    private let onDone: (() -> Void)?

    init(opening: DocumentRoute? = nil, onDone: (() -> Void)? = nil) {
        self.opening = opening
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack(path: $openFolders) {
            Group {
                if let model {
                    LibraryScreen(model: model, path: "", openFolders: $openFolders)
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
                    Button("Done") {
                        if let onDone { onDone() } else { dismiss() }
                    }
                }
            }
            .navigationDestination(for: FolderRoute.self) { route in
                if let model {
                    LibraryScreen(model: model, path: route.path, openFolders: $openFolders)
                }
            }
            .task {
                guard model == nil else { return }
                let created = MyFilesViewModel(
                    service: session.files, manager: session.fileManagement,
                    // The library kept between launches, and the documents kept for offline:
                    // together, what lets My Files be used with no signal.
                    cache: session.cache,
                    offline: session.offlineCopies.map { OfflineDocuments(store: $0.documents) },
                    officePreview: session.officePreview)
                // Each reading of the library keeps the device's search in step with it.
                created.onTreeLoaded = { AppSpotlight.shared.libraryLoaded($0) }
                model = created
                await created.load()
                if let opening {
                    openFolders = opening.folderStack.map { FolderRoute(path: $0) }
                    created.requestPreview(of: opening.path)
                }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let model: MyFilesViewModel
    /// `""` for the top level.
    let path: String
    /// The navigation stack's path. A folder tile opens its folder by appending to it.
    @Binding var openFolders: [FolderRoute]

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
            // A document asked for from outside — a search result — previews on the screen of
            // the folder it is in, once that screen is showing.
            .onChange(of: model.pendingPreview, initial: true) { _, _ in
                if let file = model.takePreview(in: path) {
                    previewing = Previewing(file: file)
                }
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
            // The viewer keeps what it opens, so the offline marks are read again once it closes.
            .sheet(item: $previewing, onDismiss: { model.refreshOfflineStatus() }) { item in
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
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, Spacing.sm)

            ListStateView(
                presentation: model.presentation(for: model.section),
                retry: { await model.load() }
            ) {
                switch model.section {
                case .folders: foldersList(at: "", query: model.query)
                case .recent: recentList
                case .favorites: favoritesList
                }
            } empty: {
                if model.showsNoSearchResults(in: model.section) {
                    NoResultsView(query: model.query)
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
        EmptyStateView(copy.title, systemImage: copy.systemImage, message: copy.message)
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
                NoResultsView(query: query)
            } else {
                // A search reaches the whole subtree, so a hit can sit at any depth: every tile
                // and every row says where it is.
                libraryList(
                    folders: results.folders, files: results.files,
                    filesTitle: "Documents", showsLocations: true)
            }
        } else if let listing = model.listing(at: path) {
            libraryList(
                folders: listing.folders, files: listing.files,
                // At the top level these are the documents filed in no folder. The web shows
                // them only under Recent; listing them here keeps them reachable.
                filesTitle: path.isEmpty ? "Not in a folder" : "Documents",
                showsLocations: false)
            .refreshable { await model.load() }
        }
    }

    /// The folders as a grid of tiles, then the documents as rows.
    ///
    /// One `List` holds both, with the grid as a single row of it, because a document's swipe
    /// actions exist only inside a `List`. A `ScrollView` of cards would have drawn the grid more
    /// naturally and dropped them — and with them the quickest way to star, share or delete, and
    /// the actions VoiceOver lists for a row. So the grid's row gives up its background, insets
    /// and separator, the tiles sit on the canvas as cards of their own, and the documents follow
    /// in the same inset-grouped card as every other list in the app.
    private func libraryList(
        folders: [FolderSummary], files: [FileNode.StoredFile],
        filesTitle: String, showsLocations: Bool
    ) -> some View {
        List {
            if !folders.isEmpty {
                Section {
                    folderGrid(folders, showsLocations: showsLocations)
                } header: {
                    SectionHeader(title: "Folders", detail: "\(folders.count)")
                }
            }
            if !files.isEmpty {
                Section {
                    ForEach(files, id: \.path) { file in
                        documentRow(
                            file, location: showsLocations ? FileBrowser.location(of: file) : nil)
                    }
                } header: {
                    SectionHeader(title: filesTitle, detail: "\(files.count)")
                }
                .listRowBackground(theme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
    }

    /// Two tiles across on a phone, as many as fit on an iPad; one at the accessibility text
    /// sizes, where a half-width tile would wrap a folder's name a word to a line.
    private var tileColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 140), spacing: Spacing.md, alignment: .top)]
    }

    private func folderGrid(_ folders: [FolderSummary], showsLocations: Bool) -> some View {
        LazyVGrid(columns: tileColumns, alignment: .leading, spacing: Spacing.md) {
            ForEach(folders) { folder in
                folderTile(
                    folder, location: showsLocations ? FileBrowser.location(of: folder) : nil)
            }
        }
        // Room for the cards' shadow, which the row would otherwise cut off.
        .padding(.vertical, Spacing.xs)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Rows

    /// A folder, as a tile that opens it.
    ///
    /// One element to VoiceOver — a button that says the folder's name and what it holds. A
    /// long press offers Rename and Delete. A tile has no swipe actions, which VoiceOver would
    /// have listed as the row's actions, so the same two are offered to it directly.
    private func folderTile(_ folder: FolderSummary, location: String?) -> some View {
        Button {
            openFolders.append(FolderRoute(path: folder.path))
        } label: {
            FolderTileLabel(folder: folder, location: location, isBusy: model.isBusy(folder.path))
        }
        // Plain, so that each tile in the shared row answers only its own tap.
        .buttonStyle(.plain)
        .contentShape(
            .contextMenuPreview,
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityLabel(folder.spokenLabel(location: location))
        .accessibilityHint("Opens the folder")
        .accessibilityIdentifier("folder-\(folder.path)")
        .accessibilityAction(named: "Rename") {
            renameText = folder.name
            renamingFolder = folder
        }
        .accessibilityAction(named: "Delete folder") {
            model.requestDeletion(of: folder)
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
                file: file, location: location, date: date, isBusy: model.isBusy(file.path),
                offline: model.offlineStatus(of: file))
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
            offlineAction(file)
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
            offlineAction(file)
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

    /// "Save for offline", or "Remove offline copy" once it is saved. A copy kept only because the
    /// document was opened is offered for saving: it would otherwise be the first to go.
    @ViewBuilder
    private func offlineAction(_ file: FileNode.StoredFile) -> some View {
        if model.offlineStatus(of: file) == .saved {
            Button {
                model.removeOfflineCopy(file)
            } label: {
                Label("Remove offline copy", systemImage: "arrow.down.circle.dotted")
            }
            .tint(theme.textTertiary)
        } else {
            Button {
                Task { await model.saveForOffline(file) }
            } label: {
                Label("Save for offline", systemImage: "arrow.down.circle")
            }
            .tint(theme.accent)
        }
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
            EmptyStateView(
                "Could not prepare that document",
                systemImage: "exclamationmark.triangle",
                message: "There was no room to save a copy to share. Free some space and try again.",
                tone: .warning)
        }
    }
}

/// A folder as a file manager draws one: a large gold folder, its name beneath, and what it
/// holds.
///
/// The name is held to two lines, and two lines are reserved even for a short one, so every
/// tile in a row of the grid is the same height and the names line up. The counts are
/// `contentsSummary` — documents at every depth, folders directly inside — as the web's folder
/// card counts them. In a search, where folders from several levels are listed together, the
/// tile also says which folder it is in.
private struct FolderTileLabel: View {
    @Environment(\.theme) private var theme

    let folder: FolderSummary
    var location: String?
    /// An edit — a rename, a deletion — is running against this folder.
    var isBusy = false

    var body: some View {
        VStack(spacing: Spacing.sm + 2) {
            FolderGlyph()
            VStack(spacing: Spacing.xxs + 1) {
                Text(folder.displayName)
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                Text(folder.contentsSummary)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                if let location {
                    Label(location, systemImage: "folder")
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.md)
        .frame(maxWidth: .infinity)
        .panel()
        .overlay(alignment: .topTrailing) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(Spacing.sm)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// The folder at the head of a tile: `IconTile`'s gold square and white glyph, drawn larger than
/// any row's icon, because on a tile the folder is the thing being pointed at.
///
/// The web draws its folders in the same gold (`src/pages/MyFilesPage.jsx`, `FolderCard`), as
/// does the Move sheet below. Scaled with Dynamic Type up to a ceiling, as `IconTile` is, so a
/// large text size grows the folder without letting it crowd out the name.
private struct FolderGlyph: View {
    @Environment(\.theme) private var theme

    @ScaledMetric(relativeTo: .title) private var scaledSide: CGFloat = 56

    var body: some View {
        let side = min(scaledSide, 76)
        return Image(systemName: "folder.fill")
            .font(.system(size: side * 0.46, weight: .semibold))
            .foregroundStyle(theme.onTile)
            .frame(width: side, height: side)
            .background(
                theme.tile(.gold),
                in: RoundedRectangle(cornerRadius: side * 0.26, style: .continuous))
            .accessibilityHidden(true)
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
                    EmptyStateView(
                        "Nowhere else to put it",
                        systemImage: "folder",
                        message: "Create another folder first, then move the document into it.")
                } else {
                    List {
                        Section {
                            ForEach(destinations) { folder in
                                Button {
                                    onChoose(folder)
                                    dismiss()
                                } label: {
                                    HStack(spacing: Spacing.md) {
                                        IconTile(systemImage: "folder", hue: .gold, size: .small)
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
