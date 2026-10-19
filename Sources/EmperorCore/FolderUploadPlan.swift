import Foundation

/// A whole folder picked for upload, worked out before a byte is sent: which files go, where each
/// one lands, which were left out and why, and how much it all comes to.
///
/// The web's folder upload is the model (`src/components/upload/UploadModal.jsx`, the uploader in
/// `src/components/chat/DmsSidebar.jsx`, `destinationFor` in `src/lib/uploadDuplicates.js`). A
/// folder pick names every file by its path from the picked folder down —
/// `Wadhwa/Orders/2025-01-04.pdf` — and that path becomes the file's folder on the server, so the
/// folder's structure survives: `Wadhwa` and `Wadhwa/Orders` appear in My Files as folders. The
/// picked folder's own name leads, unless the destination already ends in a folder of that name
/// (re-dropping `Wadhwa` onto `Clients/Wadhwa` must not make `Clients/Wadhwa/Wadhwa`). At the top
/// level the folder lands under its own name, which is why a folder — unlike a loose file — may be
/// uploaded there.
///
/// What is left out, in the web's order: operating-system debris (`UploadJunk`), silently; then,
/// each said out loud, a type the library does not hold, a file over 500 MB, and anything past
/// 200 files. Nothing here touches the disk; the screen enumerates the folder and hands over
/// relative paths and sizes.
struct FolderUploadPlan: Equatable, Sendable {

    /// One file found in the picked folder.
    struct Source: Equatable, Sendable {
        /// From the picked folder down, its own name first: `Wadhwa/Orders/Order.pdf`.
        let relativePath: String
        let size: Int
    }

    /// One file that will be uploaded.
    struct Entry: Equatable, Sendable, Identifiable {
        let relativePath: String
        /// Where it lands, `/`-joined, as `/upload-chunk` takes it.
        let folderName: String
        let fileName: String
        let size: Int
        /// Whether it lands directly in the destination rather than in a folder beneath it.
        let isTopLevel: Bool

        var id: String { relativePath }
    }

    /// A file that will not be uploaded, and why.
    struct Skipped: Equatable, Sendable {
        enum Reason: Equatable, Sendable {
            case unsupportedType
            case tooLarge
            case overLimit
        }
        let relativePath: String
        let reason: Reason

        var fileName: String { FolderUploadPlan.lastSegment(of: relativePath) }

        /// The web's words for each, in its toast.
        var reasonText: String {
            switch reason {
            case .unsupportedType: return "not a type the library holds"
            case .tooLarge: return "over 500 MB"
            case .overLimit: return "over the \(FolderUploadPlan.maxFileCount)-file limit"
            }
        }
    }

    /// Per upload, as the web caps it (`MAX_FILE_COUNT` in `DmsSidebar.jsx`).
    static let maxFileCount = 200
    /// Per file (`MAX_FILE_BYTES`).
    static let maxFileBytes = 500 * 1024 * 1024

    /// The destination chosen, `""` for the top level.
    let chosenDestination: String
    /// Where the batch actually goes: the chosen folder, or — at the top level — the picked
    /// folder's own name.
    let destination: String
    /// The picked folder's name, as its files' paths begin.
    let pickedFolderName: String
    let entries: [Entry]
    let skipped: [Skipped]
    /// Operating-system files dropped without a word. Counted for tests, never shown.
    let junkCount: Int

    init(sources: [Source], destination chosen: String) {
        let chosen = FileBrowser.normalized(chosen)
        var kept: [Source] = []
        var junk = 0
        for source in sources {
            if UploadJunk.isJunkPath(source.relativePath) { junk += 1 } else { kept.append(source) }
        }
        let picked = kept.lazy
            .compactMap { $0.relativePath.split(separator: "/").first.map(String.init) }
            .first ?? ""
        let destination = chosen.isEmpty ? picked : chosen

        var entries: [Entry] = []
        var skipped: [Skipped] = []
        var seen = Set<String>()
        for source in kept {
            let name = Self.lastSegment(of: source.relativePath)
            if !LibraryUpload.isAccepted(fileName: name) {
                skipped.append(Skipped(relativePath: source.relativePath, reason: .unsupportedType))
                continue
            }
            if source.size > Self.maxFileBytes {
                skipped.append(Skipped(relativePath: source.relativePath, reason: .tooLarge))
                continue
            }
            // The same path twice cannot come out of one folder; ignored rather than counted.
            guard seen.insert(source.relativePath).inserted else { continue }
            if entries.count >= Self.maxFileCount {
                skipped.append(Skipped(relativePath: source.relativePath, reason: .overLimit))
                continue
            }
            let landing = Self.destination(
                forRelativePath: source.relativePath, name: name, in: destination)
            entries.append(Entry(
                relativePath: source.relativePath,
                folderName: landing.folderName,
                fileName: landing.fileName,
                size: max(0, source.size),
                isTopLevel: Self.normFolder(landing.folderName) == Self.normFolder(destination)))
        }

        self.chosenDestination = chosen
        self.destination = destination
        self.pickedFolderName = picked
        self.entries = entries
        self.skipped = skipped
        self.junkCount = junk
    }

    // MARK: - The web's rules

