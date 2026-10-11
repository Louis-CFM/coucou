# Handoff: Coucou for Android (read this first)

For a new coding session with no memory of the earlier work.

## What this is

**Coucou** (https://github.com/Louis-CFM/coucou, by Louis Raillé) is a macOS app, with a Windows/Linux Tauri port in `windows/`, where
**Mochi** shows the state of AI coding agents and lets the user approve their permission requests. **Our project** is the
Android port in `android/` (Kotlin + Compose), built by Rhytam Biswas (`Rhytam23`) with Claude on branch `android` of the fork
`Rhytam23/coucou` (`upstream` = Louis-CFM/coucou, read-only for us).

## Rules that must never be broken

Louis agreed by email (`PERMISSION.md`): Mochi, the sounds, visuals, icon and the name "Coucou for Android" for this Android app only, and
only if it is **free (no ads, paid features or analytics; CI greps for them)**, credits him in the app (About and Licences) with a link to his
repo, keeps the MIT notice, and **he approves the build and the store listing BEFORE anything is published**. Pushing source to the fork is fine.
Never create a release, upload an APK, submit to a store, or open a PR to `upstream` without the user saying so.

Repo rules (`CLAUDE.md`): no third-party dependency unless unavoidable; secrets in the keystore; no telemetry; never block the agent; never
approve a permission without an explicit click; don't restyle Louis's shipped desktop views; pill IDs are never renamed. Don't touch
`NotchBuddy/`, `relay/` (Louis's APNs relay) or the Mac docs. Android app: English only, dark only. Commit messages end with
`Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; push only to `origin android`; `change log.md` stays local.

## Where things are

- `android/app/src/main/kotlin/com/coucou/android`: `mochi/` (engine, painter, `outfit/`), `link/` (protocol, pairing, TLS client, discovery,
  `WebSocket.kt`, `RelayLink.kt`, `RelayCrypto.kt`, `Transport.kt`, `LinkHealth.kt` (what Home says, the alarm and battery rules), `Reconnect.kt`, `Diagnostics.kt`), `core/` (pure rules), `ui/` (Compose), `app/` (`AppModel`, notifications,
  `LinkService`, `SecureStore`, biometric gate), `scan/` (QR), `sound/`. Overview and features: `android/README.md`.
- Desktop side: `windows/src-tauri/src/phone_link/` (hub = rules, server = TLS, pairing, admission, discovery, chat, `relay_client.rs`,
  `relay_crypto.rs`), front end `windows/src/island/phone-link.ts` and `windows/src/settings/phone.ts`. Protocol: `docs/ANDROID_LINK.md`.
- Internet relay: `android/relay/` (Worker + Node twin, test vectors), wire `docs/RELAY_LINK.md`, plan and decisions `android/RELAY_PLAN.md`,
  threat check `android/RELAY_THREAT_CHECK.md`, deploy and test with a phone on mobile data `docs/RELAY_DEPLOY.md`, end to end `android/relay/tools/e2e.sh`.
- `android/tools/dev-desktop.mjs`: a pretend computer for trying the app (fake data, test tool). `android/PROPOSAL_FOR_LOUIS.md`: draft for the user to send; nothing is opened upstream.
- CI: `.github/workflows/phone-link.yml` ("Phone link": Windows tests, Linux interop, relay, relay end to end, Android build/tests/lint).

## Checks

```
cd android && ./gradlew test assembleDebug lint
node android/scripts/gen-strings.mjs --check          # English strings in sync
cd windows && cargo test --workspace --locked && npm test && npx tsc --noEmit
cd android/relay && npm ci && npm test && npm run vectors
```

The Kotlin suite is about 640 tests (some need `node`/`cargo` and skip without them: set `COUCOU_RUST_INTEROP=1` and `COUCOU_NODE_RELAY=1`).
Gradle and Compose compile only in CI in a cloud session; the pure Kotlin files can be compiled with kotlinc and JUnit.

## What has and has not been seen on a real phone

Seen (Samsung Galaxy A12s, Android 13, earlier stages): Mochi renders, demo mode, pairing over Wi-Fi, Allow reaches the computer.
**Not seen on a device**: a release (R8) build, which has never been installed (CI builds it unsigned and checks the logs are gone, nothing more); the keep-alive alarm and "Can't connect?" (the Galaxy A12s with the screen off for 10+ minutes is the test), the redesigned screens, the island and its motion, the widget/tile/notification, QR scan, chat, answers,
file changes, the relay path (and Doze/battery with it), anything on real Cloudflare. CI proves compilation, lint and the unit and
interop tests, not how it looks or feels.

## Still open

- The user tests each feature on the phone; Louis has not approved a build or a listing.
- Not built: stage I (send the next instruction to an agent), FCM push, a Play Store listing. Stage G (a VPN) was built and removed.
