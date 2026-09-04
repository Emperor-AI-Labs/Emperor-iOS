import Foundation

/// Where the bearer token and the cached user row are kept between launches.
///
/// The one thing `Session` genuinely cannot do on Linux is talk to the Keychain, which is a
/// Security-framework API. Naming that dependency as a protocol is what lets the rest of the
/// session — restore, sign-in, error mapping, sign-out — live in the tested core instead of
/// in the app target where nothing can reach it.
///
/// Implementations must be safe to call from any isolation domain: `Session` is `@MainActor`,
/// but nothing here promises to stay there.
protocol CredentialStore: Sendable {
    func string(for key: String) -> String?
    func set(_ value: String, for key: String)
    func remove(_ key: String)
}

/// A `CredentialStore` that keeps everything in memory.
///
/// Used by the tests, and as the fallback on any platform without a Keychain. It deliberately
/// does **not** persist: a token that survives a process restart without being protected by
/// the Secure Enclave is exactly what the real store exists to avoid.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func string(for key: String) -> String? {
        lock.withLock { values[key] }
    }

    func set(_ value: String, for key: String) {
        lock.withLock { values[key] = value }
    }

    func remove(_ key: String) {
        lock.withLock { _ = values.removeValue(forKey: key) }
    }
}
