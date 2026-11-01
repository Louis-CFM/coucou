#!/usr/bin/env python3
"""Local JSONL MCP question bridge. Answers exist only in the live tool response."""

import json
import os
import socket
import stat
import sys
import threading
import time
import uuid

MAX_BYTES = 65_536
WAIT_SECONDS = 120
FALLBACK = "Ask the user again in the original Codex conversation; no answer was accepted."
SOCKET_PATH = os.path.expanduser("~/Library/Application Support/NotchBuddy/nb.sock")

QUESTION_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "required": ["id", "question"],
    "properties": {
        "id": {"type": "string", "minLength": 1, "maxLength": 128},
        "question": {"type": "string", "minLength": 1, "maxLength": 4096},
        "header": {"type": "string", "maxLength": 128},
        "options": {"type": "array", "maxItems": 9, "items": {
            "type": "object", "additionalProperties": False, "required": ["label"],
            "properties": {"label": {"type": "string", "minLength": 1, "maxLength": 512},
                           "description": {"type": "string", "maxLength": 1024}}}},
        "isOther": {"type": "boolean", "default": True},
        "isSecret": {"type": "boolean", "default": False},
    },
}
TOOL = {
    "name": "ask_question",
    "description": "Ask 1-4 questions in local Coucou and return the user's choices or typed answers to this conversation. Requires Coucou running on this Mac. Does not intercept built-in Codex questions.",
    "inputSchema": {"type": "object", "additionalProperties": False,
                    "required": ["cwd", "questions"], "properties": {
                        "cwd": {"type": "string", "description": "Absolute directory of the current project."},
                        "questions": {"type": "array", "minItems": 1, "maxItems": 4,
                                      "items": QUESTION_SCHEMA}}},
    "annotations": {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False},
}


def text(value, limit, empty=False):
    if not isinstance(value, str) or "\0" in value or len(value.encode("utf-8")) > limit:
        raise ValueError("invalid text")
    if not empty and not value.strip():
        raise ValueError("empty text")
    return value


def normalize(arguments):
    if not isinstance(arguments, dict) or set(arguments) != {"cwd", "questions"}:
        raise ValueError("invalid arguments")
    cwd = text(arguments["cwd"], 4096)
    if not os.path.isabs(cwd) or not os.path.isdir(cwd):
        raise ValueError("invalid cwd")
    questions = arguments["questions"]
    if not isinstance(questions, list) or not 1 <= len(questions) <= 4:
        raise ValueError("invalid questions")
    result, ids = [], set()
    for question in questions:
        if not isinstance(question, dict) or set(question) - set(QUESTION_SCHEMA["properties"]):
            raise ValueError("invalid question")
        ident = text(question.get("id"), 128)
        if ident in ids or any(ord(c) < 32 for c in ident):
            raise ValueError("invalid question id")
        ids.add(ident)
        item = {"id": ident, "question": text(question.get("question"), 4096),
                "header": text(question.get("header", ""), 128, empty=True)[:12],
                "options": []}
        for flag, default in (("isOther", True), ("isSecret", False)):
            item[flag] = question.get(flag, default)
            if not isinstance(item[flag], bool):
                raise ValueError("invalid flag")
        options = question.get("options", [])
        if not isinstance(options, list) or len(options) > 9:
            raise ValueError("invalid options")
        labels = set()
        for option in options:
            if not isinstance(option, dict) or set(option) - {"label", "description"}:
                raise ValueError("invalid option")
            label = text(option.get("label"), 512)
            if label in labels:
                raise ValueError("duplicate option")
            labels.add(label)
            item["options"].append({"label": label,
                                    "description": text(option.get("description", ""), 1024, empty=True)})
        if not options and not item["isOther"]:
            raise ValueError("question has no answer field")
        result.append(item)
    return os.path.normpath(cwd), result


def decode(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique)


def valid_id(value):
    return (type(value) is int or isinstance(value, str)) and len(str(value).encode("utf-8")) <= 256


