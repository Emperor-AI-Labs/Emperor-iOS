import Foundation

/// Byte storage for cached responses.
///
/// A protocol so the cache can be exercised without touching a filesystem, and so the app can
/// swap in a container-relative directory without the cache logic knowing.
protocol CacheStore: Sendable {
    func read(_ key: String) -> Data?
    func write(_ data: Data, for key: String)
    func remove(_ key: String)
    func removeAll()
    /// Whether anything is stored under `key`, readable or not.
    ///
    /// Not the same question as `read(key) != nil`. A file protected until the phone is unlocked
    /// exists while it is locked and cannot be read; an offline index read at that moment must be
    /// told "not now", or it would take itself for empty and write over the real one.
    func contains(_ key: String) -> Bool
}

extension CacheStore {
    /// For a store whose every entry is always readable — memory, or a test.
    func contains(_ key: String) -> Bool { read(key) != nil }
}

/// A cache on disk, one file per key.
///
/// A file cache rather than SwiftData, deliberately: this product is read-mostly and the server
/// is authoritative, so what is wanted is a snapshot to show while the network answers — not a
/// second source of truth to reconcile. Nothing here is ever written back.
struct FileCacheStore: CacheStore {
    let directory: URL
    /// How the files are protected while the phone is locked.
    let protection: Protection
    /// The extension each file is written with. Cosmetic: nothing reads it back.
    let fileExtension: String

    /// The iOS data-protection class a file is written with.
    ///
    /// Chosen per store, because the two stores are read at different times. The response cache
    /// is read by background refresh, which plans hearing reminders from the cause list with the
    /// phone in a pocket — so it must stay readable once the phone has been unlocked since it
    /// started. The offline copies (conversations, documents, matters) are only ever read with
    /// the screen in front of the person, so they are sealed whenever the phone is locked: a
    /// privileged conversation or a client's pleading is the last thing that should be readable
    /// off a locked phone.
    enum Protection: Sendable {
        /// Readable from the first unlock after a restart until the phone is turned off.
        case untilFirstUnlock
        /// Readable only while the phone is unlocked. Writing one while locked fails, which the
        /// offline store treats as "not kept" rather than as an error.
        case whileUnlocked

        var writingOption: Data.WritingOptions {
            switch self {
            case .untilFirstUnlock: return .completeFileProtectionUntilFirstUserAuthentication
            case .whileUnlocked: return .completeFileProtection
            }
        }
    }

    /// - Parameter directory: created on first write if absent.
    init(
        directory: URL,
        protection: Protection = .untilFirstUnlock,
        fileExtension: String = "json"
    ) {
        self.directory = directory
        self.protection = protection
        self.fileExtension = fileExtension
    }

    /// The app's caches directory. Excluded from backup by the system, which is correct —
    /// every byte here is re-fetchable and some of it is client-confidential.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("EmperorResponseCache", isDirectory: true)
    }

    /// Where offline copies live: Application Support, not Caches.
    ///
    /// iOS empties Caches when the phone runs short of space, without asking. That is fine for a
    /// snapshot of a list, and wrong for a document someone saved for offline the night before a
    /// hearing — it would be gone when they reached the courtroom with no signal. The directory
    /// is excluded from backup on creation, as Caches is by the system: every byte is
    /// re-fetchable, and much of it is client-confidential.
    static func offlineDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("EmperorOffline", isDirectory: true)
    }

    private func url(for key: String) -> URL {
        // Keys are internal constants, but sanitise anyway so a key can never escape the
        // directory or collide via a path separator.
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return directory.appendingPathComponent(String(safe) + "." + fileExtension)
    }

    func read(_ key: String) -> Data? {
        try? Data(contentsOf: url(for: key))
    }

    func contains(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: key).path)
    }

    func write(_ data: Data, for key: String) {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            // Caches is excluded from backup by the system; Application Support is not, so the
            // offline directory says so itself. Harmless where it already is.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = directory
            try? excluded.setResourceValues(values)
        }
        try? data.write(to: url(for: key), options: [.atomic, protection.writingOption])
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A `CacheStore` that keeps everything in memory. Tests, and any platform without a caches
/// directory worth writing to.
final class InMemoryCacheStore: CacheStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    init() {}

    func read(_ key: String) -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, for key: String) { lock.withLock { values[key] = data } }
    func remove(_ key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
    func removeAll() { lock.withLock { values.removeAll() } }
}

/// A cached payload and the moment it was fetched.
///
/// The timestamp is not optional and is never inferred. Showing cached data without saying how
/// old it is invites a practitioner to act on a list that predates the hearing they are walking
/// into — so every surface that renders this must render `storedAt` alongside it.
struct CachedValue<Value: Codable & Sendable>: Codable, Sendable {
    var value: Value
    var storedAt: Date
}

/// Typed access to the response cache.
struct ResponseCache: Sendable {
    /// The things worth surviving a cold launch: what the user opens the app to check.
    enum Key: String, CaseIterable, Sendable {
        case chatList = "chat-list"
        case caseList = "case-list"
        case causeList = "cause-list"
        case notifications = "notifications"
        case calendarEvents = "calendar-events"
        /// The statutory calendar. The same for every account, but cached with the rest so it
        /// goes on sign-out like everything else here — it also carries what the team marked
        /// done.
        case complianceCalendar = "compliance-calendar"
        /// The document library, so My Files can be browsed — and its offline documents reached
        /// — without a connection.
        case fileTree = "file-tree"
    }

    let store: any CacheStore
    /// Injected so a test can assert the stamp rather than race the clock.
    let now: @Sendable () -> Date
    /// Conversations, documents and matters kept for reading without a connection, by account.
    ///
    /// Owned here so that `clear()` — which is what signing out calls — reaches it. A second
    /// store that the sign-out path had to remember separately is a store that one day it would
    /// not.
    let offline: OfflineLibrary

    /// - Parameter offline: defaults to memory, so a cache built for a test keeps nothing on
    ///   disk. The app passes one backed by `FileCacheStore.offlineDirectory()`.
    init(
        store: any CacheStore,
        now: @escaping @Sendable () -> Date = { Date() },
        offline: OfflineLibrary = OfflineLibrary(store: InMemoryCacheStore()),
        onClear: (@Sendable () -> Void)? = nil
    ) {
        self.store = store
        self.now = now
        self.offline = offline
        self.onClear = onClear
    }

    func load<Value: Codable & Sendable>(
        _ type: Value.Type, for key: Key
    ) -> CachedValue<Value>? {
        guard let data = store.read(key.rawValue) else { return nil }
        // A decode failure means a payload written by an older build. Drop it rather than
        // carrying a broken entry forward — it will be replaced by the next successful load.
        guard let decoded = try? Self.decoder.decode(CachedValue<Value>.self, from: data) else {
            store.remove(key.rawValue)
            return nil
        }
        return decoded
    }

    func save<Value: Codable & Sendable>(_ value: Value, for key: Key) {
        let boxed = CachedValue(value: value, storedAt: now())
        guard let data = try? Self.encoder.encode(boxed) else { return }
        store.write(data, for: key.rawValue)
    }

    /// Called on sign-out. Cached matters must not outlive the session that fetched them — and
    /// nor must an offline conversation or document, of any account.
    ///
    /// `onClear` lets the app layer wipe things the core cannot reach — the temporary directory
    /// share sheets write PDFs into, for instance. Signing out is purely local, so what the
    /// device forgets is the *only* protection the next person to hold the phone gets.
    func clear() {
        store.removeAll()
        offline.removeAll()
        onClear?()
    }

    /// Extra teardown run alongside `clear()`.
    var onClear: (@Sendable () -> Void)?

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
