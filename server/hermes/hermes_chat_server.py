#!/usr/bin/env python3
"""Hermes chat bridge — lets Coucou chat with the Hermes agent on the VPS.
POST /chat            {"text": "...", "session": "coucou"}  -> {"reply": "...", "session_id": "..."}
GET  /chat/history?session_id=...   -> last N user/assistant messages of that session
Auth: X-Hermes-Key header (same token as the feed).
"""
import hmac, json, subprocess, tempfile, os, re, sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TOKEN = Path("/root/.hermes/coucou/token").read_text().strip()
PORT = 8646
HIST_LIMIT = 20
DB = "/root/.hermes/state.db"


def session_id_for(title):
    try:
        con = sqlite3.connect(DB)
        row = con.execute(
            "SELECT id FROM sessions WHERE title=? ORDER BY rowid DESC LIMIT 1", (title,)).fetchone()
        con.close()
        return row[0] if row else None
    except Exception:
        return None


def history(session_id):
    try:
        con = sqlite3.connect(DB)
        rows = con.execute(
            "SELECT role, content FROM messages WHERE session_id=? AND role IN ('user','assistant') "
            "AND content IS NOT NULL AND length(content)>0 AND active=1 ORDER BY id DESC LIMIT ?",
            (session_id, HIST_LIMIT)).fetchall()
        con.close()
        return [{"role": r, "text": c[:2000]} for r, c in reversed(rows)]
    except Exception:
        return []


def run_agent(text, session):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write(text)
        qfile = f.name
    try:
        cmd = ["hermes", "chat", "-Q", "--continue", session,
               "--query-file", qfile, "--create-if-missing"]
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        out = (p.stdout or "").strip()
        if p.returncode != 0:
            err = (p.stderr or "").strip().splitlines()
            out = out or ("⚠️ agent error: " + (err[-1] if err else f"rc={p.returncode}"))
        return out, session_id_for(session), p.returncode
    finally:
        os.unlink(qfile)


class H(BaseHTTPRequestHandler):
    def _auth(self):
        return hmac.compare_digest((self.headers.get("X-Hermes-Key") or "").strip(), TOKEN)

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/chat/history":
            if not self._auth():
                return self._send(401, {"error": "unauthorized"})
            qs = self.path.split("?", 1)
            q = dict(pair.split("=", 1) for pair in qs[1].split("&") if "=" in pair) if len(qs) > 1 else {}
            sid = q.get("session_id", "") or (session_id_for("coucou") or "")
            return self._send(200, {"messages": history(sid), "session_id": sid})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?")[0] != "/chat":
            return self._send(404, {"error": "not found"})
        if not self._auth():
            return self._send(401, {"error": "unauthorized"})
        try:
            n = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(n) or b"{}")
            text = str(body.get("text", "")).strip()
            session = str(body.get("session", "coucou"))
        except Exception:
            return self._send(400, {"error": "bad json"})
        if not text:
            return self._send(400, {"error": "empty text"})
        try:
            reply, sid, rc = run_agent(text, session)
            return self._send(200, {"reply": reply, "session_id": sid or session, "rc": rc})
        except subprocess.TimeoutExpired:
            return self._send(504, {"error": "agent timeout"})
        except Exception as e:
            return self._send(500, {"error": str(e)})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"hermes chat bridge on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
