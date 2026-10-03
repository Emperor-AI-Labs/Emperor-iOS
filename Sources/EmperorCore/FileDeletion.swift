import Foundation

/// What is about to be deleted, and the confirmation that says so.
///
/// Built from the live tree at the moment the user asks, never from anything remembered, so the
/// numbers in the sentence are the numbers on screen (`openDelete`,
/// `src/pages/MyFilesPage.jsx:861-868`). The rules the web's dialog follows are kept: it names
/// what is going, counts what is going, and never lets a folder read like a file
/// (`DeleteDialog`, `src/pages/MyFilesPage.jsx:430-500`).
///
/// There is no undo anywhere in this product, so nothing here hints at one.
struct FileDeletion: Identifiable, Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case file(FileNode.StoredFile)
        case folder(FolderSummary)
    }

    let target: Target

    var id: String {
        switch target {
        case .file(let file): return "file:" + file.path
        case .folder(let folder): return "folder:" + folder.path
        }
    }

    /// How many documents stop existing. For a folder that is not the number of rows selected —
    /// which is exactly the confusion the sentence exists to remove.
    var documentCount: Int {
        switch target {
        case .file: return 1
        case .folder(let folder): return folder.documentCount
        }
    }

    var isFolder: Bool {
        if case .folder = target { return true }
        return false
    }

    init(file: FileNode.StoredFile) {
        target = .file(file)
    }

    /// `nil` for the storage root.
    ///
    /// The root is not a folder anyone made and cannot be deleted from here. It is refused when
    /// the confirmation is built, and again before the request is sent (`MyFilesViewModel`),
    /// because `.` and the empty string are both ways of naming it on these routes.
    init?(folder: FolderSummary) {
        guard !FileBrowser.normalized(folder.path).isEmpty else { return nil }
        target = .folder(folder)
    }

    // MARK: - Wording

    /// Names the item, in the same form its row shows it, so the person confirming recognises
    /// what they are confirming.
    var title: String {
        switch target {
        case .file(let file):
            return "Delete “\(DisplayText.fileName(file.name))”?"
        case .folder(let folder):
            return "Delete the folder “\(folder.displayName)”?"
        }
    }

    var message: String {
        switch target {
        case .file(let file):
            return "It will be permanently deleted from \(FileBrowser.location(of: file)), along with "
                + "the text and search index built from it. This cannot be undone."
        case .folder(let folder):
            let documents = folder.documentCount
            let subfolders = folder.subfolderCount
            if documents > 0 {
                // A folder deletion is a different kind of event from a document deletion, so
                // it opens by saying so rather than with a longer version of the same sentence.
                let opening = subfolders > 0
                    ? "Everything inside goes with it, including anything in its sub-folders. "
                    : "Everything inside goes with it. "
                let within = subfolders > 0
                    ? " in \(FileBrowser.count(subfolders, "sub-folder"))"
                    : ""
                return opening
                    + "\(FileBrowser.count(documents, "document"))\(within) will be permanently "
                    + "deleted, along with the text and search index built from "
                    + "\(documents == 1 ? "it" : "them"). This cannot be undone."
            }
            if subfolders > 0 {
                return "It holds \(FileBrowser.count(subfolders, "sub-folder")) and no documents, "
                    + "so no document will be lost. This cannot be undone."
            }
            return "It is empty, so no document will be lost. This cannot be undone."
        }
    }

    /// The destructive button. It carries the count, so the blast radius is on the control that
    /// causes it rather than in a sentence above it.
    var confirmLabel: String {
        switch target {
        case .file:
            return "Delete document"
        case .folder(let folder):
            return folder.documentCount > 0
                ? "Delete \(FileBrowser.count(folder.documentCount, "document"))"
                : "Delete folder"
        }
    }

    /// Said once the server has answered and the library has been re-read.
    var doneNotice: String {
        switch target {
        case .file(let file):
            return "\(DisplayText.fileName(file.name)) was deleted."
        case .folder(let folder):
            switch folder.documentCount {
            case 0: return "\(folder.displayName) was deleted."
            case 1: return "\(folder.displayName) and the document in it were deleted."
            default:
                return "\(folder.displayName) and the \(folder.documentCount) documents in it were deleted."
            }
        }
    }
}
