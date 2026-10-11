# Android link (protocol v1)

How *Coucou for Android* talks to a desktop Coucou. The iPhone uses iCloud (CloudKit) and Apple
push, neither of which exists on Android, so the Android app connects to the desktop directly over
the local network.

Status: the Android client, `android/tools/dev-desktop.mjs` (a stand-in desktop for testing) and the
real desktop server of the Windows/Linux app (`windows/src-tauri/src/phone_link/`) implement this.
The Mac app is left to its author.

## Transport

- TCP, then TLS 1.2 or 1.3. The desktop uses a self-signed certificate it generates once.
- Newline-delimited JSON (one object per line, UTF-8). A line over 64 KiB is a protocol error.
- No hostname check and no certificate authority: the phone accepts exactly one certificate, the
  one whose SHA-256 it got when pairing (certificate pinning).
- Default port 47821 (any port works; it is in the pairing link).

## Pairing

The desktop shows a QR code (and a copyable link) containing:

```
coucou://pair?v=1&host=192.168.1.20&port=47821&fp=<sha256 hex of the TLS certificate>&token=<secret>&name=<desktop name>
```

- `token` is 16 to 128 characters of `[A-Za-z0-9_-]`, random, created per pairing. It is the shared
  secret; it travels only inside the pinned TLS connection and is stored on the phone encrypted
  with a key from the Android Keystore.
- The app can read the QR code itself ("Scan QR code" on the pairing card; CameraX for the preview, zxing-core to
  decode, no Play services). Scanning the QR with the phone's own camera app also opens the link in the app (the
  app registers the `coucou://pair` scheme). Either way the app names the computer and asks the user to confirm
  before it pairs; the link can also be pasted. The camera is used only on the scan screen and nothing is stored or sent.
- Unpairing on either side deletes the token. The desktop should accept one token per phone and let
  the user revoke it.

## Messages

Phone to desktop:

| `type` | fields | meaning |
|---|---|---|
| `hello` | `v`, `token`, `device` | first message; must match the pairing |
| `decision` | `fingerprint`, `decision` (`allow` or `deny`) | answer to an approval. No "always" from the phone |
| `ping` | | keep-alive, every 20 s |
| `bye` | | courtesy before closing; may be lost |

Desktop to phone:

| `type` | fields | meaning |
|---|---|---|
| `welcome` | `v`, `desktop`, `os` | reply to a valid `hello`. The phone refuses a different `v` |
| `error` | `code`, `message` | `auth` closes the link and the phone stops retrying quickly |
| `sessions` | `sessions[]` | the full list, replacing the previous one |
| `approval` | `pillId`, `fingerprint`, `tool`, `command`, `createdAt` (ms), `truncated` (bool, optional) | an agent waits for permission |
| `approvalResolved` | `fingerprint` | answered elsewhere or timed out; remove it |
| `pong` | | reply to `ping` |

A session is `{pillId, agent, state, statusText, stepIndex, stepCount, updatedAt}`. `state` is one of
`idle working thinking searching approval question error finished ratelimit sleeping dizzy`; an
unknown value is shown as `idle`. `pillId` values come from the pill catalog
(`windows/src/core/pills.ts`) and are never renamed. Unknown message types are ignored.

## Approvals

- `fingerprint` is the Mac's derivation (`ApprovalRelay.fingerprint`): lowercase hex SHA-256 of
  `pillId`, `sessionId`, `tool`, `command`, `inputKey` joined by U+001F.
- On the Windows/Linux desktop `inputKey` is the island's request id, so asking for the same command
  twice gives two different fingerprints.
- The desktop applies a `decision` only if its fingerprint matches the approval **still pending**
  (same session, tool, command and input). A late decision, or one for another command, is ignored.
- The phone offers an approval for at most 120 s (the desktop dismisses it at 115 s), and sends one
  decision per request.
- **Allow requires the user's biometric or screen lock on the phone.** Deny does not. With no
  screen lock set up, Allow is refused.
- The command text is hidden on the lock screen.
- **A command is sent in full up to 500 characters.** A longer one is cut to its first 500 and the approval carries
  `"truncated": true` (additive: absent means false, and a phone that does not know the field ignores it). The fingerprint
  is computed over the text as sent. For a truncated approval the phone says "Command is longer than shown", offers
  **Deny only** (sheet, notification and island), and the request is answered on the computer. The computer enforces it too:
  an `allow` for a truncated approval is ignored and the request stays pending (a `deny` works as usual).

