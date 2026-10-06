import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

/// A clock a test moves by hand, so "opened least recently" is decided by the test rather than
/// by how fast the machine runs.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval = 60) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    var reader: @Sendable () -> Date { { [self] in self.now } }
}

/// A backing store that can be "locked" like a phone: while locked, every entry still exists but
/// none can be read, and nothing can be written. Exactly what `.completeFileProtection` does.
final class LockableStore: CacheStore, @unchecked Sendable {
    private let base = InMemoryCacheStore()
    private let lock = NSLock()
    private var _isLocked = false
    private var _refusesWrites = false

    var isLocked: Bool {
        get { lock.withLock { _isLocked } }
        set { lock.withLock { _isLocked = newValue } }
    }

    /// A full disk: writes vanish.
    var refusesWrites: Bool {
        get { lock.withLock { _refusesWrites } }
        set { lock.withLock { _refusesWrites = newValue } }
    }

    func read(_ key: String) -> Data? { isLocked ? nil : base.read(key) }
    func contains(_ key: String) -> Bool { base.read(key) != nil }
    func write(_ data: Data, for key: String) {
        guard !isLocked, !refusesWrites else { return }
        base.write(data, for: key)
    }
    func remove(_ key: String) { base.remove(key) }
    func removeAll() { base.removeAll() }
}

private func bytes(_ count: Int, _ fill: UInt8 = 1) -> Data { Data(repeating: fill, count: count) }

final class OfflineStoreTests: XCTestCase {

    private func makeStore(
        budget: Int = 100, backing: any CacheStore = InMemoryCacheStore(), clock: TestClock = TestClock()
    ) -> OfflineStore {
        OfflineStore(namespace: "a1.documents", budget: budget, store: backing, now: clock.reader)
    }

    // MARK: - Round trip

    func testACopyComesBackWithWhenItWasFetched() {
        let clock = TestClock()
        let store = makeStore(clock: clock)
        store.save(Data("%PDF".utf8), for: "file:Bakshi/Plaint.pdf")
        clock.advance()

        let copy = store.open("file:Bakshi/Plaint.pdf")

        XCTAssertEqual(copy?.data, Data("%PDF".utf8))
        XCTAssertEqual(copy?.savedAt, Date(timeIntervalSince1970: 1_790_000_000),
                       "the age is when it was fetched, not when it was last opened")
    }

    func testNothingIsReturnedForAKeyNeverSaved() {
        XCTAssertNil(makeStore().open("file:Missing.pdf"))
    }

    /// On this API an empty body is "unknown", never a document. Keeping one would later open
    /// offline as a blank page, presented as the document.
    func testAnEmptyBodyIsNeverKept() {
        let store = makeStore()
        XCTAssertEqual(store.save(Data(), for: "file:Empty.pdf"), .notSaved(.empty))
        XCTAssertFalse(store.contains("file:Empty.pdf"))
    }

    /// The index lives in the backing store, so a store built afresh — the next launch — finds
    /// what the last one kept.
    func testCopiesSurviveANewStoreOverTheSameDisk() {
        let backing = InMemoryCacheStore()
        makeStore(backing: backing).save(bytes(10), for: "file:A.pdf")

        let reopened = makeStore(backing: backing)

        XCTAssertEqual(reopened.open("file:A.pdf")?.data, bytes(10))
        XCTAssertEqual(reopened.totalBytes, 10)
    }

    // MARK: - Eviction

    /// Room is made from the copy opened least recently — not the one saved first.
    func testRoomIsMadeFromTheLeastRecentlyOpened() {
        let clock = TestClock()
        let store = makeStore(clock: clock)
        store.save(bytes(40), for: "a")
        clock.advance()
        store.save(bytes(40), for: "b")
        clock.advance()
        _ = store.open("a")
        clock.advance()

        let outcome = store.save(bytes(40), for: "c")

        XCTAssertEqual(outcome.isSaved, true)
        guard case .saved(let evicted) = outcome else { return XCTFail() }
        XCTAssertEqual(evicted.map(\.key), ["b"])
        XCTAssertTrue(store.contains("a"), "opening it kept it")
        XCTAssertTrue(store.contains("c"))
        XCTAssertLessThanOrEqual(store.totalBytes, 100)
    }

