# Hermes — talking to your own agent from the notch

Coucou can chat with **Hermes**, an agent that runs on your own machine (a VPS, a home
server, this Mac), and show its alerts as a notch pill. Both live behind one small
bridge on that machine.

Unlike the built-in providers, this is **not a model endpoint**: every message runs a
real agent session there — with its memory, skills and tools. That's the point, and also
why the bridge is more powerful (and needs a secret) than an API key.

```
  MacBook  ──HTTP + X-Hermes-Key──▶  bridge :8646  ──▶  hermes chat  ──▶  your agent
  (Coucou)  ◀──GET /hermes/feed────  bridge :8645  ◀──  alert items
```

## 1. Prerequisites

- **Hermes Agent** installed on the machine that should answer (`hermes` on PATH) —
  <https://hermes-agent.nousresearch.com>
- **python3** on that machine (the bridge uses the standard library only — nothing to install)
- The Mac must be able to reach that machine: a public IP, or a tunnel
  (Cloudflare Tunnel, Tailscale, `ssh -L`)

## 2. Server side — one command

```bash
git clone https://github.com/<you>/coucou && cd coucou
bash server/hermes/install.sh
```

The installer:

- copies both servers to `~/.hermes/coucou/`
- creates the key at `~/.hermes/coucou/token` (mode 600)
- opens ports 8645/8646 in `ufw` when it can
- installs **systemd user services** (`coucou-hermes-feed`, `coucou-hermes-chat`) so they
  start on boot — falling back to `nohup` on systems without systemd
- prints the **Bridge URL** and **X-Hermes-Key** to paste into the app

Overrides: `HERMES_COUCCO_DIR`, `HERMES_FEED_PORT`, `HERMES_CHAT_PORT`.

Keep the services alive across logout with `sudo loginctl enable-linger $USER`.

Check it yourself:

```bash
curl -s http://127.0.0.1:8645/hermes/health              # {"status":"ok",...}
curl -s -H "X-Hermes-Key: $(cat ~/.hermes/coucou/token)" \
     http://127.0.0.1:8645/hermes/feed                    # the feed (401 without the key)
```

## 3. App side

**Settings → Chat → Provider → “Hermes (agent on your VPS)”**

| Field | Example |
|---|---|
| Bridge URL | `http://<host>:8646/chat` |
| X-Hermes-Key | the key printed by the installer |
| Thread name | `coucou` |

The alert pill reuses the same URL/key and derives the feed URL automatically
(`/hermes/feed`); enable **Hermes** under Integrations to see it.

## 4. Feeding the notch (optional)

Anything that appends to `~/.hermes/coucou/feed.json` shows up as a pill within 20s:

```json
{"updated": 1738000000,
 "items": [{"id": "1738000000-1", "ts": 1738000000,
            "title": "3 new alerts", "detail": "…", "level": "info"}]}
```

Keep `id` unique — the poller dedupes on it, so an unchanged item never re-alerts.
Cron jobs, watchers and scripts on the agent side can all write here; see
`server/hermes/README.md`.

## 5. Let your agent set it up instead

The repo ships a Hermes **skill** at `hermes-skill/coucou-bridge/`. Install it with:

```bash
cp -r hermes-skill/coucou-bridge ~/.hermes/skills/
```

Then just ask your agent *“set up the Coucou bridge”* — it runs the installer, verifies
the endpoints, and hands you the two values.

## Security

- The key is a **bearer secret that grants agent execution** on that machine. Treat it
  like a shell password: don't commit it, don't paste it in public, rotate it by
  replacing `~/.hermes/coucou/token` and restarting the services.
- The default transport is **plain HTTP**. On any untrusted network, put the bridge
  behind HTTPS (Cloudflare Tunnel or Tailscale) and only then expose the ports.
- Prefer binding to a tailnet/VPN address over `0.0.0.0` when you can.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `401` in the app | Key mismatch — re-copy `~/.hermes/coucou/token`, then restart the services |
| `404` on the feed | Old bridge still running — `systemctl --user restart coucou-hermes-chat coucou-hermes-feed` |
| Health works locally but not from the Mac | Firewall/NAT, or the host isn't publicly reachable — use a tunnel |
| Chat times out | Each message is a full agent run; slow first turns are normal |
| Nothing survives reboot | Enable linger (above), or re-run the installer |

## Files

- `LLMBackends.swift` — `ChatProvider.hermes` + `chatHermes(context:state:)`
- `HermesPoller.swift` — polls the alert feed, raises the orange pill
- `AppDelegate.swift` — starts the poller
- `AppState.swift` — registers the `integration_hermes` pill
- `server/hermes/` — the two servers + installer
- `hermes-skill/coucou-bridge/` — the agent-side skill

**Cost:** one agent run per chat message. Alerts are free (plain HTTP polling).
**No telemetry** — nothing is sent anywhere except the server you configure.