## Capabilities and chat (optional, still protocol v1)

`hello` may carry `caps`, a list of optional features the phone understands; `welcome` carries `caps` with the
ones this computer offers **to this phone right now**. A side that sends no `caps` gets none of them, so older
phones and older computers keep working unchanged (an unknown field is ignored, an unknown message type is ignored).
The only capability defined so far is `chat`: the phone talks to the AI providers the computer is set up for.
**The computer's API key never leaves the computer**; the phone sends text and receives text.

The computer offers `chat` only if the user turned "Let the phone chat with my AI providers" on (off by default),
and re-reads that switch for every message. The user also chooses which provider/model pairs the phone may use.

| Direction | `type` | fields |
|---|---|---|
| phone to computer | `chatModels` | none: ask for the allowed list |
| computer to phone | `chatModels` | `models[]`: `{id: "provider/model", provider, label}`, only what the user allowed |
| phone to computer | `chatSend` | `id` (1 to 64 chars of `[A-Za-z0-9_-]`, made by the phone), `model` (an `id` from the list), `text` (at most 4000 characters) |
| computer to phone | `chatDelta` | `id`, `text` appended to the answer (pieces of at most 8 KiB) |
| computer to phone | `chatDone` | `id`; `text` only if the streamed text must be replaced by this full answer |
| computer to phone | `chatError` | `id`, `reason`, `message` |
| phone to computer | `chatCancel` | `id`: stop waiting for this answer |
| phone to computer | `chatReset` | none: new chat; the computer forgets the conversation and stops a running answer |

- `reason` is one of `off not_allowed busy rate too_long empty no_key unreachable auth provider canceled internal`.
  `message` is a fixed English sentence written by the computer; a provider's own error text is never sent
  (some providers echo part of a key in an error).
- One answer runs at a time (`busy`), at most 12 sends per 10 minutes (`rate`). An answer stops when its phone leaves,
  when the user turns the switch or the link off, or on `chatCancel`. Stopping cannot undo what a provider already started.
- A `chatSend` whose id is not valid is ignored (there is nothing to answer to). A phone that did not negotiate `chat` is
  never sent, and never answered about, any `chat*` message.
- The computer keeps the conversation in memory only while the switch is on; nothing new is written to disk. The phone
  sends no files, window context, keys or addresses, and the computer would not accept them.
