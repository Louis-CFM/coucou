# Coucou relay

A tiny Cloudflare Worker that lets the Mac app start and update the iPhone's
Live Activity (Mochi in the Dynamic Island while the Mac is locked).

Why it exists: Live Activity pushes must be signed with the APNs key, and that
key can't ship inside the Mac app. The Mac posts Mochi's state here; the relay
signs and forwards it to Apple.

What it sees: the push token of the iPhone's Live Activity and Mochi's state
(agent name, state, "working · 3/7", counts), plus, while a command waits for
your OK, its fingerprint (a SHA-256 hash, so the Lock Screen's Allow and Deny
answer that exact command). Never a project name, a command, a path or a
message. It stores nothing and logs nothing.

## Deploy (once)

1. Apple Developer → Certificates, Identifiers & Profiles → **Keys** → **+**.
   Name it "Coucou relay", tick **Apple Push Notifications service (APNs)**,
   environment **Sandbox & Production**, Continue, Register, **Download** the
   `AuthKey_XXXXXXXXXX.p8` (only downloadable once). Note the **Key ID**.
2. A free Cloudflare account, then in this folder:
   ```
   npm install
   npx wrangler login
   npx wrangler secret put APNS_KEY_ID      # paste the Key ID
   npx wrangler secret put APNS_KEY < ~/Downloads/AuthKey_XXXXXXXXXX.p8
   npx wrangler deploy
   ```
   `deploy` prints the URL, like `https://coucou-relay.<you>.workers.dev`.
3. Check it: `curl https://coucou-relay.<you>.workers.dev/` answers "Coucou relay".

## API

`POST /v1/live-activity`

```json
{ "token": "<hex>", "env": "development|production", "event": "start|update|end",
  "state": { "pillId": "", "agent": "", "color": "", "state": "", "statusText": "",
             "tone": "", "stepIndex": 0, "stepCount": 0, "others": 0 },
  "urgent": false, "dismissAfter": 0 }
```

200 when Apple accepted the push, 410 when the token is no longer valid,
400 when the request is malformed.

## Android companion (`/v1/phone/*`)

The same worker also carries the Android companion: instead of APNs + CloudKit,
the PC and the phone meet in a per-pair "box" (a Durable Object) on a relay you
deploy yourself, and Firebase Cloud Messaging wakes the phone when a card is
waiting. Everything on the free tier — Worker requests, Durable Objects, FCM —
and the app is sideloaded, so no Play account either.

What the box sees: the same session fields the iPhone widget gets (agent,
state, step count), the waiting card's title and detail, question options, and
the last few chat lines — clipped, and readable only with the pairing secret.
The FCM payload itself carries just an event kind and a timestamp; the phone
fetches the content from the box. The relay stores the secret's SHA-256, the
phone's FCM token, and a small outbox — all wiped on unpair.

### Deploy your relay for Android

1. **Worker.** A free Cloudflare account, then in this folder:

   ```
   npm install
   npx wrangler login
   npx wrangler deploy
   ```

   `deploy` prints your URL, like `https://coucou-relay.<you>.workers.dev`.
   The `PHONE_BOX` Durable Object binding and migration are already in
   `wrangler.toml` — no extra setup. (If you don't want the APNs route, it
   stays inert without the Apple secrets; you can also delete the
   `/v1/live-activity` block and the `APNS_*` vars.)

2. **Firebase project (free Spark plan).**
   [console.firebase.google.com](https://console.firebase.google.com) → Add
   project → create an Android app with package `fr.louisraille.coucou.phone`
   → download `google-services.json` (it goes in `android/app/` when you build
   the app — it is gitignored and is not a secret, it identifies the project).

3. **Service account → worker secret.** Firebase console → Project settings →
   Service accounts → **Generate new private key** → a JSON file downloads.
   Then:

   ```
   npx wrangler secret put FCM_SA < service-account.json
   ```

   The worker signs an OAuth JWT with that key to call FCM HTTP v1. Keep the
   file out of git, and delete it after the secret is stored.

4. **Coucou → Settings → Android phone.** Paste your worker URL, click
   *Pair phone…*, and scan the QR or paste the code into the app
   (`android/` builds a normal APK — see its README). The pairing code is
   `pcId|secret|workerUrl`; the secret is generated on the spot and stored in
   the OS keychain (`phone-secret`), never in settings.json.

### Phone API

All calls are `POST /v1/phone/<action>` with `{"id", "secret", …}` — the id
is 24–48 lowercase hex, the secret 64 hex chars (compared as SHA-256).
Responses are JSON; errors are `400` (shape), `403` (auth), `409` (box id
taken), `413`/`429` (bounds), `501` (no `PHONE_BOX` binding).

| action | caller | body / reply |
|---|---|---|
| `pair` | PC | `{id, secret}` → creates the box |
| `claimed` | PC | → `{paired, device}` while waiting |
| `state` | PC | `{id, secret, state, alert?}` → stores clipped state; `alert` (`approval`/`question`/`finished`) pushes FCM |
| `take` | PC | → drains `{out:[…]}` — phone decisions and chat lines |
| `unpair` | either | wipes the box |
| `claim` | phone | `{id, secret, token, name}` → stores FCM token + device name |
| `fetch` | phone | → `{paired, device, state, card}` |
| `decide` | phone | `{requestId, decision:"allow"|"deny"|"answer", answers?}` — `answers` is `{question: label}` |
| `chat` | phone | `{text}` → lands in the PC's chat |

State shape: `{sessions:[{pillId, agent, color, state, statusText, stepIndex,
stepCount}], awaiting:{requestId, pillId, agent, kind, title, detail, options,
questions:[{q, options}]}, chatTail:[{role, text}]}`. Outbox items are
`{type:"decision", requestId, decision, answers?}` or `{type:"chat", text}`
and expire after 10 minutes.

Security notes: use `https://` worker URLs (the settings UI refuses plain http
except loopback); the pairing code *is* the credential — treat the QR/clipboard
like a password; `unpair` from either side wipes the box, so a lost phone is a
one-click revoke in Coucou's settings.
