# Coucou relay

A tiny Cloudflare Worker that lets the Mac app start and update the iPhone's
Live Activity (Mochi in the Dynamic Island while the Mac is locked).

Why it exists: Live Activity pushes must be signed with the APNs key, and that
key can't ship inside the Mac app. The Mac posts Mochi's state here; the relay
signs and forwards it to Apple.

What it sees: the push token of the iPhone's Live Activity and Mochi's state
(agent name, state, "working · 3/7", counts). Never a project name, a command,
a path or a message. It stores nothing and logs nothing.

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
