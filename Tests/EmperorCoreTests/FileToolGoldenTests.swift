import XCTest
@testable import EmperorCore

/// The Document Utilities' numbers, held to the platform's own JavaScript.
///
/// Each fixture was produced by running the web's function under Node
/// (`scripts/generate-file-tool-fixtures.mjs`): `fmtBytes`, `compressToTarget` against a recorded
/// size model, `recompressImage` against a grid of images and outcomes, and `imagesToPdf` with a
/// pdf-lib stand-in that records every placement.
final class FileToolGoldenTests: XCTestCase {

    // MARK: - Byte sizes

    private struct ByteFixture: Decodable {
        struct Case: Decodable {
            let bytes: Int
            let text: String
        }
        let cases: [Case]
    }

    /// Including either side of every rounding boundary, where `toFixed`'s half-up rule and a
    /// careless `%.1f` would part company.
    func testSizesPrintExactlyAsTheWebPrintsThem() throws {
        let cases = try fileToolFixture("byte-format", as: ByteFixture.self).cases
        XCTAssertGreaterThan(cases.count, 150)
        for item in cases {
            XCTAssertEqual(FileSize.format(item.bytes), item.text, "\(item.bytes) bytes")
        }
    }

    // MARK: - Compress image

    private struct CompressImageFixture: Decodable {
        struct Call: Decodable {
            let w: Int
            let h: Int
            let q: Double
            let size: Int
        }
        struct Outcome: Decodable {
            let size: Int
            let width: Int
            let height: Int
            let quality: Double
            let hitTarget: Bool
        }
        struct Search: Decodable {
            let width: Int
            let height: Int
            let targetBytes: Int
            let calls: [Call]
            let result: Outcome
        }
        let presetsKB: [Int]
        let maxFileBytes: Int
        let searches: [Search]
    }

    /// Call for call. The fake encoder answers each attempt with the size the web's canvas
    /// reported for the *same* attempt, and fails the test the moment the Swift search asks for
    /// a different width, height or quality than the web did next.
    func testTheImageSearchMakesTheWebsAttemptsInTheWebsOrder() throws {
        let fixture = try fileToolFixture("compress-image", as: CompressImageFixture.self)
        XCTAssertEqual(ImageCompression.presetsKB, fixture.presetsKB)
        XCTAssertEqual(ImageCompression.maxSourceBytes, fixture.maxFileBytes)

        for search in fixture.searches {
            var index = 0
            let label = "\(search.width)×\(search.height) → \(search.targetBytes)"
            let result = try ImageCompression.search(
                width: search.width, height: search.height, targetBytes: search.targetBytes
            ) { w, h, q in
                guard index < search.calls.count else {
                    XCTFail("\(label): more attempts than the web made")
                    return nil
                }
                let expected = search.calls[index]
                XCTAssertEqual(w, expected.w, "\(label) attempt \(index) width")
                XCTAssertEqual(h, expected.h, "\(label) attempt \(index) height")
                XCTAssertEqual(q, expected.q, "\(label) attempt \(index) quality")
                index += 1
                return Data(count: expected.size)
            }
            XCTAssertEqual(index, search.calls.count, "\(label): fewer attempts than the web made")
            XCTAssertEqual(result.data.count, search.result.size, label)
            XCTAssertEqual(result.width, search.result.width, label)
            XCTAssertEqual(result.height, search.result.height, label)
            XCTAssertEqual(result.quality, search.result.quality, label)
            XCTAssertEqual(result.hitTarget, search.result.hitTarget, label)
        }
    }

    // MARK: - Compress PDF

    private struct CompressPDFFixture: Decodable {
        struct Level: Decodable {
            let id: String
            let label: String
            let maxDim: Int
            let quality: Double
            let desc: String
        }
        struct Encoded: Decodable {
            let w: Int
            let h: Int
            let q: Double
        }
        struct Decision: Decodable {
            let level: String
            let width: Int
            let height: Int
            let originalBytes: Int
            let candidateBytes: Int
            let encoded: Encoded?
            let saved: Int
        }
        let levels: [Level]
        let decisions: [Decision]
    }

