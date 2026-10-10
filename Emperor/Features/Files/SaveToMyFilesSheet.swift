import SwiftUI
import UIKit

/// Documents other apps hand to Emperor — "Open in Emperor" from Files, Mail, WhatsApp or the
/// share sheet — and the one place they are taken in.
///
/// The app declares the document types it can hold (`CFBundleDocumentTypes` in `project.yml`),
/// and with `LSSupportsOpeningDocumentsInPlace` off iOS hands over a **copy**, in the app's own
/// inbox. That is the whole mechanism: no share extension, which would need an app group to pass
/// the file across — a capability a sideloading tool's free signing may rename or drop.
///
/// Process-wide, because a document can arrive before any screen exists — it is what launched
/// the app — and while nobody is signed in, in which case it waits (`IncomingDocumentQueue`).
@MainActor
final class AppIncomingDocuments {
    static let shared = AppIncomingDocuments()

    let queue: IncomingDocumentQueue

    private init() {
        #if DEBUG
        if UITestSupport.isActive {
            // A store of the run's own, emptied at every launch: a document one test left
            // waiting would otherwise greet every test after it the moment it signed in.
            let store = IncomingDocumentStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("UITestIncomingDocuments", isDirectory: true))
            store.removeAll()
            queue = IncomingDocumentQueue(store: store)
            return
        }
        #endif
        queue = IncomingDocumentQueue(
            store: IncomingDocumentStore(directory: IncomingDocumentStore.defaultDirectory()))
    }

    /// From `onOpenURL`. Only a file is taken; any other URL is left for whoever handles it.
    ///
    /// - Returns: whether the URL was a file, and so this handler's.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        // Not needed for the inbox copy iOS makes, but harmless — and needed if a document is
        // ever handed over in place.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let isOwnCopy = Self.isOwnCopy(url)
        queue.receive(url, moving: isOwnCopy)
        // The inbox copy is ours; if it could only be copied, not moved, it is removed here so
        // it does not sit in the inbox for ever.
        if isOwnCopy, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        return true
    }

    /// Whether the file is in the app's own storage — the `Documents/Inbox` copy iOS makes, or
    /// one the UI tests made — and so the app's to move rather than copy.
    static func isOwnCopy(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let owned = [
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            FileManager.default.temporaryDirectory,
        ]
        .compactMap { $0?.standardizedFileURL.resolvingSymlinksInPath().path }
        return owned.contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}

// MARK: - Filing through the library's upload

/// `IncomingDocumentFiling` through the same upload My Files uses: `LibraryUploadFlow`'s duplicate
/// check, then the background uploader.
@MainActor
final class LibraryUploadFiler: IncomingDocumentFiling {
    private let duplicates: any DuplicateChecking

    init(duplicates: any DuplicateChecking) {
        self.duplicates = duplicates
    }

    func prepare(_ document: IncomingDocument, as fileName: String) async -> URL? {
        guard IncomingDocumentName.needsConversion(document.originalName) else {
            return FileManager.default.isReadableFile(atPath: document.url.path) ? document.url : nil
        }
        // A HEIC photo, converted to the JPEG the library holds — as photos picked inside the
        // app are (`LibraryUploadFlow.documents(from:)`). Kept beside the original, so letting the
        // document go removes the conversion too.
        guard let image = UIImage(contentsOfFile: document.url.path),
              let jpeg = image.jpegData(compressionQuality: 0.85)
        else { return nil }
        let folder = document.url.deletingLastPathComponent()
            .appendingPathComponent("converted", isDirectory: true)
        let url = folder.appendingPathComponent(UUID().uuidString + ".jpg")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try jpeg.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    func review(
        _ file: URL, named fileName: String, into folder: String
    ) async -> DuplicateCheck.Decision {
        let review = await LibraryUploadFlow.review(
            [PickedDocument(url: file, fileName: fileName)], into: folder, duplicates: duplicates)
        return review?.items.first?.decision ?? .upload
    }

    func upload(_ file: URL, named fileName: String, into folder: String) async -> String? {
        await LibraryUploadFlow.upload([(file, fileName)], into: folder)
    }
}

#if DEBUG
/// The UI tests' filer: the duplicate check as in the app, and the upload sent the foreground way
/// so it goes through the stub transport.
///
/// The background uploader cannot be used under test: a background `URLSession` does not consult
/// `URLProtocol`, so it would put real requests on the wire — which is why `EmperorApp` leaves it
/// unconfigured in UI-test mode. This sends the same chunk request through `UploadService`, and
/// counts the document as under way once its bytes have reached the stub — the moment the real
/// path reports, too.
@MainActor
final class StubTransportFiler: IncomingDocumentFiling {
    private let base: LibraryUploadFiler
    private let uploads: any UploadProviding

