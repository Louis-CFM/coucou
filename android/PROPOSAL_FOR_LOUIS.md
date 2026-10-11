# Draft message to Louis (the user sends it; nothing is opened on his repo)

Subject: Coucou for Android: an optional phone link in the Windows/Linux app (your call)

Hi Louis,

The Android port you allowed needs something from the desktop app to show real sessions: today Android
has no CloudKit or APNs, so the phone connects straight to the computer over the local network.
I wrote that desktop side for the Windows/Linux app, as a separate module, and I'd like to know if you
want it in Coucou. It's your app and your decision; I'll keep it on my fork if you don't.

What it is
- Settings gets an "Android phone" section. The switch is **off by default**. When it's on, the app
  listens for the Android app on the local network only; when it's off, nothing listens, nothing is
  published and no timer runs.
- The phone sees the agent sessions and the pending permission request. Allow/Deny from the phone is
  applied only if it matches the request that is still pending (same fingerprint as the Mac's
  ApprovalRelay), once, and not after 115 s. Allow asks for the fingerprint or screen lock on the phone.
  It never blocks the agent: the card on the island keeps working, and the phone is just another way to click.
- The code is in `windows/src-tauri/src/phone_link/` (about 900 lines with tests) plus a small publisher
  (`src/island/phone-link.ts`) and the settings section. Existing views are not restyled; the only edits to
  your code are a `phoneLink` setting, `dropPendingCard` exported from hooks.ts, and the secrets module
  gaining entries the webview can't reach.

Security choices
- TLS 1.2/1.3 with a self-signed certificate made once. The phone pins its SHA-256 from the pairing QR.
- The certificate key and the pairing token are in the OS keystore, never on disk. No keystore, no link.
- Only private/loopback/link-local peers are accepted; 64 KiB line limit; 8 connections; constant-time
  token check; "Pair again" revokes the old phone. The pairing code is shown only after a click.
- No telemetry, no cloud, no relay.

Cost
- Two new crates: `rcgen` (certificate, plus its `yasna` dependency) and `qrcode` (pairing QR). rustls,
  tokio-rustls and ring were already in the tree via reqwest. If you'd rather not have the QR, the link can
  be pasted and `qrcode` goes away.

Tested
- 38 cargo tests (wrong token, fingerprint mismatch, oversize line, late decision, answered at the desk,
  pairing again, local-network filter...), 9 front-end tests, and the real Android client against the
  real server. Not yet verified on a real phone with real sessions. The Settings texts are translated
  by me in the nine languages and need a native read.

The Mac app is untouched; if you ever want the same on macOS, `docs/ANDROID_LINK.md` is the protocol.
Nothing from the Android app is published until you've approved the build and the listing.

Thanks,
Rhytam
