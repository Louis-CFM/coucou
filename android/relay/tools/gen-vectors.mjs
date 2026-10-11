#!/usr/bin/env node
// Generates android/relay/test-vectors.json: fixed inputs and the exact bytes the secure channel of
// docs/RELAY_LINK.md must produce. The Rust side (phone_link/relay_crypto.rs) and the Kotlin side
// (link/RelayCrypto.kt) both read this file, so the two implementations are checked against the same bytes.
// Node's own crypto is the third, independent implementation.
//
//   node android/relay/tools/gen-vectors.mjs           writes test-vectors.json
//   node android/relay/tools/gen-vectors.mjs --check   fails if the file is not what this script produces (CI)

import { createCipheriv, createDecipheriv, createHash, createHmac, hkdfSync } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const OUT = join(dirname(fileURLToPath(import.meta.url)), "..", "test-vectors.json");
const hex = (b) => Buffer.from(b).toString("hex");
const fromHex = (s) => Buffer.from(s, "hex");
const seq = (start, n) => Buffer.from(Array.from({ length: n }, (_, i) => (start + i) & 0xff));
const b64url = (b) => Buffer.from(b).toString("base64url");

const LABEL = "coucou-relay/v1";
const VER = 1;
const T_INIT = 1, T_ACCEPT = 2, T_DATA = 3;
const DIR = { p2h: 1, h2p: 2 }; // phone to computer ("host"), computer to phone

// ── fixed inputs ────────────────────────────────────────────────────────────────
const K = seq(0x00, 32);
const roomBytes = seq(0xa0, 16);
const room = b64url(roomBytes); // 22 characters, as in the URL
const nPhone = seq(0x40, 16);
const nPc = seq(0x60, 16);

const hkdf = (ikm, salt, info, len) => Buffer.from(hkdfSync("sha256", ikm, salt, info, len));
const hmac = (key, ...parts) => createHmac("sha256", key).update(Buffer.concat(parts.map((p) => Buffer.from(p)))).digest();

const kAuth = hkdf(K, Buffer.alloc(0), `${LABEL} auth`, 32);
const kJoin = hkdf(K, Buffer.alloc(0), `${LABEL} join`, 32);
const session = hkdf(K, Buffer.concat([nPhone, nPc]), `${LABEL} session`, 64);
const key = { p2h: session.subarray(0, 32), h2p: session.subarray(32, 64) };

const u64 = (n) => {
  const b = Buffer.alloc(8);
  b.writeBigUInt64BE(BigInt(n));
  return b;
};
const header = (type, counter) => Buffer.concat([Buffer.from([VER, type]), u64(counter)]);
const nonce = (dir, counter) => Buffer.concat([Buffer.from([DIR[dir], 0, 0, 0]), u64(counter)]);
const aad = (dir, type, counter, roomText = room) =>
  Buffer.concat([Buffer.from(LABEL), Buffer.from(roomText), Buffer.from([DIR[dir]]), header(type, counter)]);

// One v1 line (no newline), as a 4-byte length, the line, then zeros up to a multiple of 128 bytes.
function pad(line) {
  const body = Buffer.from(line, "utf8");
  const len = Buffer.alloc(4);
  len.writeUInt32BE(body.length);
  const raw = Buffer.concat([len, body]);
  const total = Math.max(128, Math.ceil(raw.length / 128) * 128);
  return Buffer.concat([raw, Buffer.alloc(total - raw.length)]);
}

function seal(dir, counter, line, k = key[dir]) {
  const plaintext = pad(line);
  const c = createCipheriv("aes-256-gcm", k, nonce(dir, counter), { authTagLength: 16 });
  c.setAAD(aad(dir, T_DATA, counter));
  const ct = Buffer.concat([c.update(plaintext), c.final(), c.getAuthTag()]);
  return { plaintext, frame: Buffer.concat([header(T_DATA, counter), ct]) };
}

