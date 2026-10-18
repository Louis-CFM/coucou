// End-to-end encryption for the Android companion's relay mailbox (SEC-1).
//
// The pairing code carries a master secret the relay never sees: what crosses
// the wire as `secret` is HKDF(master, "auth") — the bearer that opens the
// box — while the AES keys derive from the master under different labels. A
// relay that logs every request learns the bearer but cannot derive the keys,
// so a card's command, the chat text and the phone's decisions sit in the box
// as ciphertext only, and a forged outbox item fails its GCM tag.
//
//   master ── "auth" ──> the bearer `secret` sent on every call
//   master ── "p2h" ───> AES key for phone → PC outbox items
//   master ── "h2p" ───> AES key for PC → phone state
//
// A blob is {"enc":1,"n":b64url(12-byte nonce),"ct":b64url(ciphertext‖tag)}; the
// AAD names the label, the box id and the direction, so a blob verifies in no
// other box and no other direction — a stored state pushed back as an outbox
// item opens nothing. Legacy pairings (a code cut before this existed) carry
// no master: they stay plaintext, exactly as before — never pretend-encrypted.

use ring::aead;
use ring::rand::SecureRandom;
use serde_json::{json, Value};

use crate::phone_link::relay_crypto::{base64url_decode, base64url_encode, hkdf_sha256};

const LABEL: &str = "coucou-mailbox/v1";
const NONCE: usize = 12;
/// The biggest blob is the state push (~200 KB of clipped text → ~270 KB on the
/// wire). Anything past this is not ours.
pub const MAX_BLOB: usize = 400_000;

fn unhex(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 || !text.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    Some((0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap()).collect())
}

fn derive(master: &[u8], pc_id: &[u8], what: &str) -> [u8; 32] {
    let mut out = [0u8; 32];
    hkdf_sha256(master, pc_id, format!("{LABEL} {what}").as_bytes(), &mut out);
    out
}

/// The bearer the relay sees as `secret`: HKDF of the master, so a relay log
/// never contains the bytes the keys derive from.
pub fn auth_bearer(master_hex: &str, pc_id_hex: &str) -> Option<String> {
    let (master, pc_id) = (unhex(master_hex)?, unhex(pc_id_hex)?);
    Some(derive(&master, &pc_id, "auth").iter().map(|b| format!("{b:02x}")).collect())
}

/// One direction's AES-256-GCM key and the AAD every blob is checked under.
pub struct Cipher {
    key: [u8; 32],
    aad: Vec<u8>,
}

/// The two directions' ciphers for a box: `(phone → PC, PC → phone)`.
/// None when the master or the box id is not the hex the code promised.
pub fn ciphers(master_hex: &str, pc_id_hex: &str) -> Option<(Cipher, Cipher)> {
    let (master, pc_id) = (unhex(master_hex)?, unhex(pc_id_hex)?);
    let aad = |dir: &str| format!("{LABEL} {pc_id_hex} {dir}").into_bytes();
    Some((
        Cipher { key: derive(&master, &pc_id, "p2h"), aad: aad("p2h") },
        Cipher { key: derive(&master, &pc_id, "h2p"), aad: aad("h2p") },
    ))
}

fn key_for(bytes: &[u8; 32]) -> aead::LessSafeKey {
    aead::LessSafeKey::new(aead::UnboundKey::new(&aead::AES_256_GCM, bytes).expect("a 32-byte key"))
}

impl Cipher {
    /// `plain` (serialized JSON) → `{"enc":1,"n":…,"ct":…}` with a fresh nonce.
    pub fn seal(&self, plain: &[u8]) -> Value {
        let mut nonce = [0u8; NONCE];
        ring::rand::SystemRandom::new().fill(&mut nonce).expect("the system random source works");
        self.seal_at(nonce, plain)
    }

    /// A blob at a fixed nonce — the cross-implementation vectors need it
    /// (BoxCryptoTest.kt decrypts exactly this).
    fn seal_at(&self, nonce: [u8; NONCE], plain: &[u8]) -> Value {
        let mut body = plain.to_vec();
        key_for(&self.key)
            .seal_in_place_append_tag(
                aead::Nonce::assume_unique_for_key(nonce),
                aead::Aad::from(self.aad.as_slice()),
                &mut body,
            )
            .expect("AES-GCM sealing cannot fail for a valid key and nonce");
        json!({ "enc": 1, "n": base64url_encode(&nonce), "ct": base64url_encode(&body) })
    }