    /// A port of `destinationFor` (`src/lib/uploadDuplicates.js`): where a file picked as part of
    /// a folder lands, and under what name.
    ///
    /// - Parameters:
    ///   - relativePath: the file's path from the picked folder down, the folder's name first.
    ///   - name: the file's own name, used when the path has no folder in it.
    ///   - folder: the destination.
    static func destination(
        forRelativePath relativePath: String, name: String, in folder: String
    ) -> (folderName: String, fileName: String) {
        var parts = relativePath.split(separator: "/").map(String.init)
        let fileName = parts.count > 1 ? parts.removeLast() : name
        // The picked folder's own name is dropped when the destination already ends in it.
        let leaf = folder.split(separator: "/").last.map(String.init) ?? ""
        if let first = parts.first, !leaf.isEmpty, normFolder(first) == normFolder(leaf) {
            parts.removeFirst()
        }
        let sub = parts.joined(separator: "/")
        guard !sub.isEmpty else { return (folder, fileName) }
        // Never reached from the screens, which always have a destination; the web would write
        // a leading slash here, which names the same place.
        guard !folder.isEmpty else { return (sub, fileName) }
        return ("\(folder)/\(sub)", fileName)
    }

    /// The web's `normFolder`: trimmed, lower-cased, and every character outside
    /// `[a-z0-9._/-]` an underscore — the server's sanitiser, so two spellings of one folder
    /// compare equal. Per UTF-16 code unit, as the JavaScript runs.
    static func normFolder(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._/-".utf16)
        let underscore = "_".utf16.first!
        return String(
            decoding: lowered.utf16.map { allowed.contains($0) ? $0 : underscore },
            as: UTF16.self)
    }

    static func lastSegment(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    // MARK: - Figures

    var isEmpty: Bool { entries.isEmpty }

    var totalBytes: Int { entries.reduce(0) { $0 + $1.size } }

    /// The distinct folders the files land in, in the order first met.
    var folderNames: [String] {
        var seen = Set<String>()
        return entries.map(\.folderName).filter { seen.insert($0).inserted }
    }

    /// Where each file is going, by its path — what the uploader needs beside the bytes.
    var folderByRelativePath: [String: String] {
        Dictionary(entries.map { ($0.relativePath, $0.folderName) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Wording

    /// "Upload “Wadhwa”?"
    var confirmTitle: String {
        "Upload “\(DisplayText.fileName(pickedFolderName))”?"
    }

    /// Said before anything is queued, as the web's folder confirmation does: a folder can pull
    /// in far more than the person glanced at.
    var confirmMessage: String {
        let count = FileBrowser.count(entries.count, "document")
        let place = chosenDestination.isEmpty
            ? "a new folder at the top of My Files"
            : Self.breadcrumb(chosenDestination)
        let folders = folderNames.count > 1
            ? " across \(FileBrowser.count(folderNames.count, "folder"))" : ""
        let size = UploadProgressFormat.size(bytes: totalBytes)
        var text = "\(count)\(folders) will be uploaded to \(place), keeping the folder’s structure."
        if !size.isEmpty { text += " \(size) in all." }
        if let note = skippedNotice { text += " " + note }
        return text
    }

    /// "Upload 48"
    var confirmLabel: String { "Upload \(entries.count)" }

    /// What was left out, naming the first three — `nil` when nothing was. Operating-system
    /// files are never mentioned: nobody chose them.
    var skippedNotice: String? {
        guard !skipped.isEmpty else { return nil }
        let preview = skipped.prefix(3).map { "\($0.fileName) (\($0.reasonText))" }
        let more = skipped.count - preview.count
        let listed = more > 0
            ? preview.joined(separator: ", ") + " and \(more) more"
            : DisplayText.list(preview)
        let noun = skipped.count == 1 ? "file was" : "files were"
        return "\(skipped.count) \(noun) left out: \(listed)."
    }

    /// Why nothing will be uploaded, when nothing will.
    var emptyMessage: String {
        if let note = skippedNotice {
            return "Nothing in that folder can go into the library. " + note
        }
        return "That folder has no documents in it."
    }

    static func breadcrumb(_ path: String) -> String {
        path.split(separator: "/").map { DisplayText.fileName(String($0)) }.joined(separator: " / ")
    }

    // MARK: - The duplicate question

    /// What to ask about each entry, given the server's verdicts.
    ///
    /// As the web's `classifyUploads`: the server judges a name clash against the destination
    /// only, so its "would replace" verdict is trusted only for a file that lands directly there.
    /// For a file bound for a folder beneath it, the library as last read stands in — a document
    /// of the same name already in that very folder is a clash worth asking about. A same-bytes
    /// copy filed anywhere is asked about wherever the new one lands. A file with no hash or no
    /// verdict is uploaded without a question, because the check must never block an upload
    /// (`DuplicateCheck`).
    ///
    /// - Parameters:
    ///   - hashes: one per entry, in order; `nil` for a file that could not be read to hash it.
    ///   - existing: the library's documents, for the clash check below the destination.
    func decisions(
        hashes: [String?], results: [DuplicateCheck.Result], existing: [FileNode.StoredFile]
    ) -> [DuplicateCheck.Decision] {
        let verdicts = LibraryUpload.decisions(forHashes: hashes, results: results)
        var held: [String: FileNode.StoredFile] = [:]
        for file in existing {
            let key = Self.normFolder(file.folderPath) + "\u{0}" + UploadService.sanitize(fileName: file.name)
            if held[key] == nil { held[key] = file }
        }
        return entries.enumerated().map { index, entry in
            let verdict = index < verdicts.count ? verdicts[index] : .upload
            if entry.isTopLevel { return verdict }
            if case .alreadyHeld = verdict { return verdict }
            let key = Self.normFolder(entry.folderName) + "\u{0}" + UploadService.sanitize(fileName: entry.fileName)
            if let clash = held[key] {
                return .wouldOverwrite(DuplicateCheck.Conflict(
                    folder: entry.folderName, fileName: clash.name, size: clash.size))
            }
            return .upload
        }
    }
}
