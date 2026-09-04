import XCTest
@testable import EmperorCore

/// The half of background upload that can be proved without a device.
///
/// The delegate plumbing needs Darwin and a real app lifecycle. The arithmetic underneath it
/// does not — and the arithmetic is where the damage is, because every mistake in it is silent.
/// A wrong byte range still uploads, still answers 200, and still reports the file ready; what
/// arrives is a corrupted brief nobody notices until it is quoted in court.
final class BackgroundUploadTests: XCTestCase {

    private func makeManifest(
        totalBytes: Int, chunkSize: Int, completed: Set<Int> = []
    ) -> UploadManifest {
        UploadManifest(
            id: "up_1", fileName: "brief.pdf", folderName: "Matters",
            totalBytes: totalBytes, chunkSize: chunkSize, sourcePath: "/tmp/brief.pdf",
            createdAt: Date(timeIntervalSince1970: 0), completed: completed)
    }

    // MARK: - Chunk arithmetic

    func testAnExactMultipleDoesNotProduceATrailingEmptyChunk() {
        let manifest = makeManifest(totalBytes: 30, chunkSize: 10)
        XCTAssertEqual(manifest.chunkCount, 3)
        XCTAssertEqual(manifest.range(of: 2), 20..<30)
    }

    /// The common case, and the one a naive `total / size` gets wrong: the remainder needs its
    /// own chunk or the tail of the document is never sent.
    func testARemainderGetsItsOwnShortChunk() {
        let manifest = makeManifest(totalBytes: 25, chunkSize: 10)
        XCTAssertEqual(manifest.chunkCount, 3)
        XCTAssertEqual(manifest.range(of: 2), 20..<25, "the last chunk must stop at the file end")
    }

    /// Reading `chunkSize` bytes for the final chunk would run past the end of the file.
    func testTheLastChunkIsClampedToTheFile() {
        let manifest = makeManifest(totalBytes: 25, chunkSize: 10)
        XCTAssertEqual(manifest.range(of: 2).count, 5)
        XCTAssertLessThanOrEqual(manifest.range(of: manifest.chunkCount - 1).upperBound, 25)
    }

    func testASingleChunkCoversTheWholeFile() {
        let manifest = makeManifest(totalBytes: 7, chunkSize: 10)
        XCTAssertEqual(manifest.chunkCount, 1)
        XCTAssertEqual(manifest.range(of: 0), 0..<7)
    }

    /// One empty chunk rather than none. An upload of zero chunks would poll for the ingestion
    /// of a file the server was never told about, then time out with something vague.
    func testAZeroByteFileIsStillOneChunk() {
        let manifest = makeManifest(totalBytes: 0, chunkSize: 10)
        XCTAssertEqual(manifest.chunkCount, 1)
        XCTAssertEqual(manifest.range(of: 0), 0..<0)
    }

    /// A chunk size of zero would divide by zero and make every range empty — an upload that
    /// reports success having sent nothing.
    func testANonPositiveChunkSizeIsRefusedRatherThanDividingByZero() {
        for size in [0, -1, Int.min] {
            let manifest = makeManifest(totalBytes: 25, chunkSize: size)
            XCTAssertGreaterThan(manifest.chunkSize, 0, "chunk size \(size)")
            XCTAssertGreaterThan(manifest.chunkCount, 0, "chunk size \(size)")
        }
    }

    func testAnOutOfRangeIndexIsEmptyRatherThanATrap() {
        let manifest = makeManifest(totalBytes: 25, chunkSize: 10)
        XCTAssertTrue(manifest.range(of: -1).isEmpty)
        XCTAssertTrue(manifest.range(of: 99).isEmpty)
    }

    /// Every byte of the file must be covered exactly once across all chunks. This is the
    /// property that actually matters, and it holds regardless of how the arithmetic is
    /// arranged.
    func testTheChunksTileTheFileExactlyOnce() {
        for total in [0, 1, 9, 10, 11, 99, 100, 101, 1_048_576, 1_048_577] {
            for size in [1, 7, 10, 4096, 1_048_576] {
                let manifest = makeManifest(totalBytes: total, chunkSize: size)
                let ranges = (0..<manifest.chunkCount).map { manifest.range(of: $0) }
                XCTAssertEqual(
                    ranges.reduce(0) { $0 + $1.count }, total,
                    "total \(total), size \(size): chunks must sum to the file")
                for (a, b) in zip(ranges, ranges.dropFirst()) {
                    XCTAssertEqual(
                        a.upperBound, b.lowerBound,
                        "total \(total), size \(size): chunks must be contiguous with no gap")
                }
                XCTAssertEqual(ranges.first?.lowerBound ?? 0, 0)
            }
        }
    }