    init(duplicates: any DuplicateChecking, uploads: any UploadProviding) {
        self.base = LibraryUploadFiler(duplicates: duplicates)
        self.uploads = uploads
    }

    func prepare(_ document: IncomingDocument, as fileName: String) async -> URL? {
        await base.prepare(document, as: fileName)
    }

    func review(
        _ file: URL, named fileName: String, into folder: String
    ) async -> DuplicateCheck.Decision {
        await base.review(file, named: fileName, into: folder)
    }

    func upload(_ file: URL, named fileName: String, into folder: String) async -> String? {
        guard let data = try? Data(contentsOf: file) else {
            return SaveIncomingDocumentModel.Copy.unreadable
        }
        do {
            for try await event in uploads.upload(data: data, fileName: fileName, folderName: folder) {
                if case .progress(let sent, let total) = event, sent >= total { return nil }
            }
            return nil
        } catch {
            return DisplayText.message(for: error)
        }
    }
}
#endif

// MARK: - Presenting it

/// Asks about each waiting document, one after another, while the signed-in app is showing.
///
/// Applied to `MainTabView` by `RootView`, so nothing is asked on the sign-in screen, behind the
/// disclaimer, or in front of the first-sign-in role question: a document that arrives then waits
/// until the tab view appears. Presented over whatever is showing (`TopPresenter`), because a
/// document is most often handed over while one of More's screens is open.
struct IncomingDocumentPresenting: ViewModifier {
    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.practice) private var practice

    @State private var presenter = TopPresenter()

    private var queue: IncomingDocumentQueue { AppIncomingDocuments.shared.queue }

    func body(content: Content) -> some View {
        content
            .onChange(of: queue.current?.id, initial: true) { _, id in
                if id == nil {
                    presenter.dismiss()
                } else {
                    // A beat after the tab view arrives: presenting in the same pass as the
                    // sign-in screen gives way can land on a controller that is leaving.
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        present()
                    }
                }
            }
            // Signing out takes the tab view away; whatever it was asking goes with it.
            .onDisappear { presenter.dismiss(animated: false) }
            .alert("Couldn't open that document", isPresented: Binding(
                get: { queue.receiveError != nil },
                set: { if !$0 { queue.receiveError = nil } }
            )) {
                Button("OK") { queue.receiveError = nil }
            } message: {
                Text(queue.receiveError ?? "")
            }
    }

    private func present() {
        let topPresenter = presenter
        guard queue.current != nil, !topPresenter.isPresenting, session.currentUser != nil
        else { return }
        topPresenter.present(
            SaveToMyFilesSheet(
                queue: queue, files: session.files, filer: makeFiler(),
                close: { topPresenter.dismiss() })
                .environment(session)
                .environment(\.theme, theme)
                .environment(\.practice, practice)
                .preferredColorScheme(theme.colorScheme)
                // The text accent, as the app's root uses — presented on its own, this sheet does
                // not inherit it.
                .tint(theme.accentText),
            modal: true)
    }

    private func makeFiler() -> any IncomingDocumentFiling {
        #if DEBUG
        if UITestSupport.isActive {
            return StubTransportFiler(duplicates: session.duplicates, uploads: session.uploads)
        }
        #endif
        return LibraryUploadFiler(duplicates: session.duplicates)
    }
}

extension View {
    /// See `IncomingDocumentPresenting`.
    func presentsIncomingDocuments() -> some View {
        modifier(IncomingDocumentPresenting())
    }
}

// MARK: - The sheet

