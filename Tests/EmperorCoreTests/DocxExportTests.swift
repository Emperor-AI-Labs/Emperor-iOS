import XCTest
@testable import EmperorCore

/// Producing a Word file that Word will actually open.
///
/// The platform tried the cheap route first — HTML with a `.docx` on the end — and its own note
/// records the result: "several Office builds opened read-only or refused as corrupt". So the
/// bar here is a real OOXML package, and these tests check the package rather than the prose.
///
/// Set `DOCX_OUT` and `testAnExportedFileIsWrittenForExternalValidation` writes real files to be
/// opened with real tooling — a Swift assertion that our own writer round-trips our own bytes
/// proves very little. That is how the missing `w:tblGrid` was caught: every assertion below
/// passed while LibreOffice was silently dropping a column.
final class DocxExportTests: XCTestCase {

    private static let pleading = """
        <h1 style="text-align:center">IN THE HIGH COURT OF DELHI AT NEW DELHI</h1>
        <p style="text-align:center"><b>W.P.(C) 1234/2026</b></p>
        <p>The Petitioner respectfully submits that the impugned order is <i>ultra vires</i> \
        Section 5 &amp; contrary to <u>Kesavananda Bharati</u>.</p>
        <table><thead><tr><th>Date</th><th>Event</th></tr></thead>
        <tbody><tr><td>14.07.2026</td><td>Notice issued</td></tr></tbody></table>
        """

    // MARK: - The container

    func testAZipEntryCarriesItsOwnChecksum() {
        // Checked against a value the format itself fixes: CRC32 of "123456789".
        XCTAssertEqual(ZipArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(ZipArchive.crc32(Data()), 0)
    }

    func testAnArchiveCarriesItsEntriesAndItsDirectory() {
        var zip = ZipArchive()
        zip.add("a.xml", "<a/>")
        zip.add("b/c.xml", "<c/>")
        let data = zip.data()

        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "local file header first")
        // End-of-central-directory, and it records both entries.
        let tail = Array(data.suffix(22))
        XCTAssertEqual(Array(tail.prefix(4)), [0x50, 0x4B, 0x05, 0x06])
        XCTAssertEqual(Int(tail[10]) | Int(tail[11]) << 8, 2, "two entries in the directory")
    }

    /// Byte-identical twice over. Nothing here may read the clock: an export that differed run to
    /// run could not be compared, and two exports of one document should be one file.
    func testTheSameDocumentExportsToTheSameBytes() {
        XCTAssertEqual(
            DocxDocument.make(fromHTML: Self.pleading),
            DocxDocument.make(fromHTML: Self.pleading))
    }

    // MARK: - The package

    /// `[Content_Types].xml` must come first, or Word cannot find the content types before the
    /// parts they describe and rejects the package.
    func testContentTypesIsTheFirstEntry() {
        let data = DocxDocument.make(fromHTML: "<p>x</p>")
        let head = String(decoding: data.prefix(200), as: UTF8.self)
        XCTAssertTrue(head.contains("[Content_Types].xml"))
    }

    func testThePackageHoldsEveryPartWordNeeds() {
        let text = String(decoding: DocxDocument.make(fromHTML: Self.pleading), as: UTF8.self)
        for part in [
            "[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml",
            "word/_rels/document.xml.rels",
        ] {
            XCTAssertTrue(text.contains(part), "missing \(part)")
        }
    }

    // MARK: - The document

    private func document(_ html: String) -> String {
        String(decoding: DocxDocument.make(fromHTML: html), as: UTF8.self)
    }

    func testAHeadingBecomesAHeadingAndKeepsWithItsText() {
        let xml = document("<h1>IN THE HIGH COURT</h1><p>Body.</p>")
        XCTAssertTrue(xml.contains("Heading1"))
        // A heading alone at the foot of a page, orphaned from what it introduces, is the thing
        // this prevents.
        XCTAssertTrue(xml.contains("<w:keepNext/><w:keepLines/>"))
        XCTAssertTrue(xml.contains("<w:jc w:val=\"center\"/>"), "a cause title is centred")
    }

