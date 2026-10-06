import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Whether the device has a route to the network at all, as the system last reported it.
///
/// Needed because this client *waits* for a connection rather than failing without one
/// (`waitsForConnectivity`, with a long timeout), so that an advocate who steps out of a dead
/// spot gets the answer they asked for. That is right for a request, and it means a request made
/// with no signal does not fail for minutes. A saved copy that stood in only once the request had
/// given up would arrive long after the person had given up too.
///
/// "Unknown" is not offline. Before the system has answered — and in every test that does not
/// say otherwise — the network is asked first, as it always was.
protocol ConnectivityReporting: Sendable {
    var isOffline: Bool { get }
}

/// When a copy kept on this device may stand in for the server, and what the screen says when
/// it does.
///
/// One rule for every screen that keeps copies — conversations, documents, matters — so they
/// cannot drift apart:
///
/// - **The network first.** A saved copy is shown before asking only when the system already
///   says there is no connection.
/// - **Only for a network that could not be reached.** A server that answered — with an error, a
///   refusal, "not found" — has said something about the item, and a saved copy would contradict
///   it.
/// - **Never written back.** A saved copy is for reading. See `ChatViewModel` for what that means
///   for a conversation, where writing back is destructive.
enum OfflineReading {

    /// Whether to open the saved copy before asking the network at all.
    static func opensSavedCopyFirst(_ connectivity: (any ConnectivityReporting)?) -> Bool {
        connectivity?.isOffline == true
    }

    /// Whether a failure lets a saved copy stand in.
    ///
    /// A timeout counts with the rest: from a corridor with one bar, a request that never came
    /// back and a request that could not be sent are the same afternoon.
    static func mayStandIn(after error: Error) -> Bool {
        DisplayText.isOffline(error)
    }

    /// "Offline — showing the copy saved 2 hours ago."
    ///
    /// Calm, and specific about age. The age is the part that matters: a practitioner deciding
    /// whether to rely on a saved answer or order needs to know whether it predates this morning.
    static func notice(savedAt: Date, now: Date = Date()) -> String {
        "Offline — showing the copy saved \(DisplayText.relative(savedAt, from: now))."
    }

    /// Why a question cannot be asked while a conversation's saved copy is on screen.
    static let askingPaused =
        "You can ask a question once the conversation reloads with a connection."
}

// MARK: - Documents

/// A document as the viewer shows it.
struct ViewableDocument: Equatable, Sendable {
    let data: Data
    /// The server's PDF rendering of a Word document, rather than the document itself.
    let isConvertedPreview: Bool
}

/// A document the server answered for but could not render, with the reason in words a person
/// can act on.
struct DocumentNotViewable: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Fetches a document the way the viewer shows it — one path for opening a document and for
/// saving it for offline, so the copy kept is exactly what opening it would have shown.
enum DocumentFetch {

    /// Word documents go through the server's converter when one is given; everything else is
    /// the file's own bytes.
    ///
    /// The converter is two requests, in order: the first converts and reports whether it worked,
    /// the second returns the bytes from the cache the first one warmed.
    ///
    /// - Throws: `DocumentNotViewable` when the converter answers `success: false` — which it
    ///   does with a 200, so the status code says nothing.
    static func fetch(
        _ attachment: ChatAttachment,
        files: any FileProviding,
        officePreview: (any OfficePreviewProviding)?
    ) async throws -> ViewableDocument {
        if OfficePreview.canPreview(fileName: attachment.name), let officePreview {
            let response = try await officePreview.preview(
                fileName: attachment.name, folderName: attachment.folderName)
            guard response.success == true else {
                throw DocumentNotViewable(message: OfficePreview.message(
                    forReason: response.reason, fallback: response.error))
            }
            let data = try await officePreview.previewPDF(
                fileName: attachment.name, folderName: attachment.folderName)
            return ViewableDocument(data: data, isConvertedPreview: true)
        }
        let data = try await files.fileData(
            name: attachment.name, folderName: attachment.folderName)
        return ViewableDocument(data: data, isConvertedPreview: false)
    }
}

/// Documents kept for reading without a connection.
///
/// Filed under the platform's identity for a document — `{folder, name}` — and under *which*
/// rendering was kept: a Word document is kept as the server's PDF of it, and a copy of one must
/// never be shown as the other.
struct OfflineDocuments: Sendable {
    let store: OfflineStore

