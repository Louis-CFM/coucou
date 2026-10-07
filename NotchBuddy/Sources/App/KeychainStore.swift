import Foundation
#if canImport(Security)
import Security
#endif

enum KeychainStatus {
    static let success: Int32 = 0
    static let itemNotFound: Int32 = -25300
}

struct KeychainStoreError: Error, Equatable, LocalizedError {
    let operation: String
    let status: Int32
    var errorDescription: String? { "Keychain \(operation) failed (OSStatus \(status))" }
}

protocol KeychainBackend: Sendable {
    func load(key: String) -> String?
    func save(key: String, value: String) -> Int32
    func delete(key: String) -> Int32
}

#if canImport(Security)
struct SystemKeychainBackend: KeychainBackend {
    static let service = "fr.louisraille.NotchBuddy"

    func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(key: String, value: String) -> Int32 {
        guard let data = value.data(using: .utf8) else { return Int32(errSecParam) }
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let update = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return Int32(update) }
        guard update == errSecItemNotFound else { return Int32(update) }
        var item = lookup
        for (key, value) in attributes { item[key] = value }
        return Int32(SecItemAdd(item as CFDictionary, nil))
    }

    func delete(key: String) -> Int32 {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
        return Int32(SecItemDelete(query as CFDictionary))
    }
}
#else
struct SystemKeychainBackend: KeychainBackend {
    func load(key: String) -> String? { nil }
    func save(key: String, value: String) -> Int32 { -4 }
    func delete(key: String) -> Int32 { -4 }
}
#endif

final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()
    private static let allKeys = [
        "anthropic-api-key",
        "resend-api-key", "resend-from",
        "n8n-url", "n8n-api-key",
        "vercel-token", "github-token", "stripe-api-key", "calcom-api-key", "notion-api-key",
        hindsightBearerTokenKey,
    ]

    private let backend: KeychainBackend
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    init(backend: KeychainBackend = SystemKeychainBackend(), keys: [String]? = nil) {
        self.backend = backend
        for key in keys ?? Self.allKeys { if let value = backend.load(key: key) { cache[key] = value } }
    }

    func get(_ key: String) -> String? { lock.withLock { cache[key] } }

    @discardableResult
    func set(_ key: String, value: String) -> Result<Void, KeychainStoreError> {
        let status = backend.save(key: key, value: value)
        guard status == KeychainStatus.success else { return .failure(.init(operation: "write", status: status)) }
        lock.withLock { cache[key] = value }
        return .success(())
    }

    @discardableResult
    func remove(_ key: String) -> Result<Void, KeychainStoreError> {
        let status = backend.delete(key: key)
        guard status == KeychainStatus.success || status == KeychainStatus.itemNotFound else {
            return .failure(.init(operation: "delete", status: status))
        }
        lock.withLock { cache[key] = nil }
        return .success(())
    }
}
