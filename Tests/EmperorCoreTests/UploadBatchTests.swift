import XCTest
@testable import EmperorCore

/// The upload panel's batch: rows, summary and the speed, driven as the uploader drives it.
final class UploadBatchTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private let mb = 1024 * 1024

    func testANewFileWaits() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "brief.pdf", size: 2 * mb, folderName: "Matter", at: at(0))
        let file = batch.files[0]
        XCTAssertEqual(file.status, .queued)
        XCTAssertEqual(file.detail, "2.0 MB · Waiting")
        XCTAssertEqual(file.trailing, "0%")
        XCTAssertEqual(batch.title, "Uploading")
        XCTAssertEqual(batch.subtitle, "0 of 1 file · 0%")
    }

    func testBytesMoveAFileToUploadingWithAnEstimate() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "brief.pdf", size: 1000, folderName: "", at: at(0))
        batch.setLoaded(100, of: "a", at: at(1))
        XCTAssertEqual(batch.files[0].status, .uploading)
        XCTAssertNil(batch.files[0].eta)
        // The clock started on the first bytes, at 1 s: 25% in 10 s → 30 s left.
        batch.setLoaded(250, of: "a", at: at(11))
        XCTAssertEqual(batch.files[0].eta, 30)
        XCTAssertEqual(batch.files[0].trailing, "25%")
        XCTAssertEqual(batch.files[0].detail, "1000 B · 30 seconds left")
    }

    func testProgressNeverGoesBackwards() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "a.pdf", size: 1000, folderName: "", at: at(0))
        batch.setLoaded(600, of: "a", at: at(1))
        batch.setLoaded(400, of: "a", at: at(2))
        XCTAssertEqual(batch.files[0].loaded, 600)
        batch.setLoaded(5000, of: "a", at: at(3))
        XCTAssertEqual(batch.files[0].loaded, 1000)
    }

    func testSummaryWhileRunning() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "a.pdf", size: 1000, folderName: "M", at: at(0))
        batch.add(id: "b", name: "b.pdf", size: 1000, folderName: "M", at: at(0))
        batch.markProcessing("a")
        batch.setLoaded(500, of: "b", at: at(1))
        XCTAssertEqual(batch.subtitle, "1 of 2 files · 75%")
        XCTAssertEqual(batch.groups.map(\.count), ["1/2"])
        XCTAssertEqual(batch.files[0].trailing, "Done")
        XCTAssertEqual(batch.files[0].detail, "1000 B · Reading the document…")
        batch.markProcessing("a", message: "Reading page 3 of 40")
        XCTAssertEqual(batch.files[0].detail, "1000 B · Reading page 3 of 40")
    }

    func testSummaryAfterFailures() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "a.pdf", size: 10, folderName: "", at: at(0))
        batch.add(id: "b", name: "b.pdf", size: 10, folderName: "", at: at(0))
        batch.markFailed("a", message: "That file type is not allowed.")
        batch.markProcessing("b")
        batch.markDone("b")
        XCTAssertEqual(batch.title, "Finished with errors")
        XCTAssertEqual(batch.subtitle, "1 of 2 files need attention")
        XCTAssertEqual(batch.files[0].trailing, "Failed")
        XCTAssertEqual(batch.files[0].error, "That file type is not allowed.")
        XCTAssertEqual(batch.groups.first?.count, "2 files")
    }

    func testSummaryWhenAllUploaded() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "a.pdf", size: 10, folderName: "", at: at(0))
        batch.markProcessing("a")
        XCTAssertEqual(batch.title, "Uploads")
        XCTAssertEqual(batch.subtitle, "All 1 file uploaded")
    }

    func testGroupsByDestinationInOrder() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "a.pdf", size: 10, folderName: "Zeta", at: at(0))
        batch.add(id: "b", name: "b.pdf", size: 10, folderName: "", at: at(0))
        batch.add(id: "c", name: "c.pdf", size: 10, folderName: "Zeta", at: at(0))
        XCTAssertEqual(batch.groups.map(\.title), ["Zeta", "My Files (root)"])
        XCTAssertEqual(batch.groups[0].files.map(\.id), ["a", "c"])
    }

    func testAddingTheSameUploadTwiceIsHarmless() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "a.pdf", size: 10, folderName: "", at: at(0))
        batch.add(id: "a", name: "a.pdf", size: 10, folderName: "", at: at(1))
        XCTAssertEqual(batch.files.count, 1)
    }

    func testAnUploadPickedUpAgainStartsPartWay() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "a.pdf", size: 100, folderName: "", loaded: 40, at: at(0))
        XCTAssertEqual(batch.files[0].status, .uploading)
        XCTAssertEqual(batch.files[0].percent, 40)
        batch.add(id: "b", name: "b.pdf", size: 100, folderName: "", sent: true, at: at(0))
        XCTAssertEqual(batch.files[1].status, .processing(nil))
    }

    func testANewBatchStartsOnceTheLastHasSentEverything() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "a.pdf", size: 10, folderName: "", at: at(0))
        batch.add(id: "b", name: "b.pdf", size: 10, folderName: "", at: at(0))
        batch.markProcessing("a")
        // Still sending b: c joins this batch.
        batch.add(id: "c", name: "c.pdf", size: 10, folderName: "", at: at(1))
        XCTAssertEqual(batch.files.count, 3)
        batch.markProcessing("b")
        batch.markProcessing("c")
        batch.add(id: "d", name: "d.pdf", size: 10, folderName: "", at: at(2))
        XCTAssertEqual(batch.files.map(\.id), ["d"])
    }

    func testSpeedLineAndEstimate() {
        var batch = UploadBatch()
        // 8 Mbps is 1,000,000 bytes a second.
        batch.add(id: "a", name: "a.pdf", size: 63_000_000, folderName: "", at: at(0))
        var sent = 0
        for second in 1...3 {
            sent += 1_000_000
            batch.record(sentBytes: 1_000_000)
            batch.setLoaded(sent, of: "a", at: at(Double(second)))
            batch.tick(at: at(Double(second)))
        }
        XCTAssertEqual(batch.remainingBytes, 60_000_000)
        XCTAssertEqual(batch.etaSeconds, 60)
        XCTAssertEqual(batch.speedLine, "Upload speed: Average (8 Mbps) · ~1 min left")

        batch.markProcessing("a")
        XCTAssertNil(batch.etaSeconds)
        XCTAssertEqual(batch.speedLine, "Upload speed: Average (8 Mbps)")
    }

    func testNoSpeedLineBeforeAnythingIsMeasured() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "a.pdf", size: 10, folderName: "", at: at(0))
        XCTAssertNil(batch.speedLine)
    }

    func testCompletionNotices() {
        var one = UploadBatch()
        one.add(id: "a", name: "a.pdf", size: 10, folderName: "", at: at(0))
        one.markProcessing("a")
        XCTAssertNil(one.completionNotice, "still being read")
        one.markDone("a")
        XCTAssertEqual(
            one.completionNotice,
            "Your document is now searchable — ask Emperor anything about it.")

        var several = UploadBatch()
        for id in ["a", "b", "c"] {
            several.add(id: id, name: "\(id).pdf", size: 10, folderName: "", at: at(0))
        }
        for id in ["a", "b", "c"] { several.markDone(id) }
        XCTAssertEqual(
            several.completionNotice,
            "All 3 uploads are now searchable — ask Emperor anything about them.")

        several.markProcessingFailed("b", message: "ERROR: unreadable")
        XCTAssertEqual(
            several.completionNotice, "1 file could not be processed — please re-upload it.")
        several.markProcessingFailed("c", message: "ERROR: unreadable")
        XCTAssertEqual(
            several.completionNotice, "2 files could not be processed — please re-upload them.")
    }

    func testNoNoticeWhenNothingReachedTheServer() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "a.pdf", size: 10, folderName: "", at: at(0))
        batch.markFailed("a", message: "Declined")
        XCTAssertNil(batch.completionNotice)
    }

    func testAFileStillBeingReadWhenPollingStopsIsNotAFailure() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "a.pdf", size: 10, folderName: "", at: at(0))
        batch.markProcessing("a")
        batch.markUnconfirmed("a", message: "Still processing")
        XCTAssertFalse(batch.isActive)
        XCTAssertEqual(batch.title, "Uploads")
        XCTAssertEqual(batch.files[0].trailing, "Done")
        XCTAssertEqual(batch.files[0].detail, "10 B · Still processing")
        XCTAssertNil(batch.completionNotice, "nothing is confirmed searchable")
    }

    func testALateProgressSentenceDoesNotReopenAFinishedFile() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "a.pdf", size: 10, folderName: "", at: at(0))
        batch.markProcessing("a", message: "Reading page 1 of 2")
        batch.markDone("a")
        batch.markProcessing("a", message: "Reading page 2 of 2")
        XCTAssertEqual(batch.files[0].status, .done)
        // "a" has finished sending, so "b" starts a batch of its own.
        batch.add(id: "b", name: "b.pdf", size: 10, folderName: "", at: at(0))
        batch.markFailed("b", message: "Declined")
        batch.markProcessing("b")
        XCTAssertEqual(batch.files.map(\.status), [.failed("Declined")])
    }

    func testDismissOnlyWhenNothingIsActive() {
        var batch = UploadBatch()
        batch.add(id: "a", name: "a.pdf", size: 10, folderName: "", at: at(0))
        batch.markProcessing("a")
        batch.dismiss()
        XCTAssertFalse(batch.isEmpty)
        batch.markDone("a")
        batch.dismiss()
        XCTAssertTrue(batch.isEmpty)
    }
}
