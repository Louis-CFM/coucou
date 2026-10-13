# Relay: threat-model check (stage R6)

A line-by-line check of `RELAY_PLAN.md` section 5 against what was built. For each threat: what stops it, **which test would fail
if that stopped being true**, and what is accepted or not covered. Written after the code, by reading it again as an attacker,
not from the plan. "Not testable here" means exactly that; it is not a claim that it works.

Test names are abbreviated: *Rust* = `windows/src-tauri/src/phone_link/` (`relay_crypto.rs`, `relay_client.rs`, `hub.rs`),
*Kotlin* = `android/app/src/test/.../link/`, *relay* = `android/relay/tests/`.

## The table

| Threat | What stops it | Test that fails if it stops | Accepted / not covered |
|---|---|---|---|
| **Guessing a room id** | 128 random bits; a wrong path, id or role is `404` before any room exists; the join proof stops a second key in a held room | relay: *refuses a bad path, room id or role with 404 and creates no room*, *never contacts a room for a request it refuses*, *refuses a second key for a room that is held (1008)* | Squatting an **empty** room before its owner connects needs the access key *and* the room id. The owner then sees "in use somewhere else"; **Pair again** fixes it. Accepted (making the verifier persistent would make the relay stateful) |
| **Replay of a recorded frame** | Counter must be exactly the previous plus 1; every connection derives new keys from fresh nonces | Rust *counter_sequences_follow_the_rule*, *a_tampered_replayed_or_reordered_frame_ends_the_conversation*; Kotlin *RelayCryptoTest* counter tests, *aTamperedReplayedOrReorderedFrameEndsTheStream* | none |
| **Malicious or compromised relay** | AES-256-GCM with a key only the two ends hold; a changed or forged frame fails the tag and ends the session | Rust *frames_that_must_be_refused_are_refused...*, *a_tampered_...*; Kotlin the same vectors and *aTampered...* | The relay can **drop, delay, cut** frames and see metadata. Accepted: that is availability, not confidentiality or integrity |
| **Relay delays an approval** | Unchanged v1 rules inside the channel: the computer accepts a decision only for the approval still pending (fingerprint match, decide-once), the phone offers it for at most 120 s from receipt | Rust *hub.rs* approval tests (same code as the LAN); *a_phone_pairs_through_the_relay...* (a decision for another fingerprint does nothing; the right one is applied once) | none |
| **Relay drops a decision** | The approval expires on the computer and is not allowed (fails safe) | Rust *hub.rs* expiry tests | none |
| **Relay truncates a conversation** | Nothing can detect it (a close looks like a close) | n/a | Denial of service only. Accepted |
| **Relay forges "the phone left" or "the computer left"** | The `{"peer":...}` hints are unauthenticated and are used for the status line and to end a conversation, nothing else; **a client cannot send a text message** (anything but `ping` closes its socket with `1003`) so only the relay itself can say it | relay: *answers a text 'ping' with 'pong' and closes on any other text (1003)*; Rust *when_the_relay_says_the_phone_left...*; Kotlin *theComputerLeavingEndsTheStream* | A hostile relay can end a conversation. Same as truncation. Accepted |
| **Stolen phone** | It has K and the token, but **Allow** still needs the fingerprint or screen lock; **Pair again** makes a new K and room, so the old phone is cut off; K is inside the Keystore-encrypted blob | Rust *after_pair_again_the_old_pairing_gets_no_answer_and_the_new_one_works*, *the_pairing_is_made_once_kept_and_replaced_on_demand*; Kotlin *PairingCodecTest*, *RelayGuardsTest.theSecureStoreKeepsEverything...* | A stolen **unlocked** phone is out of scope. The thief also has the relay's access key (quota only): rotate it if you care (`RELAY_DEPLOY.md` row 12) |
| **Stolen or compromised computer** | Out of scope (it holds the agents and the keys anyway) | n/a | n/a |
| **Eavesdropper on the network** | TLS to the relay, end-to-end ciphertext inside | Kotlin *RelayConnectorTest* (the access key and join proof are in headers only over TLS; K never leaves the app); `WsClient` enables host-name checking | The phone's `ws://` is refused for anything but this same device (`RelayUrl`); the real TLS path is only exercised by CI against loopback, not against Cloudflare |
| **Flooding the relay** | Per-room token bucket (30/s, burst 60), 66,000-byte frame cap, per-address connection limit, room-id format checked first | relay: *closes a socket that sends a frame over 66,000 bytes (1009)*, *closes a socket that floods (1008)*, *answers 429 after too many new connections from one address, before checking the key* | The real rate-limit binding across Cloudflare data centres: not testable here |
| **Flooding the computer** (init floods, junk frames) | One admission slot for the whole relay link; a newer `init` replaces the conversation; 3 bad handshake frames silence `init` for 10 s; the existing LAN caps for everything after | Rust *the_relay_connection_counts_as_one_source...*, *three_bad_handshakes_silence_init_for_a_while*, *nothing_is_served_before_the_phone_proves_it_holds_the_key* | none |
| **Creating many empty rooms to burn the free quota** | The access key is checked (`401`) before any room exists; fail closed without one | relay: *refuses a missing, wrong or malformed access key with 401, before any room exists*, *fails closed...*; Kotlin *aWrongAccessKeyIsRefusedByTheRealRelay* (against the Worker) | Anyone who holds the key (every paired phone) can still spend your quota. Fix: rotate the key. Accepted |
| **Reflection** | A different key per direction **and** the direction byte in the nonce and in the AAD | Rust and Kotlin *no_key_and_nonce_pair_repeats...*, *the_sessions_themselves_reproduce_the_vector_frames_in_each_direction* (mutation: a shared key is caught) | none |
| **Phone talks to a fake computer** | The fake has no K: its `accept` MAC fails, and the MAC covers the phone's current nonce | Kotlin *aFakeComputerWithoutTheKeyIsNeverTrusted*, *anAcceptThatAnswersAnOtherInitIsIgnored* | none |
| **A fake phone** | Its `init` MAC fails; nothing is served before a data frame decrypts | Rust *nothing_is_served_before_the_phone_proves_it_holds_the_key* | none |
| **Downgrade** | Not applicable: the LAN link is a separate, equally strict, pinned-TLS path; the relay adds a way in, not a weaker one | Kotlin *TransportTest*; the same `LinkClient` and the same token, fingerprint and biometric rules run on both | none |
| **Two phones** | One phone per room (decision D4): a second one replaces the first | Kotlin *aSecondPhoneReplacesTheFirstOne* (against the Node twin) | A second phone is a second pairing, or use the LAN link |
| **Nonce reuse** | Direction byte plus a counter that only goes up and refuses to wrap; new keys on every connection | Rust and Kotlin property tests over thousands of frames, both directions, two sessions | Random 128-bit nonces: a collision needs about 2^64 sessions |

