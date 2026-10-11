// The end-to-end encrypted channel for the relay link (docs/RELAY_LINK.md, sections 4 and 5).
//
// Pure: bytes in, bytes out. No sockets, no clock, no files, no logging. The relay client (stage R3) feeds it the binary
// frames it gets from the WebSocket and sends the frames it returns. Everything is checked against
// android/relay/test-vectors.json, which the Kotlin twin (android/.../link/RelayCrypto.kt) reads too.
//
// What it guarantees, in short:
//   * a data frame is AES-256-GCM under a key that is fresh for this connection and specific to one direction;
//   * the nonce is `direction ‖ 000 ‖ counter`, and the counter only goes up by one, so a (key, nonce) pair never repeats;
//   * a frame is accepted only if its counter is exactly the next expected one: a repeat, a gap or a jump is a fault;
//   * after any fault the session is dead (`Faulted`): the caller drops it and the phone starts a new handshake;
//   * secrets print as "..", are wiped when dropped, and nothing here writes them anywhere.

// The phone's half of the handshake (`init_frame`, `finish_handshake`) is compiled for tests only: the computer never plays the phone.

use ring::{aead, hkdf, hmac};

pub const LABEL: &str = "coucou-relay/v1";
pub const VER: u8 = 1;
pub const T_INIT: u8 = 1;
pub const T_ACCEPT: u8 = 2;
pub const T_DATA: u8 = 3;
/// What the relay accepts in one WebSocket message.
pub const MAX_FRAME: usize = 66_000;
/// A protocol v1 line, as on the LAN.
pub const MAX_LINE: usize = 65_536;
/// The last counter a session may use (2^32 - 1); then the phone re-handshakes.
pub const LAST_COUNTER: u64 = u32::MAX as u64;
const HEADER: usize = 10;
const TAG: usize = 16;
const NONCE_LEN: usize = 16;
const MAC_LEN: usize = 32;
const BLOCK: usize = 128;

/// Who sends a frame: the key and the first byte of the nonce depend on it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dir {
    PhoneToHost = 1,
    HostToPhone = 2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChannelError {
    /// Too short, an unknown version or an unexpected frame type.
    BadHeader,
    /// The authentication tag (or a handshake MAC) did not verify: wrong key, wrong room, wrong direction, altered or truncated.
    BadTag,
    /// The counter is not the next expected one (repeat, gap, jump) or is past the last allowed.
    BadCounter,
    /// The decrypted padding is not the agreed shape.
    BadPadding,
    TooLong,
    /// The session used its last counter; start a new handshake.
    Exhausted,
    /// An earlier fault ended this session.
    Faulted,
}

// ── secrets ─────────────────────────────────────────────────────────────────────

/// 32 secret bytes: redacted when printed, wiped when dropped. Never `Clone`, never `Display`.
pub struct Secret32([u8; 32]);

impl Secret32 {
    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

impl std::fmt::Debug for Secret32 {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Secret32(..)")
    }
}

impl Drop for Secret32 {
    fn drop(&mut self) {
        wipe(&mut self.0);
    }
}

fn wipe(bytes: &mut [u8]) {
    for b in bytes.iter_mut() {
        // SAFETY: a plain write to a valid byte; volatile so the compiler cannot drop it as a dead store.
        unsafe { std::ptr::write_volatile(b, 0) };
    }
}

/// K, the pairing key, from the pairing link (43 base64url characters) or made fresh.
pub struct PairingKey(Secret32);

impl PairingKey {
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        PairingKey(Secret32(bytes))
    }
    pub fn from_base64url(text: &str) -> Option<Self> {
        let bytes = base64url_decode(text)?;
        Some(PairingKey::from_bytes(bytes.try_into().ok()?))
    }
    pub fn to_base64url(&self) -> String {
        base64url_encode(self.0.as_bytes())
    }
    fn bytes(&self) -> &[u8; 32] {
        self.0.as_bytes()
    }
}

impl std::fmt::Debug for PairingKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PairingKey(..)")
    }
}

// ── derivation ──────────────────────────────────────────────────────────────────

struct Len(usize);
impl hkdf::KeyType for Len {
    fn len(&self) -> usize {
        self.0
    }
}

/// HKDF-SHA-256 (RFC 5869).
fn hkdf_sha256(ikm: &[u8], salt: &[u8], info: &[u8], out: &mut [u8]) {
    let prk = hkdf::Salt::new(hkdf::HKDF_SHA256, salt).extract(ikm);
    let info = [info];
    let okm = prk.expand(&info, Len(out.len())).expect("HKDF output length is within 255 blocks");
    okm.fill(out).expect("HKDF fill");
}

