import Foundation
import Security

/// Each provider's API key, as a generic password under the bundle id (same scheme as Lumo).
enum Keychain {
    /// One item per provider. The names are the ones each provider's key was first stored under.
    enum Account: String {
        case dashscope = "dashscope-api-key"
        case volcengine = "volc-api-key"
        /// Not a speech provider: the Mac's correction after recognition (`Correction`).
        case deepseek = "deepseek-api-key"
    }

    private static let service = "com.max1874.kay"

    private static func base(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    static func get(_ account: Account) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Empty deletes. Returns whether the Keychain accepted the change.
    @discardableResult
    static func set(_ value: String, for account: Account) -> Bool {
        guard !value.isEmpty else {
            let status = SecItemDelete(base(account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var insert = base(account)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}
