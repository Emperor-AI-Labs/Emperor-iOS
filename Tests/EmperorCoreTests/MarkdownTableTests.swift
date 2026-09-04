import XCTest
@testable import EmperorCore

final class MarkdownTableTests: XCTestCase {

    // MARK: - Parsing

    func testAPlainTableParses() {
        let table = MarkdownTable.first(in: """
            | Date | Event |
            |---|---|
            | 2026-01-14 | Suit filed |
            | 2026-03-02 | Written statement |
            """)

        XCTAssertEqual(table?.headers, ["Date", "Event"])
        XCTAssertEqual(table?.rows.count, 2)
        XCTAssertEqual(table?.rows.first, ["2026-01-14", "Suit filed"])
    }

    /// GFM makes the outer pipes optional.
    func testOuterPipesAreOptional() {
        let table = MarkdownTable.first(in: """
            Date | Event
            --- | ---
            2026-01-14 | Suit filed
            """)

        XCTAssertEqual(table?.headers, ["Date", "Event"])
        XCTAssertEqual(table?.rows.first, ["2026-01-14", "Suit filed"])
    }

    func testAlignmentsAreRead() {
        let table = MarkdownTable.first(in: """
            | Left | Middle | Right |
            |:---|:---:|---:|
            | a | b | c |
            """)

        XCTAssertEqual(table?.alignments, [.leading, .center, .trailing])
    }

    /// An empty cell between two pipes is real content — a blank "Order" column is meaningful
    /// in a chronology, and collapsing it shifts every later cell into the wrong column.
    func testAnEmptyInteriorCellSurvives() {
        let table = MarkdownTable.first(in: """
            | Date | Order | Note |
            |---|---|---|
            | 2026-01-14 |  | Adjourned |
            """)

        XCTAssertEqual(table?.rows.first, ["2026-01-14", "", "Adjourned"])
    }

    /// An escaped pipe is content, not a column break. Amounts and citations contain them.
    func testAnEscapedPipeIsNotAColumnBreak() {
        let table = MarkdownTable.first(in: """
            | Provision | Text |
            |---|---|
            | s.9 | either \\| or |
            """)

        XCTAssertEqual(table?.rows.first, ["s.9", "either | or"])
    }

    /// Model output is frequently ragged. A renderer assuming a rectangle would drop cells or
    /// trap, so normalisation happens here rather than in the view.
    func testRaggedRowsAreNormalisedToTheHeaderWidth() {
        let table = MarkdownTable.first(in: """
            | A | B | C |
            |---|---|---|
            | 1 | 2 |
            | 1 | 2 | 3 | 4 |
            """)

        XCTAssertEqual(table?.normalisedRows, [["1", "2", ""], ["1", "2", "3"]])
    }

    func testATableWithNoBodyRowsStillParses() {
        let table = MarkdownTable.first(in: """
            | Date | Event |
            |---|---|
            """)

        XCTAssertEqual(table?.headers, ["Date", "Event"])
        XCTAssertEqual(table?.rows.count, 0)
    }

    // MARK: - Not tables

    /// The rule the server uses: a header row **immediately** followed by a delimiter row.
    /// Prose containing a pipe is not a table, and treating it as one would eat the paragraph.
    func testProseContainingAPipeIsNotATable() {
        XCTAssertNil(MarkdownTable.first(in: "The claim is for damages | interest | costs."))
        XCTAssertFalse(MarkdownTable.containsTable("A sentence with a | pipe in it."))
    }

    func testAHeaderWithoutADelimiterIsNotATable() {
        XCTAssertNil(MarkdownTable.first(in: """
            | Date | Event |
            | 2026-01-14 | Suit filed |
            """))
    }

    /// A hyphenated sentence under a pipe row must not be mistaken for a delimiter.
    func testAHyphenatedRowIsNotADelimiter() {
        XCTAssertNil(MarkdownTable.first(in: """
            | Date | Event |
            | well-founded | co-operative |
            """))
    }

    /// A delimiter that disagrees with the header on width is a coincidence, not a table.
    func testAMismatchedDelimiterWidthIsRejected() {
        XCTAssertNil(MarkdownTable.first(in: """
            | A | B | C |
            |---|---|
            | 1 | 2 | 3 |
            """))
    }

    func testAnEmptyDocumentHasNoTable() {
        XCTAssertNil(MarkdownTable.first(in: ""))
        XCTAssertNil(MarkdownTable.first(in: "\n\n"))
    }

    // MARK: - Segmentation

    /// A chronology usually arrives framed by a sentence before and a note after. Dropping
    /// either loses the answer's meaning, so the document is split rather than mined.
    func testProseAroundATableIsPreservedInOrder() {
        let segments = MarkdownTable.segments(in: """
            The chronology is as follows.

            | Date | Event |
            |---|---|
            | 2026-01-14 | Suit filed |

            Limitation therefore expired on 2029-01-14.
            """)

        XCTAssertEqual(segments.count, 3)
        guard case .prose(let lead) = segments[0] else { return XCTFail("expected prose first") }
        XCTAssertTrue(lead.hasPrefix("The chronology"))
        guard case .table(let table) = segments[1] else { return XCTFail("expected a table") }
        XCTAssertEqual(table.rows.count, 1)
        guard case .prose(let tail) = segments[2] else { return XCTFail("expected trailing prose") }
        XCTAssertTrue(tail.hasPrefix("Limitation"))
    }

    func testTwoTablesInOneDocument() {
        let segments = MarkdownTable.segments(in: """
            | A |
            |---|
            | 1 |

            Between.

            | B |
            |---|
            | 2 |
            """)

        let tables = segments.compactMap { segment -> MarkdownTable? in
            if case .table(let table) = segment { return table }
            return nil
        }
        XCTAssertEqual(tables.count, 2)
        XCTAssertEqual(tables.map(\.headers), [["A"], ["B"]])
    }

    func testADocumentWithNoTableIsOneProseSegment() {
        let segments = MarkdownTable.segments(in: "Just an answer.\n\nWith two paragraphs.")
        XCTAssertEqual(segments.count, 1)
        guard case .prose = segments[0] else { return XCTFail("expected prose") }
    }
}
