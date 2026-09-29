---
name: coucou-bridge
description: Set up the Coucou notch app to chat with this agent.
version: 0.1.0
author: Febry Ardiansyah (febryardiansyah), Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [Coucou, macOS, Bridge, Chat, Notifications]
    related_skills: []
---

# Coucou Bridge Skill

Coucou is a macOS notch companion. This skill stands up the two small servers it
talks to — a chat bridge (messages run a real agent session here) and an alert
feed the notch polls — then hands the user the URL and key to paste into the app.

Does not cover building the app: the user needs Coucou installed (or their own
build with the Hermes provider on the same branch).

## When to Use

- "Set up Coucou", "connect the notch app to you", "I want to chat with you from my Mac's notch"
- The user installed Coucou and asks how to point it at their agent
- Don't use for: other notch companions, or wiring Coucou's built-in Anthropic/OpenAI providers

## Prerequisites

- Hermes Agent installed and working on the machine that should answer (`hermes` on PATH)
- `python3` (stdlib only — no packages installed)
- The user's Mac must reach this host: a public IP, or an SSH/Cloudflare tunnel
- Firewall ports open for 8645 (feed) and 8646 (chat)

## Procedure

1. **Get the bridge scripts.** They ship in the Coucou repo at `server/hermes/`:
   `hermes_feed_server.py`, `hermes_chat_server.py`, `install.sh`. If the user
   doesn't have the repo, clone it (their fork or `Louis-CFM/coucou` when the
   branch carrying `server/hermes/` is merged).
2. **Run the installer** with `terminal(command="bash server/hermes/install.sh", timeout=120)`.
   Completion: it prints `installed to …`, opens the ports, and starts both
   services (systemd user units when available, otherwise `nohup`).
3. **Verify locally** — `terminal(command="curl -sf http://127.0.0.1:8645/hermes/health", timeout=15)`
   must return `{"status":"ok",…}`. If it doesn't, the unit failed: read
   `journalctl --user -u coucou-hermes-feed -n 30`.
4. **Confirm the key.** `read_file("~/.hermes/coucou/token")`. This is the
   `X-Hermes-Key` value; never print it into a public channel or commit it.
5. **Hand over the two values** (bridge URL `http://<host>:8646/chat`, key, thread
   name `coucou`) and tell the user to enter them in
   **Coucou → Settings → Chat → Provider → "Hermes"**, then enable the **Hermes**
   pill under Integrations.
6. **Feed the notch (optional).** Anything that appends to
   `~/.hermes/coucou/feed.json` shows up as a pill within 20s:
   `{"updated": <epoch>, "items": [{"id": "<unique>", "ts": <epoch>, "title": "…", "detail": "…", "level": "info"}]}`.
   Keep `id` unique — the poller dedupes on it and re-alerts only on change.

## Verification

- `curl -sf http://127.0.0.1:8645/hermes/health` → `{"status":"ok"}`
- `curl -s -H "X-Hermes-Key: $TOKEN" http://127.0.0.1:8645/hermes/feed` → the feed JSON (401 without the header proves auth works)
- A `POST /chat` with `{"text":"ping"}` returns `{"reply": …}` from a real session
- From the Mac: the same feed URL over the public address returns 200

## Pitfalls

- **Stale services after a rename.** If the header or path ever changes, the
  running servers keep the old contract — restart them (`systemctl --user restart
  coucou-hermes-chat coucou-hermes-feed`) or the app gets 401/404.
- **Logout kills the units.** Without `sudo loginctl enable-linger $USER`, user
  services stop when the SSH session ends.
- **Plain HTTP by default.** The key is a bearer secret that grants agent
  execution on this host. On untrusted networks put it behind HTTPS
  (Cloudflare tunnel, Tailscale) before sharing the URL.
- **Each chat message is a full agent run**, so it costs tokens — unlike the feed
  poll, which is free.
- **The chat thread lives server-side** (`--continue <thread>`), so app-side
  history and server-side history can drift; that is expected.