    /// A document saved for offline on purpose goes after every automatic copy, however long ago
    /// it was opened.
    func testASavedDocumentIsEvictedLast() {
        let clock = TestClock()
        let store = makeStore(clock: clock)
        store.save(bytes(40), for: "pinned", pin: true)
        clock.advance()
        store.save(bytes(40), for: "automatic")
        clock.advance()

        store.save(bytes(40), for: "new")

        XCTAssertTrue(store.contains("pinned"), "the older saved copy outlived a newer automatic one")
        XCTAssertFalse(store.contains("automatic"))
    }

    /// An automatic copy never pushes out a deliberate one. When only saved copies stand in the
    /// way, the new one is not kept, and nothing else is touched.
    func testAnAutomaticCopyNeverDisplacesASavedOne() {
        let store = makeStore()
        store.save(bytes(60), for: "p1", pin: true)
        store.save(bytes(30), for: "p2", pin: true)

        XCTAssertEqual(store.save(bytes(20), for: "auto"), .notSaved(.noRoom))
        XCTAssertFalse(store.contains("auto"))
        XCTAssertTrue(store.contains("p1"))
        XCTAssertTrue(store.contains("p2"))
    }

    /// Saving on purpose may displace an older saved copy — but only once every automatic one is
    /// gone, and the outcome names it, so the screen can say space ran out.
    func testSavingOnPurposeDisplacesOlderSavedCopiesOnlyAfterAutomaticOnes() {
        let clock = TestClock()
        let store = makeStore(clock: clock)
        store.save(bytes(50), for: "old-pinned", pin: true)
        clock.advance()
        store.save(bytes(30), for: "automatic")
        clock.advance()

        let outcome = store.save(bytes(60), for: "new-pinned", pin: true)

        guard case .saved(let evicted) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(evicted.map(\.key), ["automatic", "old-pinned"], "automatic first")
        XCTAssertEqual(outcome.evictedPinned.map(\.key), ["old-pinned"])
        XCTAssertEqual(store.entries.map(\.key), ["new-pinned"])
    }

    /// Nothing is removed for a save that will not fit anyway.
    func testAnUnfittableSaveRemovesNothingElse() {
        let store = makeStore()
        store.save(bytes(50), for: "keep", pin: true)
        store.save(bytes(30), for: "also")

        XCTAssertEqual(store.save(bytes(101), for: "huge", pin: true), .notSaved(.tooLarge))
        XCTAssertEqual(Set(store.entries.map(\.key)), ["keep", "also"])
    }

    /// A fresh version that cannot be kept takes the older one with it — the device never offers
    /// a version older than one it has already shown as current.
    func testAFreshVersionThatCannotBeKeptRemovesTheOlderOne() {
        let store = makeStore()
        store.save(bytes(40), for: "grew")
        XCTAssertEqual(store.save(bytes(140), for: "grew"), .notSaved(.tooLarge))
        XCTAssertNil(store.open("grew"))
    }

    /// Opening a saved document refreshes its bytes; it must not quietly stop being saved.
    func testRefreshingACopyKeepsWhetherItWasSaved() {
        let store = makeStore()
        store.save(bytes(10), for: "doc", pin: true)
        store.save(bytes(12), for: "doc", pin: nil)

        XCTAssertTrue(store.isPinned("doc"))
        XCTAssertEqual(store.totalBytes, 12, "the old bytes are replaced, not added to")
    }

    func testPinningAnExistingCopyNeedsNoBytes() {
        let store = makeStore()
        XCTAssertFalse(store.pin("absent"))
        store.save(bytes(10), for: "doc")
        XCTAssertTrue(store.pin("doc"))
        XCTAssertTrue(store.isPinned("doc"))
    }

    func testRekeyingMovesTheCopyAndItsStanding() {
        let store = makeStore()
        store.save(bytes(10, 7), for: "file:A/Old.pdf", pin: true)

        store.rekey("file:A/Old.pdf", to: "file:B/Old.pdf")

        XCTAssertNil(store.entry(for: "file:A/Old.pdf"))
        XCTAssertEqual(store.open("file:B/Old.pdf")?.data, bytes(10, 7))
        XCTAssertTrue(store.isPinned("file:B/Old.pdf"))
    }

    func testRemovingByRule() {
        let store = makeStore()
        store.save(bytes(5), for: "keep")
        store.save(bytes(5), for: "drop-1")
        store.save(bytes(5), for: "drop-2")

        store.removeAll { $0.key.hasPrefix("drop") }

        XCTAssertEqual(store.entries.map(\.key), ["keep"])
        XCTAssertEqual(store.totalBytes, 5)
    }

