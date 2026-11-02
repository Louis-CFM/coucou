use ring::{
    digest, hmac,
    rand::{SecureRandom, SystemRandom},
    signature::{self, EcdsaKeyPair},
};
use serde_json::json;

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
pub fn base64(bytes: &[u8]) -> String {
    crate::claude::base64_for(bytes)
}
fn base64url(bytes: &[u8]) -> String {
    base64(bytes)
        .trim_end_matches('=')
        .replace('+', "-")
        .replace('/', "_")
}

pub fn decode(text: &str) -> Result<Vec<u8>, String> {
    let text = text.trim();
    let bytes = text.as_bytes();
    if bytes.len() % 4 != 0 {
        return Err("Invalid base64 key".into());
    }
    let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::new();
    for (index, chunk) in bytes.chunks(4).enumerate() {
        let padding = chunk.iter().rev().take_while(|b| **b == b'=').count();
        if padding > 2 || (padding > 0 && (index + 1) * 4 != bytes.len()) {
            return Err("Invalid base64 key".into());
        }
        let mut bits = 0u32;
        for (i, byte) in chunk.iter().enumerate().take(4 - padding) {
            let value = alphabet
                .iter()
                .position(|b| b == byte)
                .ok_or("Invalid base64 key")? as u32;
            bits |= value << (18 - i * 6);
        }
        if (padding == 2 && bits & 0xffff != 0) || (padding == 1 && bits & 0xff != 0) {
            return Err("Invalid base64 key".into());
        }
        out.extend_from_slice(&bits.to_be_bytes()[1..4 - padding]);
    }
    Ok(out)
}

pub fn sha256_hex(secret: &str, message: &str) -> String {
    hex(hmac::sign(
        &hmac::Key::new(hmac::HMAC_SHA256, secret.as_bytes()),
        message.as_bytes(),
    )
    .as_ref())
}

pub fn sha256_base64(secret: &str, message: &str) -> String {
    base64(
        hmac::sign(
            &hmac::Key::new(hmac::HMAC_SHA256, secret.as_bytes()),
            message.as_bytes(),
        )
        .as_ref(),
    )
}

pub fn kraken(secret: &str, path: &str, nonce: &str, body: &str) -> Result<String, String> {
    let secret = decode(secret)?;
    let hash = digest::digest(&digest::SHA256, format!("{nonce}{body}").as_bytes());
    let mut message = path.as_bytes().to_vec();
    message.extend_from_slice(hash.as_ref());
    Ok(base64(
        hmac::sign(&hmac::Key::new(hmac::HMAC_SHA512, &secret), &message).as_ref(),
    ))
}

fn der(tag: u8, bytes: &[u8]) -> Vec<u8> {
    let mut out = vec![tag];
    if bytes.len() < 128 {
        out.push(bytes.len() as u8);
    } else if bytes.len() < 256 {
        out.extend_from_slice(&[0x81, bytes.len() as u8]);
    } else {
        out.extend_from_slice(&[0x82, (bytes.len() >> 8) as u8, bytes.len() as u8]);
    }
    out.extend_from_slice(bytes);
    out
}

pub fn signing_key(pem: &str) -> Result<EcdsaKeyPair, String> {
    let pem = pem.trim().replace("\\n", "\n");
    let sec1 = pem.starts_with("-----BEGIN EC PRIVATE KEY-----");
    let tag = if sec1 {
        "EC PRIVATE KEY"
    } else {
        "PRIVATE KEY"
    };
    let body = pem
        .strip_prefix(&format!("-----BEGIN {tag}-----"))
        .and_then(|s| s.strip_suffix(&format!("-----END {tag}-----")))
        .ok_or("An ECDSA P-256 private key is required")?;
    let mut bytes = decode(&body.split_whitespace().collect::<String>())?;
    if sec1 {
        // PKCS#8: version 0, id-ecPublicKey + prime256v1, SEC1 in an OCTET STRING.
        let mut info = vec![
            0x02, 0x01, 0x00, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
        ];
        info.extend(der(0x04, &bytes));
        bytes = der(0x30, &info);
    }
    EcdsaKeyPair::from_pkcs8(
        &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
        &bytes,
        &SystemRandom::new(),
    )
    .map_err(|_| "An ECDSA P-256 private key is required".into())
}