## What I found while reading the code again (and fixed)

1. **The pairing link had a size limit that the relay fields could break.** The phone refused links over 1,024 characters. With
   the four relay fields, a long relay host and a 48-character accented computer name the link can reach about 900 characters
   once percent-encoded; with the old limit a legitimate code could have been refused as "not a Coucou link". The limit is now
   2,048 and a test (Rust and Kotlin) builds the longest realistic link and checks both the phone's parser and the QR encoder.
2. **The phone's pairing confirmation did not show the relay.** The spec says it must. It now names the relay's host, so a code
   that points somewhere you did not set up is visible before anything is stored (`RelayLinkTest.theConfirmationShows...`).
3. **The Node twin could not start on Node 22** (a TypeScript construct that type stripping does not accept). Fixed in R4; the
   relay's own tests still pass.
4. **A failed write of `init` hid why the relay had closed the connection**, so "this pairing is in use" read as "network
   dropped". Fixed in R4 (the connector reads the close frame), found by a test.

## Accepted limits, said plainly

- **No forward secrecy** (decision D3). If K ever leaks, traffic someone recorded earlier can be read. K lives in the OS keystore on
  the computer and in the Keystore-encrypted blob on the phone, and "Pair again" replaces it.
- **Metadata is visible to the relay and Cloudflare:** IP addresses, that a pairing exists (the room id is stable), when each side
  is online, frame sizes (padded to 128 bytes) and timing.
- **The pairing code is a secret.** It contains the end-to-end key and the relay's access key. It is shown only in the settings
  window after you press *Show pairing code*, the copy hint says so, the phone's pairing screen is excluded from screenshots, and
  *Pair again* invalidates it. Anyone who photographs the QR code can pair a phone until you press *Pair again*, exactly as with the
  local-network code.
- **The relay can be used up by whoever holds the access key** (quota only).
- **Cloudflare's behaviour in production** (hibernation timing, idle WebSocket handling, the real rate-limit binding, the free-tier
  numbers) is from documentation and memory. The tests run the real Worker code under `wrangler dev` (workerd) only.
- **Not seen on a real device:** Doze and battery cost of the connection, the Settings card's appearance, Compose and lint results
  (CI only), the pairing confirmation text on a small screen.

## Rules kept

Nothing published, no release, no store listing, no pull request to upstream; Louis's `relay/` is untouched; no telemetry; the
agent is never blocked by the relay (its own task, a failure only changes a status line); no permission is approved without an
explicit tap and the phone's screen-lock check; secrets only in the OS keystore and the Android Keystore; the Android app stays
English only and the new computer-side strings have all nine translations.
