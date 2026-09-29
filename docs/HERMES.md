# Hermes — talking to your own agent from the notch

Coucou can chat with **Hermes**, an agent that runs on your VPS (Hermes Agent), and show
its alerts as a notch pill. Both live behind one small bridge on the server.

Unlike the built-in providers, this is not a model endpoint: each message runs a real
agent session on your machine — with its own memory, skills and tools.

## 1. Server side

Two stdlib-only Python servers (no dependencies):

| File | Port | Purpose |
|---|---|---|
| `hermes_chat_server.py` | 8646 | `POST /chat {text, session}` → `{reply}` · `GET /chat/history` |
| `hermes_feed_server.py` | 8645 | `GET /hermes/feed` → the alert feed the notch polls |

Both authenticate with an `X-Hermes-Key` header (token in `~/.hermes/coucou/token`).
Open the ports in your firewall (`ufw allow 8645/tcp`, `8646/tcp`).

The chat bridge shells out to `hermes chat -Q --continue <thread> --query-file …`,
so the thread lives server-side and survives app restarts.

## 2. App side

**Settings → Chat → Provider → “Hermes (agent on your VPS)”**

| Field | Example |
|---|---|
| Bridge URL | `http://<vps-ip>:8646/chat` |
| X-Hermes-Key | the token from the server |
| Thread name | `coucou` |

The alert pill reuses the same URL/key and derives the feed URL automatically
(`/hermes/feed`); enable **Hermes** under Integrations to see it.

## 3. Files

- `LLMBackends.swift` — `ChatProvider.hermes` + `chatHermes(context:state:)`
- `HermesPoller.swift` — polls the alert feed, raises the orange pill
- `AppDelegate.swift` — starts the poller
- `AppState.swift` — registers the `integration_hermes` pill

## Notes

- **Cost**: one agent run per chat message. Alerts are free (plain HTTP polling).
- **Transport**: plain HTTP with a shared token by default — put the bridge behind
  HTTPS (e.g. a Cloudflare tunnel) if the machine travels on untrusted networks.
- **No telemetry**, and nothing is sent anywhere except the server you configure.
