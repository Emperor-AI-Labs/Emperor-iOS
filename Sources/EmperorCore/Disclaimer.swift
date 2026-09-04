import Foundation

/// Small persistent flags that are not credentials and not cached responses.
///
/// Separate from `CredentialStore` (Keychain, secret) and `CacheStore` (disk, disposable,
/// wiped on sign-out) because this outlives a session: having read the disclaimer once should
/// not be forgotten because someone signed out.
protocol PreferenceStore: Sendable {
    func bool(for key: String) -> Bool
    func setBool(_ value: Bool, for key: String)
    func string(for key: String) -> String?
    func setString(_ value: String, for key: String)
}

final class InMemoryPreferenceStore: PreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [String: Bool]
    private var strings: [String: String] = [:]

    init(_ flags: [String: Bool] = [:]) { self.flags = flags }

    func bool(for key: String) -> Bool { lock.withLock { flags[key] ?? false } }
    func setBool(_ value: Bool, for key: String) { lock.withLock { flags[key] = value } }
    func string(for key: String) -> String? { lock.withLock { strings[key] } }
    func setString(_ value: String, for key: String) { lock.withLock { strings[key] = value } }
}

/// The legal-advice disclaimer.
///
/// Required for App Store review of a product in this category, but the substantive reason is
/// the product itself: it answers questions about live matters, in a jurisdiction, in a voice
/// that reads as advice. The model is also demonstrably capable of citing a page that does not
/// say what it claims — which is why every answer carries a source the reader can open.
///
/// The text is deliberately specific rather than a generic liability paragraph. A disclaimer a
/// practitioner skims and forgets protects nobody.
enum Disclaimer {
    static let key = "disclaimer.acknowledged.v1"

    static let title = "Before you rely on this"

    static let body = """
        Emperor is a research and drafting assistant. It is not a lawyer, and what it produces \
        is not legal advice.

        Everything it writes must be checked before you rely on it, file it, or send it to a \
        client. It can misread a document, miss a provision, or state something confidently \
        that is wrong. Where an answer cites a page, open the page.

        You remain responsible for the advice you give and the documents you file.
        """

    /// Shown under the body on first run, where the action is a choice rather than a footnote.
    static let acknowledgement = "I understand"

    static func hasAcknowledged(_ store: any PreferenceStore) -> Bool {
        store.bool(for: key)
    }

    static func acknowledge(_ store: any PreferenceStore) {
        store.setBool(true, for: key)
    }
}
