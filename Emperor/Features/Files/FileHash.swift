import CryptoKit
import Foundation

/// The sha256 of a file's bytes, which is what `/check-duplicates` matches on.
///
/// Lives in the app layer rather than the core because CryptoKit is a Darwin framework, and the
/// core is compiled on Linux for its tests. That is the right side of the line: the hash itself
/// is a standard primitive that does not need a test of its own, whereas the decisions taken
/// from the answer — which are what actually go wrong — are all in `DuplicateCheck` and are
/// tested there.
enum FileHash {

    /// Read in blocks rather than whole.
    ///
    /// The documents this is asked about are the same 200-page scans the background uploader
    /// exists for. Hashing by loading the file would reintroduce, at the moment *before* an
    /// upload, exactly the memory spike that upload was restructured to avoid.
    private static let blockSize = 1 * 1024 * 1024

    /// - Returns: the lowercase hex digest, or `nil` if the file could not be read.
    ///
    ///   `nil` is not an error to report. A file that cannot be hashed simply is not asked
    ///   about — it uploads without a prompt, which is the same outcome as the check being
    ///   unavailable, and the server dedupes on arrival regardless.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let block = try? handle.read(upToCount: blockSize), !block.isEmpty else { break }
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
