import XCTest
@testable import EmperorCore

/// The device's search: what a case and a document become in the index, what a tapped result
/// opens, and when the index is written and emptied.
@MainActor
final class SpotlightTests: XCTestCase {

    // MARK: - Cases

    private static let bakshi: LegalCase = {
        var legalCase = LegalCase(id: "case1")
        legalCase.title = "Bakshi v. State of Maharashtra"
        legalCase.parties = "Rohan Bakshi vs. State of Maharashtra"
        legalCase.courtName = "Bombay High Court"
        legalCase.caseType = "W.P."
        legalCase.caseNumber = "1234"
        legalCase.caseYear = "2025"
        legalCase.cnr = "MHHC010012342025"
        legalCase.nextHearingDateRaw = "2026-10-06"
        return legalCase
    }()

    /// A case is found by its name, and the line under it says where and when it is next heard.
    func testACaseBecomesAnEntryWithItsReferenceCourtAndNextHearing() async throws {
        let entry = try XCTUnwrap(SpotlightCatalogue.entries(for: [Self.bakshi]).first)

        XCTAssertEqual(entry.identifier, "case:case1")
        XCTAssertEqual(entry.domain, .cases)
        XCTAssertEqual(entry.title, "Bakshi v. State of Maharashtra")
        XCTAssertEqual(entry.detail, "W.P. 1234/2025 · Bombay High Court · Next hearing 6 Oct 2026")
        XCTAssertNil(entry.fileExtension)
    }

    /// The parties, the court, the reference and the CNR are all things a person types to find a
    /// matter, so all of them are matched.
    func testACaseIsFoundByItsPartiesCourtReferenceAndCNR() async throws {
        let entry = try XCTUnwrap(SpotlightCatalogue.entries(for: [Self.bakshi]).first)

        XCTAssertTrue(entry.keywords.contains("Rohan Bakshi vs. State of Maharashtra"))
        XCTAssertTrue(entry.keywords.contains("Bombay High Court"))
        XCTAssertTrue(entry.keywords.contains("W.P. 1234/2025"))
        XCTAssertTrue(entry.keywords.contains("MHHC010012342025"))
        XCTAssertFalse(entry.keywords.contains("Bakshi v. State of Maharashtra"), "the title is already searched")
    }

    /// A case with no hearing date says nothing about one rather than inventing it.
    func testACaseWithoutAHearingSaysNothingAboutOne() async throws {
        var legalCase = Self.bakshi
        legalCase.nextHearingDateRaw = nil
        let entry = try XCTUnwrap(SpotlightCatalogue.entries(for: [legalCase]).first)
        XCTAssertEqual(entry.detail, "W.P. 1234/2025 · Bombay High Court")
    }