    // MARK: - A locked phone, a full disk, a signed-out account

    /// Read while the phone is locked, the index exists but cannot be read. Taking that for an
    /// empty index would let the next save write over the real one and lose every copy.
    func testALockedIndexIsNotMistakenForAnEmptyOne() {
        let backing = LockableStore()
        makeStore(backing: backing).save(bytes(10), for: "kept")

        backing.isLocked = true
        let whileLocked = makeStore(backing: backing)
        XCTAssertNil(whileLocked.open("kept"))
        XCTAssertEqual(whileLocked.save(bytes(5), for: "new"), .notSaved(.unavailable))

        backing.isLocked = false
        XCTAssertEqual(makeStore(backing: backing).open("kept")?.data, bytes(10),
                       "the copy kept before the lock is still there afterwards")
    }

    /// A write that did not land must not cost the copies it was going to replace.
    func testAFailedWriteEvictsNothing() {
        let backing = LockableStore()
        let store = makeStore(budget: 50, backing: backing)
        store.save(bytes(40), for: "old")

        backing.refusesWrites = true
        XCTAssertEqual(store.save(bytes(40), for: "new"), .notSaved(.unavailable))

        backing.refusesWrites = false
        XCTAssertEqual(store.open("old")?.data, bytes(40))
    }

    /// A download that finishes after the person signed out must not put a document back.
    func testARevokedStoreNeitherReadsNorWrites() {
        let backing = InMemoryCacheStore()
        let store = makeStore(backing: backing)
        store.save(bytes(10), for: "before")

        store.revoke()

        XCTAssertNil(store.open("before"))
        XCTAssertEqual(store.save(bytes(10), for: "after"), .notSaved(.unavailable))
        XCTAssertNil(makeStore(backing: backing).entry(for: "after"))
    }

    // MARK: - Typed values

    func testTypedValuesRoundTrip() {
        let store = makeStore(budget: 10_000)
        store.save([ChatSummary(id: "c1", title: "Bakshi")], for: "list")
        XCTAssertEqual(store.value([ChatSummary].self, for: "list")?.value.first?.title, "Bakshi")
    }

    /// A copy written by an older build that this one cannot decode goes, rather than failing on
    /// every open.
    func testAnUndecodableValueIsRemoved() {
        let store = makeStore()
        store.save(Data("not json".utf8), for: "list")
        XCTAssertNil(store.value([ChatSummary].self, for: "list"))
        XCTAssertFalse(store.contains("list"))
    }

    // MARK: - On disk

    /// The file store is what ships. Its files are written, read back, found by `contains`, and
    /// removed with the directory.
    func testOnDiskWithTheOfflineProtectionClass() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmperorOfflineTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = FileCacheStore(directory: directory, protection: .whileUnlocked, fileExtension: "dat")
        let store = OfflineStore(namespace: "a1.documents", budget: 1_000, store: disk)

        store.save(Data("%PDF-1.7".utf8), for: "file:Matters/Order.pdf")

        XCTAssertEqual(store.open("file:Matters/Order.pdf")?.data, Data("%PDF-1.7".utf8))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 2, "one document and the index")
        XCTAssertTrue(files.allSatisfy { $0.hasSuffix(".dat") })
        XCTAssertFalse(files.contains { $0.contains("Order") },
                       "a document's name is never a file name on disk")

        disk.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFileStoreContainsWithoutReading() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmperorOfflineTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = FileCacheStore(directory: directory)
        XCTAssertFalse(disk.contains("x"))
        disk.write(Data("1".utf8), for: "x")
        XCTAssertTrue(disk.contains("x"))
    }
}

// MARK: - Accounts and sign-out

final class OfflineLibraryTests: XCTestCase {

    /// Keyed by account: one person's copies are never another's, whatever else happens.
    func testOneAccountNeverSeesAnothersCopies() {
        let library = OfflineLibrary(store: InMemoryCacheStore())
        library.copies(for: 1).conversations.save(Data("mine".utf8), for: "c1")

        XCTAssertNil(library.copies(for: 2).conversations.open("c1"))
        XCTAssertEqual(library.copies(for: 2).totalBytes, 0)
        XCTAssertNotNil(library.copies(for: 1).conversations.open("c1"))
    }

