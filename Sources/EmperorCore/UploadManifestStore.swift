import Foundation

/// Where in-flight uploads are remembered.
///
/// Every write is atomic and every read tolerates a file that is missing, truncated or from an
/// older build. That is not defensiveness for its own sake: the process can be killed at any
/// moment, including partway through a write, and the next launch may be the system handing
/// back a finished transfer. A store that threw on a half-written file would lose an upload
/// that had actually completed.
///
/// Kept in `Application Support` rather than `Caches`, because the system may purge `Caches`
/// under pressure — losing the tally while the transfer it describes is still running.
struct UploadManifestStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Uploads", isDirectory: true)
    }

    /// Where the copied source document and the per-chunk bodies live for one upload.
    ///
    /// One directory per upload so that discarding it is a single recursive remove, and so an
    /// abandoned upload cannot leave chunk files that a later upload mistakes for its own.
    func payloadDirectory(for id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    func chunkBodyURL(for id: String, index: Int) -> URL {
        payloadDirectory(for: id).appendingPathComponent("chunk-\(index).part")
    }

    private func manifestURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).manifest.json")
    }

    // MARK: - Reading and writing

    func save(_ manifest: UploadManifest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL(for: manifest.id), options: .atomic)
    }

    func load(id: String) -> UploadManifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UploadManifest.self, from: data)
    }

    /// Every manifest on disk, newest first.
    ///
    /// A file that will not decode is skipped rather than throwing: one corrupt manifest must
    /// not make the other in-flight uploads unreachable.
    func all() -> [UploadManifest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".manifest.json") }
            .map { String($0.dropLast(".manifest.json".count)) }
            .compactMap { load(id: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Records a chunk and returns the updated manifest, or `nil` if it is not one of ours.
    ///
    /// Read-modify-write against disk rather than against an in-memory copy, because a
    /// relaunched app has no in-memory copy, and because two chunks can complete close enough
    /// together that a stale copy would drop one of them.
    @discardableResult
    func recordCompletion(id: String, index: Int) -> UploadManifest? {
        guard var manifest = load(id: id) else { return nil }
        manifest.markCompleted(index)
        try? save(manifest)
        return manifest
    }

    // MARK: - Cleanup

    /// Removes the manifest and everything staged for it.
    func discard(id: String) {
        try? FileManager.default.removeItem(at: manifestURL(for: id))
        try? FileManager.default.removeItem(at: payloadDirectory(for: id))
    }

    /// Drops uploads old enough that they cannot still be running.
    ///
    /// Without this, a transfer abandoned by a crash keeps its copy of the document — which for
    /// this app is a client's scanned brief — on disk indefinitely. The default is deliberately
    /// generous: a large scan on a courtroom connection may genuinely take hours, and deleting
    /// a live upload's source is worse than keeping a dead one a while longer.
    func discardExpired(olderThan age: TimeInterval = 7 * 24 * 60 * 60, now: Date) {
        for manifest in all() where now.timeIntervalSince(manifest.createdAt) > age {
            discard(id: manifest.id)
        }
    }

    /// Payload directories with no surviving manifest.
    ///
    /// These are the residue of a crash between staging the bytes and writing the manifest.
    /// Nothing will ever claim them, and each one holds a copy of a document.
    func discardOrphanedPayloads() {
        let known = Set(all().map(\.id))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where !name.hasSuffix(".manifest.json") && !known.contains(name) {
            var isDirectory: ObjCBool = false
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
