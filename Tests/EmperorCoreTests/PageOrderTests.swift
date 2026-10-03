import XCTest
@testable import EmperorCore

/// Reads a fixture written by `scripts/generate-file-tool-fixtures.mjs`.
func fileToolFixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    let url = try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "file-tools"),
        "missing fixture \(name).json — run scripts/generate-file-tool-fixtures.mjs")
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

/// Rearrange's ordering language.
///
/// The golden half runs every case the platform's own `parsePageOrder` answered under Node —
/// the self-test's cases, the whitespace and digit sets where Swift and JavaScript disagree, the
/// expansion cap, and four hundred generated instructions — and requires the same pages, the same
/// errors word for word, and the same dropped list. The hand-written half states the rules the
/// module exists for, so a failure names the rule rather than a fixture row.
final class PageOrderTests: XCTestCase {

    private struct Fixture: Decodable {
        struct ParseCase: Decodable {
            let spec: String
            let pageCount: Int
            let pages: [Int]
            let errors: [String]
            let dropped: [Int]
        }
        struct FormatCase: Decodable {
            let pages: [Int]
            let formatted: String
            let roundTrip: [Int]
        }
        struct SummariseCase: Decodable {
            let list: [Int]
            let text: String
        }
        struct ExampleCase: Decodable {
            let label: String
            let spec: String
            let why: String
            let filled: [String: String]
        }
        let maxOutputPages: Int
        let examples: [ExampleCase]
        let parse: [ParseCase]
        let format: [FormatCase]
        let summarise: [SummariseCase]
    }

    private func fixture() throws -> Fixture {
        try fileToolFixture("page-order", as: Fixture.self)
    }

    /// The web's one sentence that names the browser. This client says "on the phone"; the
    /// substitution is the only place the two may differ.
    private func localised(_ error: String) -> String {
        error.replacingOccurrences(
            of: "more than this tool will build in the browser.",
            with: "more than this tool will build on the phone.")
    }

    // MARK: - Golden

    func testEveryCaseTheWebAnsweredIsAnsweredTheSameWay() throws {
        let fixture = try fixture()
        XCTAssertGreaterThan(fixture.parse.count, 1000, "the corpus should be broad")
        var failures = 0
        for item in fixture.parse {
            let parsed = PageOrder.parse(item.spec, pageCount: item.pageCount)
            if parsed.pages != item.pages || parsed.errors != item.errors.map(localised)
                || parsed.dropped != item.dropped {
                failures += 1
                if failures <= 10 {
                    XCTFail("""
                        \(item.spec.debugDescription) on \(item.pageCount) pages:
                          web   \(item.pages.prefix(20)) \(item.errors) dropped \(item.dropped.prefix(20))
                          swift \(parsed.pages.prefix(20)) \(parsed.errors) dropped \(parsed.dropped.prefix(20))
                        """)
                }
            }
        }
        XCTAssertEqual(failures, 0, "\(failures) of \(fixture.parse.count) cases differ from the web")
    }

    func testTheCapIsTheWebsCap() throws {
        XCTAssertEqual(try fixture().maxOutputPages, PageOrder.maxOutputPages)
    }

    func testFormattingMatchesTheWebAndRoundTrips() throws {
        let fixture = try fixture()
        for item in fixture.format {
            XCTAssertEqual(PageOrder.format(item.pages), item.formatted, "\(item.pages)")
            XCTAssertEqual(
                PageOrder.parse(item.formatted, pageCount: 9).pages, item.roundTrip,
                "\(item.formatted) must read back as the web reads it back")
            if item.pages.allSatisfy({ $0 <= 9 }) {
                XCTAssertEqual(item.roundTrip, item.pages, "\(item.formatted) round-trips")
            }
        }
    }

    func testTheDroppedNoticeSummarisesAsTheWebDoes() throws {
        for item in try fixture().summarise {
            XCTAssertEqual(PageOrder.summarise(item.list), item.text, "\(item.list)")
        }
    }