    /// Every screen is handed the same store for an account — two would each keep an index and
    /// write over the other's.
    func testTheSameStoreIsHandedToEveryScreen() {
        let library = OfflineLibrary(store: InMemoryCacheStore())
        library.copies(for: 1).documents.save(Data("a".utf8), for: "one")
        library.copies(for: 1).documents.save(Data("b".utf8), for: "two")

        XCTAssertTrue(library.copies(for: 1).documents === library.copies(for: 1).documents)
        XCTAssertEqual(library.copies(for: 1).documents.entries.count, 2)
    }

    func testRemovingEverythingWipesEveryAccountAndStopsOldHandles() {
        let backing = InMemoryCacheStore()
        let library = OfflineLibrary(store: backing)
        let held = library.copies(for: 1).documents
        held.save(Data("a".utf8), for: "one")
        library.copies(for: 2).matters.save(Data("b".utf8), for: "m")

        library.removeAll()

        XCTAssertEqual(library.copies(for: 1).totalBytes, 0)
        XCTAssertEqual(library.copies(for: 2).totalBytes, 0)
        XCTAssertEqual(held.save(Data("late".utf8), for: "late"), .notSaved(.unavailable),
                       "a screen still holding the old store puts nothing back")
        XCTAssertNil(library.copies(for: 1).documents.open("late"))
    }

    /// Settings' "Clear offline copies": everything goes, and the account keeps saving.
    func testClearingKeepsTheAccountWorking() {
        let library = OfflineLibrary(store: InMemoryCacheStore())
        let documents = library.copies(for: 1).documents
        documents.save(Data("a".utf8), for: "one", pin: true)

        library.clear(keeping: 1)

        XCTAssertEqual(library.copies(for: 1).totalBytes, 0)
        XCTAssertTrue(documents.save(Data("b".utf8), for: "two").isSaved)
        XCTAssertEqual(library.copies(for: 1).documents.entries.map(\.key), ["two"])
    }

    /// The session's cache clear — what signing out calls — reaches the offline copies.
    func testTheResponseCacheClearReachesOfflineCopies() {
        let library = OfflineLibrary(store: InMemoryCacheStore())
        let cache = ResponseCache(store: InMemoryCacheStore(), offline: library)
        library.copies(for: 7).conversations.save(Data("transcript".utf8), for: "c1")

        cache.clear()

        XCTAssertEqual(library.copies(for: 7).totalBytes, 0)
    }
}