fn derive32(k: &PairingKey, salt: &[u8], what: &str) -> Secret32 {
    let mut out = [0u8; 32];
    hkdf_sha256(k.bytes(), salt, format!("{LABEL} {what}").as_bytes(), &mut out);
    Secret32(out)
}

/// `K_auth`: MACs the two handshake frames.
pub fn k_auth(k: &PairingKey) -> Secret32 {
    derive32(k, &[], "auth")
}

/// `K_join`: presented to the relay as a join proof; one-way from K.
pub fn k_join(k: &PairingKey) -> Secret32 {
    derive32(k, &[], "join")
}

/// The join proof for the `coucou.join.<…>` sub-protocol.
pub fn join_proof(k: &PairingKey) -> String {
    base64url_encode(k_join(k).as_bytes())
}

/// The two session keys, `(phone → host, host → phone)`, from K and the two fresh nonces.
fn session_keys(k: &PairingKey, n_phone: &[u8; NONCE_LEN], n_host: &[u8; NONCE_LEN]) -> (Secret32, Secret32) {
    let mut salt = [0u8; NONCE_LEN * 2];
    salt[..NONCE_LEN].copy_from_slice(n_phone);
    salt[NONCE_LEN..].copy_from_slice(n_host);
    let mut out = [0u8; 64];
    hkdf_sha256(k.bytes(), &salt, format!("{LABEL} session").as_bytes(), &mut out);
    let mut a = [0u8; 32];
    let mut b = [0u8; 32];
    a.copy_from_slice(&out[..32]);
    b.copy_from_slice(&out[32..]);
    wipe(&mut out);
    (Secret32(a), Secret32(b))
}

/// `direction ‖ 0x00 0x00 0x00 ‖ counter` (12 bytes).
pub fn nonce_for(dir: Dir, counter: u64) -> [u8; 12] {
    let mut n = [0u8; 12];
    n[0] = dir as u8;
    n[4..].copy_from_slice(&counter.to_be_bytes());
    n
}

fn header(frame_type: u8, counter: u64) -> [u8; HEADER] {
    let mut h = [0u8; HEADER];
    h[0] = VER;
    h[1] = frame_type;
    h[2..].copy_from_slice(&counter.to_be_bytes());
    h
}

fn aad(room: &str, dir: Dir, header: &[u8; HEADER]) -> Vec<u8> {
    let mut a = Vec::with_capacity(LABEL.len() + room.len() + 1 + HEADER);
    a.extend_from_slice(LABEL.as_bytes());
    a.extend_from_slice(room.as_bytes());
    a.push(dir as u8);
    a.extend_from_slice(header);
    a
}

// ── handshake ───────────────────────────────────────────────────────────────────

fn mac(k_auth: &Secret32, parts: &[&[u8]]) -> hmac::Tag {
    let key = hmac::Key::new(hmac::HMAC_SHA256, k_auth.as_bytes());
    let mut msg = Vec::new();
    for p in parts {
        msg.extend_from_slice(p);
    }
    hmac::sign(&key, &msg)
}

fn mac_ok(k_auth: &Secret32, parts: &[&[u8]], tag: &[u8]) -> bool {
    let key = hmac::Key::new(hmac::HMAC_SHA256, k_auth.as_bytes());
    let mut msg = Vec::new();
    for p in parts {
        msg.extend_from_slice(p);
    }
    hmac::verify(&key, &msg, tag).is_ok() // constant time
}

/// A fresh 16-byte handshake nonce.
pub fn fresh_nonce() -> [u8; NONCE_LEN] {
    use ring::rand::SecureRandom;
    let mut n = [0u8; NONCE_LEN];
    ring::rand::SystemRandom::new().fill(&mut n).expect("the system random source works");
    n
}

fn parse_handshake(frame: &[u8], wanted: u8) -> Result<([u8; NONCE_LEN], &[u8]), ChannelError> {
    if frame.len() != HEADER + NONCE_LEN + MAC_LEN || frame[0] != VER || frame[1] != wanted || frame[2..HEADER] != 0u64.to_be_bytes() {
        return Err(ChannelError::BadHeader);
    }
    let mut nonce = [0u8; NONCE_LEN];
    nonce.copy_from_slice(&frame[HEADER..HEADER + NONCE_LEN]);
    Ok((nonce, &frame[HEADER + NONCE_LEN..]))
}