    func testEmphasisSurvivesAsFormattingRatherThanTags() {
        let xml = document("<p><b>bold</b> <i>italic</i> <u>under</u> <s>struck</s></p>")
        XCTAssertTrue(xml.contains("<w:b/>"))
        XCTAssertTrue(xml.contains("<w:i/>"))
        XCTAssertTrue(xml.contains("<w:u w:val=\"single\"/>"))
        XCTAssertTrue(xml.contains("<w:strike/>"))
        XCTAssertFalse(xml.contains("&lt;b&gt;"), "the tag itself must not print")
    }

    /// The editor writes weight as inline CSS at least as often as as a tag, and the platform's
    /// converter reads both. Reading only tags would drop an emphasis that is plain on screen.
    func testInlineCSSEmphasisIsReadToo() {
        XCTAssertTrue(document("<p><span style=\"font-weight:bold\">x</span></p>")
            .contains("<w:b/>"))
        XCTAssertTrue(document("<p><span style=\"font-style: italic\">x</span></p>")
            .contains("<w:i/>"))
    }

    /// A long chronology must break between whole rows with its header repeated — not slice a
    /// date in half across a page break.
    func testATableRepeatsItsHeaderAndNeverSplitsARow() {
        let xml = document(Self.pleading)
        XCTAssertTrue(xml.contains("<w:tbl>"))
        XCTAssertTrue(xml.contains("<w:tblHeader/>"), "the header row repeats")
        XCTAssertTrue(xml.contains("<w:cantSplit/>"), "a row is never sliced")
    }

    /// **The one the XML could not tell us about.** Every Swift assertion here passed while
    /// LibreOffice was dropping every column but the first — the document was well-formed and
    /// wrong. `w:tblGrid` is what a reader lays the cells against, and without it the second
    /// column silently disappeared and the page count doubled.
    func testATableDeclaresItsColumnGrid() {
        let twoColumns = document(Self.pleading)
        XCTAssertTrue(twoColumns.contains("<w:tblGrid>"))
        XCTAssertEqual(
            twoColumns.components(separatedBy: "<w:gridCol").count - 1, 2,
            "one gridCol per column, or a reader has nothing to lay the cells against")

        let three = document("<table><tr><td>a</td><td>b</td><td>c</td></tr></table>")
        XCTAssertEqual(three.components(separatedBy: "<w:gridCol").count - 1, 3)
    }

    /// The grid is sized to the page it will be printed on, not left to chance.
    func testColumnsShareTheUsablePageWidth() {
        // A4 is 11906 twips; the margins take 1418 and 1134, leaving 9354 to divide.
        XCTAssertTrue(document("<table><tr><td>a</td><td>b</td></tr></table>")
            .contains("<w:gridCol w:w=\"4677\"/>"))
    }

    /// A `&` in a party's name makes the package unopenable if it reaches the XML raw.
    func testAmpersandsAndAnglesAreEscaped() {
        let xml = document("<p>Tata &amp; Sons &lt;Pvt&gt; Ltd</p>")
        XCTAssertTrue(xml.contains("Tata &amp; Sons &lt;Pvt&gt; Ltd"))
        XCTAssertFalse(xml.contains("<w:t xml:space=\"preserve\">Tata & Sons"))
    }

    /// `&nbsp;` is everywhere in what the editor emits. Left undecoded it prints as six literal
    /// characters in the middle of a cause title.
    func testEntitiesAreDecodedBeforeTheyReachTheDocument() {
        XCTAssertEqual(HTMLFragment.decodeEntities("A&nbsp;B"), "A\u{00A0}B")
        XCTAssertEqual(HTMLFragment.decodeEntities("&amp;&lt;&gt;"), "&<>")
        XCTAssertEqual(HTMLFragment.decodeEntities("&#8377;100"), "₹100")
        XCTAssertEqual(HTMLFragment.decodeEntities("&#x20B9;100"), "₹100")
        XCTAssertEqual(
            HTMLFragment.decodeEntities("100% & rising"), "100% & rising",
            "a bare ampersand is not an entity and must survive")
    }