@MainActor
final class OfflineSessionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func signedInSession(_ library: OfflineLibrary) async -> Session {
        let user = User(id: 42, email: "adv@example.test", name: "R. Iyer")
        let encoded = String(decoding: try! JSONEncoder().encode(user), as: UTF8.self)
        let session = Session(
            store: InMemoryCredentialStore(["auth.token": "tok", "auth.user": encoded]),
            cache: ResponseCache(store: InMemoryCacheStore(), offline: library),
            urlSession: HTTPStub.session())
        await session.restore()
        return session
    }

    func testCopiesBelongToTheSignedInAccount() async {
        let library = OfflineLibrary(store: InMemoryCacheStore())
        let session = await signedInSession(library)

        XCTAssertEqual(session.offlineCopies?.account, 42)
        XCTAssertTrue(session.offlineCopies?.documents === library.copies(for: 42).documents)
    }

    /// Signing out is the only protection the next person to hold the phone gets: every offline
    /// conversation and document goes with the token.
    func testSigningOutWipesEveryOfflineCopy() async {
        HTTPStub.always(.json(#"{"success":true}"#))
        let backing = InMemoryCacheStore()
        let library = OfflineLibrary(store: backing)
        let session = await signedInSession(library)
        let copies = try! XCTUnwrap(session.offlineCopies)
        copies.conversations.save(Data("privileged".utf8), for: "c1")
        copies.documents.save(Data("%PDF".utf8), for: "file:Plaint.pdf", pin: true)

        await session.signOut()

        XCTAssertNil(session.offlineCopies, "nothing is kept for nobody")
        XCTAssertEqual(library.copies(for: 42).totalBytes, 0)
        XCTAssertNil(copies.conversations.open("c1"))
        XCTAssertEqual(
            copies.documents.save(Data("late".utf8), for: "file:Late.pdf"), .notSaved(.unavailable))
    }
}

// MARK: - The rule, and its words

final class OfflineReadingTests: XCTestCase {

    private struct Connectivity: ConnectivityReporting { let isOffline: Bool }

    /// The network first: a saved copy opens before asking only when the system says there is no
    /// connection — never when it simply has not said.
    func testTheSavedCopyOpensFirstOnlyWhenKnownOffline() {
        XCTAssertFalse(OfflineReading.opensSavedCopyFirst(nil))
        XCTAssertFalse(OfflineReading.opensSavedCopyFirst(Connectivity(isOffline: false)))
        XCTAssertTrue(OfflineReading.opensSavedCopyFirst(Connectivity(isOffline: true)))
    }

    /// Only a network that could not be reached lets the copy stand in. A server that answered
    /// has said something, and a copy would contradict it.
    func testOnlyANetworkFailureLetsTheCopyStandIn() {
        XCTAssertTrue(OfflineReading.mayStandIn(after: URLError(.notConnectedToInternet)))
        XCTAssertTrue(OfflineReading.mayStandIn(after: URLError(.timedOut)))
        XCTAssertTrue(OfflineReading.mayStandIn(
            after: APIError.transport("The Internet connection appears to be offline.")))
        XCTAssertTrue(OfflineReading.mayStandIn(after: APIError.transport("The network connection was lost.")))

        XCTAssertFalse(OfflineReading.mayStandIn(after: APIError.server(status: 500, message: "boom")))
        XCTAssertFalse(OfflineReading.mayStandIn(
            after: APIError.server(status: 404, message: "That document is no longer in your library.")))
        XCTAssertFalse(OfflineReading.mayStandIn(after: APIError.invalidCredentials))
        XCTAssertFalse(OfflineReading.mayStandIn(after: APIError.maintenance(message: "Back soon.")))
        XCTAssertFalse(OfflineReading.mayStandIn(after: APIError.decoding("bad")))
        XCTAssertFalse(OfflineReading.mayStandIn(after: APIError.refused(
            Refusal(code: .accountSuspended, status: 403, serverMessage: "Paused"))))
        XCTAssertFalse(OfflineReading.mayStandIn(after: DocumentNotViewable(message: "No preview")))
    }

    func testTheNoticeSaysOfflineAndHowOldTheCopyIs() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(
            OfflineReading.notice(savedAt: now.addingTimeInterval(-2 * 3_600), now: now),
            "Offline — showing the copy saved 2 hours ago.")
        XCTAssertEqual(
            OfflineReading.notice(savedAt: now.addingTimeInterval(-20), now: now),
            "Offline — showing the copy saved just now.")
        XCTAssertEqual(
            OfflineReading.notice(savedAt: now.addingTimeInterval(-60), now: now),
            "Offline — showing the copy saved 1 minute ago.")
    }

    /// Calm: it says what will make asking possible again, and nothing about failure.
    func testTheReasonAskingIsPausedNamesWhatBringsItBack() {
        XCTAssertTrue(OfflineReading.askingPaused.contains("once the conversation reloads"))
        XCTAssertFalse(OfflineReading.askingPaused.lowercased().contains("error"))
        XCTAssertFalse(OfflineReading.askingPaused.lowercased().contains("fail"))
    }

    // MARK: - Document keys

    /// `{folder, name}` is a document's identity, every spelling of the root is the root, and the
    /// rendering is part of the key.
    func testDocumentKeys() {
        XCTAssertEqual(OfflineDocuments.path(name: "A.pdf", folderName: nil), "A.pdf")
        XCTAssertEqual(OfflineDocuments.path(name: "A.pdf", folderName: ""), "A.pdf")
        XCTAssertEqual(OfflineDocuments.path(name: "A.pdf", folderName: "."), "A.pdf")
        XCTAssertEqual(OfflineDocuments.path(name: "A.pdf", folderName: "Bakshi/Orders/"), "Bakshi/Orders/A.pdf")
        let attachment = ChatAttachment(name: "Brief.docx", folderName: "Bakshi")
        XCTAssertEqual(OfflineDocuments.key(for: attachment, converted: true), "preview:Bakshi/Brief.docx")
        XCTAssertEqual(OfflineDocuments.key(for: attachment, converted: false), "file:Bakshi/Brief.docx")
        XCTAssertEqual(OfflineDocuments.path(fromKey: "preview:Bakshi/Brief.docx"), "Bakshi/Brief.docx")
        XCTAssertEqual(OfflineDocuments.fileName(fromKey: "file:Root.pdf"), "Root.pdf")
    }

    /// Two matters may each hold an `Order.pdf`; their copies are two documents.
    func testSameNamedDocumentsInTwoFoldersAreKeptApart() {
        let documents = OfflineDocuments(store: OfflineStore(
            namespace: "a1.documents", budget: 1_000, store: InMemoryCacheStore()))
        let first = ChatAttachment(name: "Order.pdf", folderName: "Bakshi")
        let second = ChatAttachment(name: "Order.pdf", folderName: "Arora")
        documents.keep(ViewableDocument(data: Data("one".utf8), isConvertedPreview: false), of: first, pin: nil)
        documents.keep(ViewableDocument(data: Data("two".utf8), isConvertedPreview: false), of: second, pin: nil)

        XCTAssertEqual(documents.copy(of: first, converted: false)?.data, Data("one".utf8))
        XCTAssertEqual(documents.copy(of: second, converted: false)?.data, Data("two".utf8))
    }

    /// Pruning keeps the documents still in the library and lets go of the automatic copies of
    /// the rest. A document saved on purpose stays: the server moves documents between folders
    /// of its own accord, and a moved path is not a deleted document.
    func testPruningLetsGoOfAutomaticCopiesNoLongerInTheLibrary() {
        let documents = OfflineDocuments(store: OfflineStore(
            namespace: "a1.documents", budget: 1_000, store: InMemoryCacheStore()))
        let kept = ChatAttachment(name: "Plaint.pdf", folderName: "Bakshi")
        let gone = ChatAttachment(name: "Old.pdf", folderName: "Bakshi")
        let savedButMoved = ChatAttachment(name: "Paperbook.pdf", folderName: "Bakshi")
        let word = ChatAttachment(name: "Brief.docx", folderName: nil)
        documents.keep(ViewableDocument(data: Data("x".utf8), isConvertedPreview: false), of: kept, pin: true)
        documents.keep(ViewableDocument(data: Data("x".utf8), isConvertedPreview: false), of: gone, pin: nil)
        documents.keep(ViewableDocument(data: Data("x".utf8), isConvertedPreview: false), of: savedButMoved, pin: true)
        documents.keep(ViewableDocument(data: Data("x".utf8), isConvertedPreview: true), of: word, pin: nil)

        documents.prune(keepingPaths: ["Bakshi/Plaint.pdf", "Brief.docx"])

        XCTAssertTrue(documents.isAvailable(kept))
        XCTAssertTrue(documents.isAvailable(word))
        XCTAssertFalse(documents.isAvailable(gone))
        XCTAssertTrue(documents.isSaved(savedButMoved))
    }

    /// Every document gone at once is likelier a bad reading than an emptied library.
    func testAnEmptyLibraryPrunesNothing() {
        let documents = OfflineDocuments(store: OfflineStore(
            namespace: "a1.documents", budget: 1_000, store: InMemoryCacheStore()))
        let plaint = ChatAttachment(name: "Plaint.pdf", folderName: "Bakshi")
        documents.keep(ViewableDocument(data: Data("x".utf8), isConvertedPreview: false), of: plaint, pin: nil)

        documents.prune(keepingPaths: [])

        XCTAssertTrue(documents.isAvailable(plaint))
    }

    // MARK: - Settings

    func testStorageSizesReadAsIOSWritesThem() {
        XCTAssertEqual(OfflineStorageSummary.size(0), "1 KB")
        XCTAssertEqual(OfflineStorageSummary.size(1_499), "1 KB")
        XCTAssertEqual(OfflineStorageSummary.size(512_000), "512 KB")
        XCTAssertEqual(OfflineStorageSummary.size(12_400_000), "12.4 MB")
        XCTAssertEqual(OfflineStorageSummary.size(300_000_000), "300 MB")
        XCTAssertEqual(OfflineStorageSummary.size(1_250_000_000), "1.3 GB")
    }

    func testTheSummarySaysWhatIsKept() {
        XCTAssertEqual(OfflineStorageSummary().sizeText, "None")
        XCTAssertEqual(OfflineStorageSummary().contentsText, "Nothing is kept for offline reading yet.")
        let summary = OfflineStorageSummary(bytes: 2_500_000, conversations: 2, documents: 1, matters: 0)
        XCTAssertEqual(summary.sizeText, "2.5 MB")
        XCTAssertEqual(summary.contentsText, "2 conversations and 1 document")
        XCTAssertTrue(OfflineStorageSummary.explanation.contains("300 MB"))
    }
}
