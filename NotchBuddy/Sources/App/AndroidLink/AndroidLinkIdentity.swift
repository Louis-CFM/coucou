import CryptoKit
import Foundation

// MARK: - Android link: the Mac's identity (certificate, key, pairing token)
//
// A TLS certificate made once, and the pairing token. As on Windows/Linux, both live in the
// Keychain, never in a file and never in UserDefaults. If the Keychain refuses, the link
// simply does not start: there is no fallback to disk.
//
// The certificate is self-signed (ECDSA P-256) and has no host name: the phone does not check a
// host name or an authority, it accepts exactly the certificate whose SHA-256 it was given in the
// pairing link (certificate pinning). So it only has to be generated once and kept; if it is lost,
// phones pair again. Swift has no X.509 writer in the system frameworks, so the few DER bytes of
// a certificate are written here by hand (`AndroidLinkDER`), signed with CryptoKit.

// MARK: DER

enum AndroidLinkDER {
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func sequence(_ parts: [[UInt8]]) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func set(_ parts: [[UInt8]]) -> [UInt8] { tlv(0x31, parts.flatMap { $0 }) }
    static func integer(_ bytes: [UInt8]) -> [UInt8] { tlv(0x02, bytes) }
    static func utf8(_ s: String) -> [UInt8] { tlv(0x0C, Array(s.utf8)) }
    static func utcTime(_ s: String) -> [UInt8] { tlv(0x17, Array(s.utf8)) }
    static func generalizedTime(_ s: String) -> [UInt8] { tlv(0x18, Array(s.utf8)) }
    /// A BIT STRING of whole bytes (no unused bits).
    static func bitString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0x00] + bytes) }

    // Object identifiers, already encoded.
    static let oidEcPublicKey: [UInt8] = tlv(0x06, [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
    static let oidPrime256v1: [UInt8] = tlv(0x06, [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
    static let oidEcdsaWithSHA256: [UInt8] = tlv(0x06, [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
    static let oidCommonName: [UInt8] = tlv(0x06, [0x55, 0x04, 0x03])

    /// The self-signed certificate for `key`, valid from 2024 to 2124 (like the Rust one), as DER.
    static func selfSignedCertificate(key: P256.Signing.PrivateKey, commonName: String, serial: [UInt8]) -> [UInt8]? {
        let name = sequence([set([sequence([oidCommonName, utf8(commonName)])])])
        let signatureAlgorithm = sequence([oidEcdsaWithSHA256])
        let publicKey = Array(key.publicKey.x963Representation)   // 04 || X || Y
        let spki = sequence([sequence([oidEcPublicKey, oidPrime256v1]), bitString(publicKey)])
        let tbs = sequence([
            tlv(0xA0, integer([0x02])),                            // version 3
            integer(serial),
            signatureAlgorithm,
            name,                                                  // issuer = subject
            sequence([utcTime("240101000000Z"), generalizedTime("21240101000000Z")]),
            name,
            spki,
        ])
        guard let signature = try? key.signature(for: Data(tbs)) else { return nil }
        return sequence([tbs, signatureAlgorithm, bitString(Array(signature.derRepresentation))])
    }
}

// MARK: Identity

/// Where the secrets are kept. The app uses the Keychain; the tests use memory.
protocol AndroidLinkSecretStore: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String) -> Bool
}

struct AndroidLinkIdentity {
    /// The certificate as DER, and the lowercase hex SHA-256 of it: the `fp` of the pairing link.
    let certificateDER: Data
    let fingerprint: String
    let privateKey: P256.Signing.PrivateKey

    static let certKey = "android-link-cert"
    static let privateKeyKey = "android-link-key"
    static let tokenKey = "android-link-token"

    /// The certificate already made, else a new one: stored before it is used.
    static func loadOrCreate(store: AndroidLinkSecretStore) -> AndroidLinkIdentity? {
        if let certHex = store.get(certKey), let keyHex = store.get(privateKeyKey),
           let cert = unhex(certHex), let raw = unhex(keyHex),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return AndroidLinkIdentity(certificateDER: cert, fingerprint: AndroidLinkProtocol.sha256Hex(cert), privateKey: key)
        }
        // A damaged or missing entry: start over (phones pair again).
        let key = P256.Signing.PrivateKey()
        var serial = (0..<16).map { _ in UInt8.random(in: 0...255) }
        serial[0] = (serial[0] & 0x7F) | 0x01   // positive, never starts with a zero byte
        guard let der = AndroidLinkDER.selfSignedCertificate(key: key, commonName: "Coucou phone link", serial: serial) else { return nil }
        let cert = Data(der)
        // Key first: a certificate without its key is useless, the reverse is harmless.
        guard store.set(privateKeyKey, AndroidLinkProtocol.hex(key.rawRepresentation)),
              store.set(certKey, AndroidLinkProtocol.hex(cert)) else { return nil }
        return AndroidLinkIdentity(certificateDER: cert, fingerprint: AndroidLinkProtocol.sha256Hex(cert), privateKey: key)
    }

    /// The pairing token: the stored one, else a new one.
    static func token(store: AndroidLinkSecretStore) -> String? {
        if let t = store.get(tokenKey), AndroidLinkProtocol.isToken(t) { return t }
        return newToken(store: store)
    }

    /// A fresh token. Whatever phone held the old one is locked out.
    static func newToken(store: AndroidLinkSecretStore) -> String? {
        let t = AndroidLinkProtocol.randomToken()
        return store.set(tokenKey, t) ? t : nil
    }

    private static func unhex(_ s: String) -> Data? {
        let bytes = Array(s.utf8)
        guard !bytes.isEmpty, bytes.count % 2 == 0 else { return nil }
        var out = Data()
        var i = 0
        while i < bytes.count {
            guard let hi = nibble(bytes[i]), let lo = nibble(bytes[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x61...0x66: return b - 0x61 + 10
        case 0x41...0x46: return b - 0x41 + 10
        default: return nil
        }
    }
}
