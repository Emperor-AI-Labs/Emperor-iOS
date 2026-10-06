import Foundation
#if canImport(Darwin)
import Observation
#endif

// MARK: - What goes into the index

/// The two kinds of thing the device's search can find, each in a domain of its own so one kind
/// can be replaced without touching the other.
enum SpotlightDomain: String, CaseIterable, Sendable {
    case cases = "com.emperorailabs.emperor.cases"
    case documents = "com.emperorailabs.emperor.documents"
}

/// One searchable item, as the device's search will show it.
///
/// Plain values, so the mapping from a docket or a library to the index can be tested without
/// the framework that holds the index; `CoreSpotlightIndex` turns these into searchable items.
struct SpotlightEntry: Equatable, Sendable {
    /// Unique across the app, and parsed back into a destination when the result is tapped —
    /// see `SpotlightCatalogue.target(forIdentifier:)`.
    let identifier: String
    let domain: SpotlightDomain
    let title: String
    /// The line under the title.
    let detail: String
    /// Words the search also matches that are not in the title or the detail.
    let keywords: [String]
    /// A document's extension, so the result can be drawn as that kind of file. `nil` for a case.
    let fileExtension: String?
}

/// Where a tapped result leads.
enum SpotlightTarget: Equatable, Sendable {
    case caseDetail(id: String)
    /// A document, by its path in the library — `Bakshi/Orders/Interim_Order.pdf`.
    case document(path: String)
}

/// The mapping between the person's matters and documents and the device's search.
///
/// ## What is indexed, and why it is this much
///
/// A case is found by what a practitioner would type into the search on the Home Screen: the
/// matter's name, the parties, the court, the reference ("W.P.(C) 10421/2024"), the CNR or the
/// diary number. Its next hearing is the line under it, because "when is Kapoor next listed" is
/// the question the search is most often asked. A document is found by its name and the folder
/// — usually the matter — it is filed under.
///
/// Nothing else: no notes, no orders' text, no document contents. Those are what the app is for,
/// and the index is a way into the app, not a copy of it. The index is also on the device only,
/// is emptied on sign-out, and is never written while the setting is off (`SpotlightCoordinator`).
enum SpotlightCatalogue {

    static let casePrefix = "case:"
    static let documentPrefix = "document:"

    // MARK: Cases

    static func entries(for cases: [LegalCase]) -> [SpotlightEntry] {
        var seen = Set<String>()
        return cases.compactMap { legalCase in
            let id = legalCase.id.trimmingCharacters(in: .whitespacesAndNewlines)
            // An id is what a tap opens; without one, or twice over, it cannot be indexed.
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return entry(for: legalCase, id: id)
        }
    }

    static func entry(for legalCase: LegalCase, id: String) -> SpotlightEntry {
        let title = legalCase.displayTitle
        let reference = clean(legalCase.caseReference)
        let court = clean(legalCase.courtName)

        var detail = [reference, court].compactMap { $0 }
        if let day = legalCase.nextHearingDate {
            detail.append("Next hearing \(FileBrowser.shortDate(day))")
        }

        var keywords: [String] = []
        func add(_ word: String?) {
            guard let word = clean(word), word != title, !keywords.contains(word) else { return }
            keywords.append(word)
        }
        for party in partyNames(legalCase.parties) { add(party) }
        add(court)
        add(reference)
        add(legalCase.cnr)
        add(legalCase.diaryNumber)
        add(legalCase.caseType)
        add(legalCase.judge)

        return SpotlightEntry(
            identifier: casePrefix + id,
            domain: .cases,
            title: title,
            detail: detail.joined(separator: " · "),
            keywords: keywords,
            fileExtension: nil)
    }