    func testTheExamplesAreTheWebsAndFillTheSameWay() throws {
        let examples = try fixture().examples
        XCTAssertEqual(PageOrder.examples.map(\.label), examples.map(\.label))
        for (ours, theirs) in zip(PageOrder.examples, examples) {
            XCTAssertEqual(ours.template, theirs.spec)
            XCTAssertEqual(ours.why, theirs.why)
            for (count, filled) in theirs.filled {
                XCTAssertEqual(ours.spec(pageCount: Int(count)!), filled, "\(ours.label) at \(count)")
            }
        }
    }

    // MARK: - The rules, by name

    /// The one behaviour that separates this parser from Split's: `9-7` counts down.
    func testADescendingRangeCountsDownRatherThanBeingSorted() {
        XCTAssertEqual(PageOrder.parse("9-7", pageCount: 10).pages, [9, 8, 7])
        XCTAssertEqual(PageOrder.parse("1-3, 9-7", pageCount: 10).pages, [1, 2, 3, 9, 8, 7])
        XCTAssertEqual(PageOrder.parse("5, 3, 1", pageCount: 10).pages, [5, 3, 1])
    }

    /// No set, no de-duplication: a page written three times appears three times.
    func testDuplicatesSurvive() {
        XCTAssertEqual(PageOrder.parse("5, 5, 5", pageCount: 10).pages, [5, 5, 5])
        XCTAssertEqual(PageOrder.parse("5x3", pageCount: 10).pages, [5, 5, 5])
        XCTAssertEqual(PageOrder.parse("5*3", pageCount: 10).pages, [5, 5, 5])
        XCTAssertEqual(PageOrder.parse("3-4x2", pageCount: 10).pages, [3, 4, 3, 4])
        XCTAssertEqual(PageOrder.parse("1, 5, 1, 6, 1", pageCount: 10).pages, [1, 5, 1, 6, 1])
    }

    func testNamedSelectors() {
        XCTAssertEqual(PageOrder.parse("all", pageCount: 4).pages, [1, 2, 3, 4])
        XCTAssertEqual(PageOrder.parse("reverse", pageCount: 4).pages, [4, 3, 2, 1])
        XCTAssertEqual(PageOrder.parse("rev", pageCount: 3).pages, [3, 2, 1])
        XCTAssertEqual(PageOrder.parse("odd, even", pageCount: 6).pages, [1, 3, 5, 2, 4, 6])
        XCTAssertEqual(PageOrder.parse("last, first", pageCount: 8).pages, [8, 1])
        XCTAssertEqual(PageOrder.parse("ALL", pageCount: 3).pages, [1, 2, 3])
    }

    /// An out-of-range page is refused and named — never clamped into a different page.
    func testAPagePastTheEndIsRefusedNotClamped() {
        let parsed = PageOrder.parse("1-3, 12", pageCount: 10)
        XCTAssertEqual(parsed.pages, [1, 2, 3])
        XCTAssertEqual(parsed.errors, ["Page 12: this document only has 10 pages."])

        let span = PageOrder.parse("8-12", pageCount: 10)
        XCTAssertEqual(span.pages, [], "a span reaching past the end is refused whole")
        XCTAssertEqual(span.errors, ["Pages 8-12: this document only has 10 pages."])

        XCTAssertEqual(
            PageOrder.parse("2", pageCount: 1).errors,
            ["Page 2: this document only has 1 page."], "singular for a one-page document")
    }

    func testOneBadTokenDoesNotDiscardTheGoodOnes() {
        let parsed = PageOrder.parse("1-3, banana, 5", pageCount: 10)
        XCTAssertEqual(parsed.pages, [1, 2, 3, 5])
        XCTAssertEqual(parsed.errors.count, 1)
        XCTAssertTrue(parsed.errors[0].hasPrefix("\"banana\" is not something I understand"))
    }

    /// Leaving pages out is legitimate here, so it is reported rather than refused.
    func testDroppedPagesAreReportedAscendingEvenWhenTheOrderIsNot() {
        XCTAssertEqual(PageOrder.parse("5, 1", pageCount: 6).dropped, [2, 3, 4, 6])
        XCTAssertEqual(PageOrder.parse("1x5", pageCount: 3).dropped, [2, 3],
                       "repeats do not mask the pages they omit")
        XCTAssertEqual(PageOrder.parse("all", pageCount: 5).dropped, [])
    }

