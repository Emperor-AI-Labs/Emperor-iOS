import XCTest
@testable import EmperorCore

/// Page selections as a person types them.
///
/// Ported from the Android client's suite, which found most of these on a device. Everything is
/// **1-based**: these are the numbers printed on a document, not array indices.
final class PageRangesTests: XCTestCase {

    // MARK: - parse

    func testAMixedSelectionFlattensInPageOrder() {
        XCTAssertEqual(PageRanges.parse("1-3, 5, 8-10", pageCount: 20), [1, 2, 3, 5, 8, 9, 10])
    }

    func testWhitespaceAnywhereIsTolerated() {
        XCTAssertEqual(PageRanges.parse("  1 - 3 ,   5  ", pageCount: 10), [1, 2, 3, 5])
        XCTAssertEqual(PageRanges.parse("1-3,5", pageCount: 10), [1, 2, 3, 5])
    }

    func testABackwardsSpanReadsTheSameAsAForwardsOne() {
        XCTAssertEqual(
            PageRanges.parse("3-1", pageCount: 10), PageRanges.parse("1-3", pageCount: 10))
    }

    func testOverlappingSelectionsDoNotDuplicateAPage() {
        XCTAssertEqual(PageRanges.parse("1-3, 2-4, 3", pageCount: 10), [1, 2, 3, 4])
    }

    /// A bundle re-exported at a different length is the common case, so ignoring page 400 of a
    /// 380-page file is friendlier than refusing the whole selection.
    func testPagesPastTheEndAreDroppedRatherThanRejectingTheSelection() {
        XCTAssertEqual(PageRanges.parse("8-40", pageCount: 10), [8, 9, 10])
        XCTAssertEqual(PageRanges.parse("1-2, 99", pageCount: 10), [1, 2])
    }

    func testPageZeroAndNegativesAreNotPages() {
        XCTAssertEqual(PageRanges.parse("0-2", pageCount: 10), [1, 2])
        XCTAssertEqual(PageRanges.parse("-3", pageCount: 10), [])
    }

    /// **Empty must never mean everything.** A caller that treated it as "all pages" would
    /// export a whole bundle when the user asked for nothing.
    func testAWhollyOutOfRangeSelectionIsEmptyNeverEverything() {
        XCTAssertEqual(PageRanges.parse("50-90", pageCount: 10), [])
        XCTAssertEqual(PageRanges.parse("", pageCount: 10), [])
        XCTAssertEqual(PageRanges.parse(nil, pageCount: 10), [])
        XCTAssertEqual(PageRanges.parse("   ", pageCount: 10), [])
        XCTAssertEqual(PageRanges.parse(",,,", pageCount: 10), [])
    }

    func testJunkBetweenValidPartsDoesNotDiscardTheValidParts() {
        XCTAssertEqual(PageRanges.parse("1-2, banana, 7", pageCount: 10), [1, 2, 7])
        XCTAssertEqual(PageRanges.parse("4, 1--2, 3-", pageCount: 10), [4])
    }

    func testADocumentWithNoPagesSelectsNothing() {
        XCTAssertEqual(PageRanges.parse("1-5", pageCount: 0), [])
        XCTAssertEqual(PageRanges.parse("1-5", pageCount: -1), [])
    }

    func testANumberTooLargeDoesNotCrashTheParse() {
        XCTAssertEqual(PageRanges.parse("99999999999999", pageCount: 10), [])
        XCTAssertEqual(PageRanges.parse("99999999999999, 3", pageCount: 10), [3])
        XCTAssertEqual(
            PageRanges.parse("999999999999999999999999, 3", pageCount: 10), [3],
            "a number past Int's range must be ignored, not trap")
    }

    /// ICU reads `\d` as the whole Unicode `Nd` category where the platform's JavaScript and the
    /// Android client's Java read ASCII only. A page number in Arabic-Indic digits must be
    /// ignored here too, or the three clients disagree about what the user typed.
    func testOnlyASCIIDigitsAreDigits() {
        XCTAssertEqual(PageRanges.parse("١-٣", pageCount: 10), [])
        XCTAssertEqual(PageRanges.parse("٣, 2", pageCount: 10), [2])
    }

    // MARK: - parseGroups