/// The waiting documents, the first of them asked about. Each is a fresh form, so one document's
/// name or folder never carries into the next.
struct SaveToMyFilesSheet: View {
    let queue: IncomingDocumentQueue
    let files: any FileProviding
    let filer: any IncomingDocumentFiling
    let close: () -> Void

    var body: some View {
        if let document = queue.current {
            SaveIncomingDocumentForm(
                document: document, waiting: queue.waitingCount, files: files, filer: filer,
                onFinish: { finish(document) })
                .id(document.id)
        } else {
            Color.clear.onAppear { close() }
        }
    }

    private func finish(_ document: IncomingDocument) {
        queue.finish(document)
        if queue.current == nil { close() }
    }
}

/// "Save to My Files" for one document: its name, its folder, and Save.
private struct SaveIncomingDocumentForm: View {
    @Environment(\.theme) private var theme

    @State private var model: SaveIncomingDocumentModel
    let waiting: Int
    let onFinish: () -> Void

    private typealias Copy = SaveIncomingDocumentModel.Copy

    init(
        document: IncomingDocument, waiting: Int, files: any FileProviding,
        filer: any IncomingDocumentFiling, onFinish: @escaping () -> Void
    ) {
        _model = State(initialValue: SaveIncomingDocumentModel(
            document: document, files: files, filer: filer))
        self.waiting = waiting
        self.onFinish = onFinish
    }

    private var isSaved: Bool {
        if case .saved = model.phase { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSaved {
                    savedView
                } else {
                    form
                }
            }
            .background(theme.canvas)
            .navigationTitle(Copy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            .task {
                if model.foldersState == .idle { await model.loadFolders() }
            }
        }
    }