    /// The `"[]"` sentinel is no parties at all; an array in a string is a list of names.
    func testPartiesAreReadInEachOfTheirShapes() async {
        XCTAssertEqual(SpotlightCatalogue.partyNames("[]"), [])
        XCTAssertEqual(SpotlightCatalogue.partyNames("  "), [])
        XCTAssertEqual(SpotlightCatalogue.partyNames(nil), [])
        XCTAssertEqual(SpotlightCatalogue.partyNames("A vs. B"), ["A vs. B"])
        XCTAssertEqual(SpotlightCatalogue.partyNames(#"["Kapoor Textiles","Union of India"]"#),
                       ["Kapoor Textiles", "Union of India"])
        XCTAssertEqual(SpotlightCatalogue.partyNames(#"[{"name":"Meridian Finance"},{"role":"x"}]"#),
                       ["Meridian Finance"])
        XCTAssertEqual(SpotlightCatalogue.partyNames("[not json"), [], "a broken array is not prose")
    }

    /// A case's id is what a tap opens, so one without an id — or the same id twice — is left out.
    func testCasesWithoutAUsableIdAreLeftOut() async {
        let blank = LegalCase(id: "  ")
        let entries = SpotlightCatalogue.entries(for: [Self.bakshi, blank, Self.bakshi])
        XCTAssertEqual(entries.map(\.identifier), ["case:case1"])
    }

    // MARK: - Documents

    private static let tree: [FileNode] = [
        folder("Bakshi", [
            .file(readyFile("Bakshi/Plaint.pdf")),
            folder("Bakshi/Orders", [.file(readyFile("Bakshi/Orders/Interim_Order.pdf"))]),
        ]),
        .file(readyFile("Engagement_Letter.docx")),
    ]

    /// A document is found by its name as a person wrote it and by the folders it sits in.
    func testADocumentBecomesAnEntryWithItsFolder() async throws {
        let entries = SpotlightCatalogue.entries(for: Self.tree)
        XCTAssertEqual(entries.count, 3, "every document, at every depth")

        let order = try XCTUnwrap(entries.first { $0.identifier == "document:Bakshi/Orders/Interim_Order.pdf" })
        XCTAssertEqual(order.domain, .documents)
        XCTAssertEqual(order.title, "Interim Order.pdf")
        XCTAssertEqual(order.detail, "Bakshi / Orders")
        XCTAssertEqual(order.fileExtension, "pdf")
        XCTAssertTrue(order.keywords.contains("Bakshi"))
        XCTAssertTrue(order.keywords.contains("Orders"))
        XCTAssertTrue(order.keywords.contains("Interim_Order.pdf"), "the stored name is searchable too")

        let letter = try XCTUnwrap(entries.first { $0.identifier == "document:Engagement_Letter.docx" })
        XCTAssertEqual(letter.detail, "My Files")
        XCTAssertEqual(letter.fileExtension, "docx")
    }

    // MARK: - Tapped results

    func testIdentifiersParseBackToWhereTheyLead() async {
        XCTAssertEqual(SpotlightCatalogue.target(forIdentifier: "case:case-hc-delhi"), .caseDetail(id: "case-hc-delhi"))
        XCTAssertEqual(
            SpotlightCatalogue.target(forIdentifier: "document:Bakshi/Orders/Interim_Order.pdf"),
            .document(path: "Bakshi/Orders/Interim_Order.pdf"))
        XCTAssertNil(SpotlightCatalogue.target(forIdentifier: "case:"))
        XCTAssertNil(SpotlightCatalogue.target(forIdentifier: "document:/"))
        XCTAssertNil(SpotlightCatalogue.target(forIdentifier: "chat:c1"), "not written by this build")
        XCTAssertNil(SpotlightCatalogue.target(forIdentifier: ""))
    }

    /// Every identifier written parses back to the thing it was written for.
    func testEveryEntryRoundTrips() async {
        for entry in SpotlightCatalogue.entries(for: [Self.bakshi]) {
            XCTAssertEqual(SpotlightCatalogue.target(forIdentifier: entry.identifier), .caseDetail(id: "case1"))
        }
        let paths = FileService.allFiles(in: Self.tree).map(\.path)
        for (entry, path) in zip(SpotlightCatalogue.entries(for: Self.tree), paths) {
            XCTAssertEqual(SpotlightCatalogue.target(forIdentifier: entry.identifier), .document(path: path))
        }
    }

    func testTheInboxHoldsATappedResultUntilTaken() async {
        let inbox = SpotlightInbox()
        inbox.open(identifier: "case:case1")
        XCTAssertEqual(inbox.tapCount, 1)
        XCTAssertEqual(inbox.take(), .caseDetail(id: "case1"))
        XCTAssertNil(inbox.take(), "taken once")

        inbox.open(identifier: "something:else")
        XCTAssertNil(inbox.pending)
        XCTAssertEqual(inbox.tapCount, 1, "an identifier this build did not write is ignored")
    }

    /// A case result opens the case on the Matters tab, through the same request the Calendar uses.
    func testACaseResultOpensTheCase() async {
        let navigator = AppNavigator(selectedTab: .files)
        navigator.open(.caseDetail(id: "case1"))
        XCTAssertEqual(navigator.selectedTab, .matters)
        XCTAssertEqual(navigator.takePendingCaseStack()?.map(\.caseID), ["case1"])
    }

    /// A document result leaves the tab alone — My Files is shown over it — and is taken once.
    func testADocumentResultWaitsForMyFiles() async {
        let navigator = AppNavigator(selectedTab: .you)
        navigator.open(.document(path: "/Bakshi/Orders/Interim_Order.pdf"))

        XCTAssertEqual(navigator.selectedTab, .you)
        let route = navigator.takePendingDocument()
        XCTAssertEqual(route?.path, "Bakshi/Orders/Interim_Order.pdf")
        XCTAssertNil(navigator.takePendingDocument())

        navigator.openDocument(path: " / ")
        XCTAssertNil(navigator.pendingDocument, "nothing to open")
    }

    /// The folders are opened on the way down, outermost first, so Back climbs the library.
    func testADocumentOpensThroughEachOfItsFolders() async {
        XCTAssertEqual(DocumentRoute(path: "Bakshi/Orders/Interim_Order.pdf").folderStack, ["Bakshi", "Bakshi/Orders"])
        XCTAssertEqual(DocumentRoute(path: "Bakshi/Plaint.pdf").folderPath, "Bakshi")
        XCTAssertEqual(DocumentRoute(path: "Engagement_Letter.docx").folderStack, [])
    }

    /// Two requests for the same document are still two changes to observe.
    func testAskingAgainIsANewRequest() async {
        let navigator = AppNavigator()
        navigator.openDocument(path: "Bakshi/Plaint.pdf")
        let first = navigator.takePendingDocument()
        navigator.openDocument(path: "Bakshi/Plaint.pdf")
        XCTAssertNotEqual(first, navigator.pendingDocument)
    }

    // MARK: - My Files previews the document

    private func filesModel() -> MyFilesViewModel {
        let files = FakeFiles()
        files.tree = Self.tree
        return MyFilesViewModel(service: files, manager: InertFileManager())
    }

    func testTheDocumentsFolderPreviewsIt() async {
        let model = filesModel()
        model.requestPreview(of: "Bakshi/Orders/Interim_Order.pdf")
        XCTAssertNil(model.takePreview(in: "Bakshi/Orders"), "not before the library has loaded")

        await model.load()

        XCTAssertNil(model.takePreview(in: ""), "the top level is not its folder")
        XCTAssertNil(model.takePreview(in: "Bakshi"))
        XCTAssertEqual(model.takePreview(in: "Bakshi/Orders")?.name, "Interim_Order.pdf")
        XCTAssertNil(model.takePreview(in: "Bakshi/Orders"), "taken once")
    }

    func testADocumentAtTheTopLevelPreviewsThere() async {
        let model = filesModel()
        await model.load()
        model.requestPreview(of: "Engagement_Letter.docx")
        XCTAssertEqual(model.takePreview(in: "")?.name, "Engagement_Letter.docx")
    }

    /// A document deleted since the search last saw it is let go with a word, not an empty viewer.
    func testADocumentNoLongerThereSaysSo() async {
        let model = filesModel()
        await model.load()
        model.requestPreview(of: "Bakshi/Gone.pdf")

        XCTAssertNil(model.takePreview(in: "Bakshi"))
        XCTAssertEqual(model.actionNotice, "That document is no longer in your library.")
        XCTAssertNil(model.pendingPreview)
    }

    /// Each reading of the library is passed on, which is how the search learns the documents.
    func testEachReadingOfTheLibraryIsPassedOn() async {
        let model = filesModel()
        var readings: [[FileNode]] = []
        model.onTreeLoaded = { readings.append($0) }

        await model.load()

        XCTAssertEqual(readings, [Self.tree])
    }

    // MARK: - The setting

    func testTheSettingIsOnUntilTurnedOff() async {
        let store = InMemoryPreferenceStore()
        XCTAssertTrue(SpotlightPreference.isEnabled(in: store))
        SpotlightPreference.setEnabled(false, in: store)
        XCTAssertFalse(SpotlightPreference.isEnabled(in: store))
        SpotlightPreference.setEnabled(true, in: store)
        XCTAssertTrue(SpotlightPreference.isEnabled(in: store))
    }

    // MARK: - When the index is written

    private func coordinator(
        enabled: Bool = true
    ) -> (SpotlightCoordinator, FakeSpotlightIndex, InMemoryPreferenceStore) {
        let store = InMemoryPreferenceStore()
        SpotlightPreference.setEnabled(enabled, in: store)
        let index = FakeSpotlightIndex()
        return (SpotlightCoordinator(index: index, store: store), index, store)
    }

    func testALoadedDocketIsIndexed() async {
        let (coordinator, index, _) = coordinator()
        await coordinator.casesLoaded([Self.bakshi], isSignedIn: true)?.value
        XCTAssertEqual(index.operations, [.replace(.cases, ["case:case1"])])
    }

    func testALoadedLibraryIsIndexed() async {
        let (coordinator, index, _) = coordinator()
        await coordinator.documentsLoaded(Self.tree, isSignedIn: true)?.value
        XCTAssertEqual(index.operations.count, 1)
        guard case .replace(let domain, let ids) = index.operations.first else {
            return XCTFail("expected a replace")
        }
        XCTAssertEqual(domain, .documents)
        XCTAssertEqual(ids.count, 3)
    }

    /// Off means nothing is written at all.
    func testNothingIsIndexedWhileTheSettingIsOff() async {
        let (coordinator, index, _) = coordinator(enabled: false)
        XCTAssertNil(coordinator.casesLoaded([Self.bakshi], isSignedIn: true))
        XCTAssertNil(coordinator.documentsLoaded(Self.tree, isSignedIn: true))
        XCTAssertTrue(index.operations.isEmpty)
    }

    /// A docket that lands after sign-out — a request already on its way — is not indexed.
    func testNothingIsIndexedForNobody() async {
        let (coordinator, index, _) = coordinator()
        XCTAssertNil(coordinator.casesLoaded([Self.bakshi], isSignedIn: false))
        XCTAssertTrue(index.operations.isEmpty)
    }

    /// Turning it off removes everything, and is remembered.
    func testTurningItOffEmptiesTheIndex() async {
        let (coordinator, index, store) = coordinator()
        await coordinator.casesLoaded([Self.bakshi], isSignedIn: true)?.value

        await coordinator.setEnabled(false, isSignedIn: true)?.value

        XCTAssertEqual(index.operations.last, .removeAll)
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertFalse(SpotlightPreference.isEnabled(in: store))
    }

    /// Turning it back on indexes what is already loaded, without waiting for the next load.
    func testTurningItOnIndexesWhatIsKnown() async {
        let (coordinator, index, _) = coordinator(enabled: false)
        coordinator.casesLoaded([Self.bakshi], isSignedIn: true)
        coordinator.documentsLoaded(Self.tree, isSignedIn: true)

        await coordinator.setEnabled(true, isSignedIn: true)?.value

        XCTAssertEqual(index.operations.map(\.kind), ["replace:cases", "replace:documents"])
    }

    /// Sign-out empties the index and forgets what was loaded, so turning the setting on again
    /// for the next person indexes nothing of the last one's.
    func testSigningOutEmptiesTheIndexAndForgets() async {
        let (coordinator, index, _) = coordinator()
        await coordinator.casesLoaded([Self.bakshi], isSignedIn: true)?.value

        await coordinator.signedOut()?.value
        XCTAssertEqual(index.operations.last, .removeAll)

        await coordinator.setEnabled(false, isSignedIn: false)?.value
        let before = index.operations.count
        XCTAssertNil(coordinator.setEnabled(true, isSignedIn: true))
        XCTAssertEqual(index.operations.count, before)
    }

    /// At launch, an index that should be empty is emptied — in case a removal never ran.
    func testLaunchEmptiesAnIndexThatShouldBeEmpty() async {
        let (off, offIndex, _) = coordinator(enabled: false)
        await off.launched(isSignedIn: true)?.value
        XCTAssertEqual(offIndex.operations, [.removeAll])

        let (signedOut, signedOutIndex, _) = coordinator()
        await signedOut.launched(isSignedIn: false)?.value
        XCTAssertEqual(signedOutIndex.operations, [.removeAll])

        let (normal, normalIndex, _) = coordinator()
        XCTAssertNil(normal.launched(isSignedIn: true))
        XCTAssertTrue(normalIndex.operations.isEmpty)
    }

    /// One piece of work at a time, in order: a removal is never overtaken by a write that was
    /// asked for before it.
    func testWorkRunsInTheOrderAsked() async {
        let (coordinator, index, _) = coordinator()
        index.delay = true
        coordinator.casesLoaded([Self.bakshi], isSignedIn: true)
        let last = coordinator.signedOut()

        await last?.value

        XCTAssertEqual(index.operations.map(\.kind), ["replace:cases", "removeAll"])
    }
}

/// The index, recorded. Test-only.
@MainActor
final class FakeSpotlightIndex: SpotlightIndexing {
    enum Operation: Equatable {
        case replace(SpotlightDomain, [String])
        case removeAll

        var kind: String {
            switch self {
            case .replace(let domain, _): return "replace:\(domain == .cases ? "cases" : "documents")"
            case .removeAll: return "removeAll"
            }
        }
    }

    private(set) var operations: [Operation] = []
    /// Makes each write yield before recording, so a later request has the chance to overtake.
    var delay = false

    func replace(_ domain: SpotlightDomain, with entries: [SpotlightEntry]) async {
        if delay { for _ in 0..<5 { await Task.yield() } }
        operations.append(.replace(domain, entries.map(\.identifier)))
    }

    func removeAll() async {
        operations.append(.removeAll)
    }
}

/// A file manager that is never asked to do anything. Test-only.
final class InertFileManager: FileManaging, @unchecked Sendable {
    func delete(name: String, folderName: String?) async throws {}
    func rename(
        name: String, in folderName: String?, to newName: String
    ) async throws -> FileOperationResult {
        throw APIError.transport("unused")
    }
    func move(name: String, from folderName: String?, to destination: String?) async throws {}
    func setFavorite(_ favorite: Bool, name: String, folderName: String?) async throws -> Bool { favorite }
    func createFolder(named path: String) async throws {}
    func renameFolder(at path: String, to newName: String) async throws -> String { newName }
    func deleteFolder(named path: String) async throws {}
}
