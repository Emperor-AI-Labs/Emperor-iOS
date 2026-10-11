import XCTest
@testable import EmperorCore

/// The upload panel's numbers and their wording, held to the web tray's.
final class UploadProgressTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - Speed meter

    /// One megabit a second is 125,000 bytes.
    private let oneMbps = 125_000

    func testMeterPublishesNothingBeforeThreeSamples() {
        var meter = UploadSpeedMeter()
        meter.start(at: at(0))
        meter.record(bytes: oneMbps * 12)
        meter.tick(at: at(1))
        meter.record(bytes: oneMbps * 12)
        meter.tick(at: at(2))
        XCTAssertNil(meter.mbps)
        XCTAssertNil(meter.band)
        meter.record(bytes: oneMbps * 12)
        meter.tick(at: at(3))
        XCTAssertEqual(meter.mbps ?? 0, 12, accuracy: 0.0001)
        XCTAssertEqual(meter.band, .good)
    }

    func testMeterAveragesTheLastFiveSamples() {
        var meter = UploadSpeedMeter()
        meter.start(at: at(0))
        // 1, 2, 3, 4, 5, 6, 7 Mbps — the published figure is the mean of 3…7.
        for second in 1...7 {
            meter.record(bytes: oneMbps * second)
            meter.tick(at: at(Double(second)))
        }
        XCTAssertEqual(meter.recent.count, 5)
        XCTAssertEqual(meter.mbps ?? 0, 5, accuracy: 0.0001)
    }

    func testMeterSamplesOnlyOnceASecond() {
        var meter = UploadSpeedMeter()
        meter.start(at: at(0))
        meter.record(bytes: oneMbps)
        meter.tick(at: at(0.4))
        XCTAssertEqual(meter.sampleCount, 0)
        meter.tick(at: at(1))
        XCTAssertEqual(meter.sampleCount, 1)
        XCTAssertEqual(meter.recent.first ?? 0, 1, accuracy: 0.0001)
    }

    func testMeterDividesByTheRealIntervalWhenATickIsLate() {
        var meter = UploadSpeedMeter()
        meter.start(at: at(0))
        meter.record(bytes: oneMbps * 4)
        meter.tick(at: at(2))
        XCTAssertEqual(meter.recent.first ?? 0, 2, accuracy: 0.0001)
    }

    func testMeterIgnoresNegativeAndZeroDeltas() {
        var meter = UploadSpeedMeter()
        meter.record(bytes: -500)
        meter.record(bytes: 0)
        meter.record(bytes: 10)
        XCTAssertEqual(meter.totalBytes, 10)
    }

    func testMeterDoesNotSampleWhenStopped() {
        var meter = UploadSpeedMeter()
        meter.record(bytes: oneMbps)
        meter.tick(at: at(5))
        XCTAssertEqual(meter.sampleCount, 0)
    }

    func testMeterKeepsItsFigureButDropsTheEstimateWhenStopped() {
        var meter = UploadSpeedMeter()
        meter.start(at: at(0))
        for second in 1...3 {
            meter.record(bytes: oneMbps * 8)
            meter.tick(at: at(Double(second)))
        }
        XCTAssertNotNil(meter.etaSeconds(remainingBytes: 1_000_000))
        meter.stop()
        XCTAssertEqual(meter.mbps ?? 0, 8, accuracy: 0.0001)
        XCTAssertNil(meter.etaSeconds(remainingBytes: 1_000_000))
    }

    func testANewUploadIsMeasuredAfreshButShowsTheOldFigureMeanwhile() {
        var meter = UploadSpeedMeter()
        meter.start(at: at(0))
        for second in 1...3 {
            meter.record(bytes: oneMbps * 8)
            meter.tick(at: at(Double(second)))
        }
        meter.stop()
        meter.start(at: at(100))
        XCTAssertEqual(meter.sampleCount, 0)
        meter.record(bytes: oneMbps)
        meter.tick(at: at(101))
        XCTAssertEqual(meter.mbps ?? 0, 8, accuracy: 0.0001)
        meter.record(bytes: oneMbps)
        meter.tick(at: at(102))
        meter.record(bytes: oneMbps)
        meter.tick(at: at(103))
        XCTAssertEqual(meter.mbps ?? 0, 1, accuracy: 0.0001)
    }

    func testOverallEstimateFromTheMeasuredRate() {
        var meter = UploadSpeedMeter()
        meter.start(at: at(0))
        for second in 1...3 {
            meter.record(bytes: oneMbps * 8)
            meter.tick(at: at(Double(second)))
        }
        // 8 Mbps is 1 MB a second; 60 MB left is a minute.
        XCTAssertEqual(meter.etaSeconds(remainingBytes: 60_000_000), 60)
    }

    func testNoEstimateBelowFiftyKbps() {
        var meter = UploadSpeedMeter()
        meter.start(at: at(0))
        for second in 1...3 {
            meter.record(bytes: 5_000)   // 40 kbps
            meter.tick(at: at(Double(second)))
        }
        XCTAssertNotNil(meter.mbps)
        XCTAssertNil(meter.etaSeconds(remainingBytes: 1_000_000))
    }

    func testBands() {
        XCTAssertEqual(UploadSpeedBand.band(forMbps: 10), .good)
        XCTAssertEqual(UploadSpeedBand.band(forMbps: 9.99), .average)
        XCTAssertEqual(UploadSpeedBand.band(forMbps: 2), .average)
        XCTAssertEqual(UploadSpeedBand.band(forMbps: 1.99), .poor)
        XCTAssertEqual(UploadSpeedBand.band(forMbps: 0), .poor)
        XCTAssertEqual(UploadSpeedBand.good.label, "Good")
        XCTAssertEqual(UploadSpeedBand.average.label, "Average")
        XCTAssertEqual(UploadSpeedBand.poor.label, "Poor")
    }

    // MARK: - Per-file estimate

    func testPerFileEstimateIsWithheldEarly() {
        var estimator = UploadETAEstimator()
        estimator.restart(at: at(0))
        XCTAssertNil(estimator.update(percent: 50, at: at(1)))     // under 1.5 s
        XCTAssertNil(estimator.update(percent: 2, at: at(5)))      // under 3%
        XCTAssertNil(estimator.update(percent: 100, at: at(5)))    // finished
    }

    func testPerFileEstimateExtrapolatesThenSmooths() {
        var estimator = UploadETAEstimator()
        estimator.restart(at: at(0))
        // 10 s for 25% → 30 s left.
        XCTAssertEqual(estimator.update(percent: 25, at: at(10)), 30)
        // 20 s for 50% → raw 20; smoothed 0.7*30 + 0.3*20 = 27.
        XCTAssertEqual(estimator.update(percent: 50, at: at(20)), 27)
    }

    func testPerFileEstimateIsAtLeastOneSecond() {
        var estimator = UploadETAEstimator()
        estimator.restart(at: at(0))
        XCTAssertEqual(estimator.update(percent: 99.99, at: at(2)), 1)
    }

    func testPerFileClockRestartsAtZero() {
        var estimator = UploadETAEstimator()
        estimator.restart(at: at(0))
        _ = estimator.update(percent: 50, at: at(10))
        XCTAssertNil(estimator.update(percent: 0, at: at(100)))
        XCTAssertEqual(estimator.startedAt, at(100))
        XCTAssertNil(estimator.smoothed)
        // 4 s for 50% → 4 s left, from the new start and with no memory of the old estimate.
        XCTAssertEqual(estimator.update(percent: 50, at: at(104)), 4)
    }

    func testPerFileClockStartsOnFirstUpdateWhenNeverStarted() {
        var estimator = UploadETAEstimator()
        XCTAssertNil(estimator.update(percent: 10, at: at(0)))
        XCTAssertEqual(estimator.startedAt, at(0))
    }

    // MARK: - Wording

    func testSpeedWording() {
        XCTAssertEqual(UploadProgressFormat.speed(mbps: 0.4), "400 kbps")
        XCTAssertEqual(UploadProgressFormat.speed(mbps: 0.0125), "13 kbps")
        XCTAssertEqual(UploadProgressFormat.speed(mbps: 12), "12 Mbps")
        XCTAssertEqual(UploadProgressFormat.speed(mbps: 3.44), "3.4 Mbps")
        XCTAssertEqual(UploadProgressFormat.speed(mbps: 1), "1 Mbps")
    }

    func testCoarseEstimateWording() {
        XCTAssertEqual(UploadProgressFormat.coarseETA(seconds: 59), "under a minute left")
        XCTAssertEqual(UploadProgressFormat.coarseETA(seconds: 60), "~1 min left")
        XCTAssertEqual(UploadProgressFormat.coarseETA(seconds: 150), "~3 min left")
        XCTAssertEqual(UploadProgressFormat.coarseETA(seconds: 3599), "~60 min left")
        XCTAssertEqual(UploadProgressFormat.coarseETA(seconds: 5400), "~1.5 hr left")
    }

    func testPerFileEstimateWording() {
        XCTAssertEqual(UploadProgressFormat.eta(seconds: 1), "1 second left")
        XCTAssertEqual(UploadProgressFormat.eta(seconds: 45), "45 seconds left")
        XCTAssertEqual(UploadProgressFormat.eta(seconds: 60), "1 minute left")
        XCTAssertEqual(UploadProgressFormat.eta(seconds: 89), "1 minute left")
        XCTAssertEqual(UploadProgressFormat.eta(seconds: 150), "3 minutes left")
    }

    func testSizeWording() {
        XCTAssertEqual(UploadProgressFormat.size(bytes: 0), "")
        XCTAssertEqual(UploadProgressFormat.size(bytes: 512), "512 B")
        XCTAssertEqual(UploadProgressFormat.size(bytes: 1536), "2 KB")
        XCTAssertEqual(UploadProgressFormat.size(bytes: 5 * 1024 * 1024 + 300 * 1024), "5.3 MB")
    }

    func testSpeedLine() {
        XCTAssertNil(UploadProgressFormat.speedLine(mbps: nil, etaSeconds: 30))
        XCTAssertEqual(
            UploadProgressFormat.speedLine(mbps: 12.3, etaSeconds: 120),
            "Upload speed: Good (12.3 Mbps) · ~2 min left")
        XCTAssertEqual(
            UploadProgressFormat.speedLine(mbps: 0.5, etaSeconds: nil),
            "Upload speed: Poor (500 kbps)")
    }

    // MARK: - Processing stages

    func testStageLines() {
        XCTAssertEqual(
            IngestStage.line(for: IngestProgress(stage: "reading", percent: 10)),
            "1/4 Reading file · 10%")
        XCTAssertEqual(
            IngestStage.line(for: IngestProgress(stage: "ocr", percent: 45)),
            "2/4 Extracting data · 45%")
        XCTAssertEqual(
            IngestStage.line(for: IngestProgress(stage: "embedding", percent: 0)),
            "3/4 Making searchable · 0%")
        XCTAssertEqual(
            IngestStage.line(for: IngestProgress(stage: "indexing", percent: 120)),
            "4/4 Organising · 100%")
        XCTAssertEqual(IngestStage.line(for: IngestProgress(stage: "ocr")), "2/4 Extracting data")
    }

    func testQueuedLines() {
        XCTAssertEqual(
            IngestStage.line(for: IngestProgress(stage: "queued", queuePosition: 3)), "Queued #3")
        XCTAssertEqual(IngestStage.line(for: IngestProgress(stage: "queued")), "Queued…")
        XCTAssertEqual(IngestStage.line(for: IngestProgress()), "Queued…")
    }

    func testTerminalAndMissingStagesSayNothing() {
        XCTAssertNil(IngestStage.line(for: nil))
        XCTAssertNil(IngestStage.line(for: IngestProgress(stage: "done", percent: 100)))
        XCTAssertNil(IngestStage.line(for: IngestProgress(stage: "error")))
        XCTAssertEqual(IngestStage.line(for: IngestProgress(stage: "novel", percent: 7)), "7%")
    }

    func testStageFraction() {
        XCTAssertEqual(IngestStage.fraction(for: IngestProgress(stage: "ocr", percent: 45)), 0.45)
        XCTAssertNil(IngestStage.fraction(for: IngestProgress(stage: "queued", percent: 0)))
        XCTAssertNil(IngestStage.fraction(for: IngestProgress(stage: "ocr")))
    }

    func testLatchHoldsAPercentWithinAStage() {
        var latch = IngestPercentLatch()
        XCTAssertEqual(latch.percent(for: IngestProgress(stage: "ocr", percent: 40), at: "A/x.pdf"), 40)
        XCTAssertEqual(latch.percent(for: IngestProgress(stage: "ocr", percent: 30), at: "A/x.pdf"), 40)
        XCTAssertEqual(latch.percent(for: IngestProgress(stage: "ocr", percent: 55), at: "A/x.pdf"), 55)
        // A new stage starts again from its own zero.
        XCTAssertEqual(
            latch.percent(for: IngestProgress(stage: "embedding", percent: 0), at: "A/x.pdf"), 0)
        // Another document is its own.
        XCTAssertEqual(latch.percent(for: IngestProgress(stage: "ocr", percent: 5), at: "B/y.pdf"), 5)
    }

    func testLatchAppliesThroughTheTree() {
        func tree(_ percent: Int) -> [FileNode] {
            [.folder(.init(name: "A", path: "A", files: [
                .file(.init(name: "x.pdf", path: "A/x.pdf", status: "Reading",
                            progress: IngestProgress(stage: "ocr", percent: percent))),
            ]))]
        }
        var latch = IngestPercentLatch()
        XCTAssertEqual(latch.apply(to: tree(60)), tree(60))
        XCTAssertEqual(latch.apply(to: tree(50)), tree(60))
    }
}

private extension IngestProgress {
    init(stage: String? = nil, percent: Int? = nil, queuePosition: Int? = nil) {
        self.init(
            stage: stage, pagesDone: nil, pagesTotal: nil, percent: percent, etaSeconds: nil,
            startedAt: nil, updatedAt: nil, queuePosition: queuePosition, queueTotal: nil,
            message: nil)
    }
}