/// The phone's first frame, and the nonce it must remember to check the answer.
#[cfg(test)]
pub fn init_frame(k: &PairingKey, room: &str, n_phone: [u8; NONCE_LEN]) -> Vec<u8> {
    let tag = mac(&k_auth(k), &[b"init", room.as_bytes(), &n_phone]);
    let mut f = header(T_INIT, 0).to_vec();
    f.extend_from_slice(&n_phone);
    f.extend_from_slice(tag.as_ref());
    f
}

/// The computer's side: checks an `init`, answers with `accept`, and returns the session it will talk in.
pub fn accept_init(k: &PairingKey, room: &str, init: &[u8], n_host: [u8; NONCE_LEN]) -> Result<(Vec<u8>, Session), ChannelError> {
    let (n_phone, tag) = parse_handshake(init, T_INIT)?;
    let auth = k_auth(k);
    if !mac_ok(&auth, &[b"init", room.as_bytes(), &n_phone], tag) {
        return Err(ChannelError::BadTag);
    }
    let reply = mac(&auth, &[b"accept", room.as_bytes(), &n_phone, &n_host]);
    let mut f = header(T_ACCEPT, 0).to_vec();
    f.extend_from_slice(&n_host);
    f.extend_from_slice(reply.as_ref());
    let (p2h, h2p) = session_keys(k, &n_phone, &n_host);
    Ok((f, Session::new(Dir::HostToPhone, room, p2h, h2p)))
}

/// The phone's side: checks that the `accept` answers **its current** nonce, and returns the session.
#[cfg(test)]
pub fn finish_handshake(k: &PairingKey, room: &str, n_phone: &[u8; NONCE_LEN], accept: &[u8]) -> Result<Session, ChannelError> {
    let (n_host, tag) = parse_handshake(accept, T_ACCEPT)?;
    if !mac_ok(&k_auth(k), &[b"accept", room.as_bytes(), n_phone, &n_host], tag) {
        return Err(ChannelError::BadTag);
    }
    let (p2h, h2p) = session_keys(k, n_phone, &n_host);
    Ok(Session::new(Dir::PhoneToHost, room, p2h, h2p))
}

// ── the session ─────────────────────────────────────────────────────────────────

/// One connection's keys and counters. `send` is the direction this side writes, `recv` the one it reads.
pub struct Session {
    room: String,
    send_dir: Dir,
    send_key: Secret32,
    recv_key: Secret32,
    send_counter: u64,
    recv_next: u64,
    send_done: bool,
    faulted: bool,
}

impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Session(..)")
    }
}

fn recv_dir(send: Dir) -> Dir {
    match send {
        Dir::PhoneToHost => Dir::HostToPhone,
        Dir::HostToPhone => Dir::PhoneToHost,
    }
}

impl Session {
    fn new(me: Dir, room: &str, p2h: Secret32, h2p: Secret32) -> Session {
        let (send_key, recv_key) = if me == Dir::PhoneToHost { (p2h, h2p) } else { (h2p, p2h) };
        Session { room: room.to_string(), send_dir: me, send_key, recv_key, send_counter: 0, recv_next: 0, send_done: false, faulted: false }
    }

    /// Encrypts one protocol v1 line (UTF-8 JSON, without the newline) into a binary frame.
    pub fn seal(&mut self, line: &[u8]) -> Result<Vec<u8>, ChannelError> {
        if self.faulted {
            return Err(ChannelError::Faulted);
        }
        if line.len() > MAX_LINE {
            return Err(ChannelError::TooLong);
        }
        if self.send_done {
            return Err(ChannelError::Exhausted);
        }
        let counter = self.send_counter;
        let frame = seal_with(self.send_key.as_bytes(), &self.room, self.send_dir, counter, line);
        if counter == LAST_COUNTER {
            self.send_done = true; // that was the last frame this session may send
        } else {
            self.send_counter += 1;
        }
        Ok(frame)
    }

    /// Decrypts a binary frame from the other side. The counter must be exactly the next one. Any error ends the session.
    pub fn open(&mut self, frame: &[u8]) -> Result<Vec<u8>, ChannelError> {
        if self.faulted {
            return Err(ChannelError::Faulted);
        }
        let result = self.open_checked(frame);
        if result.is_err() {
            self.faulted = true;
        }
        result
    }

