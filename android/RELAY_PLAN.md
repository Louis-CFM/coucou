# Relay plan: Coucou for Android away from home Wi-Fi (PROPOSAL, nothing is built)

Status: **approved by the user on 2026-10-10**, with the decisions and two additions below. Implementation goes stage by stage
(R0 first); the user is told the commit id after each stage. Nothing is deployed, published or sent to Louis, and Louis's
`relay/` is not touched. The earlier "stage G" (VPN switch) was built and then removed at the user's request; this plan replaces it.

### Approval record

- **D1 yes** (`tokio-tungstenite` on the PC). **D2 yes**: in-house WebSocket client on Android, with tests for framing, masking,
  fragmentation, oversized frames and a malformed-input fuzz test; **OkHttp stays the fallback**. **D3 yes** (no forward secrecy
  for now). **D4 yes** (one phone per room). **D5 yes** (`android/relay/`). **D6 yes** (no FCM for now). **D7 yes** (pad to 128).
  **D8 yes** (join proof in memory only).
- **Addition 1, deploy-time access key.** The relay creates or joins rooms only for requests carrying a random 256-bit access key
  the user sets at deploy time as a Worker secret (`wrangler secret put ACCESS_KEY`, never in git). The PC setting and the
  pairing link carry it (the link is the only place the phone learns it). The relay **still never sees any content key**. It
  is checked before any room is created, in constant time, and **the relay fails closed** (no key configured = every room
  request refused). Rotation is documented in `docs/RELAY_LINK.md` section 7: set the new secret, paste it on the PC; live
  sockets are closed at their next frame; the PC tells paired phones the new key inside the encrypted channel (`relayAccess`),
  so they do not have to scan again. This also closes the "burn the free quota with random rooms" hole of section 5: that now
  needs the access key.
- **Addition 2, separate directions.** Each direction has its **own key** (`k_p2h`, `k_h2p`) **and** a direction byte in the
  nonce (`nonce = direction ‖ 000 ‖ counter`), so a (key, nonce) pair cannot repeat across directions even if one of the two
  protections had a bug; counters only go up by one; every connection derives fresh keys. The generator of the test vectors
  asserts "no (key, nonce) twice" over thousands of frames, both directions and two sessions; R2 repeats it in Rust and Kotlin.
- **Stage R0 (done):** `docs/RELAY_LINK.md` (the wire spec) and `android/relay/test-vectors.json` with its generator.

Sources read: `docs/ANDROID_LINK.md`, `relay/README.md` and `relay/src/index.ts` (Louis's APNs
relay, for style), the former parity plan (stage G, row 16; deleted in the cleanup, it is in the git history), `CLAUDE.md`, and the phone-link code on both sides.

## 1. Goal and non-goals

**Goal.** The phone and the PC sync over the internet from different networks (phone on mobile data, PC on home
Wi-Fi), with no USB, no VPN and no shared Wi-Fi. The direct LAN link stays as the fast path and is tried first.

**Non-goals.**
- No accounts, no sign-in, no database, no analytics, no push provider.
- No change to protocol v1: sessions, approvals, decisions, chat, diffs and the rest ride inside the secure channel as they are.
- No built-in third-party endpoint: the relay URL is empty until the user enters one (section 9).
- Stage I (running instructions on the PC) stays "not planned".
- Nothing is deployed or published by me. The user deploys with their own Cloudflare account.

## 2. Architecture in one picture

```
 PC (Coucou, Rust)  ──outbound WSS──►  Cloudflare Worker  ──►  Durable Object "room"  ◄──  outbound WSS ──  Phone (Kotlin)
                                        (routes by room id)     (forwards opaque frames)
        └────────────────── direct LAN link (TLS, pinned) stays the fast path ──────────────────┘
```

- **Relay** = one Cloudflare Worker plus one Durable Object class, `Room`. The object's name is the room id. A room
  holds at most two live WebSockets: one with role `pc`, one with role `phone`.
- It **forwards binary frames from one socket to the other and nothing else.** It cannot read them (they are end-to-end
  encrypted), stores nothing (no database, no KV, no R2, no storage API call), logs nothing (observability off, as in
  Louis's `wrangler.toml`), has no accounts and holds no secret at all (unlike Louis's relay, which holds the APNs key).
- **Both sides connect outward**, so no port opening, no router setting, no dynamic DNS. Works behind NAT and carrier NAT.
- The Durable Object uses the **WebSocket Hibernation API**, so an idle room is not billed for duration and holds no memory.
  Keep-alive pings are answered by the platform (`setWebSocketAutoResponse`) without waking the object.

URL shape: `wss://<the user's worker>/v1/room/<roomId>?role=pc|phone`.

## 3. Pairing and keys

The pairing link and QR gain optional fields (old phones ignore unknown keys and keep pairing over the LAN only):