- Cloud providers answer all at once (as on the computer's own chat), local models stream.

## Session details (optional capability `details`)

A phone that sends `caps: ["details"]` in its `hello`, while the user has turned on "Show session details on the phone" on the
computer (off by default; re-read for every connection), is offered `details` in `welcome.caps`. Its `sessions` lines then
carry these optional fields on each session; any other phone gets the exact v1 fields and nothing else:

| field | meaning |
|---|---|
| `steps` | the last steps of the session, oldest first: at most 20, each at most 200 characters, as the island shows them (a file change is its file name). Can include commands. |
| `finalLine` | the agent's final line after it stopped, at most 200 characters |
| `project` | the **folder name** the session runs in, at most 64 characters. Never a path (only the last segment survives, on both the island and the link) |
| `color` | the pill's colour as `#RRGGBB`; anything else is dropped |

The whole `sessions` line stays under 56 KiB: when many sessions carry many steps, the oldest steps are dropped until it fits.
A field with nothing to say is left out. Turning the switch on or off disconnects the phones once so they reconnect and are told.
Not sent, ever: the prompt, command output, Claude's full answer, file contents, full paths.

## Answering Claude Code's questions (optional capability `answers`)

A phone that sends `caps: ["answers"]` in its `hello`, while the user has turned on "Let the phone answer Claude Code's
questions" on the computer (off by default; re-read for every connection), is offered `answers` in `welcome.caps`. Any other
phone never hears of a question and cannot answer one (its `answer` messages are ignored).

| Direction | `type` | fields |
|---|---|---|
| computer to phone | `question` | `pillId`, `fingerprint`, `createdAt` (ms), `questions[]`: `{question, multiSelect, options[]: {label, description}}` |
| phone to computer | `answer` | `fingerprint`, `picks`: one list of labels per question, in order |
| computer to phone | `approvalResolved` | `fingerprint`: the question was answered (here or on the computer) or timed out; remove it |

- At most 4 questions of at most 8 options. A question with a longer text (500 characters), a longer label (120) or description
  (300), no option, or two options with the same label is **not offered** (it stays on the computer): the answer must carry the
  exact text and labels back to the agent, so nothing is ever cut.
- `fingerprint` identifies the pending question like an approval's does (derived from the session, the question texts and the
  island's request id); the request id itself never leaves the computer.
- The computer applies an `answer` only if its fingerprint is the question **still pending**, it is not older than 115 s, and
  `picks` matches exactly: one list per question; each label equal to one of that question's labels (exact, case-sensitive);
  one label for a single choice; one or more distinct labels for a multiple choice. Anything else changes nothing and the
  question stays open. Applied once, then the island's card closes as if answered there. The agent receives
  `{question text: label}` (a list of labels for a multiple choice), the same shape the island produces.
- **The phone asks for its screen lock (fingerprint, pattern, PIN) before it sends an answer**, like Allow. Nothing is
  logged about what was picked, on either side.
- A permission request is still sent to every phone as an `approval`, unchanged.

## File changes (optional capability `diffs`)

A phone that sends `caps: ["diffs"]` in its `hello`, while the user has turned on "Show the files an agent changed on the
phone" on the computer (off by default, a switch of its own; re-read for every connection), is offered `diffs` in `welcome.caps`.
Any other phone gets the v1 `sessions` line and cannot ask for a diff (its `getDiff` messages are ignored).

**The list.** With `diffs`, a session may carry `files`, at most 20 (the newest), each `{id, name, added, removed}` plus
`tooLarge: true` (the change is too large to show line by line: counts only) and `isNew: true` (a file that was written whole).
`name` is the **file name only**: the computer keeps the last segment of the path, cut at 80 characters, and the phone does the
same again if it is sent more. The line counts toward the 56 KiB budget of a `sessions` line like the details do.

**The lines, on request only.**

| Direction | `type` | fields |
|---|---|---|
| phone to computer | `getDiff` | `pillId`, `fileId` (an `id` from the list) |
| computer to phone | `diff` | `pillId`, `fileId`, `name`, `added`, `removed`, `tooLarge`, `gone`, `truncated`, `part`, `parts`, `lines` |

- `lines` are `[kind, text]`: kind `+` (added), `-` (removed), ` ` (context) or `@` (a hunk starts; the text is `@@ <line>`).
  An unknown kind is read as context.
- At most **200 lines** per file, each cut at **400 characters**, sent in **parts of 100 lines** (`part` from 0 to `parts - 1`, at
  most 2 parts), so no line of the link nears 64 KiB. `truncated: true` says there were more than 200. A diff the island no
  longer has is answered with `gone: true` and no lines (one part); a change that was `tooLarge` has no lines either.
- The answer goes to the phone that asked, and only if it still has `diffs`. A phone may ask for at most 20 diffs in 10 seconds.
- The phone holds the lines in memory while its sheet is open and forgets them when it closes; nothing is stored or logged.
- Deviation from the plan: the plan said "600 lines in total"; the computer keeps 200 lines per file and the 20-in-10-seconds rate
  instead, which bounds the same thing (at most 4 000 lines in 10 s) without per-connection bookkeeping.

## Service cards (optional capability `services`)

Read-only cards of the island's service pills (Stripe, GitHub, Vercel, n8n, Resend, Notion, Cal.com). **One tick per service**
in Settings > Android phone on the computer, none ticked by default; a phone that sends `caps: ["services"]` is offered
`services` in `welcome.caps` only if at least one service is ticked (re-read for every connection; a change reconnects the phones).
Each phone is sent only the services ticked, and nothing is sent for the others, not even their names.

```json
{"type":"services","services":[{"id":"integration_stripe","title":"Stripe","headline":"12.50 EUR","reason":"Payments",
  "items":[{"label":"Payment","detail":"+9.00 · 2m"}]}]}
```

Sent after the first `sessions` when there is something to show, and again when the cards of **that phone's** services change.
An empty `services` list takes the cards away. Limits, kept by the computer and checked again by the phone: only the seven ids above
(once each), `title`/`headline`/`reason`/`label`/`detail` one line of at most 24/40/80/60/60 characters (80 on the phone), at most
three `items`. What each card says (and what it never says):

| Service | Headline | Lines | Never sent |
|---|---|---|---|
| Stripe | the balance | the last three payments: paid or failed, the amount, how long ago | descriptions, customers |
| GitHub | total stars | the number of repositories | repository names, links |
| Vercel | latest deployment ready or failed | project name, ready or failed, how long ago | links, branches |
| Resend | total emails | delivered or not, how long ago | addresses, subjects |
| Notion | number of recent pages | the page titles and how long ago | links, content |
| Cal.com | the next call's date and time | titles and times | attendees, links |
| n8n | the last workflow's result | its name | the error text |

Nothing in a card can be acted on, and nothing goes back: there are no actions on any service from the phone.

## Plan usage (optional capability `usage`)

A phone that sends `caps: ["usage"]` in its `hello`, while the user has turned on "Show my plan usage on the phone" on the
computer (off by default, a switch of its own; re-read for every connection), is offered `usage` in `welcome.caps`. It is then
sent, right after the first `sessions` and again whenever a number changes, what the island's Claude and Codex pills show:

```json
{"type":"usage",
 "claude":{"fiveHour":{"pct":42,"resetsAt":1900000000000},"sevenDay":{"pct":7,"resetsAt":1900500000000},"plan":"max","updatedAt":1899999990000},
 "codex":{"sevenDay":{"pct":100,"resetsAt":1900500000000},"resetCredits":2,"plan":"plus"}}
```

`pct` is a whole percent 0..100 (rounded and clamped by the computer), `resetsAt` epoch milliseconds, `plan` a short name (letters,
digits, spaces and dashes, 20 characters at most), `resetCredits` Codex's free resets (0..99). A plan with no usable window is left
out. A bare `{"type":"usage"}` means the computer has nothing to say any more: the phone removes the panel. A window whose
`resetsAt` has passed counts as 0 on the phone, as on the PC. Nothing else about the plans (no account, no token, no cost) is
ever sent, and nothing goes back.

## Admission (what a flood cannot do)

The server answers the local network before it knows who is calling, so it bounds what a caller who has not yet sent
a valid `hello` can hold (`phone_link/admission.rs`, pure bookkeeping with unit tests):

- one source address may hold at most **2** connections that have not said a valid hello;
- addresses that never authenticated (strangers) share **4** such connections between them, so at least half of the 8
  slots stay free for a phone the computer already knows;
- an address that sent a valid hello is remembered, in memory only (8 addresses, never written to disk), and is not
  held to the stranger pool: the paired phone can always reconnect, even during a flood from other addresses;
- when the pool is getting full, the TLS handshake and the hello get 3 s instead of 10 s, so silent connections free
  their slots quickly;
- a slot is given back whenever the connection ends, however it ends.

What it does not do: a device that floods from many addresses at once can still keep a *new, never-paired* phone out
for a few seconds at a time; it cannot keep out the phone that is already paired. A wrong token still costs the caller
a pause and is never admitted.

## Mochi's outfit (optional capability `prefs`)

A phone that sends `caps: ["prefs"]` in its `hello` is offered `prefs` in `welcome.caps` (no switch on the computer: what
Mochi wears is no secret and says nothing about the user's work). It is then sent what the island's wardrobe says, right
after the first `sessions` and again whenever it changes:

```json
{"type":"prefs","outfit":"beanie"}
```

`outfit` is one of `auto`, `none`, `partyHat`, `beanie`, `crown`, `sunglasses`, `roundGlasses`, `bow`, `scarf`, `witchHat`,
`pumpkin`, `santaHat`, `bunnyEars`: the PC's and the Mac's stored values, nothing else is ever sent (the computer checks the
list; a test compares it with `windows/src/mochi/wardrobe.ts`). `auto` means "dress for the season": **the phone applies the
seasons to its own calendar**, the computer sends no date. A phone ignores a value it does not know and keeps what it wore.
The phone has its own choice too (Settings > Mochi's wardrobe): "Same as my computer" (default) or one outfit, which then wins.
Nothing goes back to the computer.

## Finding the computer again (optional, still protocol v1)

The pairing link holds the computer's address, and an address changes with every network (a home Wi-Fi, a hotspot, a
new router). So the computer can also announce itself on the local network, and the phone can find it there. This is
an addition: **v=1 is unchanged, the saved address stays the first thing tried, and an old phone or an old computer
simply keeps using the saved address.**

- **Announcement** (computer): while the phone link is on, DNS-SD over multicast DNS, service type `_coucou._tcp`,
  instance name = the computer's name, the real port, IPv4 address. Off means silent: when the switch is turned off, the
  link stops or the app quits, the announcement is withdrawn and nothing runs.
- **TXT record**: `v=1` and `fp=<first 16 lowercase hex characters of the certificate's SHA-256>`. Nothing else. Never the
  token, never the pairing link, never a user name or a path. The certificate is public by nature (every peer that connects
  receives it), so its short id is not a secret, and it is **a hint, not a credential**.
- **Phone**: the framework's `NsdManager` (no library). It searches only when it has a paired computer, a Wi-Fi or cable is
  up and the link is not connected; it holds a multicast lock only while searching.
  1. The saved address is tried first and gets 2 s to accept the TCP connection.
  2. After that failure the network is searched for up to 15 s. Between searches it waits 20 s, 60 s, 3 min, then 5 min;
     a network change (`ConnectivityManager` callback) starts a search at once and resets the waiting. No Wi-Fi: no search.
  3. A service is a candidate only if its `fp` equals the first 16 characters of the **paired** certificate fingerprint and its
     `v` is `1` (or absent), and its address is on the local network. The name and the address never count.
  4. A candidate is then checked with a bare TLS handshake against the **full** pinned fingerprint. The probe takes no
     token: nothing secret can be sent to it. Only a certificate that matches is accepted; one that does not (a lookalike
     that copied the short id) is dropped and never saved. When the paired fingerprint is announced twice, the first that
     passes wins.
  5. The stored host and port are replaced; the token and the pinned fingerprint are untouched. The link reconnects.
- If nothing is found, the phone says so calmly (same Wi-Fi? computer awake and Coucou running? firewall? hotspots and guest
  networks can block devices from finding each other, "client isolation") and offers to pair again or to type the address.
- Limits, honestly: multicast does not cross routers or VPNs; some access points block it between clients; a firewall that
  blocks UDP 5353 on the private profile hides the computer (the Windows prompt "allow Coucou on private networks" covers
  it); two computers with the same certificate do not exist (each has its own).

## Behaviour rules (same as the other ports)

- Never block the agent: if the phone does not answer, the desktop's own approval stays usable.
- No telemetry. The only network traffic is between the phone and its paired desktop.
- The desktop link is **off by default** and opt-in in settings. It should listen only while it is
  on, and only to the local network.

## Windows/Linux implementation notes

- Settings → Android phone: off by default (`phoneLink` in settings.json, owned by Rust: the webview
  cannot switch it on). While off, nothing listens, nothing is published and no timer runs.
- It listens on `0.0.0.0` (port 47821, else any free port) but drops every peer that is not on the
  local network (private, loopback, link-local). At most 8 connections; 10 s to say hello (3 s when the pool is
  filling up); 20 min idle (a sleeping phone cannot ping every 20 s, see "Keeping the link alive"). Unauthenticated connections are limited, see "Admission" below.
- The certificate (ECDSA P-256, self-signed) is generated once; its key and the pairing token live in
  the OS keystore (Credential Manager / Secret Service) and nowhere else. Without a keystore the link
  does not start.
- One token at a time: "Pair again" replaces it and disconnects the phone that had the old one. The
  pairing code is shown only after a click, and only to the settings window.
- Chat (Settings → Android phone → "Let the phone chat with my AI providers"): off by default, owned by Rust like
  `phoneLink` (`phoneChat`, `phoneChatModels` in settings.json; the webview cannot change them). The user ticks the
  provider/model pairs the phone may use (a provider's model list is asked for only when its "Choose models" button is
  pressed). Turning the switch on or off disconnects the phones once so they reconnect and learn about the capability;
  turning it off also stops a running answer and forgets the phone's conversation. The phone's conversation is a
  separate in-memory `Chat`, not the island's. The provider code is the island's (`chat::send_for_phone`); a provider's
  error text is never forwarded or logged, only a kind (no key, unreachable, auth, provider).
- Permission requests (Allow/Deny) go to every phone. A question from Claude Code goes only to a phone with the `answers`
  capability (Settings → Android phone → "Let the phone answer Claude Code's questions", off by default); otherwise its
  options are picked on the island.
- New crates: `mdns-sd` (+ `flume`, `if-addrs`, `socket-pktinfo`, `spin`; default features off, so no async runtime or logger) announces the computer on the local network while the link is on (`phone_link/discovery.rs`); `rcgen` (+ `yasna`) makes the certificate once, `qrcode` draws the pairing QR; `rustls`,
  `tokio-rustls` and `ring` were already in the dependency tree (through `reqwest`) and are now named
  directly. Hashing, randomness and the constant-time comparison use `ring`; no other crate.

## Android notes

- Android 16 asks for local network access the first time the app connects.
- A foreground service keeps the link alive in the background so approvals arrive as notifications.
- The app needs Android 11 or later (API 30) for the combined biometric / screen-lock prompt.

## Testing

- `android/tools/dev-desktop.mjs` pretends to be a desktop (needs `node` and `openssl`). With `--fake-chat` it offers
  `chat` with a fake provider (no key, no cost): `/error`, `/auth`, `/slow`, `/long` and `/rewrite` trigger the odd cases.
- `DevDesktopInteropTest` runs the Android client against it.
- `cargo test -p coucou phone_link` also tests the announcement (what is published and when, that no secret can be in it); the real multicast needs a real network and is not in the tests.
- `cargo test -p coucou phone_link` tests the real server (wrong token, fingerprint mismatch, oversize
  line, late decision, answered-at-the-desk, pairing again, local-network filter...).
- `RustDesktopInteropTest` runs the Android client against the real Rust server
  (`COUCOU_RUST_INTEROP=1`, needs cargo; the `Phone link` workflow does it).

## Through a relay (optional capability `relay`)

When the user turns on "Away from home Wi-Fi" in Settings > Android phone, the pairing link carries four more fields
(`relay`, `room`, `key`, `access`) and a phone that sends `caps: ["relay"]` is offered `relay` in `welcome.caps` (re-read for
every connection). The conversation itself is unchanged and runs inside an end-to-end encrypted channel through the user's own
relay; the wire is in `docs/RELAY_LINK.md`. When the user replaces the relay's access key, each phone that negotiated `relay`
is sent `{"type":"relayAccess","access":"<43 base64url characters>"}` and follows the new key. A phone that did not negotiate
`relay` is never sent it.

## Keeping the link alive while the phone sleeps

What actually happens when the screen is off, as found and fixed (Galaxy A12s, Android 13):

- **A foreground service keeps the process alive, not the connection.** `LinkService` is what stops Android from killing the app, but
  the app's own timers (the 20-second ping, every timeout) are stopped with the CPU in Doze, and the network of an app that is not
  exempt from battery optimisation is restricted while the phone is idle. So the phone could not ping, the computer (which allowed only 90 s of
  silence) closed the connection, and the phone found out only when it woke up and sent something: a new connection from the phone's
  address at wake time.
- **The computer is more patient**: an authenticated phone may be silent for 20 minutes (`IDLE_TIMEOUT` in `server.rs`). A conversation
  whose phone disappeared without saying goodbye (its address changed) holds one of the 8 places until then.
- **The phone has a heartbeat that works in Doze**: an alarm every 4 minutes (`AlarmManager.setAndAllowWhileIdle`, no exact-alarm
  permission). Android may run it later (about every 9 minutes in Doze, or in a maintenance window), never more often. Each time, the
  app asks the computer for a pong and drops the connection (so it reconnects) if nothing comes within 8 s, or reconnects at once if the
  link was down. The check holds a wake lock for at most 15 seconds, only so the question and its answer can cross; nothing is held between checks.
- **Other triggers**, all through one rule table (`ReconnectPolicy`): the screen turning on or the phone being unlocked, a new
  default network (Wi-Fi joined, Wi-Fi to mobile data), and the connection dying (the usual reconnect with backoff). Connected: ask for a
  pong. Not connected: reconnect now, if there is a network to use.
- **What is not possible**: while Doze restricts the network of an app that is *not* exempt, nothing can reach or leave the app until the
  next maintenance window, whatever the app does. The only reliable fix is the user's: set the app's battery usage to **Unrestricted** (on
  Samsung also: not in Sleeping apps or Deep sleeping apps). The app suggests it, calmly, only after a connection that ended on its own after
  the screen had been off, and only opens Android's screen: it cannot change the setting itself and does not ask for the permission that
  would allow a one-tap request (Google restricts it on its store). Push notifications (FCM) would work without this setting, but need Google's
  servers and a Google account of the app; they are not used (decision D6 of the relay plan).
- Home says what happened ("Connection lost 2 min ago, reconnecting", and why: the computer stopped answering / closed the connection /
  the network dropped). **Settings > Computer > "Can't connect?"** checks, in order, the phone's network, the saved address, whether the
  computer announces itself, the pinned certificate, the pairing code and version, and the relay if the pairing has one. Its copyable
  report names the checks and what they found, and never contains the pairing code, the certificate fingerprint, the computer's name or
  the full address.

