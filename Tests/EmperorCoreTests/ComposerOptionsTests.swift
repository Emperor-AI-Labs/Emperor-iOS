import XCTest
@testable import EmperorCore

/// Linux XCTest cannot invoke a `@MainActor` test method — see `ChatViewModelTests`.
@MainActor
private func onComposerMainActor(_ body: @MainActor () async -> Void) async {
    await body()
}

/// Draft length, research sources and page setup: how each is remembered, and where page setup
/// lands in a Word file. Their data is held to the web by `ComposerOptionsGoldenTests`.
final class ComposerOptionsTests: XCTestCase {

    // MARK: Draft length

    func testDraftLengthStartsDetailedAndIsRememberedPerAccount() {
        let store = InMemoryPreferenceStore()
        XCTAssertEqual(DraftDepth.stored(in: store, userID: 7), .detailed)
        DraftDepth.short.save(to: store, userID: 7)
        XCTAssertEqual(DraftDepth.stored(in: store, userID: 7), .short)
        XCTAssertEqual(DraftDepth.stored(in: store, userID: 8), .detailed, "another account keeps its own")
    }

    func testAnUnknownStoredLengthFallsBackToDetailed() {
        let store = InMemoryPreferenceStore()
        store.setString("medium", for: DraftDepth.key(forUser: 1))
        XCTAssertEqual(DraftDepth.stored(in: store, userID: 1), .detailed)
    }

    // MARK: Research sources

    func testSourcesToggleAndCount() {
        var sources = ResearchSources.default
        XCTAssertEqual(sources.activeCount, 1)
        sources.toggle("uk")
        sources.toggle("web")
        XCTAssertTrue(sources.searchesWeb)
        XCTAssertEqual(sources.activeCount, 3)
        sources.toggle("uk")
        XCTAssertFalse(sources.isOn("uk"))
    }

    func testSourcesRoundTripAndAnEmptySelectionStaysEmpty() {
        let store = InMemoryPreferenceStore()
        var sources = ResearchSources.default
        sources.toggle("in")
        sources.save(to: store, userID: 3)
        XCTAssertEqual(ResearchSources.stored(in: store, userID: 3).selected, [],
                       "everything switched off is a choice, not a missing value")
        sources.toggle("rbi")
        sources.toggle("web")
        sources.save(to: store, userID: 3)
        XCTAssertEqual(ResearchSources.stored(in: store, userID: 3).selected, ["rbi", "web"])
        XCTAssertEqual(ResearchSources.stored(in: store, userID: 4), .default)
    }

    func testARetiredSourceIsDroppedOnRead() {
        let store = InMemoryPreferenceStore()
        store.setString("web,atlantis,in", for: ResearchSources.key(forUser: 1))
        XCTAssertEqual(ResearchSources.stored(in: store, userID: 1).selected, ["web", "in"])
    }

    /// The footer may say what is kept and what reaches the server — and must not say the
    /// jurisdictions narrow anything, because on no client do they yet.
    func testTheFooterMakesNoClaimItCannotKeep() {
        let footer = ResearchSources.footer
        XCTAssertTrue(footer.contains("this device"))
        XCTAssertTrue(footer.contains("Web search"))
        XCTAssertTrue(footer.contains("do not yet narrow"))
    }

    func testTheModelSavesEveryChangeAndSharesTheWebRow() async {
        await onComposerMainActor {
            let store = InMemoryPreferenceStore()
            let model = ResearchSourcesModel(store: store, userID: 5)
            XCTAssertFalse(model.searchesWeb)
            model.setSearchesWeb(true)
            XCTAssertTrue(ResearchSources.stored(in: store, userID: 5).searchesWeb)
            model.toggle(ResearchSources.webID)
            XCTAssertFalse(model.searchesWeb)
            model.toggle("sg")
            XCTAssertEqual(ResearchSourcesModel(store: store, userID: 5).sources.selected, ["in", "sg"])
        }
    }

    // MARK: Page setup