function open(dir, frame, k = key[dir], roomText = room) {
  if (frame.length < 10 + 16 + 128 || frame[0] !== VER || frame[1] !== T_DATA) return null;
  const counter = frame.readBigUInt64BE(2);
  const body = frame.subarray(10);
  const d = createDecipheriv("aes-256-gcm", k, nonce(dir, counter), { authTagLength: 16 });
  d.setAAD(aad(dir, T_DATA, counter, roomText));
  d.setAuthTag(body.subarray(body.length - 16));
  try {
    return Buffer.concat([d.update(body.subarray(0, body.length - 16)), d.final()]);
  } catch {
    return null;
  }
}

// ── handshake frames ────────────────────────────────────────────────────────────
const initMac = hmac(kAuth, "init", room, nPhone);
const acceptMac = hmac(kAuth, "accept", room, nPhone, nPc);
const initFrame = Buffer.concat([header(T_INIT, 0), nPhone, initMac]);
const acceptFrame = Buffer.concat([header(T_ACCEPT, 0), nPc, acceptMac]);

// ── data frames ─────────────────────────────────────────────────────────────────
const longLine = JSON.stringify({ type: "sessions", sessions: Array.from({ length: 3 }, (_, i) => ({ pillId: "integration_claude", agent: "Claude Code", state: "working", statusText: `step ${i}`, stepIndex: i, stepCount: 9, updatedAt: 1760000000000 + i })) });
const cases = [
  ["p2h", 0, JSON.stringify({ type: "hello", v: 1, token: "TOKEN-for-tests-only", device: "Test phone" })],
  ["h2p", 0, JSON.stringify({ type: "welcome", v: 1, desktop: "Test PC", os: "linux" })],
  ["p2h", 1, JSON.stringify({ type: "ping" })],
  ["h2p", 1, longLine],
  ["h2p", 2, JSON.stringify({ type: "pong" })],
  ["p2h", 4294967295, JSON.stringify({ type: "ping" })], // the last counter of a session (2^32 - 1)
].map(([dir, counter, line]) => {
  const { plaintext, frame } = seal(dir, counter, line);
  return { dir, counter, line, nonce: hex(nonce(dir, counter)), aad: hex(aad(dir, T_DATA, counter)), plaintext: hex(plaintext), frame: hex(frame) };
});

// ── frames that must be refused ─────────────────────────────────────────────────
const good = fromHex(cases[0].frame);
const flip = (buf, at) => {
  const b = Buffer.from(buf);
  b[at] ^= 0x01;
  return b;
};
const negatives = [
  { name: "a bit flipped in the ciphertext", dir: "p2h", frame: hex(flip(good, good.length - 20)), expect: "bad_tag" },
  { name: "a bit flipped in the tag", dir: "p2h", frame: hex(flip(good, good.length - 1)), expect: "bad_tag" },
  { name: "the counter in the header changed", dir: "p2h", frame: hex(flip(good, 9)), expect: "bad_tag" },
  { name: "the frame type changed", dir: "p2h", frame: hex(flip(good, 1)), expect: "bad_header" },
  { name: "an unknown version", dir: "p2h", frame: hex(flip(good, 0)), expect: "bad_header" },
  { name: "a phone frame presented as a computer frame (reflection)", dir: "h2p", frame: cases[0].frame, expect: "bad_tag" },
  { name: "truncated", dir: "p2h", frame: hex(good.subarray(0, good.length - 1)), expect: "bad_tag" },
  { name: "shorter than a header and a tag", dir: "p2h", frame: hex(good.subarray(0, 20)), expect: "bad_header" },
  { name: "another room", dir: "p2h", room: b64url(seq(0xb0, 16)), frame: cases[0].frame, expect: "bad_tag" },
  { name: "another key", dir: "p2h", key: hex(seq(0x80, 32)), frame: cases[0].frame, expect: "bad_tag" },
];
for (const n of negatives) {
  const k = n.key ? fromHex(n.key) : key[n.dir];
  const opened = open(n.dir, fromHex(n.frame), k, n.room ?? room);
  if (opened) throw new Error(`negative vector was accepted: ${n.name}`);
}
// Sequences the counter rule must refuse (the frames themselves are valid).
const sequences = [
  { name: "the same frame twice (replay)", dir: "p2h", counters: [0, 0], accepted: [true, false] },
  { name: "a frame going back", dir: "p2h", counters: [0, 1, 0], accepted: [true, true, false] },
  { name: "a gap (a frame was dropped)", dir: "p2h", counters: [0, 2], accepted: [true, false] },
  { name: "the first frame is not counter 0", dir: "p2h", counters: [1], accepted: [false] },
];

