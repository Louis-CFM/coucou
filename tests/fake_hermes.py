#!/usr/bin/env python3
"""Minimal fake Hermes API server (localhost only) for tests/HermesChatTests.swift.

Usage: python3 fake_hermes.py <port-file>

Keys: test-key-default (unprefixed and /p/default), test-key-mark (/p/mark).
Routes (prefix is "", "/p/default" or "/p/mark"):
  GET  <prefix>/v1/models            -> {"data":[{"id":"mark"}]} / hermes-agent
  GET  /dashboard/v1/models          -> 200 text/html (SSO page stand-in)
  GET  /sso/v1/models                -> 302 to /login
  POST <prefix>/v1/chat/completions  -> SSE (keepalive, named event, reasoning, content, finish, [DONE])
        last user message "fail" -> finish_reason "error" + error.message "boom"
        last user message "busy" -> 429 OpenAI envelope
        "content_error"  -> some content, then finish_reason "error" + message
        "content_closed" -> some content, then the connection closes (no finish, no [DONE])
        "content_reset"  -> some content, then the connection is reset (RST)
        "longline"       -> one 5000 byte line without a newline
        "bigtext"        -> content frames totalling 3000 characters
        "slow"           -> some content, then keepalive lines for ~8 s
        "steps"          -> text, a tool (running then completed, real hermes.tool.progress shape), text
        "steps2"         -> text, two tools, text, one more tool, the answer
        "steps_off"      -> the same text as "steps" with no named frame at all
        "approval"       -> text, a named approval.request frame (a marker command, no request id: not answerable)
        "approval-wait"  -> text, an approval.request (request id rq-1, four choices), then keepalive lines until
                            POST <prefix>/v1/runs/<run id>/approval answers it (or approval_wait seconds pass), then
                            "ran: <choice>" / "blocked: deny" / "no answer"
        "approval-two"   -> two approval.request frames (rq-a, rq-b), each answered by its own POST
        "approval-end"   -> an approval.request, then the stream ends while it is pending
        "approval-long"  -> an approval.request whose command is over the ceiling
        "approval-bidi"  -> an approval.request with a right to left override and zero width characters
        "approval-bad-run" -> an approval.request whose run_id has path characters
        "approval-smart" -> an approval.request with choices once and deny (smart denied)
        "long_label"     -> a tool whose label is 5000 characters
        "status"         -> a named hermes.status frame between two texts
        "cut_in_tool"    -> text, a tool that starts and never finishes, then the connection closes
        "think_split"    -> a <think> block that opens before a tool and closes after it, then a second tool and the answer
        "reuse_id"       -> one toolCallId used by two calls in a row, each with its own text before it
        "burst"          -> a hundred tool running / completed pairs in one write, then the answer
        "seq3"           -> three tools in sequence with a pause (0.5 s) before each completion: the next tool starts right after
                            the previous one ends, as the server does in a round
        "text_tool"      -> a sentence and the start of a tool in ONE write, a pause, then the completion and the answer
        "think_open"     -> a <think> that never closes, across two tools, then the answer
        "think_literal"  -> an answer that names the tag in inline code
        "bigmodels"      -> (GET /big/v1/models) a 100 KB body
  POST <prefix>/v1/runs/<run id>/approval -> the approval endpoint of the real server (api_server_runs.py): bearer of the key
        that started the stream, body {"choice", "request_id"}: 200 {"object": "hermes.run.approval_response", "run_id",
        "choice", "request_id", "resolved": 1}, 409 approval_not_pending, 400 for a bad choice or id, 404 for another key.
Test control (shared by both endpoints):
  POST /_test/reset                    counters and failures back to zero
  POST /_test/config {"models_drop": N, "chat_drop": N, "chat_stall": seconds, "chat_stall_count": N, "chat_status": 500,
                      "models_stall": seconds, "models_stall_count": N, "approval_status": N, "approval_wait": seconds}
        approval_status: every approval POST answers this status (401, 404, 500...)
        approval_wait: how long an approval scenario waits for the POST (default 6)
        models_drop: accept the next N models requests and close the connection without answering
        chat_drop: accept the next N chat requests, READ THE WHOLE BODY, then close without answering (the request
          reached the server, so the client must not send it again)
        models_stall: hold the response headers of the next models_stall_count models requests for that long
        chat_stall: hold the response headers of the next chat_stall_count chat requests for that long
        chat_status: answer every chat request with this status
  GET  /_test/state                    {"models_hits": n, "chat_hits": n, "approval_posts": n, "stream_closed": n}
  GET  /_test/posts                    {"posts": [every approval POST: path, bearer, body, profile]}
  GET  /_test/last_body                the raw JSON body of the last chat request (as the client sent it)
Wrong/missing key -> 401 gateway_auth_failed. Unknown profile -> 404.
Response header X-Test-Model echoes the request "model"; X-Test-System is "1" if a system
message was sent (the client must not send one).
"""

