import Foundation

/// One kind of offline copy for one account — its conversations, its documents or its matters —
/// held to a size budget.
///
/// ## What it is for
///
/// Court buildings often have no signal. A practitioner who opened a conversation, a pleading or
/// a matter in chambers should be able to open it again in the corridor outside the courtroom.
/// So whatever the screens fetched successfully is kept here, and read back **only** when the
/// network cannot be reached (`OfflineReading`). The server stays the source of truth: nothing in
/// this store is ever sent back to it.
///
/// ## Eviction
///
/// When a new copy would take the store over budget, room is made by removing the copies opened
/// least recently. A copy the person saved on purpose ("Save for offline" — `isPinned`) is
/// removed only after every automatic copy has gone, and only to make room for another saved
/// one: an automatic copy never pushes out a deliberate one. When even that cannot make room,
/// nothing is removed and the save reports why, so the screen can say space ran out.
///
/// ## Storage
///
/// Bytes are written under a random name and found through an index, rather than under a name
/// derived from the key. Keys are document paths and chat ids — a long Devanagari filename
/// escaped into a file name would pass the file system's length limit, and any shortening of it
/// risks two documents sharing one file, which would show one client's pleading in place of
/// another's.
///
/// Thread-safe: the screens call it from the main actor, and signing out may reach it from
/// anywhere.
final class OfflineStore: @unchecked Sendable {

    /// One kept copy.
    struct Entry: Codable, Equatable, Sendable {
        /// What the screen asked for it by: a chat id, a document's identity, a matter id.
        var key: String
        /// Where its bytes are in the backing store.
        var blob: String
        var bytes: Int
        /// When it was fetched. Shown beside it, always: a saved copy read without knowing its age
        /// invites someone to act on a version that has since changed.
        var savedAt: Date
        /// When it was last saved or opened — what eviction orders by.
        var lastOpened: Date
        /// Saved on purpose, so evicted last.
        var isPinned: Bool
    }

    enum SaveOutcome: Equatable, Sendable {
        /// Kept. `evicted` lists what was removed to make room for it, oldest first.
        case saved(evicted: [Entry])
        case notSaved(NotSaved)

        var isSaved: Bool {
            if case .saved = self { return true }
            return false
        }

        /// Copies saved on purpose that went to make room. Worth saying out loud: the person chose
        /// to keep them.
        var evictedPinned: [Entry] {
            if case .saved(let evicted) = self { return evicted.filter(\.isPinned) }
            return []
        }
    }

    enum NotSaved: Equatable, Sendable {
        /// Nothing to keep. An empty body is "unknown" on this API, never a document.
        case empty
        /// Larger than the whole budget.
        case tooLarge
        /// Only copies this one may not displace are left — documents saved on purpose, when
        /// this is an automatic copy.
        case noRoom
        /// Signed out since this store was handed over, or the phone is locked, or the write
        /// itself failed (a full disk).
        case unavailable
    }

    /// The most this store keeps, in bytes.
    let budget: Int

    private let namespace: String
    private let store: any CacheStore
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// `nil` until read. Read lazily, so a store that is never opened costs no disk access.
    private var index: [String: Entry]?
    /// Set on sign-out. A screen still holding this store — a download finishing after the person
    /// signed out — must not put anything back.
    private var isRevoked = false

    /// - Parameters:
    ///   - namespace: keeps two stores sharing one backing store apart — the account and the
    ///     kind, as `OfflineLibrary` composes it.
    ///   - now: injected so tests can order openings without racing the clock.
    init(
        namespace: String,
        budget: Int,
        store: any CacheStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.namespace = namespace
        self.budget = budget
        self.store = store
        self.now = now
    }

    // MARK: - Reading

    /// The kept bytes and when they were fetched. Counts as opening the copy, so it is kept
    /// longer than one nobody has looked at.
    func open(_ key: String) -> (data: Data, savedAt: Date)? {
        lock.withLock {
            guard var entries = loadedIndex(), var entry = entries[key] else { return nil }
            guard let data = store.read(blobKey(entry.blob)) else {
                // Gone from the disk — keep the index honest. Present but unreadable is the phone
                // being locked, and the copy is still there for later.
                if !store.contains(blobKey(entry.blob)) {
                    entries[key] = nil
                    persist(entries)
                }
                return nil
            }
            entry.lastOpened = now()
            entries[key] = entry
            persist(entries)
            return (data, entry.savedAt)
        }
    }

    /// The record for a copy, without opening it.
    func entry(for key: String) -> Entry? {
        lock.withLock { loadedIndex()?[key] }
    }

    func contains(_ key: String) -> Bool { entry(for: key) != nil }

    func isPinned(_ key: String) -> Bool { entry(for: key)?.isPinned == true }

    /// Every copy, most recently opened first.
    var entries: [Entry] {
        lock.withLock {
            (loadedIndex() ?? [:]).values.sorted { Self.evictionOrder($1, $0) }
        }
    }

    var totalBytes: Int {
        lock.withLock { (loadedIndex() ?? [:]).values.reduce(0) { $0 + $1.bytes } }
    }