// ── self-checks: the primitives, and "no (key, nonce) pair twice" ───────────────
// RFC 5869 appendix A.1.
{
  const ikm = Buffer.alloc(22, 0x0b);
  const salt = fromHex("000102030405060708090a0b0c");
  const info = fromHex("f0f1f2f3f4f5f6f7f8f9");
  const okm = hex(hkdf(ikm, salt, info, 42));
  if (okm !== "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865") throw new Error("HKDF does not match RFC 5869");
}
{
  const seen = new Set();
  const note = (dir, counter, k) => {
    const id = `${hex(k)}:${hex(nonce(dir, counter))}`;
    if (seen.has(id)) throw new Error(`(key, nonce) used twice: ${dir} ${counter}`);
    seen.add(id);
  };
  // Both directions of this session, then a second session with fresh nonces (as after a reconnect).
  const second = hkdf(K, Buffer.concat([seq(0x50, 16), seq(0x70, 16)]), `${LABEL} session`, 64);
  for (const [k1, k2] of [[key.p2h, key.h2p], [second.subarray(0, 32), second.subarray(32, 64)]]) {
    for (let c = 0; c < 2000; c++) { note("p2h", c, k1); note("h2p", c, k2); }
  }
  if (hex(key.p2h) === hex(key.h2p)) throw new Error("the two directions share a key");
  if (hex(key.p2h) === hex(second.subarray(0, 32))) throw new Error("two sessions share a key");
  // Even if a bug made both directions use one key, the direction byte alone keeps the nonces apart.
  if (hex(nonce("p2h", 5)) === hex(nonce("h2p", 5))) throw new Error("the direction is not in the nonce");
}

const out = {
  _about: "Generated by android/relay/tools/gen-vectors.mjs. Do not edit by hand: change the script and regenerate. All byte strings are lowercase hex unless noted.",
  version: VER,
  label: LABEL,
  frameTypes: { init: T_INIT, accept: T_ACCEPT, data: T_DATA },
  directions: DIR,
  rfc5869_a1: {
    ikm: "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b",
    salt: "000102030405060708090a0b0c",
    info: "f0f1f2f3f4f5f6f7f8f9",
    length: 42,
    okm: "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
  },
  inputs: { key: hex(K), roomBytes: hex(roomBytes), room, nPhone: hex(nPhone), nPc: hex(nPc) },
  derived: {
    kAuth: hex(kAuth),
    kJoin: hex(kJoin),
    joinVerifier: hex(createHash("sha256").update(kJoin).digest()),
    kP2H: hex(key.p2h),
    kH2P: hex(key.h2p),
  },
  init: { macInput: hex(Buffer.concat([Buffer.from("init"), Buffer.from(room), nPhone])), mac: hex(initMac), frame: hex(initFrame) },
  accept: { macInput: hex(Buffer.concat([Buffer.from("accept"), Buffer.from(room), nPhone, nPc])), mac: hex(acceptMac), frame: hex(acceptFrame) },
  data: cases,
  mustRefuse: negatives,
  mustRefuseInOrder: sequences,
};

const text = JSON.stringify(out, null, 2) + "\n";
if (process.argv.includes("--check")) {
  const have = readFileSync(OUT, "utf8");
  if (have !== text) {
    console.error("android/relay/test-vectors.json is not what gen-vectors.mjs produces. Run: node android/relay/tools/gen-vectors.mjs");
    process.exit(1);
  }
  console.log("test vectors are up to date");
} else {
  writeFileSync(OUT, text);
  console.log(`wrote ${OUT}`);
}