import json
import socket
import socketserver
import struct
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

KEYS = {"": "test-key-default", "default": "test-key-default", "mark": "test-key-mark"}
MODEL_IDS = {"": "hermes-agent", "default": "hermes-agent", "mark": "mark"}

CONTENT = ["Hello ", "from ", "mark."]
EXPECTED_RESPONSE = "Hello from mark."

# The text of the "steps" scenarios: what the agent says before a tool, and the answer after it. In the real
# stream the text after a tool round starts with one blank line (agent/stream_delivery.py "_stream_needs_break").
STEPS_FIRST = "Let me check the page."
STEPS_ANSWER = "The page is limited."
STEPS_TEXT = STEPS_FIRST + "\n\n" + STEPS_ANSWER
REASONING_MARKER = "REASONING_MARKER_77"
APPROVAL_MARKER = "rm -rf APPROVAL_COMMAND_MARKER_88"


def envelope(message, etype, code):
    return json.dumps({"error": {"message": message, "type": etype, "code": code}}).encode()


LOCK = threading.Lock()
CONFIG = {}
COUNTS = {}
LAST = {"body": b""}
APPROVALS = {}   # run id -> {"bearer", "request_ids": {id: entry}}
POSTS = []       # every approval POST: path, bearer, body, status


def reset():
    with LOCK:
        CONFIG.clear()
        CONFIG.update({"models_drop": 0, "chat_drop": 0, "chat_stall": 0, "chat_stall_count": 0, "chat_status": 0,
                       "models_stall": 0, "models_stall_count": 0, "approval_status": 0, "approval_wait": 6})
        COUNTS.clear()
        COUNTS.update({"models_hits": 0, "chat_hits": 0, "other_hits": 0, "approval_posts": 0, "stream_closed": 0})
        LAST["body"] = b""
        APPROVALS.clear()
        POSTS.clear()


reset()