    // MARK: - Writing

    /// Keeps `data` as the copy for `key`, making room if it has to.
    ///
    /// - Parameter pin: `true` to save on purpose, `false` to keep as an automatic copy, `nil`
    ///   to leave the copy as it was. A document opened after being saved for offline must not
    ///   lose that just because opening it refreshed the bytes.
    ///
    /// A fresh version that cannot be kept also removes the older copy of the same thing, so the
    /// device never offers a version older than one it has already shown as current.
    @discardableResult
    func save(_ data: Data, for key: String, pin: Bool? = nil) -> SaveOutcome {
        guard !data.isEmpty else { return .notSaved(.empty) }
        return lock.withLock {
            guard var entries = loadedIndex() else { return .notSaved(.unavailable) }
            let existing = entries[key]
            let pinned = pin ?? existing?.isPinned ?? false
            let size = data.count

            func dropExisting() {
                guard let existing else { return }
                store.remove(blobKey(existing.blob))
                entries[key] = nil
                persist(entries)
            }

            guard size <= budget else {
                dropExisting()
                return .notSaved(.tooLarge)
            }

            // What may make room: every other copy of the same standing or lower, least recently
            // opened first — automatic copies before any saved one.
            var total = entries.values.reduce(0) { $0 + $1.bytes } - (existing?.bytes ?? 0)
            let candidates = entries.values
                .filter { $0.key != key && (pinned || !$0.isPinned) }
                .sorted(by: Self.evictionOrder)
            var evicted: [Entry] = []
            for candidate in candidates where total + size > budget {
                evicted.append(candidate)
                total -= candidate.bytes
            }
            guard total + size <= budget else {
                dropExisting()
                return .notSaved(.noRoom)
            }

            // The new bytes first, and confirmed, before anything is removed for them: a write
            // refused by a locked phone or a full disk must not cost the copies it was going to
            // replace.
            let blob = UUID().uuidString
            store.write(data, for: blobKey(blob))
            guard store.contains(blobKey(blob)) else { return .notSaved(.unavailable) }

            for gone in evicted {
                store.remove(blobKey(gone.blob))
                entries[gone.key] = nil
            }
            if let existing { store.remove(blobKey(existing.blob)) }
            let stamp = now()
            entries[key] = Entry(
                key: key, blob: blob, bytes: size, savedAt: stamp, lastOpened: stamp,
                isPinned: pinned)
            persist(entries)
            return .saved(evicted: evicted)
        }
    }

    /// Marks an existing copy as saved on purpose. Needs no download and no room: the bytes are
    /// already here. Returns whether there was a copy to mark.
    @discardableResult
    func pin(_ key: String) -> Bool {
        lock.withLock {
            guard var entries = loadedIndex(), var entry = entries[key] else { return false }
            entry.isPinned = true
            entries[key] = entry
            persist(entries)
            return true
        }
    }

    /// Files a copy under a new key — a document renamed or moved in this app keeps its copy, and
    /// whether it was saved on purpose.
    func rekey(_ old: String, to new: String) {
        guard old != new else { return }
        lock.withLock {
            guard var entries = loadedIndex(), var entry = entries[old] else { return }
            if let displaced = entries[new] { store.remove(blobKey(displaced.blob)) }
            entries[old] = nil
            entry.key = new
            entries[new] = entry
            persist(entries)
        }
    }

    func remove(_ key: String) {
        lock.withLock {
            guard var entries = loadedIndex(), let entry = entries[key] else { return }
            store.remove(blobKey(entry.blob))
            entries[key] = nil
            persist(entries)
        }
    }

    /// Removes every copy `shouldRemove` picks.
    func removeAll(where shouldRemove: (Entry) -> Bool) {
        lock.withLock {
            guard var entries = loadedIndex() else { return }
            let doomed = entries.values.filter(shouldRemove)
            guard !doomed.isEmpty else { return }
            for entry in doomed {
                store.remove(blobKey(entry.blob))
                entries[entry.key] = nil
            }
            persist(entries)
        }
    }

    // MARK: - Lifetime

    /// The backing store was wiped from outside — by `OfflineLibrary` — and this account carries
    /// on: start again from empty rather than from a remembered index of files that are gone.
    func forgetEverything() {
        lock.withLock { index = [:] }
    }

    /// Signed out. Nothing is read or written through this store again.
    func revoke() {
        lock.withLock {
            isRevoked = true
            index = [:]
        }
    }

    // MARK: - Internals

    /// Automatic copies before saved ones; within each, least recently opened first. The key
    /// breaks a tie, so the order is the same on every run.
    private static func evictionOrder(_ a: Entry, _ b: Entry) -> Bool {
        if a.isPinned != b.isPinned { return !a.isPinned }
        if a.lastOpened != b.lastOpened { return a.lastOpened < b.lastOpened }
        return a.key < b.key
    }

    private var indexKey: String { "\(namespace).index" }

    private func blobKey(_ blob: String) -> String { "\(namespace).\(blob)" }