    /// The document's path in the library, which is how My Files and a citation both name it.
    /// `nil`, `""` and `"."` all mean the storage root.
    static func path(name: String, folderName: String?) -> String {
        let folder = (folderName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !folder.isEmpty, folder != "." else { return name }
        return "\(folder)/\(name)"
    }

    static func key(path: String, converted: Bool) -> String {
        (converted ? "preview:" : "file:") + path
    }

    static func key(for attachment: ChatAttachment, converted: Bool) -> String {
        key(path: path(name: attachment.name, folderName: attachment.folderName),
            converted: converted)
    }

    /// The library path a key was made from.
    static func path(fromKey key: String) -> String {
        String(key.drop { $0 != ":" }.dropFirst())
    }

    /// The document's own name, from its key — for naming a copy that had to go.
    static func fileName(fromKey key: String) -> String {
        String(path(fromKey: key).split(separator: "/").last ?? "")
    }

    /// The rendering this app's viewer shows a document in: the converter's PDF for a Word
    /// document, the file itself for anything else.
    static func showsConverted(_ fileName: String) -> Bool {
        OfficePreview.canPreview(fileName: fileName)
    }

    private static func key(for attachment: ChatAttachment) -> String {
        key(for: attachment, converted: showsConverted(attachment.name))
    }

    func copy(of attachment: ChatAttachment, converted: Bool) -> (data: Data, savedAt: Date)? {
        store.open(Self.key(for: attachment, converted: converted))
    }

    @discardableResult
    func keep(_ document: ViewableDocument, of attachment: ChatAttachment, pin: Bool?)
        -> OfflineStore.SaveOutcome {
        store.save(
            document.data,
            for: Self.key(for: attachment, converted: document.isConvertedPreview),
            pin: pin)
    }

    /// Whether the document opens without a connection.
    func isAvailable(_ attachment: ChatAttachment) -> Bool {
        store.contains(Self.key(for: attachment))
    }

    /// Whether it was saved on purpose.
    func isSaved(_ attachment: ChatAttachment) -> Bool {
        store.isPinned(Self.key(for: attachment))
    }

    /// Marks a copy already on the device as saved on purpose.
    func pin(_ attachment: ChatAttachment) -> Bool {
        store.pin(Self.key(for: attachment))
    }

    func remove(_ attachment: ChatAttachment) {
        store.remove(Self.key(for: attachment, converted: true))
        store.remove(Self.key(for: attachment, converted: false))
    }

    /// Carries a copy to the document's new name or folder, after a rename or a move made here.
    func carry(_ attachment: ChatAttachment, to moved: ChatAttachment) {
        for converted in [true, false] {
            store.rekey(
                Self.key(for: attachment, converted: converted),
                to: Self.key(for: moved, converted: converted))
        }
    }

    /// Lets go of the automatic copies of documents no longer in the library — renamed, moved or
    /// deleted on the web or another phone. Only ever with a library the server has just sent: a
    /// cached one would throw away copies of documents that still exist.
    ///
    /// A document saved for offline on purpose is kept even then. The server files documents
    /// into folders of its own choosing, so a path can change without anyone deleting anything —
    /// and a saved conversation's citations still name the document where it was. It goes when
    /// the person removes it, clears offline copies, or room is needed for another saved one.
    ///
    /// An empty library prunes nothing: every document gone at once is likelier a bad reading
    /// than a library emptied.
    func prune(keepingPaths paths: Set<String>) {
        guard !paths.isEmpty else { return }
        store.removeAll { !$0.isPinned && !paths.contains(Self.path(fromKey: $0.key)) }
    }

    /// The paths with a copy, and those saved on purpose — for drawing a whole list of rows from
    /// one read of the index rather than one per row.
    var status: (available: Set<String>, saved: Set<String>) {
        var available = Set<String>()
        var saved = Set<String>()
        for entry in store.entries {
            let path = Self.path(fromKey: entry.key)
            available.insert(path)
            if entry.isPinned { saved.insert(path) }
        }
        return (available, saved)
    }
}

// MARK: - Settings

/// What Settings → Storage says about the copies kept offline.
struct OfflineStorageSummary: Equatable, Sendable {
    var bytes: Int
    var conversations: Int
    var documents: Int
    var matters: Int

    init(bytes: Int = 0, conversations: Int = 0, documents: Int = 0, matters: Int = 0) {
        self.bytes = bytes
        self.conversations = conversations
        self.documents = documents
        self.matters = matters
    }

    init(_ copies: OfflineCopies) {
        self.init(
            bytes: copies.totalBytes,
            conversations: copies.conversations.entries.count,
            documents: copies.documents.entries.count,
            matters: copies.matters.entries.count)
    }

    var isEmpty: Bool { conversations + documents + matters == 0 }

    /// "12.4 MB", or "None".
    var sizeText: String { isEmpty ? "None" : Self.size(bytes) }

    /// "2 conversations, 3 documents and 1 matter".
    var contentsText: String {
        guard !isEmpty else { return "Nothing is kept for offline reading yet." }
        func count(_ n: Int, _ noun: String) -> String? {
            n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")"
        }
        return DisplayText.list([
            count(conversations, "conversation"),
            count(documents, "document"),
            count(matters, "matter"),
        ].compactMap { $0 })
    }

    /// Decimal units, as iOS counts storage in its own Settings — so the figure here matches the
    /// one the person sees there. Hand-rolled because `ByteCountFormatter` words things
    /// differently on Linux, where this is tested.
    static func size(_ bytes: Int) -> String {
        let units = ["KB", "MB", "GB"]
        var value = Double(max(bytes, 0)) / 1_000
        var unit = 0
        while value >= 1_000, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        if unit == 0 {
            return "\(max(1, Int(value.rounded()))) KB"
        }
        let rounded = (value * 10).rounded() / 10
        let text = rounded == rounded.rounded()
            ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "\(text) \(units[unit])"
    }
}

extension OfflineStorageSummary {
    /// Said under the figure: what is kept, how much at most, and when it goes.
    static let explanation = """
        Conversations, documents and matters you open are kept on this device so they open \
        without a connection. Documents are held to \
        \(size(OfflineLibrary.documentBudget)): the least recently opened go first, and those \
        you saved for offline go last. Signing out removes all of it.
        """
}

/// Settings → Storage: how much is kept offline, and clearing it.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class OfflineStorageViewModel {
    private(set) var summary = OfflineStorageSummary()

    private let library: OfflineLibrary
    private let account: Int?

    /// - Parameter account: the signed-in account, whose copies are counted. `nil` counts
    ///   nothing — there is nobody to have kept anything for.
    init(library: OfflineLibrary, account: Int?) {
        self.library = library
        self.account = account
        refresh()
    }

    func refresh() {
        guard let account else {
            summary = OfflineStorageSummary()
            return
        }
        summary = OfflineStorageSummary(library.copies(for: account))
    }

    /// Removes every offline copy. Asked first, by the screen: a document saved for tomorrow's
    /// hearing is gone until it is next opened with a connection.
    func clear() {
        guard let account else { return }
        library.clear(keeping: account)
        refresh()
    }
}
