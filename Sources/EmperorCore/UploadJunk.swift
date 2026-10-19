import Foundation

/// The files an operating system leaves in a folder, which are never documents: `.DS_Store`,
/// `Thumbs.db`, a `._Award.pdf` sidecar, anything under `__MACOSX/`.
///
/// A port of the platform's `src/lib/junkNames.js`, the one definition of "junk" that both the
/// web's upload dialog and the server's upload route use. A folder picked on a phone carries the
/// same debris as one picked on a laptop — a folder copied from a Mac onto a USB stick and then
/// into Files arrives with a sidecar beside every PDF — so a folder upload drops these before the
/// person sees the count, exactly as the web does, and without a word: they are not files anyone
/// chose. The server refuses them too, so sending one would only produce a failed row.
///
/// Every name here is reserved by an operating system and cannot be produced by a person naming a
/// file, which is what makes dropping them silently safe. Held to the JavaScript by golden data
/// (`scripts/generate-upload-junk-fixtures.mjs`).
enum UploadJunk {

    /// Exact reserved basenames, compared case-insensitively: macOS and Windows file systems are
    /// both case-insensitive, so the same file arrives as `.DS_Store` or `.ds_store`.
    private static let reservedNames: [String: String] = [
        // macOS
        ".ds_store": "macOS Finder directory state (.DS_Store)",
        "._.ds_store": "AppleDouble sidecar of .DS_Store",
        ".spotlight-v100": "macOS Spotlight index directory",
        ".trashes": "macOS per-volume trash directory",
        ".trash": "macOS trash directory",
        ".fseventsd": "macOS FSEvents log directory",
        ".temporaryitems": "macOS Finder temporary staging directory",
        ".apdisk": "macOS Time Machine volume-exclusion marker",
        ".localized": "macOS Finder localisation marker",
        ".documentrevisions-v100": "macOS document-revisions store",
        "__macosx": "macOS zip metadata directory (__MACOSX)",
        // Windows
        "thumbs.db": "Windows Explorer thumbnail cache (Thumbs.db)",
        "ehthumbs.db": "Windows Media Center thumbnail cache (ehthumbs.db)",
        "ehthumbs_vista.db": "Windows Media Center thumbnail cache (Vista)",
        "desktop.ini": "Windows Explorer folder customisation (desktop.ini)",
        "$recycle.bin": "Windows Recycle Bin directory",
        "recycler": "Windows Recycle Bin directory (legacy)",
        "system volume information": "Windows NTFS volume metadata directory",
        // Linux
        ".trash-1000": "Linux freedesktop trash directory",
        ".directory": "KDE folder view settings (.directory)",
    ]

    /// The last path component, treating `\` as a separator as well as `/` — an archive written
    /// on Windows yields `folder\Thumbs.db`.
    static func baseName(_ path: String) -> String {
        var trimmed = Substring(path)
        while let last = trimmed.last, last == "/" || last == "\\" { trimmed = trimmed.dropLast() }
        guard let separator = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) else {
            return String(trimmed)
        }
        return String(trimmed[trimmed.index(after: separator)...])
    }

    /// An AppleDouble resource-fork sidecar: `._Award.pdf`. A file named exactly `._` is not one.
    static func isAppleDoubleName(_ name: String) -> Bool {
        let base = baseName(name)
        // UTF-16 length, as the JavaScript measures it.
        return base.utf16.count > 2 && base.hasPrefix("._")
    }

    /// The Finder's custom-icon file: `Icon` followed by carriage returns. Plain `Icon` is an
    /// ordinary name and is not matched.
    static func isFinderIconName(_ name: String) -> Bool {
        let units = Array(baseName(name).utf16)
        let icon = Array("Icon".utf16)
        guard units.count > icon.count, Array(units.prefix(icon.count)) == icon else { return false }
        return units.dropFirst(icon.count).allSatisfy { $0 == 0x0D }
    }

    /// Why this one path component is platform junk, or `nil` when it is not.
    static func nameReason(_ name: String) -> String? {
        let base = baseName(name)
        if base.isEmpty || base == "." || base == ".." { return nil }
        if let exact = reservedNames[base.lowercased()] { return exact }
        if isFinderIconName(base) { return "macOS Finder custom-icon file (Icon\\r)" }
        if isAppleDoubleName(base) { return "AppleDouble resource-fork sidecar (._ prefix)" }
        // `Thumbs.db:encryptable` — an NTFS alternate data stream flattened into a name.
        if base.lowercased().hasPrefix("thumbs.db:") {
            return "Windows thumbnail cache alternate data stream"
        }
        return nil
    }

    static func isJunkName(_ name: String) -> Bool { nameReason(name) != nil }

    /// Why any component of the path is platform junk — `__MACOSX/Award.pdf` has an innocent
    /// basename and is still junk — or `nil` when none is.
    static func pathReason(_ path: String) -> String? {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        for (index, part) in parts.enumerated() {
            if let reason = nameReason(part) {
                return index == parts.count - 1 ? reason : "\(reason) — in path segment \"\(part)\""
            }
        }
        return nil
    }

    static func isJunkPath(_ path: String) -> Bool { pathReason(path) != nil }
}
