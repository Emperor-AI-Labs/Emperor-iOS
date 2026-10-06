import Foundation
#if canImport(Darwin)
import Observation
#endif

// MARK: - Naming

/// The name a document handed to the app will be saved under.
///
/// The person can change the name but not the type: the extension is what the library files a
/// document by, and the server keeps a document's extension whatever it is renamed to
/// (`rename-file`), so letting it be edited here would only promise a change that cannot happen.
enum IncomingDocumentName {

    /// Splits `Order.final.pdf` into `Order.final` and `pdf`. A leading dot is part of the name,
    /// not an extension — the same rule `LibraryUpload.isAccepted` reads names by.
    static func split(_ fileName: String) -> (base: String, ext: String) {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
            return (fileName, "")
        }
        return (String(fileName[..<dot]), String(fileName[fileName.index(after: dot)...]))
    }

    /// Photos the library cannot hold as they are, and so are converted to JPEG before upload.
    ///
    /// A photo shared from the Photos app is usually HEIC, which the platform neither accepts
    /// nor lists (`LibraryUpload.acceptedExtensions`) — the reason `LibraryUploadFlow` converts
    /// photos picked inside the app, too.
    static let convertedExtensions: Set<String> = ["heic", "heif"]

    static func needsConversion(_ fileName: String) -> Bool {
        convertedExtensions.contains(split(fileName).ext.lowercased())
    }

    /// The extension it will be uploaded with: its own, or `jpg` for a converted photo.
    static func uploadExtension(for fileName: String) -> String {
        needsConversion(fileName) ? "jpg" : split(fileName).ext
    }

    /// The name joined back up, trimmed.
    static func fileName(base: String, ext: String) -> String {
        let name = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    /// What the server will store it as, said only when that is more than spaces becoming
    /// underscores — those read back as spaces everywhere in the app, so they are no surprise.
    static func savedAsNotice(for fileName: String) -> String? {
        let stored = UploadService.sanitize(fileName: fileName)
        guard stored != fileName.replacingOccurrences(of: " ", with: "_") else { return nil }
        return "It will be saved as \(stored)."
    }
}

// MARK: - Documents waiting

/// A document another app handed to Emperor, held on this device until it is saved or let go.
struct IncomingDocument: Identifiable, Equatable, Sendable {
    /// The folder it is held in, which also orders the queue: it starts with the moment it came.
    let id: String
    /// The app's own copy.
    let url: URL

    /// The name it arrived with.
    var originalName: String { url.lastPathComponent }
}

