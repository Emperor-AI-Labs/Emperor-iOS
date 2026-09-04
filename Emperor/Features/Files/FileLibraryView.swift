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
                guard case .success(let urls) = outcome, let model else { return }
                Task {
                    for url in urls {
                        // A picker URL is security-scoped and must be opened before reading.
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        guard let data = try? Data(contentsOf: url) else { continue }
                        await model.upload(data: data, fileName: url.lastPathComponent)
                    }
                }
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
            if model.isUploading {
                // Ingestion runs after the upload's 200, so this stays up until the server
                // reports the file readable — not until the bytes land.
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.uploadProgress < 1
                         ? "Uploading…"
                         : "Reading the document…")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                    ProgressView(value: model.uploadProgress)
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
