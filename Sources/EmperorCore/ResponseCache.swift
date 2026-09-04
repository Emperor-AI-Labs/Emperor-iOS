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
}

/// A cache on disk, one file per key.
///
/// A file cache rather than SwiftData, deliberately: this product is read-mostly and the server
/// is authoritative, so what is wanted is a snapshot to show while the network answers — not a
/// second source of truth to reconcile. Nothing here is ever written back.
struct FileCacheStore: CacheStore {
    let directory: URL

    /// - Parameter directory: created on first write if absent.
    init(directory: URL) {
        self.directory = directory
    }

    /// The app's caches directory. Excluded from backup by the system, which is correct —
    /// every byte here is re-fetchable and some of it is client-confidential.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("EmperorResponseCache", isDirectory: true)
    }

    private func url(for key: String) -> URL {
        // Keys are internal constants, but sanitise anyway so a key can never escape the
        // directory or collide via a path separator.
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    func read(_ key: String) -> Data? {
        try? Data(contentsOf: url(for: key))
    }

    func write(_ data: Data, for key: String) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: key), options: .atomic)
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
    }

    let store: any CacheStore
    /// Injected so a test can assert the stamp rather than race the clock.
    let now: @Sendable () -> Date

    init(
        store: any CacheStore,
        now: @escaping @Sendable () -> Date = { Date() },
        onClear: (@Sendable () -> Void)? = nil
    ) {
        self.store = store
        self.now = now
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

    /// Called on sign-out. Cached matters must not outlive the session that fetched them.
    ///
    /// `onClear` lets the app layer wipe things the core cannot reach — the temporary directory
    /// share sheets write PDFs into, for instance. Signing out is purely local, so what the
    /// device forgets is the *only* protection the next person to hold the phone gets.
    func clear() {
        store.removeAll()
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
