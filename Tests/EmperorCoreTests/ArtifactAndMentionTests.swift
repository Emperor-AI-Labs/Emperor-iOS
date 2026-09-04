import XCTest
@testable import EmperorCore

/// Behaviours verified against the live platform source rather than against its (stale)
/// AGENTS.md — see the citations on each case.
final class ArtifactAndMentionTests: XCTestCase {

    // MARK: - Reasoning wrappers

    /// Different upstream models wrap deliberation differently. The platform strips six
    /// variants (`src/lib/output.js:11-22`); missing one puts private working in front of a
    /// client.
    func testEveryReasoningWrapperIsStripped() {
        for tag in ["think", "thinking", "scratchpad", "reasoning", "internal", "reflection"] {
            let content = StreamContent.parse("<\(tag)>private working</\(tag)>The answer.")
            XCTAssertEqual(content.prose, "The answer.", "<\(tag)> leaked into prose")
            XCTAssertEqual(content.reasoning, ["private working"])
        }
    }

    // MARK: - Annexure citations

    /// The citation token is markup, not prose, but it is also the product's core claim —
    /// so it is removed from the text and kept as structured data.
    func testCitationTokenIsLiftedOutOfProse() {
        let content = StreamContent.parse(
            "The sale was completed on 4 March 2019<@sale_deed.pdf:A-1:4-9>.")

        XCTAssertEqual(content.prose, "The sale was completed on 4 March 2019.")
        XCTAssertEqual(content.mentions.count, 1)
        let mention = content.mentions[0]
        XCTAssertEqual(mention.fileName, "sale_deed.pdf")
        XCTAssertEqual(mention.mark, "A-1")
        XCTAssertEqual(mention.startPage, 4)
        XCTAssertEqual(mention.endPage, 9)
        XCTAssertEqual(mention.pageDescription, "pp. 4–9")
    }

    /// The page range is optional in the spec.
    func testCitationWithoutPageRange() {
        let content = StreamContent.parse("As pleaded<@counter_affidavit.pdf:R-3>.")
        XCTAssertEqual(content.prose, "As pleaded.")
        XCTAssertEqual(content.mentions.first?.fileName, "counter_affidavit.pdf")
        XCTAssertEqual(content.mentions.first?.mark, "R-3")
        XCTAssertNil(content.mentions.first?.startPage)
        XCTAssertNil(content.mentions.first?.pageDescription)
    }

    func testSinglePageCitationReadsAsOnePage() {
        let content = StreamContent.parse("Order dated 1 May<@order.pdf:A-2:7-7>.")
        XCTAssertEqual(content.mentions.first?.pageDescription, "p. 7")
    }

    func testMultipleCitationsArePreservedInOrder() {
        let content = StreamContent.parse(
            "First<@a.pdf:A-1:1-2> then second<@b.pdf:A-2:3-4>.")
        XCTAssertEqual(content.mentions.map(\.fileName), ["a.pdf", "b.pdf"])
        XCTAssertEqual(content.prose, "First then second.")
    }

    /// An email address or a stray `<@` must not be mistaken for a citation.
    func testNonCitationAngleContentIsUntouched() {
        let text = "Write to counsel at the address on record."
        XCTAssertEqual(StreamContent.parse(text).prose, text)
        XCTAssertTrue(StreamContent.parse(text).mentions.isEmpty)
    }

    // MARK: - Artifact format sniffing

    /// The wrapper is a claim, not a fact. The platform records a live incident where a
    /// pleading arrived as HTML paragraphs inside `<table_content>`
    /// (`src/lib/canvasShape.js:1-9`); rendering that as Markdown shows raw tags.
    func testHTMLInsideTableWrapperIsDetectedAsHTML() {
        let content = StreamContent.parse("""
        [TABLE_TRIGGER: Chronology]<table_content>
        <p style="text-align:center"><strong>IN THE HIGH COURT</strong></p>
        <p>The petitioner submits as follows.</p>
        </table_content>
        """)
        XCTAssertEqual(content.artifacts.first?.kind, .table)
        XCTAssertEqual(content.artifacts.first?.format, .html)
    }

    /// A genuine GFM table, with the alignment colons the platform actually emits.
    func testGenuineMarkdownTableIsDetectedAsMarkdown() {
        let content = StreamContent.parse("""
        [TABLE_TRIGGER: Index]<table_content>
        | S. No. | Particulars | Page No. |
        |:------:|:------------|:--------:|
        | 1. | Notice of Motion | i |
        </table_content>
        """)
        XCTAssertEqual(content.artifacts.first?.format, .markdown)
    }