    func testTheLevelsAreTheWebsLevels() throws {
        let fixture = try fileToolFixture("compress-pdf", as: CompressPDFFixture.self)
        XCTAssertEqual(PDFCompression.levels.map(\.id), fixture.levels.map(\.id))
        for (ours, theirs) in zip(PDFCompression.levels, fixture.levels) {
            XCTAssertEqual(ours.label, theirs.label)
            XCTAssertEqual(ours.maxDimension, theirs.maxDim)
            XCTAssertEqual(ours.quality, theirs.quality)
            XCTAssertEqual(ours.detail, theirs.desc)
        }
        XCTAssertEqual(PDFCompression.defaultLevel.id, "bal")
    }

    /// The web's per-image rules: skip anything under 4 KB, scale the longest side down to the
    /// level's limit (never up), and keep the original unless the re-encode is more than 3%
    /// smaller. The same three rules decide a page here.
    func testThePerImageRulesMatchTheWeb() throws {
        let fixture = try fileToolFixture("compress-pdf", as: CompressPDFFixture.self)
        XCTAssertGreaterThan(fixture.decisions.count, 500)
        for decision in fixture.decisions {
            let level = try XCTUnwrap(PDFCompression.levels.first { $0.id == decision.level })
            let label = "\(decision.level) \(decision.width)×\(decision.height) \(decision.originalBytes)→\(decision.candidateBytes)"

            let considered = decision.originalBytes >= PDFCompression.minimumBytes
            XCTAssertEqual(considered, decision.encoded != nil, "\(label): the 4 KB floor")

            if let encoded = decision.encoded {
                let size = PDFCompression.scaledSize(
                    width: decision.width, height: decision.height, maxDimension: level.maxDimension)
                XCTAssertEqual(size.width, encoded.w, "\(label): width")
                XCTAssertEqual(size.height, encoded.h, "\(label): height")
                XCTAssertEqual(level.quality, encoded.q, "\(label): quality")
            }

            let replaced = considered && PDFCompression.worthReplacing(
                originalBytes: decision.originalBytes, candidateBytes: decision.candidateBytes)
            XCTAssertEqual(replaced, decision.saved > 0, "\(label): the 3% rule")
            if replaced {
                XCTAssertEqual(decision.saved, decision.originalBytes - decision.candidateBytes)
            }
        }
    }

    // MARK: - Image to PDF

    private struct ImageToPDFFixture: Decodable {
        struct Draw: Decodable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
        }
        struct Page: Decodable {
            let size: [Double]
            let draws: [Draw]
        }
        struct Layout: Decodable {
            let pageSize: String
            let images: [[Double]]
            let pages: [Page]
        }
        let imageExtensions: [String]
        let pageSizeOrder: [String]
        let pageSizes: [String: [Double]]
        let layouts: [Layout]
    }

    func testPaperSizesAndExtensionsAreTheWebs() throws {
        let fixture = try fileToolFixture("image-to-pdf", as: ImageToPDFFixture.self)
        XCTAssertEqual(ImagePDFLayout.PageSize.allCases.map(\.rawValue), fixture.pageSizeOrder)
        for size in ImagePDFLayout.PageSize.allCases {
            let points = try XCTUnwrap(fixture.pageSizes[size.rawValue])
            XCTAssertEqual([size.points.width, size.points.height], points, size.rawValue)
        }
        XCTAssertEqual(ImagePDFLayout.webExtensions, fixture.imageExtensions)
        XCTAssertTrue(
            fixture.imageExtensions.allSatisfy(ImagePDFLayout.acceptedExtensions.contains),
            "everything the web accepts is accepted here")
    }

    /// Every page the web built, every rectangle it drew — to the last bit of the Double.
    func testEveryImageLandsWhereTheWebPutsIt() throws {
        let fixture = try fileToolFixture("image-to-pdf", as: ImageToPDFFixture.self)
        for layout in fixture.layouts {
            let size = try XCTUnwrap(ImagePDFLayout.PageSize(rawValue: layout.pageSize))
            XCTAssertEqual(layout.pages.count, layout.images.count, "one page per image")
            for (image, page) in zip(layout.images, layout.pages) {
                XCTAssertEqual(page.size, [size.points.width, size.points.height])
                let draw = try XCTUnwrap(page.draws.first)
                let placement = ImagePDFLayout.placement(
                    imageWidth: image[0], imageHeight: image[1], on: size)
                let label = "\(layout.pageSize) \(image)"
                XCTAssertEqual(placement.x, draw.x, label)
                XCTAssertEqual(placement.y, draw.y, label)
                XCTAssertEqual(placement.width, draw.width, label)
                XCTAssertEqual(placement.height, draw.height, label)
            }
        }
    }
}