def take(key):
    with LOCK:
        if CONFIG[key] > 0:
            CONFIG[key] -= 1
            return True
    return False


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send_json(self, status, body, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def route(self):
        """Returns (profile, tail) or None when the path is unknown."""
        path = self.path.split("?")[0]
        if path.startswith("/p/"):
            rest = path[3:]
            profile, _, tail = rest.partition("/")
            if profile not in ("default", "mark"):
                return ("__unknown__", "/" + tail)
            return (profile, "/" + tail)
        return ("", path)

    def authed(self, profile):
        return self.headers.get("Authorization", "") == "Bearer " + KEYS[profile]

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/_test/state":
            with LOCK:
                return self.send_json(200, json.dumps(COUNTS).encode())
        if path == "/_test/posts":
            with LOCK:
                return self.send_json(200, json.dumps({"posts": POSTS}).encode())
        if path == "/_test/last_body":
            with LOCK:
                return self.send_json(200, LAST["body"] or b"{}")
        if path == "/dashboard/v1/models":
            body = b"<html><body>Login</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/big/v1/models":
            body = b'{"data":[{"id":"mark"}],"pad":"' + b"x" * 100_000 + b'"}'
            return self.send_json(200, body)
        if path == "/sso/v1/models":
            self.send_response(302)
            self.send_header("Location", "/login")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        profile, tail = self.route()
        if profile == "__unknown__":
            return self.send_json(404, envelope("no such profile", "not_found", "profile_not_found"))
        if tail == "/v1/models":
            with LOCK:
                COUNTS["models_hits"] += 1
            if take("models_drop"):
                self.close_connection = True
                return
            if take("models_stall_count"):
                with LOCK:
                    hold = CONFIG["models_stall"]
                time.sleep(hold)
        if tail != "/v1/models":
            with LOCK:
                COUNTS["other_hits"] += 1
            return self.send_json(404, envelope("not found", "not_found", "not_found"))
        if not self.authed(profile):
            return self.send_json(401, envelope("Invalid API key", "invalid_request_error", "gateway_auth_failed"))
        self.send_json(200, json.dumps({"object": "list", "data": [{"id": MODEL_IDS[profile]}]}).encode())

    def approval_post(self, profile, tail, raw):
        """POST <prefix>/v1/runs/<run id>/approval, as the real handler answers it (api_server_runs.py)."""
        run_id = tail[len("/v1/runs/"):-len("/approval")]
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = None
        with LOCK:
            COUNTS["approval_posts"] += 1
            forced = CONFIG["approval_status"]
            POSTS.append({"path": self.path, "bearer": self.headers.get("Authorization", ""), "body": body, "profile": profile})
        if profile == "__unknown__":
            return self.send_json(404, envelope("no such profile", "not_found", "profile_not_found"))
        if forced:
            return self.send_json(forced, envelope("injected", "server_error", "injected"))
        if not self.authed(profile):
            return self.send_json(401, envelope("Invalid API key", "invalid_request_error", "gateway_auth_failed"))
        with LOCK:
            run = APPROVALS.get(run_id)
        if run is None or run["bearer"] != self.headers.get("Authorization", ""):
            return self.send_json(404, envelope("run not found", "not_found", "run_not_found"))
        if not isinstance(body, dict) or body.get("choice") not in ("once", "session", "always", "deny") \
                or not isinstance(body.get("request_id"), str) or not body.get("request_id"):
            return self.send_json(400, envelope("bad choice or request id", "invalid_request_error", "invalid_choice"))
        with LOCK:
            entry = run["requests"].get(body["request_id"])
            if entry is None or entry["choice"] is not None or run["ended"]:
                code = "approval_not_active" if run["ended"] else "approval_not_pending"
                return self.send_json(409, envelope("nothing is waiting", "conflict", code))
            entry["choice"] = body["choice"]
            entry["event"].set()
        return self.send_json(200, json.dumps({"object": "hermes.run.approval_response", "run_id": run_id,
                                               "choice": body["choice"], "request_id": body["request_id"], "resolved": 1}).encode())

    def do_POST(self):
        if self.path.split("?")[0] in ("/_test/reset", "/_test/config"):
            n = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(n) if n else b""
            if self.path.endswith("reset"):
                reset()
            else:
                with LOCK:
                    CONFIG.update(json.loads(raw or b"{}"))
            return self.send_json(200, b"{}")
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            req = json.loads(raw)
        except Exception:
            req = {}
        profile, tail = self.route()
        if tail.startswith("/v1/runs/") and tail.endswith("/approval"):
            return self.approval_post(profile, tail, raw)
        if tail == "/v1/chat/completions":
            with LOCK:
                LAST["body"] = raw
        if profile == "__unknown__":
            return self.send_json(404, envelope("no such profile", "not_found", "profile_not_found"))
        if tail != "/v1/chat/completions":
            with LOCK:
                COUNTS["other_hits"] += 1
            return self.send_json(404, envelope("not found", "not_found", "not_found"))
        with LOCK:
            COUNTS["chat_hits"] += 1
            status = CONFIG["chat_status"]
        if take("chat_drop"):
            self.close_connection = True
            return
        if take("chat_stall_count"):
            with LOCK:
                hold = CONFIG["chat_stall"]
            time.sleep(hold)
        if status:
            return self.send_json(status, envelope("injected", "server_error", "injected"))
        if not self.authed(profile):
            return self.send_json(401, envelope("Invalid API key", "invalid_request_error", "gateway_auth_failed"))

        msgs = req.get("messages", [])
        has_system = any(m.get("role") == "system" for m in msgs)
        last_user = ""
        for m in reversed(msgs):
            if m.get("role") == "user":
                c = m.get("content")
                last_user = c if isinstance(c, str) else json.dumps(c)
                break
        extra = {"X-Test-Model": str(req.get("model", "")), "X-Test-System": "1" if has_system else "0"}

        if last_user == "busy":
            return self.send_json(429, envelope("Too many requests", "rate_limit_error", "busy"), extra)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        for k, v in extra.items():
            self.send_header(k, v)
        self.end_headers()
        self.close_connection = True

        class Gone(Exception):
            pass

        def emit(raw_text):
            try:
                self.wfile.write(raw_text.encode())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                raise Gone()
            time.sleep(0.005)

        run_id = "chatcmpl-" + secrets.token_hex(15)[:29]
        run = {"bearer": self.headers.get("Authorization", ""), "requests": {}, "ended": False}
        with LOCK:
            APPROVALS[run_id] = run

        def approval_event(request_id, command, choices=("once", "session", "always", "deny"), rid=None, **extra):
            """The frame of api_server.py: the queue's data plus event, run_id, timestamp, session_id and choices."""
            payload = {"event": "approval.request", "run_id": rid or run_id, "timestamp": 1.0, "session_id": "s1",
                       "choices": list(choices), "request_id": request_id, "command": command, "description": "recursive delete",
                       "pattern_key": "recursive delete", "pattern_keys": ["recursive delete"],
                       "allow_permanent": "always" in choices, "allow_session": "session" in choices}
            payload.update(extra)
            entry = {"choice": None, "event": threading.Event()}
            with LOCK:
                run["requests"][request_id] = entry
            return "event: approval.request\ndata: " + json.dumps(payload) + "\n\n", entry

        def wait_for(entries):
            with LOCK:
                limit = CONFIG["approval_wait"]
            end = time.time() + limit
            while time.time() < end and not all(e["event"].is_set() for e in entries):
                emit(": keepalive\n\n")
                time.sleep(0.05)

        def chunk(delta, finish=None, **more):
            c = {"object": "chat.completion.chunk", "id": run_id, "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            c.update(more)
            return "data: " + json.dumps(c) + "\n\n"

        def reset_connection():
            self.wfile.flush()
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            self.connection.close()

        def tool_running(call_id, tool, label, emoji="🔧"):
            # The real shape: hermes/gateway/platforms/api_server_openai_routes.py, tool_progress "running".
            return ("event: hermes.tool.progress\ndata: " + json.dumps(
                {"tool": tool, "emoji": emoji, "label": label, "toolCallId": call_id, "status": "running"}) + "\n\n")

        def tool_completed(call_id, tool):
            return ("event: hermes.tool.progress\ndata: " + json.dumps(
                {"tool": tool, "toolCallId": call_id, "status": "completed"}) + "\n\n")

        own_stream = ("steps", "steps2", "steps_off", "approval", "approval-wait", "approval-two", "approval-end", "approval-long",
                      "approval-bidi", "approval-bad-run", "approval-smart", "long_label", "status", "cut_in_tool", "think_split", "reuse_id", "burst",
                      "seq3", "text_tool", "think_open", "think_literal", "media")
        try:
            emit(chunk({"role": "assistant"}))
            emit(": keepalive\n\n")
            if last_user not in own_stream:
                emit(tool_running("call_1", "terminal", "curl -s localhost", "💻"))
                emit(chunk({"reasoning_content": "thinking about it"}))
            if last_user == "steps" or last_user == "steps_off":
                emit(chunk({"reasoning_content": REASONING_MARKER}))
                emit(chunk({"content": STEPS_FIRST}))
                if last_user == "steps":
                    emit(tool_running("call_1", "terminal", "curl -s graph.facebook.com/v19.0/me", "💻"))
                    emit(tool_completed("call_1", "terminal"))
                emit(chunk({"content": "\n\n" + STEPS_ANSWER}))
                emit(chunk({}, "stop", usage={"total_tokens": 3}))
            elif last_user == "steps2":
                emit(chunk({"content": "Let me check the page."}))
                emit(tool_running("call_1", "terminal", "curl -s graph.facebook.com/v19.0/me", "💻"))
                emit(tool_completed("call_1", "terminal"))
                emit(chunk({"content": "\n\nThe restriction has an unlock date. Checking the queue."}))
                emit(tool_running("call_2", "mongo_query", "automations-flow, last 48h", "🗄️"))
                emit(tool_completed("call_2", "mongo_query"))
                emit(chunk({"content": "\n\n**Yes.** The page is *limited* now."}))
                emit(chunk({}, "stop", usage={"total_tokens": 3}))
            elif last_user == "approval":
                emit(chunk({"content": "I need to run a command."}))
                emit("event: approval.request\ndata: " + json.dumps(
                    {"event": "approval.request", "run_id": run_id, "command": APPROVAL_MARKER, "description": "danger",
                     "session_id": "s1", "timestamp": 1.0, "choices": ["once", "deny"]}) + "\n\n")
                emit(chunk({"content": "\n\nWaiting."}))
                emit(chunk({}, "stop"))
            elif last_user in ("approval-wait", "approval-smart", "approval-long", "approval-bidi", "approval-bad-run", "approval-end"):
                emit(chunk({"content": "I need to run a command."}))
                command = "rm -rf /tmp/x " + APPROVAL_MARKER
                choices = ("once", "session", "always", "deny")
                rid = None
                if last_user == "approval-smart":
                    choices = ("once", "deny")
                elif last_user == "approval-long":
                    command = "echo first\n" + ("x" * 2600) + APPROVAL_MARKER
                elif last_user == "approval-bidi":
                    command = "cat \u202egpj.sh\u202c \u200b" + APPROVAL_MARKER
                elif last_user == "approval-bad-run":
                    rid = "chatcmpl-ab/../x"
                frame, entry = approval_event("rq-1", command, choices, rid=rid)
                emit(frame)
                if last_user == "approval-end":
                    time.sleep(0.4)
                    with LOCK:
                        run["ended"] = True
                    return
                wait_for([entry])
                choice = entry["choice"]
                emit(chunk({"content": "\n\n" + ("no answer" if choice is None else "blocked: deny" if choice == "deny" else "ran: " + choice)}))
                emit(chunk({}, "stop"))
            elif last_user == "approval-two":
                emit(chunk({"content": "Two commands."}))
                fa, ea = approval_event("rq-a", "echo a " + APPROVAL_MARKER)
                fb, eb = approval_event("rq-b", "echo b " + APPROVAL_MARKER)
                emit(fa + fb)
                wait_for([ea, eb])
                emit(chunk({"content": "\n\na:%s b:%s" % (ea["choice"], eb["choice"])}))
                emit(chunk({}, "stop"))
            elif last_user == "long_label":
                emit(chunk({"content": "Working."}))
                emit(tool_running("call_1", "terminal", "L" * 5000))
                emit(tool_completed("call_1", "terminal"))
                emit(chunk({"content": "\n\nDone."}))
                emit(chunk({}, "stop"))
            elif last_user == "status":
                emit(chunk({"content": "Before."}))
                emit("event: hermes.status\ndata: " + json.dumps({"kind": "wait", "text": "STATUS_MARKER_99 waiting"}) + "\n\n")
                emit(chunk({"content": " After."}))
                emit(chunk({}, "stop"))
            elif last_user == "cut_in_tool":
                emit(chunk({"content": "Starting."}))
                emit(tool_running("call_1", "terminal", "sleep 100"))
                return
            elif last_user == "think_split":
                emit(chunk({"content": "Hello. <think>plan part one"}))
                emit(tool_running("call_1", "terminal", "ls", "💻"))
                emit(tool_completed("call_1", "terminal"))
                emit(chunk({"content": "\n\nplan part two</think>Mid text."}))
                emit(tool_running("call_2", "terminal", "ls", "💻"))
                emit(tool_completed("call_2", "terminal"))
                emit(chunk({"content": "\n\nAnswer."}))
                emit(chunk({}, "stop"))
            elif last_user == "reuse_id":
                emit(chunk({"content": "First."}))
                emit(tool_running("same", "terminal", "ls", "💻"))
                emit(tool_completed("same", "terminal"))
                emit(chunk({"content": "\n\nAgain."}))
                emit(tool_running("same", "terminal", "ls", "💻"))
                emit(tool_completed("same", "terminal"))
                emit(chunk({"content": "\n\nAnswer."}))
                emit(chunk({}, "stop"))
            elif last_user == "media":
                # The media directives of an agent that hands over a file, cut inside the keyword and inside the path.
                for part in ("Primeiro audio. 6s.\n\n[[audio", "_as_voice]]\nME", "DIA:/tmp/AI Br", "ain/her-new-photos.ogg\n\nOuve e me fala."):
                    emit(chunk({"content": part}))
                emit(chunk({}, "stop"))
            elif last_user == "burst":
                # One write: the client reads the hundred pairs inside a single refresh window.
                emit("".join(tool_running("b%d" % i, "terminal", "step %d" % i) + tool_completed("b%d" % i, "terminal") for i in range(100)))
                emit(chunk({"content": "Burst done."}))
                emit(chunk({}, "stop"))
            elif last_user == "seq3":
                emit(chunk({"content": "Look."}))
                emit(tool_running("s1", "terminal", "one", "💻"))
                emit(tool_completed("s1", "terminal"))
                emit(tool_running("s2", "terminal", "two", "💻"))
                time.sleep(0.5)
                emit(tool_completed("s2", "terminal"))
                emit(tool_running("s3", "terminal", "three", "💻"))
                time.sleep(0.5)
                emit(tool_completed("s3", "terminal"))
                emit(chunk({"content": "\n\nAnswer."}))
                emit(chunk({}, "stop"))
            elif last_user == "text_tool":
                emit(chunk({"content": "Sentence."}) + tool_running("w1", "terminal", "work", "💻"))
                time.sleep(0.6)
                emit(tool_completed("w1", "terminal"))
                emit(chunk({"content": "\n\nAnswer."}))
                emit(chunk({}, "stop"))
            elif last_user == "think_open":
                emit(chunk({"content": "Hi. <think>plan"}))
                emit(tool_running("o1", "terminal", "ls", "💻"))
                emit(tool_completed("o1", "terminal"))
                emit(chunk({"content": "\n\nMore."}))
                emit(tool_running("o2", "terminal", "ls", "💻"))
                emit(tool_completed("o2", "terminal"))
                emit(chunk({"content": "\n\nAnswer."}))
                emit(chunk({}, "stop"))
            elif last_user == "think_literal":
                emit(chunk({"content": "Use the `<think>` tag for reasoning. Then answer."}))
                emit(chunk({}, "stop"))
            elif last_user == "fail":
                emit(chunk({}, "error", error={"message": "boom"}))
            elif last_user == "content_error":
                emit(chunk({"content": "Partial "}))
                emit(chunk({"content": "answer."}))
                emit(chunk({}, "error", error={"message": "tool crashed"}))
            elif last_user == "content_closed":
                emit(chunk({"content": "Partial answer."}))
                return
            elif last_user == "content_reset":
                emit(chunk({"content": "Partial answer."}))
                time.sleep(0.2)
                reset_connection()
                return
            elif last_user == "longline":
                emit("data: " + "x" * 5000)
                time.sleep(0.5)
                return
            elif last_user == "bigtext":
                emit(chunk({"content": "Start. "}))
                for _ in range(30):
                    emit(chunk({"content": "y" * 100}))
                emit(chunk({}, "stop"))
            elif last_user == "slow":
                emit(chunk({"content": "Slow start."}))
                for _ in range(160):
                    emit(": keepalive\n\n")
                    time.sleep(0.05)
            else:
                emit(tool_completed("call_1", "terminal"))
                for piece in CONTENT:
                    emit(chunk({"content": piece}))
                emit(chunk({}, "stop", usage={"total_tokens": 3}))
            emit("data: [DONE]\n\n")
        except Gone:
            with LOCK:
                COUNTS["stream_closed"] += 1
        finally:
            with LOCK:
                run["ended"] = True


class FastBindHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


if __name__ == "__main__":
    port = find_free_port()
    server = FastBindHTTPServer(("127.0.0.1", port), Handler)
    if len(sys.argv) > 1:
        with open(sys.argv[1], "w") as f:
            f.write(str(port))
            f.flush()
    server.serve_forever()