    /// `all x1000` on a long document would build a file the phone cannot hold. The cap stops
    /// reading at the token that would cross it, keeping what came before.
    func testAnAbsurdExpansionIsRefusedAndStopsTheParse() {
        let parsed = PageOrder.parse("1, all x1000, 2", pageCount: 10)
        XCTAssertEqual(parsed.pages, [1])
        XCTAssertEqual(parsed.errors.count, 1)
        XCTAssertTrue(parsed.errors[0].contains("more than 5000 pages"))
        XCTAssertFalse(parsed.errors[0].contains("browser"), "there is no browser here")

        XCTAssertEqual(PageOrder.parse("all x500", pageCount: 10).pages.count, 5000, "exactly at the cap is fine")
    }

    /// The JavaScript loops `repeat` times even when the expansion is empty, which for a huge
    /// count never returns. The port must give the same (empty) answer and return.
    func testAnEmptyExpansionWithAHugeRepeatReturnsImmediately() {
        let parsed = PageOrder.parse("even x99999999999999999999", pageCount: 1)
        XCTAssertEqual(parsed.pages, [])
        XCTAssertEqual(parsed.errors, [])
        XCTAssertEqual(parsed.dropped, [1])
    }

    /// `\d` is ASCII in JavaScript. A page typed in Arabic-Indic or full-width digits must be
    /// refused here too, or the two clients disagree about what was typed.
    func testOnlyASCIIDigitsAreDigits() {
        XCTAssertEqual(PageOrder.parse("١", pageCount: 10).pages, [])
        XCTAssertEqual(PageOrder.parse("５", pageCount: 10).errors.count, 1)
    }

    /// `\r\n` is one `Character` in Swift; JavaScript splits it on the `\n` and trims the `\r`.
    func testAPastedWindowsLineBreakSeparatesTokens() {
        XCTAssertEqual(PageOrder.parse("1\r\n2", pageCount: 3).pages, [1, 2])
    }

    func testANumberPastEveryIntegerTypeIsReportedInTheWebsWords() {
        XCTAssertEqual(
            PageOrder.parse("99999999999999999999", pageCount: 10).errors,
            ["Page 100000000000000000000: this document only has 10 pages."])
    }

    func testAZeroRepeatIsRefused() {
        XCTAssertEqual(
            PageOrder.parse("5x0", pageCount: 10).errors,
            ["\"5x0\": a repeat count has to be 1 or more."])
    }

    func testADocumentWithNoPagesHasNothingToSay() {
        XCTAssertEqual(PageOrder.parse("1-3", pageCount: 0), .init(pages: [], errors: [], dropped: []))
    }

    func testTheSeedIsTheDocumentAsItIs() {
        XCTAssertEqual(PageOrder.identity(pageCount: 12), "1-12")
        XCTAssertEqual(PageOrder.identity(pageCount: 1), "1")
        XCTAssertEqual(PageOrder.parse(PageOrder.identity(pageCount: 12), pageCount: 12).pages, Array(1...12))
    }

    func testFormatCollapsesRepeatsAndRunsButNotPairs() {
        XCTAssertEqual(PageOrder.format([4, 4, 4]), "4x3")
        XCTAssertEqual(PageOrder.format([9, 8, 7]), "9-7")
        XCTAssertEqual(PageOrder.format([1, 2]), "1, 2")
        XCTAssertEqual(PageOrder.format([]), "")
    }

    func testJavaScriptNumberFormatting() {
        XCTAssertEqual(PageOrder.javaScriptString(1e20), "100000000000000000000")
        XCTAssertEqual(PageOrder.javaScriptString(1e21), "1e+21")
        XCTAssertEqual(PageOrder.javaScriptString(12345678901234567168), "12345678901234567000")
        XCTAssertEqual(PageOrder.javaScriptString(.infinity), "Infinity")
    }
}
