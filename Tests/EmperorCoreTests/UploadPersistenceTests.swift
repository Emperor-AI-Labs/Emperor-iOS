import XCTest
@testable import EmperorCore

/// The store and the chunk writer, against a real filesystem.
///
/// These use temporary directories rather than a fake, because what is being tested *is* the
/// disk behaviour: surviving a process that was killed, tolerating a half-written file, and
/// reading one chunk out of a large document without loading the rest.
final class UploadPersistenceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uploads-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> UploadManifestStore { UploadManifestStore(directory: root) }

    private func makeManifest(
        id: String = "up_1", totalBytes: Int = 25, chunkSize: Int = 10, createdAt: Date = Date()
    ) -> UploadManifest {
        UploadManifest(
            id: id, fileName: "brief.pdf", folderName: "Matters", totalBytes: totalBytes,
            chunkSize: chunkSize, sourcePath: "/tmp/brief.pdf", createdAt: createdAt)
    }

    // MARK: - Surviving the process

    /// The whole point: the app can be killed and relaunched by the system purely to be handed
    /// a finished transfer, and it must still know what that transfer was part of.
    func testAManifestSurvivesBeingWrittenAndReadBackByAFreshStore() throws {
        try makeStore().save(makeManifest())

        // A different instance, as a relaunched process would have.
        let reloaded = UploadManifestStore(directory: root).load(id: "up_1")

        XCTAssertEqual(reloaded?.id, "up_1")
        XCTAssertEqual(reloaded?.fileName, "brief.pdf")
        XCTAssertEqual(reloaded?.chunkCount, 3)
    }

    func testCompletedChunksSurviveTheRoundTrip() throws {
        let store = makeStore()
        var manifest = makeManifest()
        manifest.markCompleted(0)
        manifest.markCompleted(2)
        try store.save(manifest)

        let reloaded = try XCTUnwrap(UploadManifestStore(directory: root).load(id: "up_1"))
        XCTAssertEqual(reloaded.completed, [0, 2])
        XCTAssertEqual(reloaded.pending, [1])
    }

    /// Two chunks can finish close enough together that recording against an in-memory copy
    /// drops one. Recording goes through disk each time for exactly that reason.
    func testRecordingCompletionsIndependentlyDoesNotLoseEither() throws {
        let store = makeStore()
        try store.save(makeManifest())

        store.recordCompletion(id: "up_1", index: 0)
        store.recordCompletion(id: "up_1", index: 2)

        let reloaded = try XCTUnwrap(store.load(id: "up_1"))
        XCTAssertEqual(reloaded.completed, [0, 2], "the second write must not clobber the first")
    }

    func testRecordingAgainstAnUnknownUploadIsIgnored() {
        XCTAssertNil(makeStore().recordCompletion(id: "never-existed", index: 0))
    }

    // MARK: - Tolerating damage

    /// A kill partway through a write leaves a truncated file. Throwing on it would lose the
    /// other uploads too, so a bad manifest is skipped rather than fatal.
    func testACorruptManifestIsSkippedRatherThanBreakingTheRest() throws {
        let store = makeStore()
        try store.save(makeManifest(id: "good_1"))
        try Data("{ this is not json".utf8)
            .write(to: root.appendingPathComponent("broken_1.manifest.json"))

        let all = store.all()

        XCTAssertEqual(all.map(\.id), ["good_1"])
        XCTAssertNil(store.load(id: "broken_1"))
    }

    func testUnrelatedFilesInTheDirectoryAreIgnored() throws {
        let store = makeStore()
        try store.save(makeManifest())
        try Data("noise".utf8).write(to: root.appendingPathComponent("notes.txt"))

        XCTAssertEqual(store.all().count, 1)
    }

    func testManifestsComeBackNewestFirst() throws {
        let store = makeStore()
        try store.save(makeManifest(id: "old", createdAt: Date(timeIntervalSince1970: 100)))
        try store.save(makeManifest(id: "new", createdAt: Date(timeIntervalSince1970: 900)))

        XCTAssertEqual(store.all().map(\.id), ["new", "old"])
    }

    // MARK: - Cleanup

    /// Every abandoned upload holds a copy of a client's document. Leaving them indefinitely is
    /// a privacy problem, not just a disk one.
    func testAnExpiredUploadIsDiscardedWithItsPayload() throws {
        let store = makeStore()
        let old = makeManifest(id: "stale", createdAt: Date(timeIntervalSince1970: 0))
        try store.save(old)
        try FileManager.default.createDirectory(
            at: store.payloadDirectory(for: "stale"), withIntermediateDirectories: true)
        try Data("bytes".utf8).write(to: store.chunkBodyURL(for: "stale", index: 0))

        store.discardExpired(olderThan: 60, now: Date(timeIntervalSince1970: 10_000))

        XCTAssertTrue(store.all().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.payloadDirectory(for: "stale").path),
            "the staged document must go with the manifest")
    }

    /// A large scan on a courtroom connection can genuinely take hours. Deleting a live
    /// upload's source is worse than keeping a dead one a while longer.
    func testARecentUploadIsLeftAlone() throws {
        let store = makeStore()
        try store.save(makeManifest(id: "live", createdAt: Date(timeIntervalSince1970: 9_990)))

        store.discardExpired(olderThan: 60, now: Date(timeIntervalSince1970: 10_000))

        XCTAssertEqual(store.all().map(\.id), ["live"])
    }

    /// The residue of a crash between staging the bytes and writing the manifest: a directory
    /// of document data nothing will ever claim.
    func testAnOrphanedPayloadDirectoryIsCleanedUp() throws {
        let store = makeStore()
        try store.save(makeManifest(id: "claimed"))
        try FileManager.default.createDirectory(
            at: store.payloadDirectory(for: "claimed"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: store.payloadDirectory(for: "orphan"), withIntermediateDirectories: true)

        store.discardOrphanedPayloads()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.payloadDirectory(for: "claimed").path),
            "a payload with a live manifest must survive")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.payloadDirectory(for: "orphan").path))
    }

    // MARK: - Writing a chunk body

    private func writeSource(_ bytes: [UInt8]) throws -> URL {
        let url = root.appendingPathComponent("source.bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func fields(index: Int, count: Int, size: Int, total: Int) -> MultipartChunk.Fields {
        MultipartChunk.Fields(
            userID: "42", fileName: "brief.pdf", folderName: "Matters", uploadID: "up_1",
            chunkIndex: index, chunkCount: count, chunkSize: size, totalBytes: total)
    }

    /// The body must contain exactly the chunk's own bytes — not the start of the file, and not
    /// the whole of it.
    func testAChunkBodyCarriesOnlyThatChunksBytes() throws {
        let source = try writeSource(Array(0..<30).map(UInt8.init))
        let destination = root.appendingPathComponent("chunk.part")
        let boundary = "TestBoundary"

        try MultipartChunk.write(
            chunkAt: 10..<20, from: source, to: destination,
            fields: fields(index: 1, count: 3, size: 10, total: 30), boundary: boundary)

        let written = try Data(contentsOf: destination)
        let header = MultipartChunk.header(
            fields: fields(index: 1, count: 3, size: 10, total: 30), boundary: boundary)
        let payload = written.dropFirst(header.count)
            .dropLast(MultipartChunk.trailer(boundary: boundary).count)
        XCTAssertEqual(Array(payload), Array(10..<20).map(UInt8.init))
    }

    /// `chunkSize` is what makes the server write at an absolute offset. Without it the route
    /// appends, and enqueuing every chunk at once — which is the whole design — corrupts the
    /// document.
    func testEveryChunkBodyCarriesTheChunkSize() throws {
        let source = try writeSource(Array(repeating: 7, count: 30))
        let destination = root.appendingPathComponent("chunk.part")

        try MultipartChunk.write(
            chunkAt: 0..<10, from: source, to: destination,
            fields: fields(index: 0, count: 3, size: 10, total: 30), boundary: "B")

        let text = String(decoding: try Data(contentsOf: destination), as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"chunkSize\""), "chunkSize must always be sent")
        XCTAssertTrue(text.contains("name=\"uploadId\""))
        XCTAssertTrue(text.contains("name=\"chunkIndex\""))
    }

    /// The file part is ignored entirely without a `filename` parameter — the server answers
    /// 200 and stores nothing, which looks exactly like success.
    func testTheFilePartCarriesAFilename() throws {
        let source = try writeSource(Array(repeating: 1, count: 5))
        let destination = root.appendingPathComponent("chunk.part")

        try MultipartChunk.write(
            chunkAt: 0..<5, from: source, to: destination,
            fields: fields(index: 0, count: 1, size: 10, total: 5), boundary: "B")

        let text = String(decoding: try Data(contentsOf: destination), as: UTF8.self)
        XCTAssertTrue(text.contains("filename=\"brief.pdf\""))
    }

    /// The foreground path builds its body in memory and the background path writes one to
    /// disk. If those ever differ, the difference ships in the one nothing can test.
    func testTheDiskBodyIsIdenticalToTheInMemoryBody() throws {
        let bytes = Array(0..<25).map(UInt8.init)
        let source = try writeSource(bytes)
        let destination = root.appendingPathComponent("chunk.part")
        let f = fields(index: 1, count: 3, size: 10, total: 25)

        try MultipartChunk.write(
            chunkAt: 10..<20, from: source, to: destination, fields: f, boundary: "B")

        let fromDisk = try Data(contentsOf: destination)
        let inMemory = MultipartChunk.body(
            chunk: Data(bytes[10..<20]), fields: f, boundary: "B")
        XCTAssertEqual(fromDisk, inMemory)
    }

    /// If the document shrank after the manifest recorded its size, sending a short chunk would
    /// leave every later chunk at the wrong offset in a file the server still calls complete.
    func testAShortReadIsRefusedRatherThanSentTruncated() throws {
        let source = try writeSource(Array(repeating: 3, count: 12))
        let destination = root.appendingPathComponent("chunk.part")

        XCTAssertThrowsError(
            try MultipartChunk.write(
                chunkAt: 10..<20, from: source, to: destination,
                fields: fields(index: 1, count: 2, size: 10, total: 20), boundary: "B")
        ) { error in
            XCTAssertEqual(
                error as? MultipartChunk.ChunkError,
                .shortRead(expected: 10, got: 2))
        }
    }

    func testAMissingSourceIsReportedRatherThanTrapping() {
        XCTAssertThrowsError(
            try MultipartChunk.write(
                chunkAt: 0..<10, from: root.appendingPathComponent("gone.bin"),
                to: root.appendingPathComponent("chunk.part"),
                fields: fields(index: 0, count: 1, size: 10, total: 10), boundary: "B")
        )
    }

    /// The reason for seeking rather than loading: the document this feature exists for is big
    /// enough that holding it in memory is what gets the app killed.
    func testALargeSourceIsReadOneChunkAtATime() throws {
        let size = 4 * 1024 * 1024
        let source = root.appendingPathComponent("large.bin")
        try Data(repeating: 9, count: size).write(to: source)
        let destination = root.appendingPathComponent("chunk.part")
        let chunkSize = 512 * 1024

        try MultipartChunk.write(
            chunkAt: (size - chunkSize)..<size, from: source, to: destination,
            fields: fields(index: 7, count: 8, size: chunkSize, total: size), boundary: "B")

        let written = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int
        let overhead = MultipartChunk.header(
            fields: fields(index: 7, count: 8, size: chunkSize, total: size), boundary: "B").count
            + MultipartChunk.trailer(boundary: "B").count
        XCTAssertEqual(written, chunkSize + overhead, "only the last chunk should be in the body")
    }
}
