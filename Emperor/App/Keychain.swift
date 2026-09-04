import Foundation
import Security

/// The real `CredentialStore`: an iOS Keychain item.
///
/// The token must not live in `UserDefaults`: it is a long-lived bearer credential, so anything
/// that leaks it grants access to the account's matters for as long as it stays valid.
struct Keychain: CredentialStore {
    private let service = "com.emperorailabs.emperor"

    private func query(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func set(_ value: String, for key: String) {
        let query = query(for: key)
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        // Privileged client material: never sync to iCloud, and keep it unreadable while the
        // device is locked so a seized-but-locked phone does not hand it over.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    func string(for key: String) -> String? {
        var query = query(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remove(_ key: String) {
        SecItemDelete(query(for: key) as CFDictionary)
    }
}