    // MARK: - Progress

    /// `completed.count * chunkSize` is the tempting form and it is wrong: the short last chunk
    /// makes it overcount, so the bar passes 100% and stops.
    func testProgressIsSummedFromRealRangesNotChunkCount() {
        let manifest = makeManifest(totalBytes: 25, chunkSize: 10, completed: [0, 1, 2])
        XCTAssertEqual(manifest.bytesSent, 25)
        XCTAssertEqual(manifest.progress, 1.0)
    }

    func testProgressNeverExceedsOne() {
        let manifest = makeManifest(totalBytes: 25, chunkSize: 10, completed: [0, 1, 2, 5, 9])
        XCTAssertLessThanOrEqual(manifest.progress, 1.0)
    }

    func testPartialProgressReflectsBytesNotChunks() {
        // Two of three chunks, but 20 of 25 bytes — 80%, not 66%.
        let manifest = makeManifest(totalBytes: 25, chunkSize: 10, completed: [0, 1])
        XCTAssertEqual(manifest.bytesSent, 20)
        XCTAssertEqual(manifest.progress, 0.8, accuracy: 0.0001)
    }

    // MARK: - Completion

    func testAnUploadIsCompleteOnlyWhenEveryChunkHasLanded() {
        var manifest = makeManifest(totalBytes: 25, chunkSize: 10)
        XCTAssertFalse(manifest.isComplete)
        manifest.markCompleted(0)
        manifest.markCompleted(2)
        XCTAssertFalse(manifest.isComplete, "a gap in the middle is not completion")
        XCTAssertEqual(manifest.pending, [1])
        manifest.markCompleted(1)
        XCTAssertTrue(manifest.isComplete)
    }

    /// The system can report the same transfer twice, and a relaunched app re-reads a manifest
    /// that already counted it. Recording must not double-count or the progress bar lies.
    func testRecordingTheSameChunkTwiceIsHarmless() {
        var manifest = makeManifest(totalBytes: 25, chunkSize: 10)
        manifest.markCompleted(1)
        manifest.markCompleted(1)
        XCTAssertEqual(manifest.completed, [1])
        XCTAssertEqual(manifest.bytesSent, 10)
    }

    func testAnOutOfRangeCompletionIsIgnored() {
        var manifest = makeManifest(totalBytes: 25, chunkSize: 10)
        manifest.markCompleted(99)
        manifest.markCompleted(-1)
        XCTAssertTrue(manifest.completed.isEmpty)
        XCTAssertFalse(manifest.isComplete)
    }

    // MARK: - Identifying a task after the process died

    /// On relaunch the Swift context is gone and `taskDescription` is the only thing left to
    /// identify a transfer by. It has to survive the round trip.
    func testATaskDescriptionRoundTrips() {
        let manifest = makeManifest(totalBytes: 25, chunkSize: 10)
        let parsed = UploadManifest.parseTaskDescription(manifest.taskDescription(for: 2))
        XCTAssertEqual(parsed?.id, "up_1")
        XCTAssertEqual(parsed?.index, 2)
    }

    /// The id is a UUID today, but nothing stops it containing the separator later. Splitting
    /// on the *last* `#` keeps that from silently truncating the id.
    func testAnIDContainingTheSeparatorStillParses() {
        let manifest = UploadManifest(
            id: "up#odd#id", fileName: "a.pdf", folderName: "f", totalBytes: 10,
            chunkSize: 10, sourcePath: "/tmp/a", createdAt: Date())
        let parsed = UploadManifest.parseTaskDescription(manifest.taskDescription(for: 0))
        XCTAssertEqual(parsed?.id, "up#odd#id")
        XCTAssertEqual(parsed?.index, 0)
    }

    func testAMalformedTaskDescriptionIsRejectedRatherThanGuessed() {
        for bad in [nil, "", "no-separator", "#3", "up_1#", "up_1#x", "up_1#-2"] {
            XCTAssertNil(
                UploadManifest.parseTaskDescription(bad),
                "\(bad ?? "nil") should not parse")
        }
    }
}