    /// An empty document is still a document. Word will not open a body with no paragraph.
    func testAnEmptyFragmentStillProducesAValidBody() {
        let xml = document("")
        XCTAssertTrue(xml.contains("<w:body>"))
        XCTAssertTrue(xml.contains("<w:p/>") || xml.contains("<w:p>"))
    }

    // MARK: - The reader

    func testUnknownWrappersAreDescendedIntoRatherThanDropped() {
        // The text inside is the pleading; the tag is packaging.
        XCTAssertTrue(document("<article><section><p>Kept.</p></section></article>")
            .contains("Kept."))
        XCTAssertTrue(document("<mark><p>Kept.</p></mark>").contains("Kept."))
    }

    func testScriptAndStyleContentNeverReachesTheDocument() {
        let xml = document("<p>Real.</p><script>alert(1)</script><style>p{color:red}</style>")
        XCTAssertTrue(xml.contains("Real."))
        XCTAssertFalse(xml.contains("alert(1)"))
        XCTAssertFalse(xml.contains("color:red"))
    }

    /// Model-authored markup carries stray close tags often enough that failing on one would mean
    /// refusing to export a document the user is looking at.
    func testStrayMarkupDoesNotLoseTheDocument() {
        XCTAssertTrue(document("<p>One.</p></div><p>Two.</p>").contains("One."))
        XCTAssertTrue(document("<p>One.</p></div><p>Two.</p>").contains("Two."))
        XCTAssertTrue(document("<p>Unclosed").contains("Unclosed"))
    }

    // MARK: - Written out for the shell to validate

    /// Writes a real file so it can be opened by real ZIP and XML tooling. Our own writer
    /// round-tripping our own bytes would prove almost nothing about whether Word accepts it.
    func testAnExportedFileIsWrittenForExternalValidation() throws {
        guard let path = ProcessInfo.processInfo.environment["DOCX_OUT"] else {
            throw XCTSkip("set DOCX_OUT to write a sample for external validation")
        }
        try DocxDocument.make(fromHTML: Self.pleading)
            .write(to: URL(fileURLWithPath: path))

        // The markdown route as well, which reaches the same writer through `MarkdownHTML`.
        let markdown = """
            # Chronology of Events

            The **Petitioner** relies on the *following* dates.

            | Date | Event |
            | --- | --- |
            | 14.07.2026 | Notice issued |
            | 02.08.2026 | Reply filed |
            """
        try DocxDocument.make(fromHTML: MarkdownHTML.html(from: markdown))
            .write(to: URL(fileURLWithPath: path).deletingLastPathComponent()
                .appendingPathComponent("from-markdown.docx"))

        // Pictures and lists, which the XML alone cannot tell us render correctly.
        let rich = """
            <h2>Grounds</h2>
            <ol><li>That the order is without jurisdiction.</li>
            <li>That the Petitioner was not heard.
            <ul><li>No notice was served.</li><li>No hearing was fixed.</li></ul></li>
            <li>That the finding is perverse.</li></ol>
            <p>The seal affixed to the impugned order:</p>
            <p><img src="\(Self.pngDataURI)"></p>
            """
        try DocxDocument.make(fromHTML: rich)
            .write(to: URL(fileURLWithPath: path).deletingLastPathComponent()
                .appendingPathComponent("rich.docx"))
    }

    // MARK: - Pictures

    /// A real 3x2 PNG, so the header reader is exercised on an actual file rather than a guess.
    private static let pngDataURI =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAEElEQVR4nGP4z8AAQQxwFgBB0gX7h/C5SAAAAABJRU5ErkJggg=="

    func testAPictureIsSizedFromItsOwnHeader() throws {
        let image = try XCTUnwrap(EmbeddedImage.parse(dataURI: Self.pngDataURI))
        XCTAssertEqual(image.format, .png)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
    }