    /// Canvas content is inline-styled HTML fragments, never a full document.
    func testCanvasContentIsDetectedAsHTML() {
        let content = StreamContent.parse("""
        [CANVAS_TRIGGER: Writ Petition]<canvas_content>
        <p style="text-align:center"><strong><u>IN THE HIGH COURT OF DELHI</u></strong></p>
        </canvas_content>
        """)
        XCTAssertEqual(content.artifacts.first?.format, .html)
    }

    /// `<br>` is excluded from the block-tag test on purpose: Markdown table cells routinely
    /// contain one, and treating that as HTML would misroute real tables.
    func testLineBreakDoesNotForceHTMLDetection() {
        let content = StreamContent.parse("""
        [TABLE_TRIGGER: T]<table_content>
        | A | B |
        |---|---|
        | one<br>two | three |
        </table_content>
        """)
        XCTAssertEqual(content.artifacts.first?.format, .markdown)
    }

    /// Models intermittently fence the document, which would render a pleading as source.
    func testFencedArtifactBodyIsUnwrapped() {
        let content = StreamContent.parse("""
        [CANVAS_TRIGGER: Draft]<canvas_content>```html
        <p>The petitioner states.</p>
        ```</canvas_content>
        """)
        XCTAssertEqual(content.artifacts.first?.body, "<p>The petitioner states.</p>")
        XCTAssertEqual(content.artifacts.first?.format, .html)
    }

    // MARK: - Wire options

    /// `preferred_model` is only a seed for the picker; the per-request model wins.
    func testModelPreferenceMapping() {
        XCTAssertEqual(ChatModel.fromPreference("thinking"), .thinking)
        XCTAssertEqual(ChatModel.fromPreference("fast"), .fast)
        // The column can hold legacy or null values; fall back rather than fail.
        XCTAssertEqual(ChatModel.fromPreference(nil), .fast)
        XCTAssertEqual(ChatModel.fromPreference("emperor-executive-6"), .fast)
    }

    /// These three strings are what the web client puts on the wire; matching them keeps
    /// answers identical across the two products.
    func testRoleWireValuesMatchThePlatform() {
        XCTAssertEqual(
            Set(ChatRole.allCases.map(\.wireValue)),
            ["Litigator", "Corporate Counsel", "Judicial Officer"])
    }

    /// Attachments must serialise into the shape the server reads off a message, or the
    /// scanned-document check at `sync-server.js:7334` never sees them.
    func testAttachmentEncodesForEmbeddingOnAMessage() throws {
        let rooted = ChatAttachment(name: "sale_deed.pdf", folderName: "Partition_Suit")
        XCTAssertEqual(rooted.jsonValue["name"]?.stringValue, "sale_deed.pdf")
        XCTAssertEqual(rooted.jsonValue["folderName"]?.stringValue, "Partition_Suit")

        // An empty folder means the storage root on the chat path — send no key rather than
        // an empty string.
        let atRoot = ChatAttachment(name: "loose.pdf", folderName: "")
        XCTAssertNil(atRoot.jsonValue["folderName"])
        XCTAssertEqual(atRoot.jsonValue["name"]?.stringValue, "loose.pdf")
    }

    /// The single-page form from the spec: `<@file.ext:MARK:page>` with no range.
    ///
    /// The server strips only well-formed tokens, so a client regex that misses this form
    /// leaves `<@MHA_OM.pdf:P-5:7>` rendering verbatim in the middle of a pleading.
    func testSinglePageCitationFormIsMatched() {
        let content = StreamContent.parse(
            "Annexure P-5: True Copy of the MHA Office Memorandum<@MHA_OM_22.02.2021.pdf:P-5:7>")

        XCTAssertEqual(content.prose, "Annexure P-5: True Copy of the MHA Office Memorandum")
        XCTAssertEqual(content.mentions.count, 1)
        XCTAssertEqual(content.mentions.first?.fileName, "MHA_OM_22.02.2021.pdf")
        XCTAssertEqual(content.mentions.first?.mark, "P-5")
        XCTAssertEqual(content.mentions.first?.startPage, 7)
        XCTAssertNil(content.mentions.first?.endPage)
        XCTAssertEqual(content.mentions.first?.pageDescription, "p. 7")
    }

    /// All three spec forms must survive side by side in one answer.
    func testAllThreeCitationFormsCoexist() {
        let content = StreamContent.parse(
            "A<@a.pdf:P-1> B<@b.pdf:P-2:3> C<@c.pdf:P-3:4-9>.")
        XCTAssertEqual(content.prose, "A B C.")
        XCTAssertEqual(content.mentions.map(\.startPage), [nil, 3, 4])
        XCTAssertEqual(content.mentions.map(\.endPage), [nil, nil, 9])
    }
}