    func testPageSetupIsRememberedPerAccount() {
        let store = InMemoryPreferenceStore()
        XCTAssertEqual(DocumentPageSetup.stored(in: store, userID: 2), .default)
        let legal = DocumentPageSetup(size: .legal, orientation: .landscape,
                                      margins: DocumentPageMargins(top: 30, right: 15, bottom: 30, left: 40))
        legal.save(to: store, userID: 2)
        XCTAssertEqual(DocumentPageSetup.stored(in: store, userID: 2), legal)
        XCTAssertEqual(DocumentPageSetup.stored(in: store, userID: 9), .default)
    }

    func testAStoredSetupThatIsNotJSONIsTheDefault() {
        let store = InMemoryPreferenceStore()
        store.setString("A4 please", for: DocumentPageSetup.key(forUser: 1))
        XCTAssertEqual(DocumentPageSetup.stored(in: store, userID: 1), .default)
    }

    func testTypedMarginsOutsideTheRangeTakeTheirDefault() {
        let setup = DocumentPageSetup.default.with(
            margins: DocumentPageMargins(top: -1, right: 12, bottom: .nan, left: 500))
        XCTAssertEqual(setup.margins, DocumentPageMargins(top: 25, right: 12, bottom: 25, left: 25))
    }

    func testTheMenuShowsEachSizesDimensions() {
        XCTAssertEqual(DocumentPageSize.a4.dimensionsLabel, "210 × 297mm")
        XCTAssertEqual(DocumentPageSize.legal.dimensionsLabel, "215.9 × 355.6mm")
    }

    func testPointsAreSeventyTwoToTheInch() {
        let letter = DocumentPageSetup(size: .letter)
        XCTAssertEqual(letter.widthPoints, 612, accuracy: 0.01)
        XCTAssertEqual(letter.heightPoints, 792, accuracy: 0.01)
        let landscape = DocumentPageSetup(size: .a4, orientation: .landscape)
        XCTAssertEqual(landscape.widthPoints, 841.89, accuracy: 0.01)
        XCTAssertEqual(landscape.marginPoints.right, 56.69, accuracy: 0.01)
    }

    // MARK: Page setup in Word

    private func documentXML(_ html: String, _ setup: DocumentPageSetup) -> String {
        String(decoding: DocxDocument.make(fromHTML: html, pageSetup: setup), as: UTF8.self)
    }

    func testTheDefaultWordPageIsA4PortraitWithTheWebsMargins() {
        let xml = documentXML("<p>x</p>", .default)
        XCTAssertTrue(xml.contains(#"<w:pgSz w:w="11906" w:h="16838"/>"#))
        XCTAssertTrue(xml.contains(#"<w:pgMar w:top="1417" w:right="1134" w:bottom="1417" w:left="1417""#))
        XCTAssertFalse(xml.contains("w:orient"))
    }

    /// The bug the web fixed in its own exporter: a landscape page has to be *wide*, not merely
    /// labelled landscape — Word sizes the sheet from `w:w`/`w:h`.
    func testALandscapePageIsWideAndSaysSo() {
        let xml = documentXML("<p>x</p>", DocumentPageSetup(size: .a4, orientation: .landscape))
        XCTAssertTrue(xml.contains(#"<w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/>"#))
    }

    func testMarginsReachWordInTwips() {
        let setup = DocumentPageSetup(size: .letter, margins: DocumentPageMargins(top: 10, right: 12.5, bottom: 20, left: 38.1))
        let xml = documentXML("<p>x</p>", setup)
        XCTAssertTrue(xml.contains(#"<w:pgSz w:w="12240" w:h="15840"/>"#))
        XCTAssertTrue(xml.contains(#"<w:pgMar w:top="567" w:right="709" w:bottom="1134" w:left="2160""#))
    }

    /// A table is laid across the width between the margins of the page it is printed on.
    func testATableFitsTheChosenPage() {
        let table = "<table><tr><td>a</td><td>b</td></tr></table>"
        let landscape = DocumentPageSetup(size: .a4, orientation: .landscape)
        let width = landscape.contentWidthTwips
        XCTAssertEqual(width, 16838 - 1417 - 1134)
        XCTAssertTrue(documentXML(table, landscape).contains(#"<w:tblW w:w="\#(width)" w:type="dxa"/>"#))
        XCTAssertTrue(documentXML(table, landscape).contains(#"<w:gridCol w:w="\#(width / 2)"/>"#))
    }
}
