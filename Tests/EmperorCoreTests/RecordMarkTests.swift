import XCTest
@testable import EmperorCore

/// The logo is drawn from its SVG path data, so the reader is held to SVG's own rules and the
/// mark to the box the design draws it in.
final class RecordMarkTests: XCTestCase {

    func testBothStrokesRead() throws {
        for stroke in RecordMark.strokes {
            let commands = try XCTUnwrap(SVGPathReader.read(stroke))
            XCTAssertGreaterThan(commands.count, 20)
            guard case .move = commands.first else { return XCTFail("a stroke starts with a move") }
            XCTAssertEqual(commands.last, .close)
        }
    }

    /// Every point of the mark lands inside the design's `viewBox`, give or take a control point.
    /// A reader that mis-handled relative commands would walk the outline off across the canvas.
    func testTheMarkFitsItsViewBox() throws {
        let box = RecordMark.viewBox
        for stroke in RecordMark.strokes {
            let bounds = try XCTUnwrap(SVGPathReader.bounds(try XCTUnwrap(SVGPathReader.read(stroke))))
            XCTAssertGreaterThanOrEqual(bounds.minX, box.x - 1)
            XCTAssertGreaterThanOrEqual(bounds.minY, box.y - 1)
            XCTAssertLessThanOrEqual(bounds.maxX, box.x + box.width + 1)
            XCTAssertLessThanOrEqual(bounds.maxY, box.y + box.height + 1)
        }
    }

    func testRelativeCommandsAccumulate() {
        XCTAssertEqual(SVGPathReader.read("m1 1 2 2l3 0z"), [
            .move(x: 1, y: 1), .line(x: 3, y: 3), .line(x: 6, y: 3), .close,
        ])
    }

    func testAbsoluteCommandsAndShorthands() {
        XCTAssertEqual(SVGPathReader.read("M0 0H10V5L0 5Z"), [
            .move(x: 0, y: 0), .line(x: 10, y: 0), .line(x: 10, y: 5), .line(x: 0, y: 5), .close,
        ])
        XCTAssertEqual(SVGPathReader.read("M0 0q5 5 10 0t10 0"), [
            .move(x: 0, y: 0), .quad(x: 10, y: 0, cx: 5, cy: 5), .quad(x: 20, y: 0, cx: 15, cy: -5),
        ])
        XCTAssertEqual(SVGPathReader.read("M0 0c1 1 2 2 3 3s4 4 5 5"), [
            .move(x: 0, y: 0),
            .cubic(x: 3, y: 3, c1x: 1, c1y: 1, c2x: 2, c2y: 2),
            .cubic(x: 8, y: 8, c1x: 4, c1y: 4, c2x: 7, c2y: 7),
        ])
    }

    /// SVG lets numbers run together: `1.5.5` is two numbers, and so is `2-3`.
    func testNumbersThatRunTogether() {
        XCTAssertEqual(SVGPathReader.read("M1.5.5L2-3"), [.move(x: 1.5, y: 0.5), .line(x: 2, y: -3)])
        XCTAssertEqual(SVGPathReader.read("M1e1 2E-1"), [.move(x: 10, y: 0.2)])
    }

    /// An arc, or anything else the reader does not know, refuses rather than draws wrong.
    func testWhatItCannotReadIsRefused() {
        XCTAssertNil(SVGPathReader.read("M0 0A5 5 0 0 1 10 10"))
        XCTAssertNil(SVGPathReader.read("M0 0L1"))
    }
}