```
coucou://pair?v=1&host=...&port=...&fp=...&token=...&name=...&relay=wss%3A%2F%2Fmy-relay.example.workers.dev&room=<22 chars>&key=<43 chars>
```

- `room`: 128 random bits (base64url, 22 characters). Unguessable. It is a locator, not a secret the design leans on.
- `key` (**K**): 256 random bits (base64url, 43 characters), created on the PC from the OS random source. Shown only in the
  pairing code. Stored on the PC in the OS keystore (the same `keyring` store as the pairing token) and on the phone
  encrypted by the Android Keystore (the same `SecureStore` as the token). Never written to a log, a file or the relay.
- The existing LAN `token` stays: it keeps authenticating the phone to the PC inside the channel (defence in depth).
- The phone shows `relay` (the host name) in the existing "Pair with this computer?" confirmation, so the user sees which
  server is going to carry the traffic before pairing.

**Derived values** (HKDF-SHA-256, RFC 5869, no new dependency: `ring` on the PC, `javax.crypto.Mac` on Android):

| name | derivation | use |
|---|---|---|
| `K_auth` | `HKDF(K, info="coucou-relay/v1 auth")` | MACs the two handshake frames |
| `K_join` | `HKDF(K, info="coucou-relay/v1 join")` | presented to the relay as a join proof (section 6) |
| `k_p2h`, `k_h2p` | `HKDF(K, salt = N_phone ‖ N_pc, info="coucou-relay/v1 session")`, 32 bytes each | session keys, one per direction |

**Cipher.** AES-256-GCM (hardware-accelerated on both sides; `ring::aead` and `javax.crypto`, so no new crate or library).
One key per direction and per connection, and a **96-bit nonce = direction byte ‖ 3 zero bytes ‖ 64-bit frame counter** (addition 2). A counter nonce
is safe here because the keys are fresh for every connection (a restart cannot reuse a (key, nonce) pair). Random
nonces are not used. A session ends at 2^32 frames and re-handshakes.