    /// The parties as names, from a field that arrives in three shapes (`LegalCase.parties`):
    /// prose ("Kapoor vs. Union of India"), a JSON array in a string, or the `"[]"` sentinel for
    /// none. Prose is kept whole — splitting "A vs. B" is the web's job on a case page, and the
    /// search matches inside it either way.
    static func partyNames(_ raw: String?) -> [String] {
        guard let text = clean(raw), text != "[]" else { return [] }
        guard text.hasPrefix("[") else { return [text] }
        guard let parsed = JSONValue.decode(from: text), case .array(let items) = parsed else {
            return []
        }
        return items.compactMap { item in
            switch item {
            case .string(let name): return clean(name)
            case .object(let object):
                return clean(object["name"]?.stringValue ?? object["party"]?.stringValue)
            default: return nil
            }
        }
    }

    // MARK: Documents

    /// Every document in the library, folders walked all the way down.
    static func entries(for tree: [FileNode]) -> [SpotlightEntry] {
        var seen = Set<String>()
        return FileService.allFiles(in: tree).compactMap { file in
            guard !file.path.isEmpty, seen.insert(file.path).inserted else { return nil }
            return entry(for: file)
        }
    }

    static func entry(for file: FileNode.StoredFile) -> SpotlightEntry {
        let name = DisplayText.fileName(file.name)
        let location = FileBrowser.location(of: file)
        var keywords: [String] = []
        // The folders by name, one by one, so a search for the matter finds its papers even
        // though the line under the title shows the whole path.
        for folder in file.folderPath.split(separator: "/") {
            let display = DisplayText.fileName(String(folder))
            if !keywords.contains(display) { keywords.append(display) }
        }
        if file.name != name { keywords.append(file.name) }
        let ext = IncomingDocumentName.split(file.name).ext.lowercased()
        return SpotlightEntry(
            identifier: documentPrefix + file.path,
            domain: .documents,
            title: name,
            detail: location,
            keywords: keywords,
            fileExtension: ext.isEmpty ? nil : ext)
    }

    // MARK: Tapped results

    /// Where an identifier leads, or `nil` for one this build did not write.
    static func target(forIdentifier identifier: String) -> SpotlightTarget? {
        if identifier.hasPrefix(casePrefix) {
            let id = String(identifier.dropFirst(casePrefix.count))
            return id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : .caseDetail(id: id)
        }
        if identifier.hasPrefix(documentPrefix) {
            let path = FileBrowser.normalized(String(identifier.dropFirst(documentPrefix.count)))
            return path.isEmpty ? nil : .document(path: path)
        }
        return nil
    }

