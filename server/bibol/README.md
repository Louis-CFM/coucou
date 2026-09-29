# bibol bridge (server side)

The two stdlib-only servers the app talks to. They run on the machine where the
agent lives (e.g. a VPS running Hermes Agent).

```
bibol_chat_server.py   :8646   POST /chat {text, session} -> {reply}
                               GET  /chat/history
bibol_feed_server.py   :8645   GET  /bibol/feed   (X-Bibol-Key)
                               GET  /bibol/health
```

## Setup

```bash
mkdir -p ~/.hermes/coucou
python3 -c "import secrets;print(secrets.token_urlsafe(24))" > ~/.hermes/coucou/token
chmod 600 ~/.hermes/coucou/token

python3 bibol_feed_server.py &     # alerts
python3 bibol_chat_server.py &     # chat
```

Open the ports (`ufw allow 8645/tcp`, `ufw allow 8646/tcp`). Put it behind HTTPS
before exposing it to untrusted networks — the token is a bearer secret.

## Feed format

`feed.json` is a list of items, newest first; anything on the box can append:

```json
{"updated": 1738000000,
 "items": [{"id": "1738000000-3", "ts": 1738000000,
            "title": "3 new alerts", "detail": "…", "level": "info"}]}
```

The chat bridge shells out to `hermes chat -Q --continue <thread> --query-file …`,
so each message is a full agent run on the server, and the thread persists there.