    /// GIF writes its size little-endian where PNG writes it big-endian; getting that backwards
    /// lays a picture out sideways.
    func testGIFDimensionsAreReadLittleEndian() throws {
        var bytes = Data("GIF89a".utf8)
        bytes.append(contentsOf: [0x40, 0x01, 0x20, 0x00])   // 320 x 32
        let image = try XCTUnwrap(EmbeddedImage.read(bytes))
        XCTAssertEqual(image.format, .gif)
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 32)
    }

    func testAPictureIsPackedWithItsRelationshipAndContentType() {
        let data = DocxDocument.make(fromHTML: "<p><img src=\"\(Self.pngDataURI)\"></p>")
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("word/media/image1.png"), "the bytes are in the package")
        XCTAssertTrue(text.contains("<Default Extension=\"png\" ContentType=\"image/png\"/>"))
        XCTAssertTrue(text.contains("r:embed=\"rId3\""), "images start after styles and numbering")
        XCTAssertTrue(text.contains("<w:drawing>"))
        // 3px at 96dpi is 3 x 9525 EMU. Far under the page, so it is not scaled.
        XCTAssertTrue(text.contains("cx=\"28575\""))
    }

    /// A screenshot of an order is routinely wider than the text column. It is scaled to fit
    /// keeping its shape, rather than running off the page.
    func testAnOversizePictureIsScaledToTheColumn() {
        var bytes = Data("GIF89a".utf8)
        bytes.append(contentsOf: [0x10, 0x27, 0x88, 0x13])   // 10000 x 5000
        let uri = "data:image/gif;base64,\(bytes.base64EncodedString())"
        let text = String(
            decoding: DocxDocument.make(fromHTML: "<p><img src=\"\(uri)\"></p>"), as: UTF8.self)

        // The usable column is 9354 twips, and a twip is 635 EMU.
        XCTAssertTrue(text.contains("cx=\"5939790\""), "clamped to the column")
        XCTAssertTrue(text.contains("cy=\"2969895\""), "and the aspect ratio is kept")
    }

    /// An export must not depend on the network or on a credential, so a remote picture is not
    /// fetched — but the reader is told, rather than left with a silent hole where a seal was.
    func testARemotePictureIsNamedRatherThanSilentlyDropped() {
        let text = String(
            decoding: DocxDocument.make(fromHTML: "<p><img src=\"https://x/seal.png\"></p>"),
            as: UTF8.self)
        XCTAssertTrue(text.contains("[image not embedded]"))
        XCTAssertFalse(text.contains("<w:drawing>"))
    }

    // MARK: - Lists

    /// Typed-in markers print but Word will not renumber them: insert an item at the top of a
    /// list of twenty and every number below it is silently wrong.
    func testAListIsARealListRatherThanTypedMarkers() {
        let text = document("<ol><li>First</li><li>Second</li></ol>")
        XCTAssertTrue(text.contains("<w:numPr>"))
        XCTAssertTrue(text.contains("<w:numId w:val=\"2\"/>"), "ordered lists use the decimal id")
        XCTAssertFalse(text.contains("1. "), "the number must not be typed into the text")

        let bullets = document("<ul><li>One</li></ul>")
        XCTAssertTrue(bullets.contains("<w:numId w:val=\"1\"/>"))
    }

    func testTheNumberingPartIsInThePackageAndReferenced() {
        let text = String(decoding: DocxDocument.make(fromHTML: "<ul><li>x</li></ul>"), as: UTF8.self)
        XCTAssertTrue(text.contains("word/numbering.xml"))
        XCTAssertTrue(text.contains("numbering+xml"), "declared in [Content_Types].xml")
        XCTAssertTrue(text.contains("Id=\"rId2\""), "and related from the document")
    }

    /// A nested list is its own level, and its text must not also appear in its parent item.
    func testANestedListIsIndentedAndNotDuplicated() {
        let text = document("<ul><li>Outer<ul><li>Inner</li></ul></li></ul>")
        XCTAssertTrue(text.contains("<w:ilvl w:val=\"0\"/>"))
        XCTAssertTrue(text.contains("<w:ilvl w:val=\"1\"/>"))
        XCTAssertEqual(
            text.components(separatedBy: "Inner").count - 1, 1,
            "the nested item appears once, not once per level")
    }
}
