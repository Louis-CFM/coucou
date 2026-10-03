#!/usr/bin/env python3
"""Minimal fake Ollama / LM Studio server for CI testing.

Usage: python3 fake_local_llm.py <port-file>
  Writes the bound port to <port-file>, then serves until killed.

Routes:
  GET  /v1/models              → two models (one embed, should be filtered out)
  POST /v1/chat/completions    → SSE stream with <think> block, reasoning-only
                                  deltas (content=null), and Markdown answer
  POST /v1/chat/completions    → 404 when model == "unknown-model"
"""

import json
import sys
import socket
import socketserver
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

# Two models; "nomic-embed-text" must be filtered by the Swift client
MODELS_RESPONSE = {
    "data": [
        {"id": "llama3.2",         "object": "model"},
        {"id": "nomic-embed-text", "object": "model"},
    ]
}

# SSE events that make up the streamed reply:
#  - events 0-2: a <think> block split over two chunks (should be hidden from UI)
#  - event 3: a delta with reasoning_content only (content is null → ignored)
#  - events 4-7: real Markdown answer
SSE_EVENTS = [
    {"choices": [{"delta": {"content": "<think>\nstep "}}]},
    {"choices": [{"delta": {"content": "one\n</think>"}}]},
    # reasoning-only delta: content key present but value is null
    {"choices": [{"delta": {"content": None, "reasoning_content": "internal"}}]},
    {"choices": [{"delta": {"content": "## Answer\n\n"}}]},
    {"choices": [{"delta": {"content": "Here is the result:\n\n"}}]},
    {"choices": [{"delta": {"content": "- **item 1**\n"}}]},
    {"choices": [{"delta": {"content": "- item 2\n\n"}}]},
    {"choices": [{"delta": {"content": "```python\nprint('hello')\n```"}}]},
]

EXPECTED_RESPONSE = "## Answer\n\nHere is the result:\n\n- **item 1**\n- item 2\n\n```python\nprint('hello')\n```"


class FakeLLMHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress request logging

    def do_GET(self):
        if self.path == "/v1/models":
            body = json.dumps(MODELS_RESPONSE).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            req_body = json.loads(raw)
        except Exception:
            req_body = {}

        model = req_body.get("model", "")

        if self.path != "/v1/chat/completions":
            self.send_response(404)
            self.end_headers()
            return

        # Unknown model → 404 with OpenAI-format error
        if model == "unknown-model":
            err = json.dumps({
                "error": {
                    "message": f"model '{model}' not found, try pulling it first",
                    "type": "not_found",
                }
            }).encode()
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(err)))
            self.end_headers()
            self.wfile.write(err)
            return

        # SSE stream
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        for event in SSE_EVENTS:
            line = ("data: " + json.dumps(event) + "\n\n").encode()
            self.wfile.write(line)
            self.wfile.flush()
            time.sleep(0.005)

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


class FastBindHTTPServer(HTTPServer):
    """HTTPServer that skips the reverse-DNS lookup in server_bind.

    The default HTTPServer.server_bind calls socket.getfqdn(), which triggers
    a reverse-DNS lookup for the bound address.  On some CI runners this can
    block for several seconds and cause the port-file handshake to time out.
    We bypass it by calling TCPServer.server_bind directly and hard-coding
    server_name to the loopback address we already know we are binding to.
    """

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


if __name__ == "__main__":
    port = find_free_port()
    server = FastBindHTTPServer(("127.0.0.1", port), FakeLLMHandler)

    # Write port to the file passed as argv[1] so the caller can read it
    if len(sys.argv) > 1:
        with open(sys.argv[1], "w") as f:
            f.write(str(port))
            f.flush()

    server.serve_forever()