    /// The index, or `nil` when it cannot be used right now. Call with the lock held.
    private func loadedIndex() -> [String: Entry]? {
        if isRevoked { return nil }
        if let index { return index }
        guard let data = store.read(indexKey) else {
            // Absent is empty. Present but unreadable is a locked phone: say "not now", and do
            // not adopt an empty index that the next save would write over the real one.
            if store.contains(indexKey) { return nil }
            index = [:]
            return [:]
        }
        // An index this build cannot read starts the store again. Its files stay until the next
        // full clear — sign-out or Settings — which removes the whole directory.
        let decoded = (try? Self.decoder.decode([String: Entry].self, from: data)) ?? [:]
        index = decoded
        return decoded
    }

    /// Call with the lock held.
    private func persist(_ entries: [String: Entry]) {
        index = entries
        guard let data = try? Self.encoder.encode(entries) else { return }
        store.write(data, for: indexKey)
    }

    // Default date coding — a `Double` — rather than ISO 8601, which would drop the fractions of
    // a second that order two copies opened in the same second.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}

// MARK: - Typed values

extension OfflineStore {
    /// A decoded copy and when it was fetched. A copy this build cannot decode — written by an
    /// older one — is removed, as `ResponseCache.load` does.
    func value<Value: Codable & Sendable>(
        _ type: Value.Type, for key: String
    ) -> CachedValue<Value>? {
        guard let copy = open(key) else { return nil }
        guard let value = try? JSONDecoder().decode(Value.self, from: copy.data) else {
            remove(key)
            return nil
        }
        return CachedValue(value: value, storedAt: copy.savedAt)
    }

    @discardableResult
    func save<Value: Codable & Sendable>(_ value: Value, for key: String) -> SaveOutcome {
        guard let data = try? JSONEncoder().encode(value) else { return .notSaved(.empty) }
        return save(data, for: key, pin: nil)
    }
}

// MARK: - Every account's copies

/// The offline copies on this device, kept apart by account.
///
/// Keyed by account so that one person's copies can never be shown to another — not even if a
/// sign-out wipe were somehow missed. And wiped whole on sign-out (`removeAll`, through
/// `ResponseCache.clear`), because signing out is the only protection the next person to hold the
/// phone gets.
final class OfflineLibrary: @unchecked Sendable {

    // Decimal megabytes, as iOS counts storage in its own Settings, so "300 MB" here is the
    // figure the person would see there.

    /// Documents: room for a matter's paperbook, and a cap on what a phone gives up for it.
    static let documentBudget = 300 * 1_000_000
    /// Conversations are text, but an answer carrying a drafted document runs to tens of
    /// kilobytes. This holds a few hundred.
    static let conversationBudget = 50 * 1_000_000
    /// Matters are small; this holds every one on any docket.
    static let matterBudget = 10 * 1_000_000

    private let store: any CacheStore
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// The stores handed out, so that every screen asking for an account's documents is given the
    /// same one — two would each keep an index and overwrite the other's.
    private var vended: [Int: OfflineCopies] = [:]

    init(store: any CacheStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// An account's copies.
    func copies(for account: Int) -> OfflineCopies {
        lock.withLock {
            if let existing = vended[account] { return existing }
            func make(_ kind: String, _ budget: Int) -> OfflineStore {
                OfflineStore(namespace: "a\(account).\(kind)", budget: budget, store: store, now: now)
            }
            let made = OfflineCopies(
                account: account,
                conversations: make("conversations", Self.conversationBudget),
                documents: make("documents", Self.documentBudget),
                matters: make("matters", Self.matterBudget))
            vended[account] = made
            return made
        }
    }

    /// Sign-out: every copy of every account, and every store already handed out stops working —
    /// a download finishing after this must not put a document back.
    func removeAll() {
        lock.withLock {
            for copies in vended.values {
                copies.all.forEach { $0.revoke() }
            }
            vended = [:]
            store.removeAll()
        }
    }

    /// "Clear offline copies": the same wipe, from the whole directory down — nothing a partly
    /// written save left behind survives it — but the signed-in account carries on, and keeps
    /// saving what it opens next.
    func clear(keeping account: Int) {
        lock.withLock {
            for (owner, copies) in vended where owner != account {
                copies.all.forEach { $0.revoke() }
            }
            let kept = vended[account]
            vended = kept.map { [account: $0] } ?? [:]
            store.removeAll()
            kept?.all.forEach { $0.forgetEverything() }
        }
    }
}

/// One account's offline copies.
struct OfflineCopies: Sendable {
    let account: Int
    let conversations: OfflineStore
    let documents: OfflineStore
    let matters: OfflineStore

    var all: [OfflineStore] { [conversations, documents, matters] }

    var totalBytes: Int { all.reduce(0) { $0 + $1.totalBytes } }
}

extension Session {
    /// The signed-in account's offline copies — `nil` when nobody is signed in, so nothing is
    /// kept for, or shown to, nobody.
    var offlineCopies: OfflineCopies? {
        currentUser.map { cache.offline.copies(for: $0.id) }
    }
}
