# Hermes bridge (server side)

Two stdlib-only Python servers the Coucou app talks to, plus an installer. They
run on the machine where the agent lives (VPS, home server, or the Mac itself).

```
hermes_chat_server.py   :8646   POST /chat {text, session} -> {reply}
                               GET  /chat/history
hermes_feed_server.py   :8645   GET  /hermes/feed   (X-Hermes-Key)
                               GET  /hermes/health
```

## Install

```bash
bash install.sh
```

That copies both servers to `~/.hermes/coucou/`, creates the key, opens the
ports when it can, installs systemd user services (or falls back to `nohup`),
and prints the Bridge URL + key to paste into the app. Full walkthrough:
[`docs/HERMES.md`](../../docs/HERMES.md).

Env overrides: `HERMES_COUCCO_DIR` (default `~/.hermes/coucou`),
`HERMES_FEED_PORT` (8645), `HERMES_CHAT_PORT` (8646).

## Feed format

`feed.json` is a list of items, newest first; anything on the box can append:

```json
{"updated": 1738000000,
 "items": [{"id": "1738000000-3", "ts": 1738000000,
            "title": "3 new alerts", "detail": "…", "level": "info"}]}
```

`id` must be unique — the poller dedupes on it and only re-alerts on change.

## Notes

- The chat bridge shells out to `hermes chat -Q --continue <thread> --query-file …`,
  so each message is a full agent run and the thread persists server-side.
- Auth is an `X-Hermes-Key` header on every request except `/hermes/health`.
- The key is a bearer secret granting agent execution on this machine — keep it
  out of git and put the bridge behind HTTPS before exposing it publicly.