class Bridge:
    def __init__(self, socket_path=SOCKET_PATH, wait_seconds=WAIT_SECONDS):
        self.socket_path = socket_path
        self.wait_seconds = min(wait_seconds, WAIT_SECONDS)
        self.session_id = str(uuid.uuid4())
        self.lock = threading.RLock()
        self.pending = None
        self.closed = False
        self.initialized = False

    def reply(self, ident, result=None, error=None):
        with self.lock:
            if self.closed:
                return
            payload = {"jsonrpc": "2.0", "id": ident}
            payload["error" if error else "result"] = error if error else result
            try:
                sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
                sys.stdout.flush()
            except OSError:
                self.closed = True
                self.close_pending()

    def failure(self, ident, message):
        self.reply(ident, {"isError": True, "content": [{"type": "text", "text": message + " " + FALLBACK}]})

    def close_pending(self):
        if self.pending:
            self.pending["cancelled"].set()
            client = self.pending.get("socket")
            if client:
                try:
                    client.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                client.close()

    def dispatch(self, request):
        if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
            self.reply(None, error={"code": -32600, "message": "Invalid request"})
            return
        method, ident = request.get("method"), request.get("id")
        if "id" not in request:
            if method == "notifications/cancelled":
                params = request.get("params")
                with self.lock:
                    if isinstance(params, dict) and self.pending and type(params.get("requestId")) is type(self.pending["id"]) and params.get("requestId") == self.pending["id"]:
                        self.close_pending()
            return
        if not valid_id(ident) or not isinstance(method, str):
            self.reply(None, error={"code": -32600, "message": "Invalid request"})
            return
        with self.lock:
            if self.pending and type(ident) is type(self.pending["id"]) and ident == self.pending["id"]:
                self.reply(None, error={"code": -32600, "message": "Duplicate outstanding request id"})
                return
        if method == "initialize":
            if self.initialized:
                self.reply(ident, error={"code": -32600, "message": "Already initialized"})
                return
            params = request.get("params", {})
            version = params.get("protocolVersion") if isinstance(params, dict) else None
            if not isinstance(version, str):
                self.reply(ident, error={"code": -32602, "message": "Missing protocolVersion"})
                return
            self.initialized = True
            versions = {"2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"}
            self.reply(ident, {"protocolVersion": version if version in versions else "2025-11-25",
                               "capabilities": {"tools": {}},
                               "serverInfo": {"name": "coucou-desktop", "version": "0.1.0"}})
        elif method == "ping":
            self.reply(ident, {})
        elif not self.initialized:
            self.reply(ident, error={"code": -32600, "message": "Not initialized"})
        elif method == "tools/list":
            self.reply(ident, {"tools": [TOOL]})
        elif method == "tools/call":
            params = request.get("params")
            if not isinstance(params, dict) or params.get("name") != "ask_question":
                self.reply(ident, error={"code": -32602, "message": "Unknown tool"})
                return
            try:
                cwd, questions = normalize(params.get("arguments"))
            except (ValueError, UnicodeError):
                self.failure(ident, "Invalid Coucou question arguments.")
                return
            with self.lock:
                if self.pending:
                    self.failure(ident, "A Coucou question is already waiting for an answer.")
                    return
                pending = {"id": ident, "cancelled": threading.Event()}
                self.pending = pending
                worker = threading.Thread(target=self.ask, args=(pending, cwd, questions), daemon=True)
                pending["worker"] = worker
                worker.start()
        else:
            self.reply(ident, error={"code": -32601, "message": "Method not found"})

    def ask(self, pending, cwd, questions):
        client = None
        result = {"isError": True, "content": [{"type": "text", "text": "Coucou did not return a valid answer. " + FALLBACK}]}
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            with self.lock:
                if pending["cancelled"].is_set():
                    raise OSError("cancelled")
                pending["socket"] = client
            deadline = time.monotonic() + self.wait_seconds
            def remaining():
                seconds = deadline - time.monotonic()
                if seconds <= 0:
                    raise TimeoutError()
                return seconds
            metadata = os.stat(self.socket_path)
            if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.geteuid():
                raise OSError("invalid local socket")
            client.settimeout(remaining())
            client.connect(self.socket_path)
            payload = {"coucou_kind": "codex_mcp_question", "coucou_agent": "codex",
                       "session_id": self.session_id, "request_id": str(uuid.uuid4()),
                       "cwd": cwd, "originator": "Codex Desktop", "tool_input": {"questions": questions}}
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8") + b"\n"
            if len(data) > MAX_BYTES:
                raise ValueError("oversized question")
            client.settimeout(remaining())
            client.sendall(data)
            data = bytearray()
            while b"\n" not in data:
                client.settimeout(remaining())
                chunk = client.recv(min(4096, MAX_BYTES + 1 - len(data)))
                if not chunk:
                    raise OSError("closed")
                data.extend(chunk)
                if len(data) > MAX_BYTES:
                    raise ValueError("oversized answer")
            response = decode(data.split(b"\n", 1)[0])
            if not isinstance(response, dict) or response.get("permissionDecision") != "answer":
                raise ValueError("no answer")
            answers = response.get("answers")
            if not isinstance(answers, dict) or set(answers) != {q["id"] for q in questions}:
                raise ValueError("mismatched answer ids")
            for question in questions:
                entry = answers[question["id"]]
                if not isinstance(entry, dict) or set(entry) != {"answers"}:
                    raise ValueError("invalid answer")
                values = entry["answers"]
                if not isinstance(values, list) or not 1 <= len(values) <= 9:
                    raise ValueError("invalid answer")
                for value in values:
                    text(value, 8192)
                    if not question["isOther"] and value not in {o["label"] for o in question["options"]}:
                        raise ValueError("invalid choice")
            structured = {"answers": answers}
            result = {"content": [{"type": "text", "text": json.dumps(structured, ensure_ascii=False)}],
                      "structuredContent": structured, "isError": False}
        except (OSError, ValueError, UnicodeError, RecursionError):
            pass
        finally:
            if client:
                client.close()
            with self.lock:
                if self.pending is pending:
                    self.pending = None
                if pending["cancelled"].is_set():
                    result = {"isError": True, "content": [{"type": "text", "text": "Coucou question cancelled. " + FALLBACK}]}
                self.reply(pending["id"], result)

    def run(self):
        try:
            while True:
                line = sys.stdin.buffer.readline(MAX_BYTES + 1)
                if not line:
                    break
                if len(line) > MAX_BYTES:
                    self.reply(None, error={"code": -32700, "message": "JSONL request too large"})
                    break
                try:
                    self.dispatch(decode(line))
                except (ValueError, UnicodeError, RecursionError):
                    self.reply(None, error={"code": -32700, "message": "Invalid JSON"})
        finally:
            with self.lock:
                self.closed = True
                self.close_pending()
                worker = self.pending.get("worker") if self.pending else None
            if worker:
                worker.join(timeout=1)


if __name__ == "__main__":
    try:
        Bridge().run()
    except BrokenPipeError:
        pass