**Handshake** (the phone initiates; the PC only answers; the relay's "peer is here" notice is only a hint):

1. Phone connects, then sends `init`: `N_phone` (16 random bytes) + `HMAC(K_auth, "init" ‖ room ‖ N_phone)`.
2. PC checks the MAC, picks `N_pc`, sends `accept`: `N_pc` + `HMAC(K_auth, "accept" ‖ room ‖ N_phone ‖ N_pc)`.
   Because the MAC covers the phone's *current* nonce, an old recorded `accept` is rejected.
3. Both derive `k_p2h` and `k_h2p`. The first data frame each way proves the other side holds K.
4. Inside the channel the existing v1 `hello`/`welcome` run as today (token, caps, protocol version).
5. If either side reconnects, steps 1 to 4 run again with fresh nonces: new keys, counters back to 0.

**Frame** (WebSocket binary message): `ver(1) ‖ type(1) ‖ counter(8) ‖ AES-GCM(ciphertext ‖ tag)`.
- AAD = `"coucou-relay/v1" ‖ room ‖ direction ‖ ver ‖ type ‖ counter`. A frame cannot be moved to another room, turned
  around, or have its header changed.
- Data frames carry exactly one v1 line (UTF-8 JSON, at most 64 KiB, as on the LAN), padded to a multiple of 128 bytes
  so the size does not tell "ping" from "approval" (decision D7).
- **Replay and reordering:** the receiver requires the counter to be exactly the previous one plus 1. Anything else
  (repeat, gap, jump back) tears the session down and re-handshakes. Duplicates are never delivered. Frames from an old
  session fail authentication because the keys differ.
- **Key rotation:** "Pair again" on the PC makes a new K and room, disconnects the old phone, and the old room stays
  empty forever. Session keys already rotate on every connection.

**Known limit, said plainly:** the session keys come from K and the two nonces only, so there is **no forward secrecy**.
If K ever leaks, traffic someone recorded earlier could be decrypted. Adding an X25519 key agreement would fix that;
`ring` has it, but Android's `KeyAgreement("X25519")` only exists from API 33 (our minSdk is 30), so it would need a small
hand-written implementation. Decision D3 below; my recommendation is to ship without it and add it later if wanted.

## 4. How protocol v1 rides inside, unchanged

On the PC the existing server logic already runs over "any byte stream" (`server::run_with`). The relay client presents
the decrypted frames as a newline-delimited stream to that same code, so `hello`, `welcome`, `sessions`, `approval`,
`approvalResolved`, `decision`, `ping/pong`, `chat*`, `question/answer`, `getDiff/diff`, `usage`, `services`, `prefs` and
their per-feature switches work **byte for byte as on the LAN**. On the phone, `LinkClient` gets a second connector
(relay) next to the TLS-socket one. Nothing in `Protocol.kt` or `hub.rs` changes.

What stays exactly as strict as on the LAN:

| rule | on the relay |
|---|---|
| approval `fingerprint` (SHA-256 of pill, session, tool, command, input key) | unchanged; the decision names it, the PC applies it only to the approval **still pending** |
| 120 s offer / 115 s PC dismissal | unchanged; the phone's timer and the PC's both run locally, the relay has no clock role |
| decide once | unchanged; a second or late decision is ignored by the PC (`Hub::decide`) |
| Allow needs the biometric or screen lock | unchanged; it is a phone-side gate before the `decision` is even built |
| Deny does not | unchanged |
| no "always allow" from the phone | unchanged |
| per-feature PC switches (details, answers, diffs, usage, services, chat) | unchanged; re-read per connection |
| command hidden on the lock screen; labels only on Home, island, notifications | unchanged (security hardening just done) |

The relay adds **no new message that can approve anything**. Its own hints (peer online/offline) are shown as status
only and are never trusted for a decision.

## 5. Abuse and safety

| threat | what happens |
|---|---|
| **Guessing a room id** | 128 bits: not feasible. Even with the id, an attacker cannot read or forge frames (no K). The join proof (section 6) also stops them occupying the slot once a real side is in the room. |
| **Replay of a recorded frame** | Rejected: counter must be previous + 1, and old sessions used other keys. |
| **Malicious or compromised relay** | Can drop, delay or cut frames (availability), and see metadata (below). **Cannot read content, forge a frame, forge an approval, or forge Allow/Deny.** A forged or altered frame fails the GCM tag and tears the session down. |
| **Relay delays an approval** | The PC still only accepts a decision for the approval still pending; the phone offers it for at most 120 s from receipt; a late or duplicate decision is ignored. A delay cannot turn Deny into Allow. |
| **Relay drops a decision** | The approval times out on the PC and is not allowed. Failure is on the safe side. |
| **Relay truncates the end of a conversation** | Undetectable (a close looks like a close). It is a denial of service, not a break. |
| **Stolen phone** | Has K and the token, but Allow still needs the biometric or screen lock; Deny does not. The user does "Pair again" on the PC: new K and room, the stolen phone is cut off at once. Phone-side storage is Keystore-encrypted. |
| **Stolen PC / PC compromise** | Out of scope: it holds the agents and the keys anyway. |
| **Eavesdropper on the network** | Sees TLS to the relay (and E2E ciphertext inside). |
| **Flooding the relay** | Per-room message token bucket in the object (about 30 messages/s sustained, burst 60) and a per-IP connect limit at the Worker (Workers Rate Limiting binding); frame limit 66 KiB (anything bigger closes the socket with 1009); 2 sockets per room, newest of a role replaces the oldest only if it presents the join proof; the room id format is checked in the Worker before any object is created, so malformed paths cost nothing. |
| **Creating many empty rooms to burn the free quota** | Needs the deploy-time access key (addition 1); a request without it is refused with `401` before any room exists. Someone who holds the key (every paired phone does) could still burn the quota; the fix is to rotate the access key (docs/RELAY_LINK.md section 7). If the quota is exhausted the app falls back to the LAN and shows "Relay unavailable"; the paid Workers plan removes the cap. |
| **Reflection** (sending a side's own frame back) | Different key per direction and the direction in the AAD: rejected. |
| **Downgrade** (pretending the peer has no relay) | Not a downgrade: the LAN path is a separate, equally strict, pinned-TLS path. |
| **Phone talks to a fake PC through the relay** | The fake has no K: its `accept` MAC fails. |
| **Two phones** | v1 of the relay supports one phone per room (D4); a second phone is a second pairing. The LAN link keeps supporting several. |

**What the relay operator (the user, on their own Cloudflare account) and Cloudflare can learn:** the IP addresses of the
PC and phone, that a pairing exists (the room id is stable per pairing), when each side is online, frame sizes
(padded to 128 bytes) and timing, so roughly "something is happening". **They cannot learn:** any session name, command,
path, approval, chat text or file name, and not K.

## 6. The relay's rules, in detail

- `GET /` answers `Coucou link relay` (a health check, like Louis's).
- `GET /v1/room/<id>?role=pc|phone` with `Upgrade: websocket`; `<id>` must be 22 base64url characters, else 404 before any
  object is touched; `Authorization: Bearer <access key>` must match the Worker secret (401, constant-time, fail closed).
  Sub-protocol offer `coucou.v1, coucou.join.<K_join>` carries the join proof (base64url of 32 bytes). The wire is specified in `docs/RELAY_LINK.md`.
- **Join proof, held in memory only:** the first socket of a room sets `verifier = SHA-256(K_join)` in the socket's
  hibernation attachment (not storage). Later sockets must present a `K_join` that hashes to the same value or are refused
  (1008). When the room is empty the verifier is gone, so nothing is ever stored. Consequence: an attacker who knows the
  room id could squat an *empty* room before its owner connects; they still could not read or inject anything, and the
  legitimate PC would be refused until the squatter leaves, so the PC would show "Relay room is taken" and "Pair again"
  would fix it. I think that trade-off is right; the alternative (persisting a verifier) would make the relay stateful.
- Hints sent by the relay as small text messages (`{"peer":"online"|"offline"}`) when the other side joins or leaves.
- A role's new connection replaces the old one only with a valid proof (closes it with 1000 "replaced").
- Keep-alive: a client text `ping` is answered `pong` by the platform without waking the object. No idle timer in the relay (a timer would wake the room); clients judge liveness themselves.
- Limits: 66 KiB per frame, token bucket per room, 2 sockets per room, no queueing (a frame for an absent peer is dropped,
  and the sender hears `{"peer":"offline"}`). No message is ever buffered, so nothing is stored by accident.
- `wrangler.toml`: `[observability] enabled = false`, `new_sqlite_classes = ["Room"]` (Durable Objects on the free plan need the
  SQLite-backed class; we do not use its storage), no `[vars]` with secrets. The one secret, `ACCESS_KEY`, is set with
  `npx wrangler secret put ACCESS_KEY` and is never in git.
- No third-party npm runtime dependencies in the Worker; dev dependencies: `wrangler`, `typescript`, `vitest`, `@cloudflare/vitest-pool-workers`.

## 7. Android in the background

Today `LinkService` is a foreground service of type `specialUse` that holds the LAN link, with a 20 s app-level ping.
The relay transport lives inside the same service. Design:

- **Transport choice:** try the saved LAN address first (2 s, as now), then NSD discovery, then the relay if the pairing has
  one. When on the relay, retry the LAN once a minute while on Wi-Fi (and at once when the Wi-Fi changes) and switch back,
  because the LAN is faster and costs the relay nothing. One transport is active at a time; a switch reconnects and the PC
  re-sends the snapshot and any pending approval (the existing reconnect behaviour).
- **Keep-alive:** a WebSocket ping every ~30 s answered by the platform (cheap for the relay), plus the existing encrypted v1
  `ping/pong` every 20 s from the phone only while the screen is on or an agent is working; with the screen off and nothing
  running, only the 30 s WebSocket ping. Carrier NATs often drop idle TCP flows between 30 s and a few minutes, so ~30 s is
  the safe side. This is the main battery cost: radio wake-ups every 30 s while paired and away. **I have not measured it.**
  The staging plan measures it with `dumpsys batterystats` over a night.
- **Doze:** I do not know for certain how Doze treats network access for a `specialUse` foreground service on the A12s
  (Android 13). It is the biggest unknown of this plan. The staging test (screen off, phone still, 30+ minutes, mobile data)
  answers it. If the connection is cut, the first fixes are the standard ones (battery-optimisation exemption, shown to the
  user with the exact setting); the next is FCM as a wake-up signal (below).
- **Reconnect:** exponential backoff from 1 s to 60 s with jitter, reset on success; immediate retry when the network
  changes (`NetworkWatch` exists); no retry loop while the phone has no network or the user disconnected.
- **FCM, and why not now.** FCM would wake the phone reliably in Doze, but it needs Google Play services and a Firebase
  project, the `google-services` plugin and `firebase-messaging` (a large closed-source dependency and a Google account in
  the chain), would not work on phones without Google services, and a relay would then need a server credential (a secret to
  guard). That is against "no third-party dependencies", against the "free of built-in third-party endpoints" goal, and
  against the project's no-Play-services rule (the QR scanner was built without it for the same reason). So: **not now.**
  If the Doze test shows the foreground service is not enough, I would propose FCM as an optional later stage carrying an empty
  "wake up" signal only (no content: the phone then opens the WebSocket and gets everything E2E), decided with you after the data.
- Notifications, the island and the biometric Allow are untouched: they react to the same `LinkListener` events.

## 8. Cost, hosting and limits

- **Who deploys:** you, with your own Cloudflare account (free). I write the Worker, a deploy guide and the commands; I do
  not deploy it and no secret exists to put in git.
- **Free-tier limits (from my memory of Cloudflare's published limits; I will re-check the pages before the deploy guide is written,
  and you should too):** Workers about 100,000 requests/day; Durable Objects about 100,000 requests/day, with incoming
  WebSocket messages counted at roughly 1/20 of a request, plus a daily duration allowance that hibernation keeps near zero
  while idle. Rough budget for one PC and one phone: a few thousand frames a day while agents work, 2,880 pings/day: on the
  order of a few hundred "requests" a day, far below the cap. A busy setup of ten paired phones is still comfortable.
- **When exceeded:** Cloudflare refuses requests until the daily reset; the relay is unavailable, the app says "Relay
  unavailable", the LAN keeps working, and nothing is lost (no data is stored anywhere). The paid Workers plan (about $5 a month)
  removes the cap.
- **Self-hosting:** the relay is about 150 lines of TypeScript with no secrets. I will also ship a Node reference
  (`dev-relay.mjs`, used by the tests) that speaks the same wire, so it can be run on a small VPS or a Raspberry Pi. Any
  server that forwards two WebSocket peers by room id and enforces the same limits works.
- **Configurable relay URL, default none:** Settings on the PC has a field, empty by default, and the relay is off. The
  phone receives the URL only through the pairing link and shows its host before pairing. The Android app has **no built-in
  endpoint**, and neither does the PC app. This matches `CLAUDE.md` ("network calls only to services the user configured").

## 9. Desktop side

- **Settings → Android phone → "Away from home (relay)":** a switch next to Phone link, **off by default** (`phoneRelay` in
  settings, owned by Rust like the other phone switches), the relay URL field (empty), a status line ("Off", "Connecting",
  "Connected, phone online", "Connected, phone offline", "Relay unavailable", "Room is taken") and a hint under the pairing code
  explaining that the link now also contains the key for the relay. Turning it on or off disconnects phones once, as the
  other switches do. Needs the Phone link switch on; turning on with an empty URL is refused with a clear message.
- **How the PC connects out:** an async task in the existing tokio runtime. It opens `wss://<relay>/v1/room/<room>?role=pc`,
  waits for the phone's `init`, answers `accept`, then runs the existing v1 server code over the decrypted stream. It never
  runs on the hook path: **it cannot block Claude Code** (rule from `CLAUDE.md`); if the relay is unreachable the agent is
  unaffected.
- **Admission:** the relay connection counts as one extra source in the existing admission policy and takes no LAN slot.
- **Sleep and network changes:** when the PC sleeps the socket dies; the phone sees "Computer offline" and shows nothing
  stale as live (it is marked offline within a few seconds of the relay's hint, and by the encrypted ping timeout otherwise).
  On wake the task reconnects with backoff, and the phone re-handshakes. Agents do not run while the PC sleeps, so nothing
  is missed; an approval that was pending when the PC fell asleep simply expires (the agent is not allowed). The PC does not
  keep itself awake for this.
- **Logging:** the relay URL host and status transitions only. Never K, tokens, frames, rooms or commands.

## 10. What Louis should be told (draft for the user to send, or not)

- Louis's `relay/` is a Cloudflare Worker that holds his **APNs key** and does one job: Live Activity pushes for the iPhone. It is
  not touched.
- The Android fork would add a **separate, key-less, user-deployed** relay (`android/relay/`, never under his `relay/`), used only
  by Coucou for Android, **off by default, with no URL built in**, and nothing flows to any server he runs or pays for.
- The PC-side part sits in `windows/src-tauri/src/phone_link/` behind an opt-in switch; if he ever wants it upstream it is a
  small, self-contained, reviewed change, and no PR is opened without the user's decision.
- No telemetry, no accounts, no third party in the data path except the user's own Cloudflare account, and the payload is
  end-to-end encrypted, so even that account cannot read it.

## 11. Stages

Each stage is a small series of commits with tests, "Phone link" CI green, `Co-Authored-By`, pushed only to `android`.

| # | Stage | What | Tests |
|---|---|---|---|
| R0 | Spec and vectors **(done)** | `docs/RELAY_LINK.md` (wire, access key, handshake, frame, limits, rotation) and `android/relay/test-vectors.json` + generator `android/relay/tools/gen-vectors.mjs` | generator self-checks (RFC 5869 vector, no (key, nonce) twice), CI `--check`, an independent Python re-computation; the vectors are used by R2 on both sides |
| R1 | Relay service **(done)** | `android/relay/` Worker + `Room` object, `wrangler.toml` (observability off, no secrets), `dev-relay.mjs` (Node twin for tests/self-host), deploy README | **vitest + miniflare** (`@cloudflare/vitest-pool-workers`): routing by id, bad ids refused before object creation, join proof, replacement rules, size limit 1009, token bucket, peer hints, no buffering when the peer is absent, **no storage calls**, no plaintext handling. `tsc` clean. |
| R2 | Secure channel core **(done)** | Rust module (`phone_link/relay_crypto.rs`: HKDF, AES-GCM frames, handshake, counters) and Kotlin twin (`link/RelayCrypto.kt`) with no I/O | RFC 5869 HKDF vectors; the shared vectors both ways; wrong key, wrong room, wrong direction, flipped bit, truncated, replay, gap, reorder, old `accept`, counter limit; K never in `Debug`/`toString`/log text (a test greps); cross-language: Rust decrypts what Kotlin made and the reverse |
| R3 | PC client **(done)** | WS client task (**D1**), settings `phoneRelay` + URL, pairing link fields, status, Settings UI block + 9-language strings, admission, "Pair again" rotates K and room | Rust tests with an in-process fake relay; settings tests (off by default, wrong type stays off); i18n test; a flood/disconnect test; the PC never blocks on an unreachable relay |
| R4 | Android client **(done)** | WS client (**D2**), `RelayConnector` for `LinkClient`, transport selection (LAN first, relay fallback, LAN retried), SecureStore for K, pairing parser, "Away from home Wi-Fi" card in Settings, debug trigger | Kotlin tests: WS framing against the Node twin, handshake, selection and switch-back rules (pure, fake clock), parser accepts old and new links, K stored only encrypted |
| R5 | End to end and CI **(done)** | CI job runs the **real Worker under `wrangler dev` (miniflare)** and connects the Rust PC client and the Kotlin phone client through it: sessions, an approval, deny, allow-gate unchanged, decide-once, PC restart, phone restart, "Pair again" cuts the old phone | the full v1 suite once more over the relay; interop tests |
| R6 | Review **(done)** | a written threat-model check against section 5 with a test or an explicit "cannot test" for every row; deploy guide; staging checklist | as above |

### Findings while building R1

- The Workers test plugin was renamed upstream: R1 uses `@cloudflare/vitest-plugin` 1.4.0 (the old `vitest-pool-workers` is
  deprecated) with `vitest` 4.1.x. npm's resolver crashes on its peer range, so `android/relay/.npmrc` sets `legacy-peer-deps`.
- The sub-protocol offer is `coucou.v1, coucou.join.<proof>` (a strict client needs the server's choice to be one it offered).
- The relay has no idle timer (it would wake the room); the heartbeat is a text `ping` answered `pong` by the platform.
- The Workers Rate Limiting binding works in workerd; the tests raise its limit and the 429 path has its own test.
- Wrangler may send anonymous usage statistics (Cloudflare's tool, not ours): the guide says how to turn it off.

### Findings while building R2

- Rust (`phone_link/relay_crypto.rs`, `ring`: HKDF, HMAC, AES-256-GCM, no new crate) and Kotlin (`link/RelayCrypto.kt`,
  `javax.crypto`, a hand-written 20-line HKDF checked against RFC 5869) both reproduce **every byte** of
  `android/relay/test-vectors.json`, which Node and an independent Python implementation also produced. Because the vectors are
  deterministic, "Rust reads what Kotlin wrote and the reverse" holds byte for byte.
- A mutation test found a gap in my first Rust tests (both directions sharing one key went unnoticed because the vectors were
  checked with the helper functions, not with the `Session` itself). Fixed: both twins now have a test where the sessions
  themselves must reproduce the vector frames in each direction.
- A frame whose counter byte is altered is refused by the counter rule (`BadCounter`) before its tag is looked at; the vector
  file calls that case a bad tag, either way it is refused and the session is dead.
- No forward secrecy, as decided (D3).

### Decisions (all answered yes; the text is kept for the record)

- **D1, WebSocket on the PC:** add the small `tokio-tungstenite` crate (MIT, rustls) or hand-write the WebSocket client over the
  `tokio-rustls` we already have. Recommendation: the crate (a hand-rolled framing/handshake is where subtle bugs live; one
  well-known dependency, justified in the commit as `CLAUDE.md` requires).
- **D2, WebSocket on Android:** OkHttp (large, well-tested, Apache 2.0) or a minimal in-house client over `SSLSocket` (about
  250 lines: text/binary/ping/pong/close, no extensions; tested against the Node twin and the Worker). Recommendation: in-house,
  to keep the "no third-party dependency" rule; fall back to OkHttp if it proves flaky in staging.
- **D3, forward secrecy:** ship now without it (recommended) or add an X25519 exchange first (needs a hand-written X25519 on
  Android below API 33).
- **D4, one phone per room** in v1 of the relay (recommended); more phones = more pairings.
- **D5, location:** `android/relay/` (recommended, so Louis's `relay/` is never touched) versus a new top-level folder.
- **D6, FCM:** not now, revisit after the Doze test (recommended).
- **D7, size padding to 128 bytes** (recommended; costs a few bytes per frame).
- **D8, join proof held in memory only,** with the squatting trade-off in section 6 (recommended), versus persisting a verifier.

## 12. Deploy guide (written in R6: `docs/RELAY_DEPLOY.md` is the real one; this outline is kept for the record)

```
cd android/relay
npm install
npx wrangler login
npx wrangler deploy            # prints https://coucou-link.<you>.workers.dev
curl https://coucou-link.<you>.workers.dev/   # "Coucou link relay"
```

One secret is needed, the access key, and it never goes in git: `openssl rand -base64 32 | tr '+/' '-_' | tr -d '='` to make it, then `npx wrangler secret put ACCESS_KEY` and paste it. The relay holds no content key. `wrangler.toml` contains no key. On the PC: Settings → Android phone →
"Away from home (relay)": paste the URL and the access key (write-only field, stored in the OS keystore), switch on, show the pairing code. On the phone: pair again (scan), check the host shown.

## 13. Staging test plan (the real, numbered checklist is in `docs/RELAY_DEPLOY.md` section 4)

1. Deploy as above. Confirm `curl` answers. In the Cloudflare dashboard confirm **Observability/logs are off** (we never log payloads).
2. PC: switch the relay on, paste the URL, show the pairing code. Status should read "Connected, phone offline".
3. Phone: turn Wi-Fi **off** (mobile data only), scan the code, read the host in the confirmation, pair.
   Expect: "Away from home Wi-Fi: connected via relay" and the PC shows "phone online".
4. Start an agent on the PC: sessions appear on the phone. Trigger a permission request: the sheet appears, Deny works, Allow asks for the
   screen lock, then the agent proceeds. Press the same decision twice quickly: the second is ignored.
5. Let a request sit 2 minutes: it expires on both sides, and a late tap is refused.
6. Put the phone on the home Wi-Fi: it switches to the direct link within a minute, and back to the relay when you leave.
7. Sleep the PC for a minute, wake it: the phone shows "Computer offline", then recovers by itself.
8. Kill the relay URL (change it on the PC): the PC shows "Relay unavailable", the agent is never delayed, and the LAN still works at home.
9. "Pair again" on the PC: the phone is cut off at once and must scan the new code; the old phone cannot reconnect.
10. **Doze/battery:** phone on mobile data, screen off, stationary, 30 minutes: does an approval still arrive? Then overnight:
    `adb shell dumpsys batterystats --reset` before, `--charged com.coucou.android` after; report the percentage used.
11. `npx wrangler tail` during a session: it should show connections and **no frame contents** (there are none to show).

## 14. What I will not be able to test, said now

- Doze and carrier-NAT behaviour on a real phone (only you can, section 13).
- The Cloudflare free-tier limits and billing (from memory; verify on their pages; the deploy is yours).
- Real battery cost.
- The Windows build against a real WebSocket server (CI covers Windows tests, not a live relay).
- That Cloudflare's WebSocket Hibernation and auto-response behave as documented in production (miniflare approximates them).

## 15. Rules kept

Nothing published, no release, no store listing, no PR to upstream; commits end with
`Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; pushes only to `android`; the Android app stays English only;
new PC strings get the nine translations; `change log.md` stays local; secrets in the keystores; no telemetry; the agent is never blocked;
no permission is ever approved without an explicit click and the phone's screen-lock check.

### Findings while building R3

- The WebSocket framing is `tokio-tungstenite` 0.26 with **no TLS feature** (D1): TLS is the `tokio-rustls`/`ring` already in the
  tree, with the web roots (`webpki-roots`) that `reqwest` already pulled in, so no second crypto provider (aws-lc) is added. New
  direct dependencies: `tokio-tungstenite`, `webpki-roots`, `futures-util` (sink trait only); `tokio` gained `macros`.
- The relay client is one task (`phone_link/relay_client.rs`). It reuses the LAN server's conversation code unchanged: decrypted
  lines go into an in-memory pipe whose other end is `server::run_with`, exactly the function the TLS path uses, so fingerprints,
  120 s offers, decide-once, per-feature switches and the token check are the same code, not a copy. A test sends a wrong token
  and a wrong fingerprint through the relay and gets the same refusals as on the LAN.
- **Admission.** Everything arriving through the relay is one source (`192.0.2.255`, a documentation address that is never
  routable) with one slot at a time. A newer `init` replaces the previous conversation, so a flood of `init` frames cannot take
  more than one slot; 3 bad handshake frames silence `init` for 10 s.
- Secrets: the access key, the room and K are in the OS keystore (`phone-relay-access/-room/-key`), `Credentials` and the pairing
  key print as `(..)`, the module has no logging at all (a test reads its source), and the Settings window can only write the
  access key (the status it gets back says whether one is stored).
- "Pair again" now also makes a new room and a new K, then reconnects, so a phone holding the old ones is cut off at the relay as
  well as at the PC.
- `relay` capability: offered to a phone that asks for it only while the relay switch is on; when the access key is replaced, the
  phones that negotiated it are sent `relayAccess` inside the encrypted channel (an older phone is never sent it).
- A test that replays a recorded frame, flips a frame and sends frames sealed under old session keys shows each one ends the
  conversation and gives the slot back.
- Not tested here: a real Cloudflare relay (R5 runs the real Worker under `wrangler dev`) and a real phone (R4).

### Findings while building R4

- **The WebSocket client is ours (D2)**: `link/WebSocket.kt`, about 350 lines, no library. Tests for framing (RFC 6455 section 5.7 examples, every
  length boundary), masking (fresh mask per frame, an unmasked client frame is a bug), fragmentation (with a ping in between, a UTF-8
  character split across fragments), oversize (a header claiming 1 GiB is refused before anything is allocated; a message over the limit
  even in small fragments), the server rules (reserved bits, masked server frames, fragmented or long control frames, unknown opcodes,
  bad close codes), a truncated stream, 30,000 random inputs and 20,000 bit-flipped valid streams (only a protocol error or end of stream
  may come out), and the upgrade (RFC accept value, header injection, every wrong response). Six mutations (no masking, masked server
  frames accepted, no size limit, no relay-first window, an accept for another init, partial relay fields accepted) are each caught.
  OkHttp stays the fallback; `RelayGuardsTest` fails if any WebSocket library is added to Gradle without this decision being revisited.
- **Checked against someone else's WebSocket**: `RelayNodeTwinTest` talks to the relay's Node twin (the `ws` package, a separate
  implementation of the RFC): both directions, five 40 KB lines in a row, the unchanged `LinkClient` hello/welcome, a wrong access key
  (401), a wrong pairing key in a room in use, a computer that is not there, one that joins later, one that leaves, and a second phone
  replacing the first. It runs when `COUCOU_NODE_RELAY=1` (CI does `npm ci` in `android/relay` first); everything else runs everywhere.
- The Node twin refused to start on Node 22 because `Bucket` used a constructor parameter property, which Node's type stripping does not
  allow although the file said "erasable TypeScript only". Fixed in `src/protocol.ts` (plain fields); the relay's own tests still pass.
- **`LinkClient` did not change** except for the new capability: the relay is a `Connector` returning a `Socket` whose bytes are the
  encrypted lines (`RelayStreamSocket`). A test runs the real `LinkClient` over it (hello, welcome, approval, decision).
- **Selection rules** are pure (`TransportPolicy`, tested with a fake clock): LAN first with a 2.5 s timeout, the relay when the LAN does
  not answer, the relay first for 60 s after a LAN failure (with the LAN as fallback if the relay fails too), a LAN probe every 90 s
  and on a network change while on the relay, and a switch back as soon as the LAN answers. The probe is one pinned TLS handshake that
  is closed at once; it runs only while the link is on the relay.
- A failure to write `init` hid the relay's close reason (the connection was already gone): the connector now reads the close frame
  after a failed write, so "room is taken" is told apart from "network dropped". Found by a test.
- The pairing, K and the access key stay in the same Keystore-encrypted blob as the token (`PairingCodec`; a pairing saved by an older
  build loads as LAN-only). Nothing in the new code logs, and a test fails if a log line in `AppModel` names a relay secret.
- New Settings card "Away from home Wi-Fi" (a switch, on by default, shown only when the pairing has a relay, and one sentence saying
  how the phone is connected right now or why not). (A debug-only broadcast that skipped the direct link was removed in the cleanup.)
- Not tested here: Compose and lint (CI only), a real phone, the Doze behaviour and battery cost of the foreground-service WebSocket, and
  real Cloudflare. R5 runs the Rust PC against the Kotlin phone through the real Worker.

### Findings while building R5

- `android/relay/tools/e2e.sh [worker|node]` starts the relay (the real Worker under `wrangler dev`, i.e. workerd on this machine, or
  the Node twin) on 127.0.0.1 with fixed test credentials, runs the **Rust** computer side
  (`relay_client::tests::e2e_the_computer_side_for_the_phone_test`, ignored by default) and the **Kotlin** phone side
  (`RelayE2ETest`) together, and reports OK only when the phone's decision reached the computer: the real `relay_client.rs`, the real
  `LinkClient` over the in-house WebSocket, the real hub and the real relay code in between. Both modes passed here. It also checks the
  Worker's `401` for a wrong access key.
- This is the first test where Rust and Kotlin talk to each other through the relay, not only through shared vectors. It found nothing
  to fix, which is also a result.
- CI job `relay-e2e` runs both modes on every push. It deploys nothing and the relay listens on loopback only.
- Still not covered: real Cloudflare (hibernation timing, the real rate-limit binding across data centres, the 100 s idle behaviour of
  a WebSocket without traffic) and a phone on mobile data. That is the staging test (`docs/RELAY_DEPLOY.md`).

### Findings while building R6

- The threat check is in `android/RELAY_THREAT_CHECK.md`: every row of section 5 with the test that fails if it stopped being true, and
  what is accepted or not covered. Reading the code again as an attacker found two real problems, both fixed with tests: the phone
  refused links over 1,024 characters, which the relay fields plus a long accented computer name could exceed (limit now 2,048, and a
  Rust and a Kotlin test build the longest realistic link and check the parser and the QR); and the phone's pairing confirmation did not
  show the relay's host as the spec says (it does now). Two further tests were added for rows that had none (a fake computer without K,
  and "Pair again" cutting off the old pairing).
- The deploy guide and the staging checklist for the phone on mobile data and the computer on home Wi-Fi are `docs/RELAY_DEPLOY.md`.
- What is still open is only what cannot be done here: a real phone (Doze, battery), real Cloudflare, and the look of the Settings card.
