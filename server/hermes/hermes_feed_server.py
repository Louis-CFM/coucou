#!/usr/bin/env python3
"""Hermes feed server — serves the alert feed that Coucou's HermesPoller polls.
GET /hermes/health         -> {"status":"ok"}            (no auth)
GET /hermes/feed           -> feed.json                  (X-Hermes-Key required)
"""
import hmac, json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

TOKEN = Path("/root/.hermes/coucou/token").read_text().strip()
FEED = Path("/root/.hermes/coucou/feed.json")
PORT = 8645


class H(BaseHTTPRequestHandler):
    def _body(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        key = (self.headers.get("X-Hermes-Key") or "").strip()
        return hmac.compare_digest(key, TOKEN)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/hermes/health":
            self._body(200, {"status": "ok", "items": len(_load()["items"])})
        elif path == "/hermes/feed":
            if not self._auth():
                self._body(401, {"error": "unauthorized"})
                return
            self._body(200, _load())
        else:
            self._body(404, {"error": "not found"})

    def log_message(self, *a):
        pass


def _load():
    try:
        return json.loads(FEED.read_text())
    except Exception:
        return {"updated": 0, "items": []}


if __name__ == "__main__":
    print(f"hermes feed on :{PORT} (token from {TOKEN})", flush=True)
    HTTPServer(("0.0.0.0", PORT), H).serve_forever()
