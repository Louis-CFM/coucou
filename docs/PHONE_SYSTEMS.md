# Phone systems — which is canonical

This fork ships **two independent phone links**, side by side in Settings → Phone.
They do not interop: a phone speaks exactly one of them.

| | Mailbox (canonical) | LAN link (upstream path) |
|---|---|---|
| Desktop | `windows/src-tauri/src/phone.rs` (+ `mail_crypto.rs`) | `windows/src-tauri/src/phone_link/` |
| Phone | `android/…/phone/Relay.kt` (+ `BoxCrypto.kt`) | upstream app only — this fork's Android app does **not** implement it |
| Pairing code | `id\|master\|worker` (QR or paste) | `coucou://pair?…` link + QR |
| Transport | HTTPS polling against a self-hosted Cloudflare Worker (`relay/`) | TCP+TLS on the LAN; optional WSS relay frames (settings hidden behind `SHOW_RELAY_SETTINGS`) |
| Crypto | HKDF from `master` → `auth` bearer + `p2h`/`h2p` AES-GCM; the relay sees only `auth` | TLS with certificate pinning; frames sealed with `K` when relayed |
| Works off-LAN | yes (that is the point) | only with the WSS relay enabled |
| Doc | `relay/README.md` §Android companion | `docs/ANDROID_LINK.md`, `docs/RELAY_LINK.md` |

## Decision

**The mailbox is the canonical system for this fork's Android companion.** All
Android work — approvals, questions ("Other…", "Reply in terminal"), chat,
Always Allow, biometrics — lives on it. New features go there.

The LAN `phone_link` module stays for two reasons:

- it is the upstream-compatible direct link (local network, no relay needed),
- parts of it back the mailbox too: `phone_link/relay_crypto.rs` is shared
  infrastructure, and the phone settings UI (`settings/phone.ts`) still offers
  the LAN switch.

What this means concretely:

- Do not delete `phone_link/` — it is real, shipped surface, not dead code.
- Do not add features to the LAN path that the mailbox lacks; parity work goes
  the other way (mailbox first).
- The WSS relay frame client (`phone_link/relay_client.rs`) is built but its
  settings block is hidden (`SHOW_RELAY_SETTINGS = false`); enabling it would
  need an Android-side implementation that does not exist in this fork.
- Old mailbox pairings predate the sealed mailbox (SEC-1) and must be re-paired:
  the code carries `master`, older ones carry only the bearer.

## iOS is a third system, unrelated

The iPhone app uses CloudKit records + APNs pushes (`NotchBuddy/Sources/App/PhoneLink/`,
`Sources/Phone/`), not either of the above. Apple-only, unchanged by this decision.