    private static func clean(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - The setting

/// "Show in Spotlight search", in Settings. On unless turned off.
///
/// Stored as the *off* switch so that a fresh install — which has stored nothing — reads as on.
enum SpotlightPreference {
    static let disabledKey = "spotlight.disabled.v1"

    static func isEnabled(in store: any PreferenceStore) -> Bool {
        !store.bool(for: disabledKey)
    }

    static func setEnabled(_ enabled: Bool, in store: any PreferenceStore) {
        store.setBool(!enabled, for: disabledKey)
    }
}

// MARK: - Keeping the index

/// The device's search index, as far as this app uses it.
@MainActor
protocol SpotlightIndexing: AnyObject {
    /// Replaces everything in `domain` with `entries`.
    func replace(_ domain: SpotlightDomain, with entries: [SpotlightEntry]) async
    /// Removes everything this app has indexed.
    func removeAll() async
}

/// When the device's search index is written, and when it is emptied.
///
/// The rules, all of them about not leaving a client's name where it should not be:
///
/// - **Written only while the setting is on and someone is signed in.** A docket loaded a moment
///   after signing out — a request that was already on its way — is not indexed.
/// - **Emptied the moment the setting is turned off, and on sign-out.** Not hidden: removed.
/// - **Emptied at launch** when the setting is off or nobody is signed in, in case an earlier
///   removal never ran — the app closed mid-way, or the session ended where nothing saw it.
/// - **Each kind replaced whole.** A matter taken off the docket, or a document deleted, goes
///   from the search with the next load rather than lingering until it is tapped and missing.
///
/// Work runs one piece at a time, in the order asked, so a removal for sign-out can never be
/// overtaken by an index write that started before it.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class SpotlightCoordinator {

    enum Copy {
        static let toggle = "Show in Spotlight search"
        static let footer =
            "Names and details of your cases and documents then appear in this device's search."
    }

    private(set) var isEnabled: Bool

    private let index: any SpotlightIndexing
    private let store: any PreferenceStore
    /// The latest of each, kept in memory so turning the setting back on can index straight
    /// away. Forgotten on sign-out.
    private var cases: [LegalCase]?
    private var tree: [FileNode]?
    private var lastWork: Task<Void, Never>?

    init(index: any SpotlightIndexing, store: any PreferenceStore) {
        self.index = index
        self.store = store
        self.isEnabled = SpotlightPreference.isEnabled(in: store)
    }

    /// At launch: empty the index if it should be empty.
    @discardableResult
    func launched(isSignedIn: Bool) -> Task<Void, Never>? {
        guard !isEnabled || !isSignedIn else { return nil }
        return enqueue { index in await index.removeAll() }
    }

    /// The setting changed. Off removes everything; on indexes whatever is already known.
    @discardableResult
    func setEnabled(_ enabled: Bool, isSignedIn: Bool) -> Task<Void, Never>? {
        guard enabled != isEnabled else { return nil }
        isEnabled = enabled
        SpotlightPreference.setEnabled(enabled, in: store)
        guard enabled else {
            return enqueue { index in await index.removeAll() }
        }
        guard isSignedIn else { return nil }
        let cases = self.cases.map(SpotlightCatalogue.entries(for:))
        let documents = self.tree.map(SpotlightCatalogue.entries(for:))
        guard cases != nil || documents != nil else { return nil }
        return enqueue { index in
            if let cases { await index.replace(.cases, with: cases) }
            if let documents { await index.replace(.documents, with: documents) }
        }
    }

    /// The docket was loaded.
    @discardableResult
    func casesLoaded(_ cases: [LegalCase], isSignedIn: Bool) -> Task<Void, Never>? {
        guard isSignedIn else { return nil }
        self.cases = cases
        guard isEnabled else { return nil }
        let entries = SpotlightCatalogue.entries(for: cases)
        return enqueue { index in await index.replace(.cases, with: entries) }
    }

    /// The library was loaded.
    @discardableResult
    func documentsLoaded(_ tree: [FileNode], isSignedIn: Bool) -> Task<Void, Never>? {
        guard isSignedIn else { return nil }
        self.tree = tree
        guard isEnabled else { return nil }
        let entries = SpotlightCatalogue.entries(for: tree)
        return enqueue { index in await index.replace(.documents, with: entries) }
    }

    /// The session ended: forget what was loaded, and empty the index.
    @discardableResult
    func signedOut() -> Task<Void, Never>? {
        cases = nil
        tree = nil
        return enqueue { index in await index.removeAll() }
    }

    private func enqueue(
        _ work: @escaping @MainActor (any SpotlightIndexing) async -> Void
    ) -> Task<Void, Never> {
        let previous = lastWork
        let index = self.index
        let task = Task { @MainActor in
            await previous?.value
            await work(index)
        }
        lastWork = task
        return task
    }
}

/// A tapped search result, waiting for the tab view to open it (`SpotlightRouting`).
///
/// The same shape as `NotificationInbox`: a result tapped while the app was closed arrives before
/// any screen exists, and one tapped while signed out waits for the next sign-in's tab view —
/// unless the session ends first, which clears it.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class SpotlightInbox {
    private(set) var pending: SpotlightTarget?
    /// Counts taps, so the same result tapped twice is still a change to observe.
    private(set) var tapCount = 0

    init() {}

    /// Takes a tapped result's identifier. One this build did not write is ignored.
    func open(identifier: String) {
        guard let target = SpotlightCatalogue.target(forIdentifier: identifier) else { return }
        pending = target
        tapCount += 1
    }

    func take() -> SpotlightTarget? {
        defer { pending = nil }
        return pending
    }

    func clear() { pending = nil }
}
