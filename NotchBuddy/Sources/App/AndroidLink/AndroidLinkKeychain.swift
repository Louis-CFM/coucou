import CryptoKit
import Foundation
import Security

// MARK: Keychain

/// The Mac's Keychain, through the app's own `Keychain` helper (generic passwords, this device only,
/// never synced).
final class AndroidLinkKeychainStore: AndroidLinkSecretStore {
    func get(_ key: String) -> String? { Keychain.load(key: key) }

    func set(_ key: String, _ value: String) -> Bool {
        Keychain.save(key: key, value: value)
        return Keychain.load(key: key) == value
    }
}

/// The `SecIdentity` TLS needs, made from the stored certificate and key. Network.framework wants an
/// identity from the Keychain, so the key and the certificate are added there while the link runs
/// and taken out again when it stops (`remove`). Nothing is written to a file.
enum AndroidLinkSecIdentity {
    private static let label = "Coucou Android link"

    static func make(for identity: AndroidLinkIdentity) -> SecIdentity? {
        remove()
        guard let cert = SecCertificateCreateWithData(nil, identity.certificateDER as CFData) else { return nil }
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        guard let key = SecKeyCreateWithData(identity.privateKey.x963Representation as CFData, keyAttributes as CFDictionary, nil) else {
            return nil
        }
        let addKey: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: key,
            kSecAttrLabel as String: label,
        ]
        let addCert: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: label,
        ]
        let keyStatus = SecItemAdd(addKey as CFDictionary, nil)
        let certStatus = SecItemAdd(addCert as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem,
              certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            remove()
            return nil
        }
        // The key and the certificate that go together form an identity.
        var found: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, cert, &found)
        if status == errSecSuccess, let found { return found }
        remove()
        return nil
    }

    /// Takes the key and the certificate out of the Keychain again (the stored secrets stay).
    static func remove() {
        for cls in [kSecClassKey, kSecClassCertificate] {
            let query: [String: Any] = [kSecClass as String: cls, kSecAttrLabel as String: label]
            SecItemDelete(query as CFDictionary)
        }
    }
}