/// Where documents handed to the app wait — one folder each, under Application Support.
///
/// **The folder is the queue's memory.** A document that arrives while nobody is signed in has
/// to survive the app being closed before someone does, so the copies are kept on disk and the
/// queue is rebuilt from them at launch. Each waits in a folder of its own, named for the moment
/// it arrived, so two documents with the same name cannot collide and the order they came in is
/// the order the folders sort in. The order is read from the folder names, not from file dates,
/// which would also be a privacy-manifest declaration this app does not otherwise need.
///
/// Not the temporary directory, which the system may empty while the app is not running — the
/// one moment a waiting document most needs to be kept.
struct IncomingDocumentStore: Sendable {
    let directory: URL

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("IncomingDocuments", isDirectory: true)
    }

    /// Takes a copy of a handed-over file.
    ///
    /// - Parameters:
    ///   - moving: whether the source is the app's own to move — the copy iOS puts in the app's
    ///     inbox. Anything else is copied, never moved: moving a file out of another app's
    ///     storage would take it from its owner.
    ///   - sequence: separates documents that arrive in the same millisecond, in arrival order.
    func adopt(_ source: URL, moving: Bool, now: Date, sequence: Int) throws -> IncomingDocument {
        let fileManager = FileManager.default
        let id = Self.folderName(for: now, sequence: sequence)
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        #if canImport(Darwin)
        // Waiting documents are client papers on their way to the account, not data to restore
        // onto another phone from a backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        try? excluded.setResourceValues(values)
        #endif

        let name = source.lastPathComponent.isEmpty ? "Document" : source.lastPathComponent
        let destination = folder.appendingPathComponent(name)
        do {
            if moving {
                do {
                    try fileManager.moveItem(at: source, to: destination)
                } catch {
                    try fileManager.copyItem(at: source, to: destination)
                }
            } else {
                try fileManager.copyItem(at: source, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return IncomingDocument(id: id, url: destination)
    }

    /// Everything waiting, oldest first. A folder left empty — its document gone — is tidied
    /// away rather than listed.
    func pending() -> [IncomingDocument] {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }

        var documents: [IncomingDocument] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard Self.isDirectory(folder) else { continue }
            let contents = (try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            let files = contents
                .filter { !Self.isDirectory($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let file = files.first {
                documents.append(IncomingDocument(id: folder.lastPathComponent, url: file))
            } else {
                try? fileManager.removeItem(at: folder)
            }
        }
        return documents
    }

    /// Removes a document's folder — its copy, and anything made from it, such as a converted
    /// photo. Only ever inside this store's own directory.
    func remove(_ document: IncomingDocument) {
        let folder = directory.appendingPathComponent(document.id, isDirectory: true)
        guard !document.id.isEmpty, !document.id.contains("/"), document.id != ".", document.id != ".."
        else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Milliseconds since 1970, zero-padded so the names sort as the times do, then the sequence.
    static func folderName(for date: Date, sequence: Int) -> String {
        let millis = String(max(0, Int64((date.timeIntervalSince1970 * 1000).rounded(.down))))
        let paddedMillis = String(repeating: "0", count: max(0, 15 - millis.count)) + millis
        let seq = String(max(0, sequence))
        let paddedSequence = String(repeating: "0", count: max(0, 6 - seq.count)) + seq
        return "\(paddedMillis)-\(paddedSequence)-\(UUID().uuidString.prefix(8))"
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

/// Documents handed to the app, one after another.
///
/// The share sheet's "Open in Emperor" — or Files' — hands over one document at a time, but
/// several chosen together arrive together; each is asked about in turn, in the order it came.
/// A document that arrives while nobody is signed in waits (`IncomingDocumentStore` keeps it on
/// disk) and is asked about once someone is.
///
/// **Signing out lets every waiting document go.** It was handed over during the session that
/// just ended, and the next person to sign in on this phone must not be offered someone else's
/// papers to file into their own account.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class IncomingDocumentQueue {

    enum Copy {
        static let couldNotReceive = "That document couldn't be opened in Emperor. Try sharing it again."
    }

    private(set) var documents: [IncomingDocument]
    /// A document that could not be taken in, worded for the person. Cleared once shown.
    var receiveError: String?

    private let store: IncomingDocumentStore
    private let now: @Sendable () -> Date
    private var sequence = 0

    init(store: IncomingDocumentStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
        self.documents = store.pending()
    }

    /// The one being asked about.
    var current: IncomingDocument? { documents.first }

    /// How many are waiting behind it.
    var waitingCount: Int { max(0, documents.count - 1) }

    /// Takes a document handed to the app.
    @discardableResult
    func receive(_ url: URL, moving: Bool) -> IncomingDocument? {
        sequence += 1
        do {
            let document = try store.adopt(url, moving: moving, now: now(), sequence: sequence)
            documents.append(document)
            return document
        } catch {
            receiveError = Copy.couldNotReceive
            return nil
        }
    }

    /// Done with a document — saved, or not wanted. Its copy goes, and the next one comes up.
    func finish(_ document: IncomingDocument) {
        documents.removeAll { $0.id == document.id }
        store.remove(document)
    }

    /// Lets every waiting document go — see the type's notes on signing out.
    func discardAll() {
        documents = []
        store.removeAll()
    }
}

// MARK: - Saving one

/// The device's part of saving a handed-over document: reading it, converting a photo, asking
/// whether the library already holds it, and handing it to the uploader. `LibraryUploadFlow` in
/// the app; a stand-in in tests.
@MainActor
protocol IncomingDocumentFiling: AnyObject {
    /// The file to send — the stored copy, or for a photo the library cannot hold, a JPEG made
    /// from it. `nil` if it cannot be read.
    func prepare(_ document: IncomingDocument, as fileName: String) async -> URL?
    /// Whether the library already holds it. `.upload` when there is nothing to ask — including
    /// when the question could not be put, which must never stop a save (`DuplicateCheck`).
    func review(
        _ file: URL, named fileName: String, into folder: String
    ) async -> DuplicateCheck.Decision
    /// Starts the upload. The failure worded for the person, or `nil` once it is under way.
    func upload(_ file: URL, named fileName: String, into folder: String) async -> String?
}

/// "Save to My Files": the sheet a handed-over document opens in.
///
/// Three things are asked — what to call it, where to file it, and, only if the library already
/// has it, whether to save it again — and then it goes through the same upload as a document
/// added from My Files, duplicate check and all.
///
/// The folders offered are the library's, read fresh, with the top level first. A document is
/// never filed loose at the top level: like My Files' own Add at the top level
/// (`MyFilesViewModel.uploadDestination`), the top-level choice files it into the same fixed
/// folder the attach picker uses, and says so by name.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class SaveIncomingDocumentModel {

    enum Copy {
        static let title = "Save to My Files"
        static let save = "Save"
        static let dontSave = "Don't save"
        static let nameRequired = "Give the document a name."
        static let unreadable = "That document couldn't be read, so it can't be saved."
        static let foldersFailed =
            "Your folders couldn't be loaded, so only the default folder is offered."
        static let savedDetail =
            "It carries on if you leave Emperor, and appears in My Files once it has been read."
        static let defaultFolderDetail = "Where documents go unless you choose a folder"

        static func refusal(_ ext: String) -> String {
            let type = ext.isEmpty ? "This kind of file" : "A .\(ext) file"
            return "\(type) can't be kept in your library. It holds PDF, Word, OpenDocument, RTF, "
                + "text, CSV, PNG and JPEG documents."
        }
    }

    enum Phase: Equatable {
        case editing
        /// Asking about duplicates, or handing the document to the uploader.
        case working
        /// The library already holds it, or a different document by that name; asking first.
        case confirming(DuplicateCheck.Decision)
        /// Under way, into this folder.
        case saved(folder: String)
    }

    /// A folder the document can be filed into.
    struct Destination: Identifiable, Equatable, Sendable {
        /// `""` for the top-level choice — see the type's notes.
        let path: String
        let title: String
        /// Folders inside folders, for indenting.
        let depth: Int
        /// Read aloud in place of the title, so two "2025"s can be told apart.
        let spokenLabel: String
        var detail: String?

        var id: String { path.isEmpty ? "\u{0}default" : path }
    }

    let document: IncomingDocument
    var baseName: String
    /// The type, kept whatever the name becomes — see `IncomingDocumentName`.
    let fileExtension: String
    /// Where it goes. `""` is the default folder.
    var destinationPath = ""

    private(set) var folders: [FolderSummary] = []
    private(set) var foldersState: LoadState = .idle
    private(set) var phase: Phase = .editing
    /// Why the last attempt failed, worded for the person. Cleared by the next one.
    var errorMessage: String?

    private let files: any FileProviding
    private let filer: any IncomingDocumentFiling
    private var prepared: (url: URL, fileName: String)?

    init(document: IncomingDocument, files: any FileProviding, filer: any IncomingDocumentFiling) {
        self.document = document
        self.files = files
        self.filer = filer
        let parts = IncomingDocumentName.split(document.originalName)
        self.baseName = parts.base
        self.fileExtension = IncomingDocumentName.uploadExtension(for: document.originalName)
    }

    // MARK: - The name

    /// The name it will be uploaded under.
    var fileName: String { IncomingDocumentName.fileName(base: baseName, ext: fileExtension) }

    var nameProblem: String? {
        baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Copy.nameRequired : nil
    }

    var savedAsNotice: String? {
        nameProblem == nil ? IncomingDocumentName.savedAsNotice(for: fileName) : nil
    }

    /// Why this document cannot go into the library at all, if it cannot.
    var refusal: String? {
        LibraryUpload.isAccepted(fileName: "file.\(fileExtension)") ? nil : Copy.refusal(fileExtension)
    }

    /// Whether a photo will be converted on the way — said, so a `.heic` becoming a `.jpg` is
    /// not a surprise.
    var isConvertedPhoto: Bool { IncomingDocumentName.needsConversion(document.originalName) }

    var canSave: Bool { nameProblem == nil && refusal == nil && phase == .editing }

    // MARK: - The folder

    /// The folder it will actually be filed into.
    var destinationFolder: String { MyFilesViewModel.uploadDestination(for: destinationPath) }

    var destinationTitle: String {
        destinations.first { $0.path == destinationPath }?.title
            ?? DisplayText.fileName(String(destinationFolder.split(separator: "/").last ?? ""))
    }

    /// The default first, then every folder in the library, parents above their children.
    var destinations: [Destination] {
        let defaultFolder = FileLibraryViewModel.uploadFolder
        var list = [Destination(
            path: "",
            title: DisplayText.fileName(defaultFolder),
            depth: 0,
            spokenLabel: DisplayText.fileName(defaultFolder),
            detail: Copy.defaultFolderDetail)]
        for folder in folders where folder.path != defaultFolder {
            list.append(Destination(
                path: folder.path,
                title: folder.displayName,
                depth: max(0, folder.path.split(separator: "/").count - 1),
                spokenLabel: folder.breadcrumb))
        }
        return list
    }

    func loadFolders() async {
        foldersState = .loading
        do {
            folders = FileBrowser.allFolders(in: try await files.tree())
            foldersState = .loaded
        } catch {
            foldersState = .failed(LoadFailure(error))
        }
        // A folder chosen before a refresh that no longer has it falls back to the default,
        // rather than uploading into a folder the person can no longer see.
        if !destinationPath.isEmpty, !folders.contains(where: { $0.path == destinationPath }) {
            destinationPath = ""
        }
    }

    func choose(_ destination: Destination) {
        destinationPath = destination.path
    }

    // MARK: - Saving

    /// Checks with the library, then uploads — or stops to ask, if it already holds it.
    func save() async {
        guard canSave else {
            errorMessage = nameProblem ?? refusal
            return
        }
        phase = .working
        errorMessage = nil
        let name = fileName
        guard let url = await filer.prepare(document, as: name) else {
            errorMessage = Copy.unreadable
            phase = .editing
            return
        }
        prepared = (url, name)
        let decision = await filer.review(url, named: name, into: destinationFolder)
        if decision == .upload {
            await upload()
        } else {
            phase = .confirming(decision)
        }
    }

    /// What the confirmation says. `nil` outside one.
    var confirmationMessage: String? {
        guard case .confirming(let decision) = phase else { return nil }
        return DuplicateCheck.message(for: decision, fileName: DisplayText.fileName(fileName))
    }

    /// The button that saves regardless — worded for what it does.
    var confirmationAction: String {
        if case .confirming(.wouldOverwrite) = phase { return "Replace it" }
        return "Save another copy"
    }

    /// Whether going ahead destroys something, so the button can say so in colour.
    var confirmationIsDestructive: Bool {
        if case .confirming(.wouldOverwrite) = phase { return true }
        return false
    }

    /// Saves after being told the library already has it.
    func saveAnyway() async {
        guard case .confirming = phase else { return }
        phase = .working
        await upload()
    }

    /// Back to the form, to change the name or the folder instead.
    func reconsider() {
        guard case .confirming = phase else { return }
        phase = .editing
    }

    private func upload() async {
        guard let prepared else {
            phase = .editing
            return
        }
        let folder = destinationFolder
        if let failure = await filer.upload(prepared.url, named: prepared.fileName, into: folder) {
            errorMessage = failure
            phase = .editing
        } else {
            phase = .saved(folder: folder)
        }
    }

    /// "Uploading to Bakshi", once it is under way.
    var savedHeadline: String? {
        guard case .saved(let folder) = phase else { return nil }
        let name = DisplayText.fileName(String(folder.split(separator: "/").last ?? ""))
        return "Uploading to \(name)"
    }
}