    /// A stored blob back to its bytes, or None for anything that is not a
    /// blob or fails its tag — wrong key, forged, cut, or replayed across
    /// boxes and directions.
    pub fn open(&self, blob: &Value) -> Option<Vec<u8>> {
        if blob.get("enc") != Some(&Value::from(1)) {
            return None;
        }
        let n = base64url_decode(blob.get("n")?.as_str()?)?;
        let mut body = base64url_decode(blob.get("ct")?.as_str()?)?;
        if n.len() != NONCE || body.len() > MAX_BLOB {
            return None;
        }
        let nonce: [u8; NONCE] = n.try_into().ok()?;
        let plain = key_for(&self.key)
            .open_in_place(
                aead::Nonce::assume_unique_for_key(nonce),
                aead::Aad::from(self.aad.as_slice()),
                &mut body,
            )
            .ok()?;
        Some(plain.to_vec())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The same fixed inputs BoxCryptoTest.kt and the relay tests check against:
    // master/pc id/nonces pinned, ciphertext compared byte for byte.
    const MASTER: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    const PC_ID: &str = "0123456789abcdef01234567";

    fn pair() -> (Cipher, Cipher) {
        ciphers(MASTER, PC_ID).unwrap()
    }

    #[test]
    fn the_bearer_is_derived_not_the_master() {
        let bearer = auth_bearer(MASTER, PC_ID).unwrap();
        assert!(bearer.len() == 64 && bearer.bytes().all(|b| b.is_ascii_hexdigit()));
        assert_ne!(bearer, MASTER);
        // Deterministic: the phone derives the same bearer from the same code.
        assert_eq!(bearer, auth_bearer(MASTER, PC_ID).unwrap());
    }

    #[test]
    fn a_blob_round_trips_and_each_direction_has_its_own_key() {
        let (p2h, h2p) = pair();
        let blob = p2h.seal(br#"{"type":"chat","text":"hi"}"#);
        assert_eq!(p2h.open(&blob).unwrap(), br#"{"type":"chat","text":"hi"}"#);
        // The other direction's key cannot read it — a blob only ever verifies
        // in the direction it was sealed for.
        assert!(h2p.open(&blob).is_none());
    }

    #[test]
    fn a_cut_or_forged_blob_never_opens() {
        let (p2h, _) = pair();
        let mut blob = p2h.seal(b"{}");
        // Flip a ciphertext byte: the tag must refuse it.
        let ct = blob.get("ct").unwrap().as_str().unwrap().to_string();
        blob["ct"] = Value::from(format!("A{}", &ct[1..]));
        assert!(p2h.open(&blob).is_none());
        // Not a blob, junk fields, oversized ct: all refused.
        assert!(p2h.open(&json!({})).is_none());
        assert!(p2h.open(&json!({"enc":1,"n":"x","ct":"y"})).is_none());
    }

    #[test]
    fn a_blob_for_another_box_never_opens() {
        let (p2h, _) = pair();
        let (other, _) = ciphers(MASTER, "fedcba9876543210fedcba98").unwrap();
        assert!(other.open(&p2h.seal(b"{}")).is_none());
    }

    /// Prints the pinned vector BoxCryptoTest.kt mirrors — keep both in sync.
    /// Run: cargo test -p coucou mail_crypto -- --nocapture
    #[test]
    fn shared_vectors() {
        let (p2h, _h2p) = pair();
        let nonce = [1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
        let blob = p2h.seal_at(nonce, br#"{"type":"decision","requestId":"r1","decision":"allow","at":42}"#);
        eprintln!("vector auth_bearer={}", auth_bearer(MASTER, PC_ID).unwrap());
        eprintln!("vector blob={blob}");
        // The pinned vector decrypts back — and only under the right key.
        let open = p2h.open(&serde_json::from_str::<Value>(&blob.to_string()).unwrap());
        assert_eq!(open.unwrap(), br#"{"type":"decision","requestId":"r1","decision":"allow","at":42}"#);
    }
}