    /// Once it is under way the only way on is the confirmation's own button, so both items step
    /// aside then.
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if !isSaved {
                Button(Copy.dontSave) { onFinish() }
                    .disabled(model.phase == .working)
                    .accessibilityIdentifier("incoming-dont-save")
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if isSaved {
                EmptyView()
            } else if model.phase == .working {
                ProgressView()
            } else {
                Button(Copy.save) { Task { await model.save() } }
                    .fontWeight(.semibold)
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("incoming-save")
            }
        }
    }

    // MARK: - The form

    private var form: some View {
        @Bindable var bindable = model
        return List {
            Section {
                documentHeader
            }
            .listRowBackground(theme.surface)

            Section {
                HStack(spacing: Spacing.xs) {
                    TextField("Name", text: $bindable.baseName)
                        .font(.brand(.body))
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .accessibilityIdentifier("incoming-name")
                    if !model.fileExtension.isEmpty {
                        Text(".\(model.fileExtension)")
                            .font(.brand(.body))
                            .foregroundStyle(theme.textSecondary)
                            .accessibilityLabel("File type \(model.fileExtension.uppercased())")
                    }
                }
                .disabled(model.phase != .editing)
            } header: {
                SectionHeader(title: "Name")
            } footer: {
                nameFooter
            }
            .listRowBackground(theme.surface)

            Section {
                NavigationLink {
                    DestinationList(model: model)
                } label: {
                    IconRowLabel(
                        title: "Folder", systemImage: "folder", hue: .gold,
                        value: model.destinationTitle)
                }
                .disabled(model.phase != .editing)
                .accessibilityIdentifier("incoming-folder")
            } header: {
                SectionHeader(title: "Save to")
            } footer: {
                if model.foldersState.failure != nil {
                    footnote(Copy.foldersFailed)
                }
            }
            .listRowBackground(theme.surface)

            if let message = model.confirmationMessage {
                confirmation(message)
            }

            if let error = model.errorMessage ?? model.refusal {
                Section {
                    Label {
                        Text(error)
                            .font(.brand(.subheadline))
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(theme.warning)
                    }
                    .accessibilityIdentifier("incoming-error")
                }
                .listRowBackground(theme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("incoming-form")
        // What a save ran into — a refusal, a failure, a name the library already holds — lands
        // in the form below the Save that VoiceOver was on, so it is said as well.
        .onChange(of: model.errorMessage ?? model.refusal) { _, problem in
            if let problem { VoiceOver.announce(problem) }
        }
        .onChange(of: model.confirmationMessage) { _, message in
            if let message { VoiceOver.announce(message) }
        }
    }

    /// The document as it arrived — named as the other app named it, so the person can see which
    /// one is being asked about when several came together.
    private var documentHeader: some View {
        HStack(spacing: Spacing.md) {
            IconTile(systemImage: symbol, hue: .steel, size: .large)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(model.document.originalName)
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(2)
                Text(waiting == 0
                     ? "Shared with Emperor"
                     : "Shared with Emperor · \(waiting) more after this")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch model.fileExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png": return "photo"
        default: return "doc.text"
        }
    }

    @ViewBuilder
    private var nameFooter: some View {
        if let problem = model.nameProblem {
            footnote(problem)
        } else if model.isConvertedPhoto {
            footnote("Saved as a JPEG, the photo format your library holds."
                     + (model.savedAsNotice.map { " " + $0 } ?? ""))
        } else if let notice = model.savedAsNotice {
            footnote(notice)
        } else {
            footnote("The file type stays the same, whatever you call it.")
        }
    }

    /// The library already has it, or a different document by that name: asked inline rather
    /// than in a second sheet, since there is only the one document to ask about.
    private func confirmation(_ message: String) -> some View {
        Section {
            Text(message)
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("incoming-duplicate")
            Button(role: model.confirmationIsDestructive ? .destructive : nil) {
                Task { await model.saveAnyway() }
            } label: {
                Text(model.confirmationAction)
                    .font(.brand(.body, weight: .semibold))
                    .foregroundStyle(model.confirmationIsDestructive ? theme.danger : theme.accentText)
            }
            .accessibilityIdentifier("incoming-save-anyway")
            Button {
                model.reconsider()
            } label: {
                Text("Change the name or folder")
                    .font(.brand(.body))
                    .foregroundStyle(theme.accentText)
            }
        } header: {
            SectionHeader(title: "Already in your library")
        }
        .listRowBackground(theme.surface)
    }

    // MARK: - Done

    private var savedView: some View {
        EmptyStateView(
            model.savedHeadline ?? "Uploading",
            systemImage: "checkmark",
            message: Copy.savedDetail,
            tone: .success
        ) {
            Button(waiting == 0 ? "Done" : "Next document") { onFinish() }
                .buttonStyle(.primaryAction)
                .accessibilityIdentifier("incoming-done")
        }
        .accessibilityIdentifier("incoming-saved")
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.brand(.caption))
            .foregroundStyle(theme.textSecondary)
    }
}

/// Choosing the folder: the default first, then the library's folders, children indented under
/// their parents — the shape of My Files' own "Move to…".
private struct DestinationList: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let model: SaveIncomingDocumentModel

    var body: some View {
        List {
            Section {
                ForEach(model.destinations) { destination in
                    row(destination)
                }
            } footer: {
                if model.foldersState.failure != nil {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(SaveIncomingDocumentModel.Copy.foldersFailed)
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                        Button {
                            Task { await model.loadFolders() }
                        } label: {
                            Text("Try again")
                                .font(.brand(.caption, weight: .semibold))
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
            .listRowBackground(theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.groupedBackground)
        .overlay {
            if model.foldersState.isLoading && model.folders.isEmpty {
                ProgressView()
            }
        }
        .navigationTitle("Choose a folder")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("incoming-folders")
    }

    private func row(_ destination: SaveIncomingDocumentModel.Destination) -> some View {
        let isChosen = destination.path == model.destinationPath
        return Button {
            model.choose(destination)
            dismiss()
        } label: {
            HStack(spacing: Spacing.md) {
                IconTile(systemImage: destination.path.isEmpty ? "tray.and.arrow.down" : "folder",
                         hue: .gold, size: .small)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(destination.title)
                        .font(.brand(.body))
                        .foregroundStyle(theme.textPrimary)
                        .dynamicLineLimit(1)
                    if let detail = destination.detail {
                        Text(detail)
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if isChosen {
                    Image(systemName: "checkmark")
                        .font(.brand(.body, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, CGFloat(destination.depth) * 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(destination.spokenLabel)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier(
            "incoming-folder-\(destination.path.isEmpty ? "default" : destination.path)")
    }
}