pub fn coinbase(
    key_name: &str,
    secret: &str,
    host: &str,
    path: &str,
    now: u64,
) -> Result<String, String> {
    let key = signing_key(secret)?;
    let rng = SystemRandom::new();
    let mut nonce = [0u8; 16];
    rng.fill(&mut nonce)
        .map_err(|_| "Random generator failed")?;
    let header = json!({"alg":"ES256", "typ":"JWT", "kid":key_name, "nonce":hex(&nonce)});
    let payload = json!({"sub":key_name, "iss":"cdp", "nbf":now, "exp":now + 120, "uri":format!("GET {host}{path}")});
    let message = format!(
        "{}.{}",
        base64url(header.to_string().as_bytes()),
        base64url(payload.to_string().as_bytes())
    );
    let signature = key
        .sign(&rng, message.as_bytes())
        .map_err(|_| "Cannot sign request")?;
    Ok(format!("{message}.{}", base64url(signature.as_ref())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::KeyPair;
    #[test]
    fn standard_hmac_vector_and_strict_base64() {
        // RFC 4231 case 2; public test values, never a user's credential.
        assert_eq!(
            sha256_hex("Jefe", "what do ya want for nothing?"),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
        for n in 0..100 {
            let data: Vec<u8> = (0..n).collect();
            assert_eq!(decode(&base64(&data)).unwrap(), data);
        }
        for invalid in ["A", "a===", "Zg=A", "Zh==", "Zm9=", "Zg==Zg=="] {
            assert!(decode(invalid).is_err());
        }
    }
    #[test]
    fn coinbase_token_is_valid_es256_with_bounded_expiry_and_request_binding() {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&signature::ECDSA_P256_SHA256_FIXED_SIGNING, &rng)
            .unwrap();
        let pem = format!(
            "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----",
            base64(pkcs8.as_ref())
        );
        let token = coinbase(
            "test-key-name",
            &pem,
            "api.coinbase.com",
            "/api/v3/brokerage/accounts",
            100,
        )
        .unwrap();
        let parts: Vec<_> = token.split('.').collect();
        let unurl = |s: &str| {
            let mut s = s.replace('-', "+").replace('_', "/");
            while s.len() % 4 != 0 {
                s.push('=');
            }
            decode(&s).unwrap()
        };
        let claims: serde_json::Value = serde_json::from_slice(&unurl(parts[1])).unwrap();
        assert_eq!(claims["exp"], 220);
        assert_eq!(claims["nbf"], 100);
        assert_eq!(
            claims["uri"],
            "GET api.coinbase.com/api/v3/brokerage/accounts"
        );
        let key = signing_key(&pem).unwrap();
        signature::UnparsedPublicKey::new(
            &signature::ECDSA_P256_SHA256_FIXED,
            key.public_key().as_ref(),
        )
        .verify(
            format!("{}.{}", parts[0], parts[1]).as_bytes(),
            &unurl(parts[2]),
        )
        .unwrap();
        assert_ne!(
            token,
            coinbase(
                "test-key-name",
                &pem,
                "api.coinbase.com",
                "/api/v3/brokerage/accounts",
                100
            )
            .unwrap()
        );
    }
    #[test]
    fn coinbase_accepts_the_sec1_pem_format_the_service_issues() {
        fn element(bytes: &[u8]) -> (u8, &[u8], &[u8]) {
            let (length, start) = if bytes[1] < 128 {
                (bytes[1] as usize, 2)
            } else {
                let count = (bytes[1] & 127) as usize;
                (
                    bytes[2..2 + count]
                        .iter()
                        .fold(0, |n, b| n * 256 + *b as usize),
                    2 + count,
                )
            };
            (
                bytes[0],
                &bytes[start..start + length],
                &bytes[start + length..],
            )
        }
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            &SystemRandom::new(),
        )
        .unwrap();
        let (_, sequence, _) = element(pkcs8.as_ref());
        let (_, _, after_version) = element(sequence);
        let (_, _, after_algorithm) = element(after_version);
        let (tag, sec1, _) = element(after_algorithm);
        assert_eq!(tag, 4);
        let pem = format!(
            "-----BEGIN EC PRIVATE KEY-----\n{}\n-----END EC PRIVATE KEY-----",
            base64(sec1)
        );
        let actual = signing_key(&pem).unwrap();
        let expected = EcdsaKeyPair::from_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            pkcs8.as_ref(),
            &SystemRandom::new(),
        )
        .unwrap();
        assert_eq!(actual.public_key().as_ref(), expected.public_key().as_ref());
    }
}
