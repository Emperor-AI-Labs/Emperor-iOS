import XCTest
@testable import EmperorCore

/// Finding the block structure `AttributedString` will not give us.
///
/// The chat answer is Markdown — the platform says so plainly (`ToolWorkspace.jsx:503`) and
/// renders it through its own Markdown component. This app drew it with a plain `Text`, so every
/// heading, list and table arrived as literal characters on the screen people read most.
final class MarkdownBlockTests: XCTestCase {

    func testAHeadingIsAHeadingAndKeepsItsLevel() {
        XCTAssertEqual(
            MarkdownBlocks.parse("## Grounds"), [.heading(level: 2, text: "Grounds")])
        XCTAssertEqual(
            MarkdownBlocks.parse("###### Deep"), [.heading(level: 6, text: "Deep")])
    }

    /// A hash without a space is not a heading. `#1` opens plenty of paragraphs about a case
    /// number, and turning that into a title would be a visible mistake.
    func testAHashWithoutASpaceIsNotAHeading() {
        XCTAssertEqual(MarkdownBlocks.parse("#1 of 2026"), [.paragraph("#1 of 2026")])
        XCTAssertEqual(
            MarkdownBlocks.parse("####### seven"), [.paragraph("####### seven")])
    }

    func testBulletsAndNumbersAreRecognisedWithTheirDepth() {
        XCTAssertEqual(
            MarkdownBlocks.parse("- First\n- Second"),
            [.bullet(depth: 0, text: "First"), .bullet(depth: 0, text: "Second")])
        XCTAssertEqual(
            MarkdownBlocks.parse("* Star\n+ Plus"),
            [.bullet(depth: 0, text: "Star"), .bullet(depth: 0, text: "Plus")])
        XCTAssertEqual(
            MarkdownBlocks.parse("1. One\n2) Two"),
            [.numbered(depth: 0, number: 1, text: "One"),
             .numbered(depth: 0, number: 2, text: "Two")])
    }

    /// Two-space and four-space nesting both read as nesting. Models emit both, and flattening
    /// either would lose the structure of an argument set out in sub-points.
    func testNestingIsReadFromTheIndent() {
        XCTAssertEqual(
            MarkdownBlocks.parse("- Outer\n  - Inner\n    - Deeper"),
            [.bullet(depth: 0, text: "Outer"), .bullet(depth: 1, text: "Inner"),
             .bullet(depth: 2, text: "Deeper")])
        XCTAssertEqual(
            MarkdownBlocks.parse("- Outer\n\t- Tabbed"),
            [.bullet(depth: 0, text: "Outer"), .bullet(depth: 1, text: "Tabbed")])
    }

    /// A dash with no space after it is a sentence, usually a dash. It is not a list.
    func testADashWithoutASpaceIsProse() {
        XCTAssertEqual(MarkdownBlocks.parse("-not a list"), [.paragraph("-not a list")])
        XCTAssertEqual(MarkdownBlocks.parse("2026-09-17"), [.paragraph("2026-09-17")])
    }

    /// A blank line separates paragraphs; a single newline inside one does not. Getting this
    /// wrong is what turns a multi-paragraph opinion into one unbroken blob.
    func testBlankLinesSeparateParagraphsAndSingleNewlinesDoNot() {
        XCTAssertEqual(
            MarkdownBlocks.parse("One line\nstill one.\n\nSecond."),
            [.paragraph("One line\nstill one."), .paragraph("Second.")])
    }

    func testAQuoteIsItsOwnBlock() {
        XCTAssertEqual(
            MarkdownBlocks.parse("> Held, the appeal fails."),
            [.quote("Held, the appeal fails.")])
    }

    func testAFencedBlockIsKeptVerbatim() {
        XCTAssertEqual(
            MarkdownBlocks.parse("```\n  indented\n- not a list\n```"),
            [.code("  indented\n- not a list")])
    }

    /// An interrupted answer can stop inside a fence. That must not swallow everything after it
    /// as code — but it also must not lose the text.
    func testAnUnclosedFenceStillYieldsItsContent() {
        XCTAssertEqual(
            MarkdownBlocks.parse("```\nstopped mid"), [.code("stopped mid")])
    }

    func testARuleIsABreakRatherThanAListOrAParagraph() {
        XCTAssertEqual(
            MarkdownBlocks.parse("One\n\n---\n\nTwo"),
            [.paragraph("One"), .paragraph("Two")])
    }

    /// Inline markup is left alone — `AttributedString` reads that, and doing it here as well
    /// would mean two parsers disagreeing about the same text.
    func testInlineMarkupIsLeftForTheInlineParser() {
        XCTAssertEqual(
            MarkdownBlocks.parse("- **Bold** and *italic*"),
            [.bullet(depth: 0, text: "**Bold** and *italic*")])
    }

    /// The shape of a real answer, end to end.
    func testARealAnswerDecomposesAsExpected() {
        let answer = """
            ## Grounds

            The Petitioner submits as follows.

            1. That the order is without jurisdiction.
            2. That no notice was served.
               - Neither by post
               - Nor by hand

            > Held: service is mandatory.
            """
        XCTAssertEqual(MarkdownBlocks.parse(answer), [
            .heading(level: 2, text: "Grounds"),
            .paragraph("The Petitioner submits as follows."),
            .numbered(depth: 0, number: 1, text: "That the order is without jurisdiction."),
            .numbered(depth: 0, number: 2, text: "That no notice was served."),
            .bullet(depth: 1, text: "Neither by post"),
            .bullet(depth: 1, text: "Nor by hand"),
            .quote("Held: service is mandatory."),
        ])
    }
}