    fn open_checked(&mut self, frame: &[u8]) -> Result<Vec<u8>, ChannelError> {
        if frame.len() > MAX_FRAME {
            return Err(ChannelError::TooLong);
        }
        if frame.len() < HEADER + TAG || frame[0] != VER || frame[1] != T_DATA {
            return Err(ChannelError::BadHeader);
        }
        let counter = u64::from_be_bytes(frame[2..HEADER].try_into().unwrap());
        if counter != self.recv_next || counter > LAST_COUNTER {
            return Err(ChannelError::BadCounter);
        }
        let line = open_with(self.recv_key.as_bytes(), &self.room, recv_dir(self.send_dir), frame)?;
        self.recv_next = counter + 1; // past LAST_COUNTER the next frame fails the check above
        Ok(line)
    }


    #[cfg(test)]
    fn set_send_counter_for_test(&mut self, counter: u64) {
        self.send_counter = counter;
    }
}

/// 4-byte length, the line, then zeros up to a multiple of 128 bytes (at least 128).
fn pad(line: &[u8]) -> Vec<u8> {
    let raw = 4 + line.len();
    let total = raw.div_ceil(BLOCK).max(1) * BLOCK;
    let mut p = Vec::with_capacity(total);
    p.extend_from_slice(&(line.len() as u32).to_be_bytes());
    p.extend_from_slice(line);
    p.resize(total, 0);
    p
}

fn unpad(plain: &[u8]) -> Result<Vec<u8>, ChannelError> {
    if plain.len() < BLOCK || plain.len() % BLOCK != 0 {
        return Err(ChannelError::BadPadding);
    }
    let n = u32::from_be_bytes(plain[..4].try_into().unwrap()) as usize;
    if n > MAX_LINE || 4 + n > plain.len() || plain[4 + n..].iter().any(|b| *b != 0) {
        return Err(ChannelError::BadPadding);
    }
    Ok(plain[4..4 + n].to_vec())
}

fn key_for(bytes: &[u8; 32]) -> aead::LessSafeKey {
    aead::LessSafeKey::new(aead::UnboundKey::new(&aead::AES_256_GCM, bytes).expect("a 32-byte key"))
}

/// Encrypts at an explicit counter. The session guarantees the counter is never reused; tests use it for the vectors.
fn seal_with(key: &[u8; 32], room: &str, dir: Dir, counter: u64, line: &[u8]) -> Vec<u8> {
    let h = header(T_DATA, counter);
    let mut body = pad(line);
    key_for(key)
        .seal_in_place_append_tag(aead::Nonce::assume_unique_for_key(nonce_for(dir, counter)), aead::Aad::from(aad(room, dir, &h)), &mut body)
        .expect("AES-GCM sealing cannot fail for a valid key and nonce");
    let mut f = h.to_vec();
    f.extend_from_slice(&body);
    f
}

/// Header already checked by the caller; verifies the tag under the direction's key and unpads.
fn open_with(key: &[u8; 32], room: &str, dir: Dir, frame: &[u8]) -> Result<Vec<u8>, ChannelError> {
    let h: [u8; HEADER] = frame[..HEADER].try_into().unwrap();
    let counter = u64::from_be_bytes(h[2..].try_into().unwrap());
    let mut body = frame[HEADER..].to_vec();
    let plain = key_for(key)
        .open_in_place(aead::Nonce::assume_unique_for_key(nonce_for(dir, counter)), aead::Aad::from(aad(room, dir, &h)), &mut body)
        .map_err(|_| ChannelError::BadTag)?;
    let line = unpad(plain);
    wipe(&mut body);
    line
}

// ── base64url (no padding) ──────────────────────────────────────────────────────

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

pub fn base64url_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        out.push(B64[(n >> 18) as usize & 63] as char);
        out.push(B64[(n >> 12) as usize & 63] as char);
        if chunk.len() > 1 {
            out.push(B64[(n >> 6) as usize & 63] as char);
        }
        if chunk.len() > 2 {
            out.push(B64[n as usize & 63] as char);
        }
    }
    out
}

/// Strict: only the 64 URL-safe characters, no padding, and the unused trailing bits must be zero.
pub fn base64url_decode(text: &str) -> Option<Vec<u8>> {
    let val = |c: u8| B64.iter().position(|x| *x == c).map(|p| p as u32);
    let bytes = text.as_bytes();
    if bytes.len() % 4 == 1 {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() * 3 / 4);
    for chunk in bytes.chunks(4) {
        let mut n = 0u32;
        for (i, c) in chunk.iter().enumerate() {
            n |= val(*c)? << (18 - 6 * i as u32);
        }
        let take = chunk.len() * 6 / 8;
        let b = n.to_be_bytes();
        out.extend_from_slice(&b[1..1 + take]);
        let unused_bits = chunk.len() * 6 - take * 8;
        if unused_bits > 0 && (n >> (24 - chunk.len() as u32 * 6)) & ((1 << unused_bits) - 1) != 0 {
            return None;
        }
    }
    Some(out)
}

