# Coucou link relay

A tiny, key-less Cloudflare Worker that lets *Coucou for Android* and a desktop Coucou sync over the internet, from
different networks, with no VPN and no shared Wi-Fi. **It is separate from Louis's `relay/`** (which holds an APNs key and
only does iPhone Live Activities) and is deployed by you, on your own Cloudflare account.

The wire is specified in `docs/RELAY_LINK.md`; the reasoning is in `android/RELAY_PLAN.md`; the step-by-step deploy and the phone-on-mobile-data test are in `docs/RELAY_DEPLOY.md`.

## What it does, and what it cannot do

- Both the computer and the phone open **outbound** WebSockets to it. It forwards each binary frame to the other peer of the
  room, as it is. Everything inside is end-to-end encrypted by the two apps; **the relay never sees a content key**.
- It stores nothing (no KV, no R2, no database, no storage call), logs nothing (observability is off), has no accounts, and
  never buffers a frame: a frame for an absent peer is dropped.
- It holds exactly **one secret**, the access key, which only lets a request create or join a room. Without it the relay
  refuses everything (fail closed).
- Operator and Cloudflare can see IP addresses, that a pairing exists, when each side is online, and padded frame sizes and
  timing. They cannot read sessions, commands, paths, approvals or chat.

## Deploy (once)

You need a free Cloudflare account and Node 22 or newer.

```
cd android/relay
npm install
npx wrangler login
# 1. Make a random access key (43 characters) and keep it for the next step and for the computer's setting:
openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
# 2. Store it as a secret (it prompts for the value; it is never written to a file or to git):
npx wrangler secret put ACCESS_KEY
# 3. Deploy:
npx wrangler deploy
```

`deploy` prints the URL, like `https://coucou-link.<you>.workers.dev`. Check it: `curl https://coucou-link.<you>.workers.dev/`
answers `Coucou link relay`. Use the `wss://` form of that URL and the access key in the computer's settings (a later stage).

Wrangler itself (Cloudflare's tool, not this relay or the apps) may send anonymous usage statistics; turn that off with
`export WRANGLER_SEND_METRICS=false` if you prefer.

Nothing in `wrangler.toml` is secret. Do not add `ACCESS_KEY` to it, to `.dev.vars` in git, or to any file you commit.

## Rotating the access key

1. Make a new key (command above) and run `npx wrangler secret put ACCESS_KEY` with it.
2. Paste the same value in the computer's setting. New connections with the old key are refused at once; sockets that are
   already open are closed at their next frame. The computer then sends the new key to your paired phones inside the
   encrypted channel, so they do not have to scan again.
3. If a key leaked, rotate. It protects your free quota, not your data (that is protected by the pairing key).

## Free-tier limits and what happens when they run out

Written from memory of Cloudflare's published limits; check their pages: Workers and Durable Objects each allow about 100,000
requests a day on the free plan, incoming WebSocket messages count at roughly 1/20 of a request, and an idle room costs almost
nothing because it hibernates. A setup of one computer and one phone uses a few hundred "requests" a day. If the quota is
exhausted, Cloudflare refuses requests until the daily reset: the app says "Relay unavailable" and keeps working over the home
network; nothing is lost because nothing is stored. The paid Workers plan (about $5 a month) removes the cap.

## Self-hosting

`tools/dev-relay.ts` is the same relay in plain Node (it shares `src/protocol.ts` with the Worker and is checked by the same
behaviour tests). It speaks `ws://`, so put a TLS terminator in front of it on the internet.

```
npm install
ACCESS_KEY=<your key> PORT=8787 node tools/dev-relay.ts
```

Without `ACCESS_KEY` it refuses every room request.

## Develop and test

```
npm install        # .npmrc sets legacy-peer-deps (the Workers test plugin's peer range)
npm run typecheck
npm test           # the behaviour suite in workerd (Miniflare) and against the Node twin, the guards, the vectors
npm run vectors    # test-vectors.json is up to date (shared with the Rust and Kotlin code)
```

`wrangler dev` runs the Worker locally; set `ACCESS_KEY` for it with a `.dev.vars` file (git-ignored).