    func testEachSegmentBecomesItsOwnGroupInTheOrderTyped() {
        let groups = PageRanges.parseGroups("1-3, 5, 8-10", pageCount: 20)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].pages, [1, 2, 3])
        XCTAssertEqual(groups[1].pages, [5])
        XCTAssertEqual(groups[2].pages, [8, 9, 10])
    }

    func testGroupsKeepTheTypedOrderRatherThanSorting() {
        let groups = PageRanges.parseGroups("8-10, 1-3", pageCount: 20)
        XCTAssertEqual(groups[0].pages, [8, 9, 10])
        XCTAssertEqual(groups[1].pages, [1, 2, 3])
    }

    /// Asking for `5, 1-3, 5` legitimately produces three files, one of which repeats page 5.
    func testARepeatedSegmentProducesARepeatedFile() {
        let groups = PageRanges.parseGroups("5, 1-3, 5", pageCount: 10)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].pages, [5])
        XCTAssertEqual(groups[2].pages, [5])
    }

    /// A file named 8-40 that holds pages 8-10 is a lie on the filesystem.
    func testAGroupIsLabelledByWhatSurvivedNotByWhatWasTyped() {
        let group = try! XCTUnwrap(PageRanges.parseGroups("8-40", pageCount: 10).first)
        XCTAssertEqual(group.label, "8-10")
        XCTAssertEqual(group.pages, [8, 9, 10])
    }

    func testASinglePageGroupIsLabelledWithTheBareNumber() {
        XCTAssertEqual(PageRanges.parseGroups("5", pageCount: 10).first?.label, "5")
        XCTAssertEqual(PageRanges.parseGroups("5-5", pageCount: 10).first?.label, "5")
    }

    /// An empty group would become a zero-page PDF, which most readers refuse to open.
    func testAGroupThatClampsAwayEntirelyIsDropped() {
        XCTAssertEqual(PageRanges.parseGroups("50-90", pageCount: 10), [])
        let mixed = PageRanges.parseGroups("1-2, 50-90", pageCount: 10)
        XCTAssertEqual(mixed.count, 1)
        XCTAssertTrue(mixed.allSatisfy { !$0.pages.isEmpty })
    }

    func testABackwardsSpanStillRunsLowToHighInsideItsGroup() {
        let group = try! XCTUnwrap(PageRanges.parseGroups("3-1", pageCount: 10).first)
        XCTAssertEqual(group.pages, [1, 2, 3])
        XCTAssertEqual(group.label, "1-3")
    }

    // MARK: - label

    func testAContiguousSelectionIsLabelledAsOneRun() {
        XCTAssertEqual(PageRanges.label([1, 2, 3, 4, 5, 6, 7, 8]), "1-8")
        XCTAssertEqual(PageRanges.label([5]), "5")
    }

    /// Found on a device: extracting 1-8 and 17-24 produced a file called `pages_1-24`, which
    /// claims twenty-four pages and holds sixteen. On a disk of bundle parts that is how the
    /// wrong document gets filed.
    func testASelectionWithAGapNamesBothRuns() {
        XCTAssertEqual(PageRanges.label(Array(1...8) + Array(17...24)), "1-8_17-24")
    }

    func testSinglePagesAndRunsMixInOneLabel() {
        XCTAssertEqual(PageRanges.label([1, 2, 3, 7, 9, 10]), "1-3_7_9-10")
    }

    func testAnUnsortedOrDuplicatedSelectionIsNormalisedFirst() {
        XCTAssertEqual(PageRanges.label([3, 1, 2, 2]), "1-3")
    }

    /// Every odd page of a 40-page bundle is 20 runs. A name carrying all of them is unusable;
    /// a count is uninformative but true.
    func testTooManyRunsFallBackToACount() {
        XCTAssertEqual(PageRanges.label(Array(stride(from: 1, through: 40, by: 2))), "20_pages")
    }

    func testTheRunLimitIsWhereItSaysItIs() {
        XCTAssertEqual(PageRanges.label([1, 3, 5]), "1_3_5")
        XCTAssertEqual(PageRanges.label([1, 3, 5, 7]), "4_pages")
    }

    func testAnEmptySelectionIsLabelledRatherThanProducingABareUnderscore() {
        XCTAssertEqual(PageRanges.label([]), "none")
    }

    func testALabelNeverContainsACharacterThatWouldBreakAFilename() {
        for selection in [[1], [1, 2, 3], [1, 5, 9], Array(stride(from: 1, through: 40, by: 2))] {
            let label = PageRanges.label(selection)
            XCTAssertTrue(
                label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" },
                label)
        }
    }

    // MARK: - describe

    func testTheDescriptionCountsWhatWouldActuallyBeExtracted() {
        XCTAssertEqual(PageRanges.describe("1-3, 5, 8-10", pageCount: 20), "7 pages")
        XCTAssertEqual(PageRanges.describe("4", pageCount: 20), "1 page")
        // Overlap does not inflate the count.
        XCTAssertEqual(PageRanges.describe("1-3, 2", pageCount: 20), "3 pages")
        XCTAssertEqual(PageRanges.describe("", pageCount: 20), "nothing selected")
        XCTAssertEqual(PageRanges.describe("99", pageCount: 20), "nothing selected")
    }

    // MARK: - packBySize

    func testPagesArePackedIntoPartsUnderTheTarget() {
        let parts = PageRanges.packBySize(Array(repeating: 3_000_000, count: 7),
                                          targetBytes: 10_000_000)
        XCTAssertEqual(parts, [[1, 2, 3], [4, 5, 6], [7]])
    }

    /// **The property that matters**: a split must not lose or duplicate a page of a bundle.
    func testEveryPageAppearsExactlyOnceInOrder() {
        let sizes = [1, 900, 300, 50, 700, 2, 400, 100]
        let parts = PageRanges.packBySize(sizes, targetBytes: 1000)
        XCTAssertEqual(parts.flatMap { $0 }, Array(1...sizes.count))
    }

    /// A page is the smallest thing a PDF can be cut into. Dropping one to satisfy a size cap
    /// would silently remove evidence from a bundle.
    func testAPageLargerThanTheTargetBecomesItsOwnOversizedPart() {
        let parts = PageRanges.packBySize([100, 5_000, 100], targetBytes: 1_000)
        XCTAssertEqual(parts, [[1], [2], [3]])
        XCTAssertEqual(parts.flatMap { $0 }, [1, 2, 3], "the oversized page is still there")
    }

    func testAnEmptyDocumentOrANonPositiveTargetPacksNothing() {
        XCTAssertEqual(PageRanges.packBySize([], targetBytes: 1000), [])
        XCTAssertEqual(PageRanges.packBySize([100, 200], targetBytes: 0), [])
        XCTAssertEqual(PageRanges.packBySize([100, 200], targetBytes: -1), [])
    }
}