// ── tests ───────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    const VECTORS: &str = include_str!("../../../../android/relay/test-vectors.json");

    fn vectors() -> Value {
        serde_json::from_str(VECTORS).unwrap()
    }
    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }
    fn text<'a>(v: &'a Value, path: &[&str]) -> &'a str {
        let mut cur = v;
        for p in path {
            cur = &cur[*p];
        }
        cur.as_str().unwrap_or_else(|| panic!("{path:?}"))
    }
    fn hexs(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }
    fn n16(h: &str) -> [u8; 16] {
        unhex(h).try_into().unwrap()
    }
    fn key(v: &Value) -> PairingKey {
        PairingKey::from_bytes(unhex(text(v, &["inputs", "key"])).try_into().unwrap())
    }
    fn dir(s: &str) -> Dir {
        if s == "p2h" { Dir::PhoneToHost } else { Dir::HostToPhone }
    }
    fn session_keys_of(v: &Value) -> (Secret32, Secret32) {
        session_keys(&key(v), &n16(text(v, &["inputs", "nPhone"])), &n16(text(v, &["inputs", "nPc"])))
    }

    #[test]
    fn hkdf_matches_rfc_5869_a1() {
        let v = vectors();
        let r = &v["rfc5869_a1"];
        let mut out = vec![0u8; r["length"].as_u64().unwrap() as usize];
        hkdf_sha256(&unhex(text(r, &["ikm"])), &unhex(text(r, &["salt"])), &unhex(text(r, &["info"])), &mut out);
        assert_eq!(hexs(&out), text(r, &["okm"]));
    }

    #[test]
    fn derived_keys_match_the_vectors() {
        let v = vectors();
        let k = key(&v);
        assert_eq!(hexs(k_auth(&k).as_bytes()), text(&v, &["derived", "kAuth"]));
        assert_eq!(hexs(k_join(&k).as_bytes()), text(&v, &["derived", "kJoin"]));
        let (p2h, h2p) = session_keys_of(&v);
        assert_eq!(hexs(p2h.as_bytes()), text(&v, &["derived", "kP2H"]));
        assert_eq!(hexs(h2p.as_bytes()), text(&v, &["derived", "kH2P"]));
        assert_eq!(join_proof(&k), base64url_encode(k_join(&k).as_bytes()));
        assert_eq!(join_proof(&k).len(), 43);
    }

    #[test]
    fn the_handshake_frames_match_the_vectors_and_the_two_sides_agree() {
        let v = vectors();
        let (k, room) = (key(&v), text(&v, &["inputs", "room"]));
        let (n_phone, n_pc) = (n16(text(&v, &["inputs", "nPhone"])), n16(text(&v, &["inputs", "nPc"])));
        let init = init_frame(&k, room, n_phone);
        assert_eq!(hexs(&init), text(&v, &["init", "frame"]));
        let (accept, mut host) = accept_init(&k, room, &init, n_pc).unwrap();
        assert_eq!(hexs(&accept), text(&v, &["accept", "frame"]));
        let mut phone = finish_handshake(&k, room, &n_phone, &accept).unwrap();
        // They talk to each other, in order, both ways.
        let a = phone.seal(b"{\"type\":\"hello\"}").unwrap();
        assert_eq!(host.open(&a).unwrap(), b"{\"type\":\"hello\"}");
        let b = host.seal(b"{\"type\":\"welcome\"}").unwrap();
        assert_eq!(phone.open(&b).unwrap(), b"{\"type\":\"welcome\"}");
    }

    #[test]
    fn a_wrong_key_room_or_stale_accept_is_refused() {
        let v = vectors();
        let (k, room) = (key(&v), text(&v, &["inputs", "room"]));
        let (n_phone, n_pc) = (n16(text(&v, &["inputs", "nPhone"])), n16(text(&v, &["inputs", "nPc"])));
        let init = init_frame(&k, room, n_phone);
        let other = PairingKey::from_bytes([9; 32]);
        assert_eq!(accept_init(&other, room, &init, n_pc).err(), Some(ChannelError::BadTag));
        assert_eq!(accept_init(&k, "AAAAAAAAAAAAAAAAAAAAAA", &init, n_pc).err(), Some(ChannelError::BadTag));
        let (accept, _) = accept_init(&k, room, &init, n_pc).unwrap();
        // The phone has since started a new handshake with a different nonce: the old accept must not be taken.
        assert_eq!(finish_handshake(&k, room, &[7; 16], &accept).err(), Some(ChannelError::BadTag));
        // An init is not an accept, and nothing else is either.
        assert_eq!(finish_handshake(&k, room, &n_phone, &init).err(), Some(ChannelError::BadHeader));
        assert_eq!(accept_init(&k, room, &accept, n_pc).err(), Some(ChannelError::BadHeader));
        assert_eq!(accept_init(&k, room, &init[..40], n_pc).err(), Some(ChannelError::BadHeader));
        let mut flipped = init.clone();
        flipped[12] ^= 1;
        assert_eq!(accept_init(&k, room, &flipped, n_pc).err(), Some(ChannelError::BadTag));
    }

    #[test]
    fn data_frames_reproduce_the_vectors_byte_for_byte_and_open_back() {
        let v = vectors();
        let room = text(&v, &["inputs", "room"]);
        let (p2h, h2p) = session_keys_of(&v);
        for c in v["data"].as_array().unwrap() {
            let d = dir(text(c, &["dir"]));
            let k = if d == Dir::PhoneToHost { &p2h } else { &h2p };
            let counter = c["counter"].as_u64().unwrap();
            let line = text(c, &["line"]);
            assert_eq!(hexs(&nonce_for(d, counter)), text(c, &["nonce"]));
            assert_eq!(hexs(&pad(line.as_bytes())), text(c, &["plaintext"]));
            let sealed = seal_with(k.as_bytes(), room, d, counter, line.as_bytes());
            assert_eq!(hexs(&sealed), text(c, &["frame"]), "{d:?} {counter}");
            assert_eq!(open_with(k.as_bytes(), room, d, &sealed).unwrap(), line.as_bytes());
        }
    }

    /// A session standing in for the receiving side of `d`, in its first-frame state.
    fn receiver_of(v: &Value, d: Dir) -> Session {
        let (k, room) = (key(v), text(v, &["inputs", "room"]));
        let (n_phone, n_pc) = (n16(text(v, &["inputs", "nPhone"])), n16(text(v, &["inputs", "nPc"])));
        let init = init_frame(&k, room, n_phone);
        let (accept, host) = accept_init(&k, room, &init, n_pc).unwrap();
        if d == Dir::PhoneToHost { host } else { finish_handshake(&k, room, &n_phone, &accept).unwrap() }
    }

    #[test]
    fn frames_that_must_be_refused_are_refused_with_the_listed_reason() {
        let v = vectors();
        let room = text(&v, &["inputs", "room"]).to_string();
        for n in v["mustRefuse"].as_array().unwrap() {
            let d = dir(text(n, &["dir"]));
            let frame = unhex(text(n, &["frame"]));
            // Which session receives it: the one reading direction `d`.
            let mut rx = receiver_of(&v, if d == Dir::PhoneToHost { Dir::PhoneToHost } else { Dir::HostToPhone });
            // Another room or another key means a session built from different inputs.
            if n.get("room").is_some() || n.get("key").is_some() {
                let k = match n.get("key") {
                    Some(h) => PairingKey::from_bytes(unhex(h.as_str().unwrap()).try_into().unwrap()),
                    None => key(&v),
                };
                let r = n.get("room").and_then(|r| r.as_str()).unwrap_or(&room).to_string();
                let (n_phone, n_pc) = (n16(text(&v, &["inputs", "nPhone"])), n16(text(&v, &["inputs", "nPc"])));
                let (init, _) = (init_frame(&k, &r, n_phone), ());
                rx = accept_init(&k, &r, &init, n_pc).unwrap().1;
            }
            let expect = match text(n, &["expect"]) {
                "bad_tag" => ChannelError::BadTag,
                "bad_header" => ChannelError::BadHeader,
                other => panic!("{other}"),
            };
            let name = text(n, &["name"]);
            let got = rx.open(&frame).err();
            // A flipped counter byte is refused by the counter rule first; the vector calls it a bad tag (either way: refused).
            if name == "the counter in the header changed" {
                assert_eq!(got, Some(ChannelError::BadCounter), "{name}");
            } else {
                assert_eq!(got, Some(expect), "{name}");
            }
            // After a fault the session is dead.
            assert_eq!(rx.open(&frame).err(), Some(ChannelError::Faulted), "{name}");
        }
    }

    #[test]
    fn counter_sequences_follow_the_rule() {
        let v = vectors();
        let (room, k) = (text(&v, &["inputs", "room"]), key(&v));
        let (p2h, _) = session_keys_of(&v);
        for s in v["mustRefuseInOrder"].as_array().unwrap() {
            let mut rx = receiver_of(&v, Dir::PhoneToHost);
            let counters: Vec<u64> = s["counters"].as_array().unwrap().iter().map(|c| c.as_u64().unwrap()).collect();
            let want: Vec<bool> = s["accepted"].as_array().unwrap().iter().map(|c| c.as_bool().unwrap()).collect();
            let mut got = Vec::new();
            for c in counters {
                let frame = seal_with(p2h.as_bytes(), room, Dir::PhoneToHost, c, b"{\"type\":\"ping\"}");
                got.push(rx.open(&frame).is_ok());
            }
            assert_eq!(got, want, "{}", text(s, &["name"]));
        }
        let _ = k;
    }

    #[test]
    fn no_key_and_nonce_pair_repeats_across_both_directions_and_two_sessions() {
        let mut seen = std::collections::HashSet::new();
        let k = PairingKey::from_bytes([3; 32]);
        for (np, nh) in [([1u8; 16], [2u8; 16]), ([5u8; 16], [6u8; 16])] {
            let (p2h, h2p) = session_keys(&k, &np, &nh);
            assert_ne!(p2h.as_bytes(), h2p.as_bytes(), "the directions share a key");
            for c in 0..3000u64 {
                assert!(seen.insert((*p2h.as_bytes(), nonce_for(Dir::PhoneToHost, c))), "p2h {c}");
                assert!(seen.insert((*h2p.as_bytes(), nonce_for(Dir::HostToPhone, c))), "h2p {c}");
            }
        }
        assert_eq!(seen.len(), 2 * 2 * 3000, "four distinct keys, 3000 nonces each");
        // Even a bug that made both directions share a key could not collide: the direction is in the nonce.
        assert_ne!(nonce_for(Dir::PhoneToHost, 5), nonce_for(Dir::HostToPhone, 5));
    }

    #[test]
    fn the_sessions_themselves_reproduce_the_vector_frames_in_each_direction() {
        // Not just the helper functions: the keys a Session picks for sending and receiving are the vector's, per direction.
        let v = vectors();
        let mut phone = receiver_of(&v, Dir::HostToPhone); // the phone's session
        let mut host = receiver_of(&v, Dir::PhoneToHost); // the computer's session
        let mut checked = 0;
        for c in v["data"].as_array().unwrap() {
            let (d, counter) = (dir(text(c, &["dir"])), c["counter"].as_u64().unwrap());
            if counter > 2 {
                continue; // the last-counter vector is covered by its own test
            }
            let (sender, receiver) = if d == Dir::PhoneToHost { (&mut phone, &mut host) } else { (&mut host, &mut phone) };
            let frame = sender.seal(text(c, &["line"]).as_bytes()).unwrap();
            assert_eq!(hexs(&frame), text(c, &["frame"]), "{d:?} {counter}");
            assert_eq!(receiver.open(&frame).unwrap(), text(c, &["line"]).as_bytes());
            checked += 1;
        }
        assert_eq!(checked, 5);
        assert_ne!(phone.send_key.as_bytes(), phone.recv_key.as_bytes(), "a session must not send and receive under one key");
        assert_ne!(host.send_key.as_bytes(), host.recv_key.as_bytes());
        assert_eq!(phone.send_key.as_bytes(), host.recv_key.as_bytes());
        assert_eq!(host.send_key.as_bytes(), phone.recv_key.as_bytes());
    }

    #[test]
    fn a_session_sends_counters_in_order_and_never_reuses_one() {
        let v = vectors();
        let mut host = receiver_of(&v, Dir::PhoneToHost);
        let mut counters = Vec::new();
        for _ in 0..500 {
            let f = host.seal(b"{}").unwrap();
            counters.push(u64::from_be_bytes(f[2..10].try_into().unwrap()));
        }
        assert_eq!(counters, (0..500).collect::<Vec<u64>>());
    }

    #[test]
    fn a_sender_at_the_last_counter_sends_it_once_and_then_refuses() {
        let v = vectors();
        let mut host = receiver_of(&v, Dir::PhoneToHost);
        host.set_send_counter_for_test(LAST_COUNTER - 1);
        assert!(host.seal(b"{}").is_ok());
        let last = host.seal(b"{}").unwrap();
        assert_eq!(u64::from_be_bytes(last[2..10].try_into().unwrap()), LAST_COUNTER);
        assert_eq!(host.seal(b"{}").err(), Some(ChannelError::Exhausted));
        assert_eq!(host.seal(b"{}").err(), Some(ChannelError::Exhausted));
    }

    #[test]
    fn a_receiver_refuses_a_counter_past_the_last_one() {
        let v = vectors();
        let (room, (p2h, _)) = (text(&v, &["inputs", "room"]), session_keys_of(&v));
        let mut rx = receiver_of(&v, Dir::PhoneToHost);
        let beyond = seal_with(p2h.as_bytes(), room, Dir::PhoneToHost, LAST_COUNTER + 1, b"{}");
        assert_eq!(rx.open(&beyond).err(), Some(ChannelError::BadCounter));
    }

    #[test]
    fn lines_pad_to_blocks_and_the_size_limit_holds() {
        assert_eq!(pad(b"").len(), 128);
        assert_eq!(pad(&[b'a'; 124]).len(), 128);
        assert_eq!(pad(&[b'a'; 125]).len(), 256);
        let v = vectors();
        let mut tx = receiver_of(&v, Dir::PhoneToHost);
        let mut rx = receiver_of(&v, Dir::HostToPhone);
        let biggest = vec![b'x'; MAX_LINE];
        let frame = tx.seal(&biggest).unwrap();
        assert!(frame.len() <= MAX_FRAME, "{} bytes", frame.len());
        assert_eq!(rx.open(&frame).unwrap(), biggest);
        assert_eq!(tx.seal(&vec![b'x'; MAX_LINE + 1]).err(), Some(ChannelError::TooLong));
        assert_eq!(rx.open(&vec![0u8; MAX_FRAME + 1]).err(), Some(ChannelError::TooLong));
    }

    #[test]
    fn a_frame_with_bad_padding_is_refused_even_with_a_valid_tag() {
        let v = vectors();
        let (room, (p2h, _)) = (text(&v, &["inputs", "room"]), session_keys_of(&v));
        for plain in [vec![0u8; 100], { let mut p = pad(b"{}"); p[100] = 1; p }, { let mut p = pad(b"{}"); p[..4].copy_from_slice(&200u32.to_be_bytes()); p }] {
            let h = header(T_DATA, 0);
            let mut body = plain.clone();
            key_for(p2h.as_bytes())
                .seal_in_place_append_tag(aead::Nonce::assume_unique_for_key(nonce_for(Dir::PhoneToHost, 0)), aead::Aad::from(aad(room, Dir::PhoneToHost, &h)), &mut body)
                .unwrap();
            let mut f = h.to_vec();
            f.extend_from_slice(&body);
            let mut rx = receiver_of(&v, Dir::PhoneToHost);
            assert_eq!(rx.open(&f).err(), Some(ChannelError::BadPadding));
        }
    }

    #[test]
    fn base64url_round_trips_and_is_strict() {
        for len in 0..40usize {
            let bytes: Vec<u8> = (0..len as u8).map(|i| i.wrapping_mul(37)).collect();
            assert_eq!(base64url_decode(&base64url_encode(&bytes)).unwrap(), bytes, "{len}");
        }
        let v = vectors();
        assert_eq!(base64url_encode(&unhex(text(&v, &["inputs", "roomBytes"]))), text(&v, &["inputs", "room"]));
        assert_eq!(base64url_encode(&[0xfb, 0xff]), "-_8");
        for bad in ["A", "AAAAA", "AA=A", "A+AA", "A/AA", "AB", "AAB", "a b "] {
            assert_eq!(base64url_decode(bad), None, "{bad}");
        }
        assert!(PairingKey::from_base64url(&base64url_encode(&[1u8; 32])).is_some());
        assert!(PairingKey::from_base64url(&base64url_encode(&[1u8; 31])).is_none());
    }

    #[test]
    fn secrets_never_print_and_the_module_never_logs() {
        let k = PairingKey::from_bytes([0xab; 32]);
        let text_of_key = format!("{k:?} {:?}", k_auth(&k));
        assert!(!text_of_key.contains("ab") && !text_of_key.contains("171"), "{text_of_key}");
        let v = vectors();
        let s = receiver_of(&v, Dir::PhoneToHost);
        let shown = format!("{s:?}");
        assert_eq!(shown, "Session(..)");
        let src = include_str!("relay_crypto.rs");
        let code = src.split("// ── tests").next().unwrap();
        for forbidden in ["println!", "eprintln!", "dbg!", "log::", "tracing::", "std::fs", "std::env", "File::"] {
            assert!(!code.contains(forbidden), "relay_crypto.rs uses {forbidden}");
        }
    }
}
