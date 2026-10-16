#!/usr/bin/env python3
"""Read-only desktop attention bridge. Never answers questions or permissions.

Codex: accepted question calls in human Desktop root transcripts, matched replies.
OpenCode 2: pending-permission GET, for viewed, unarchived desktop roots only.
The service password stays in this process; no content or credentials are logged.

The reader sleeps in SourceWatcher (kqueue vnode filters on read-only file
descriptors) until an observed source changes or a hook hint arrives: zero
periodic scanning while idle. Hook hints are drained before each snapshot.
File-event bursts are coalesced to at most four source checks per second;
pending requests are refreshed at least every 8 s, and while OpenCode has
active viewed candidate sessions its in-memory permission list is re-queried
at most every 3 s (idle means no active candidate sessions).
"""
import argparse
import base64
import concurrent.futures
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import select
import socket
import sqlite3
import stat
import sys
import time
import urllib.parse
import urllib.request

UUID = re.compile(r"^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$")
SESSION = re.compile(r"^ses_[A-Za-z0-9]+$")
PERMISSION = re.compile(r"^per_[A-Za-z0-9]+$")
QUESTION_REPLY = re.compile(r"<send_user_message_question_reply>\s*(.*?)\s*</send_user_message_question_reply>", re.S)
MAX_TAIL = 8 * 1024 * 1024
LEASE = 25
DESKTOP_SOURCES = ("vscode", "appServer", "app_server")


def compact(value, limit=800):
    return " ".join(str(value or "").split())[:limit]


def json_object(raw):
    try:
        value = json.loads(raw) if isinstance(raw, str) else raw
        return value if isinstance(value, dict) else {}
    except (ValueError, TypeError):
        return {}


def iso_time(value):
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return 0


def verified_desktop_thread(meta, session_id, include_children=False):
    """Codex Desktop transcript verification; origin is never guessed from a
    path, cwd or title.

    Roots carry the full human metadata: thread_source "user", matching
    id/session_id, the Desktop originator and a desktop source string, with no
    parent or agent markers. Include-children mode also accepts the real
    thread_spawn chain: thread_source "subagent", id = the child session,
    session_id = the parent session, and source.subagent.thread_spawn.
    parent_thread_id naming that same parent. Guardian, memory and every other
    origin are rejected in both modes.
    """
    if not (UUID.fullmatch(session_id) and isinstance(meta, dict) and meta.get("id") == session_id):
        return False
    thread_source = meta.get("thread_source")
    if thread_source == "user":
        return _verified_root(meta, session_id)
    if include_children and thread_source == "subagent":
        return _verified_child(meta, session_id)
    return False


def _verified_root(meta, session_id):
    return (meta.get("session_id") == session_id
            and meta.get("originator") == "Codex Desktop"
            and isinstance(meta.get("source"), str)
            and meta.get("source") in DESKTOP_SOURCES
            and not meta.get("parent_thread_id")
            and not meta.get("agent_id") and not meta.get("agent_type"))


def _verified_child(meta, session_id):
    """The real thread_spawn chain: the child names its parent session both as
    session_id and inside source.subagent.thread_spawn.parent_thread_id. The
    spawner must still be the Desktop app — the catalog query alone does not
    guard HumanPermissions' direct transcript reads."""
    parent = meta.get("session_id")
    if not (isinstance(parent, str) and UUID.fullmatch(parent) and parent != session_id):
        return False
    if meta.get("originator") != "Codex Desktop":
        return False
    if meta.get("parent_thread_id") is not None and meta.get("parent_thread_id") != parent:
        return False
    source = meta.get("source")
    agent = source.get("subagent") if isinstance(source, dict) else None
    spawn = agent.get("thread_spawn") if isinstance(agent, dict) else None
    spawn_parent = spawn.get("parent_thread_id") if isinstance(spawn, dict) else None
    return spawn_parent == parent


def human_codex_root(meta, session_id):
    return verified_desktop_thread(meta, session_id, False)


class CodexQuestions:
    def __init__(self, session_id, title):
        self.session_id = session_id
        self.title = title
        self.calls = {}
        self.answered = set()
        self.turn_id = None
        self.turn_reviewer = None
        self.completed_turns = set()
        self.tool_calls = {}
        self.completed_tools = set()

    def feed(self, record):
        payload = record.get("payload", {})
        if not isinstance(payload, dict):
            return
        if record.get("type") == "turn_context":
            if payload.get("turn_id") != self.turn_id:
                self.tool_calls.clear()
                self.completed_tools.clear()
                self.completed_turns.clear()
            self.turn_id = payload.get("turn_id")
            self.turn_reviewer = payload.get("approvals_reviewer")
        if record.get("type") == "event_msg" and payload.get("type") in ("task_complete", "turn_aborted", "task_aborted"):
            ended = payload.get("turn_id") or self.turn_id
            self.completed_turns.add(ended)
            aborted = payload.get("type") != "task_complete"
            self.calls = {key: call for key, call in self.calls.items()
                          if call["turn"] != ended or (not aborted and call["name"].endswith("_async"))}
        if record.get("type") != "response_item":
            return
        kind = payload.get("type")
        call_id = payload.get("call_id")
        if kind == "function_call":
            name = payload.get("name", "")
            if not isinstance(name, str):
                return
            name = name.split(".")[-1]
            if isinstance(call_id, str):
                self.tool_calls[call_id] = (self.turn_id, tool_key(name, json_object(payload.get("arguments"))))
            if name not in ("request_user_input", "request_user_input_async") or not isinstance(call_id, str):
                return
            questions = json_object(payload.get("arguments")).get("questions")
            if not isinstance(questions, list) or not questions:
                return
            items = {}
            for index, question in enumerate(questions[:10]):
                if not isinstance(question, dict):
                    continue
                reason = compact(question.get("title") if name.endswith("_async") else question.get("question"))
                if reason:
                    items[index] = reason
            if items:
                self.calls[call_id] = {"name": name, "items": items,
                                       "accepted": not name.endswith("_async"),
                                       "turn": self.turn_id,
                                       "created": iso_time(record.get("timestamp"))}
        elif kind == "function_call_output":
            if call_id in self.tool_calls:
                self.completed_tools.add(self.tool_calls.pop(call_id))
            if call_id in self.calls:
                call = self.calls[call_id]
                if call["name"].endswith("_async") and json_object(payload.get("output")).get("accepted") is True:
                    call["accepted"] = True
                else:
                    self.calls.pop(call_id, None)
        if payload.get("role") == "user":
            content = payload.get("content", [])
            texts = [item.get("text", "") for item in content if isinstance(item, dict)] if isinstance(content, list) else []
            # A new free-text user message supersedes an old question for notification purposes.
            # The desktop accepts normal replies too; not every answer uses the question widget.
            # Runtime context updates are not user answers. Native questions are never modified.
            ordinary = [text for text in texts if isinstance(text, str) and text.strip()
                        and "<send_user_message_question_reply>" not in text
                        and not text.lstrip().startswith(("# AGENTS.md instructions", "<environment_context>",
                                                          "<permissions instructions>", "<turn_aborted>"))]
            if ordinary:
                self.calls.clear()
                self.answered.clear()
            for item in content if isinstance(content, list) else []:
                text = item.get("text", "") if isinstance(item, dict) else ""
                for match in QUESTION_REPLY.finditer(text):
                    try:
                        replies = json.loads(match.group(1))
                        if not isinstance(replies, list):
                            continue
                        for reply in replies:
                            key = json.loads(reply.get("questionItemId", ""))
                            if (isinstance(key, list) and len(key) == 3
                                    and key[0] == "request_user_input_async"
                                    and isinstance(key[1], str) and type(key[2]) is int):
                                self.answered.add((key[1], key[2]))
                    except (ValueError, TypeError, AttributeError):
                        continue
        completed = [key for key, call in self.calls.items()
                     if all((key, index) in self.answered for index in call["items"])]
        for key in completed:
            del self.calls[key]
        active = set(self.calls)
        self.answered = {key for key in self.answered if key[0] in active}

    def pending(self, now):
        result = []
        for call_id, call in self.calls.items():
            if not call["accepted"] or not 0 < call["created"] <= now + 60:
                continue
            items = [text for index, text in call["items"].items() if (call_id, index) not in self.answered]
            if items:
                result.append({"source": "codex", "id": "question:" + call_id,
                               "session_id": self.session_id, "title": self.title,
                               "reason": " / ".join(items)[:800], "kind": "question"})
        return result


class CodexReader:
    def __init__(self, root, include_children=False):
        self.root = Path(root).resolve()
        self.include_children = include_children
        self.readers = {}

    def sessions(self):
        # Subagent rows are candidates only in include-children mode; the
        # transcript metadata still decides.
        sources = "'user','subagent'" if self.include_children else "'user'"
        with sqlite3.connect((self.root / "state_5.sqlite").as_uri() + "?mode=ro", uri=True, timeout=.3) as db:
            return db.execute("SELECT id, title, rollout_path FROM threads WHERE archived=0 "
                              "AND thread_source IN (" + sources + ") AND originator='Codex Desktop' "
                              "ORDER BY updated_at DESC LIMIT 100").fetchall()

    def read(self, session_id, title, path):
        path = Path(path).resolve()
        if not any(path.is_relative_to(self.root / folder) for folder in ("sessions", "archived_sessions")):
            return None
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            file_stat = os.fstat(stream.fileno())
            if not stat.S_ISREG(file_stat.st_mode):
                return None
            meta_line = stream.readline(1024 * 1024)
            meta = json_object(meta_line.decode("utf-8", "replace"))
            if meta.get("type") != "session_meta" or not verified_desktop_thread(meta.get("payload", {}), session_id,
                                                                                 self.include_children):
                return None
            old = self.readers.get(session_id)
            if not old or old[0] != (file_stat.st_dev, file_stat.st_ino) or file_stat.st_size < old[1]:
                tracker = CodexQuestions(session_id, compact(title, 160))
                offset = max(stream.tell(), file_stat.st_size - MAX_TAIL)
                stream.seek(offset)
                if offset > len(meta_line):
                    stream.readline()  # discard a partial first record
            else:
                _, offset, tracker = old
                stream.seek(offset)
            tracker.title = compact(title, 160)
            end = min(file_stat.st_size, stream.tell() + MAX_TAIL)
            while stream.tell() < end:
                pos = stream.tell()
                line = stream.readline(1024 * 1024)
                if not line.endswith(b"\n"):
                    stream.seek(pos)  # JSONL may still be in the writer's buffer
                    break
                try:
                    tracker.feed(json.loads(line))
                except (ValueError, TypeError, AttributeError):
                    pass
            self.readers[session_id] = ((file_stat.st_dev, file_stat.st_ino), stream.tell(), tracker)
            return tracker

    def snapshot(self, now, rows=None):
        result = []
        readable = set()
        for session_id, title, path in (rows if rows is not None else self.sessions()):
            try:
                tracker = self.read(session_id, title, path)
            except (OSError, ValueError, TypeError):
                tracker = None
            if tracker:
                readable.add(session_id)
                result.extend(tracker.pending(now))
        # A source that can no longer be read (deleted, moved, unreadable) is
        # dropped together with its incremental state.
        self.readers = {key: value for key, value in self.readers.items() if key in readable}
        return result


class LocalOpenCode:
    def __init__(self, service_path, database, include_children=False):
        self.service_path = Path(service_path)
        self.database = Path(database)
        self.include_children = include_children

    def get(self, route):
        # Re-read so service restarts/credential rotation recover automatically.
        service = json.loads(self.service_path.read_text())
        url = urllib.parse.urlsplit(service["url"])
        if (url.scheme != "http" or url.hostname not in ("127.0.0.1", "localhost", "::1")
                or url.username or url.password or url.query or url.fragment or url.path not in ("", "/")):
            raise ValueError("Not a local OpenCode service")
        password = service.get("password")
        if not isinstance(password, str) or not password:
            raise ValueError("No local service authentication")
        auth = base64.b64encode(("opencode:" + password).encode()).decode()
        request = urllib.request.Request(service["url"].rstrip("/") + route,
                                         headers={"Authorization": "Basic " + auth}, method="GET")
        # No environment proxies or redirects: credentials must never leave loopback.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(request, timeout=2) as response:
            return json.loads(response.read(1024 * 1024))

    def sessions(self, include_children=None):
        # Viewed, unarchived desktop sessions only; roots unless child sessions
        # were explicitly included. "Viewed" is a heuristic for "the user cares".
        children = self.include_children if include_children is None else include_children
        query = ("SELECT id,title FROM session_v2 WHERE time_viewed IS NOT NULL AND time_viewed>0 "
                 "AND time_archived IS NULL AND time_suspended IS NOT NULL ")
        if not children:
            query += "AND parent_id IS NULL "
        query += "ORDER BY time_updated DESC LIMIT 100"
        with sqlite3.connect(self.database.as_uri() + "?mode=ro", uri=True, timeout=.3) as db:
            return db.execute(query).fetchall()

    def pending_for(self, session):
        session_id, title = session
        if not SESSION.fullmatch(session_id):
            return []
        response = self.get("/api/session/" + session_id + "/permission")
        if not isinstance(response, dict):
            raise ValueError("Invalid pending response")
        requests = response.get("data")
        if not isinstance(requests, list):
            raise ValueError("Invalid pending list")
        result = []
        for request in requests:
            if (not isinstance(request, dict) or request.get("sessionID") != session_id
                    or not PERMISSION.fullmatch(str(request.get("id", "")))):
                continue
            action = compact(request.get("action"), 80)
            resources = request.get("resources")
            details = ", ".join(compact(x, 180) for x in resources[:3]) if isinstance(resources, list) else ""
            reason = compact(request.get("message")) or compact(action + (": " + details if details else ""))
            result.append({"source": "opencode", "id": request["id"], "session_id": session_id,
                           "title": compact(title, 160), "reason": reason or "Waiting for your approval",
                           "kind": "permission"})
        return result

    def snapshot(self):
        sessions = self.sessions()
        result = []
        # Bound latency without a server-wide pending endpoint that could instantiate worker locations.
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            for future in [pool.submit(self.pending_for, session) for session in sessions]:
                try:
                    result.extend(future.result())
                except (OSError, ValueError, KeyError, TypeError):
                    pass  # Unconfirmed requests are not kept visible.
        return result


def tool_key(name, tool_input):
    raw = name.split(".")[-1] + ":" + json.dumps(tool_input, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(raw.encode()).hexdigest()


class HumanPermissions:
    """Hook hints from the existing strict relay; every hint is independently checked again."""
    def __init__(self, reader):
        self.reader = reader
        self.requests = {}

    def receive(self, payload):
        if payload.get("coucou_agent") != "codex":
            return
        # Subagent-originating hints are only considered in include-children mode,
        # and even then the transcript metadata must verify them.
        if not self.reader.include_children and (payload.get("agent_id") or payload.get("agent_type")):
            return
        session = payload.get("session_id")
        path = payload.get("transcript_path")
        turn = payload.get("turn_id")
        if not isinstance(session, str) or not isinstance(path, str) or not isinstance(turn, str):
            return
        old = self.reader.readers.get(session)
        title = old[2].title if old else "Codex main chat"
        try:
            tracker = self.reader.read(session, title, path)
        except (OSError, ValueError):
            return
        if not tracker or tracker.turn_id != turn:
            return
        event = payload.get("hook_event_name")
        name = payload.get("tool_name", "")
        tool_input = payload.get("tool_input", {})
        if not isinstance(name, str) or not isinstance(tool_input, dict):
            return
        key = tool_key(name, tool_input)
        identifier = session + ":" + turn + ":" + key
        if event == "PermissionRequest":
            if (tracker.turn_reviewer != "user" or turn in tracker.completed_turns
                    or (turn, key) in tracker.completed_tools or "mcp__" in name):
                return
            reason = compact(tool_input.get("justification") or tool_input.get("command") or name)
            self.requests[identifier] = {"source": "codex", "id": "permission:" + hashlib.sha256(identifier.encode()).hexdigest(),
                                         "session_id": session, "title": title, "reason": reason or "Waiting for your approval",
                                         "kind": "permission", "_turn": turn, "_key": key, "_path": path}
        elif event in ("PostToolUse", "PostToolUseFailure"):
            self.requests.pop(identifier, None)
        elif event in ("Stop", "StopFailure", "SessionEnd", "Interrupt", "UserPromptSubmit"):
            self.requests = {key: value for key, value in self.requests.items() if value["session_id"] != session}

    def pending(self):
        result = []
        for key, request in list(self.requests.items()):
            try:
                tracker = self.reader.read(request["session_id"], request["title"], request["_path"])
            except (OSError, ValueError):
                tracker = None
            turn = request["_turn"]
            if (not tracker or tracker.turn_id != turn or turn in tracker.completed_turns
                    or (turn, request["_key"]) in tracker.completed_tools):
                del self.requests[key]
            else:
                result.append({key: value for key, value in request.items() if not key.startswith("_")})
        return result


class HookInput:
    def __init__(self, fd, permissions):
        self.fd = fd
        self.permissions = permissions
        self.buffer = b""

    def drain(self, timeout):
        if not select.select([self.fd], [], [], timeout)[0]:
            return True
        data = os.read(self.fd, 65536)
        if not data:
            return False
        self.buffer += data
        lines = self.buffer.split(b"\n")
        self.buffer = lines.pop()
        if len(self.buffer) > 65536:
            self.buffer = b""
        for line in lines:
            if len(line) <= 65536:
                self.permissions.receive(json_object(line.decode("utf-8", "replace")))
        return True


class SourceWatcher:
    """Blocks until an observed source changes or hook input arrives.

    macOS kqueue vnode filters on read-only descriptors: the reader sleeps with
    zero periodic scanning while nothing changes. A missing file is watched
    through its nearest existing ancestor directory so its creation wakes the
    loop; update() closes every watch descriptor and reopens the current set,
    recovering replacement and creation.
    """

    # At most four source checks per second, however bursty the writes are.
    MIN_WAKE_INTERVAL = 0.25
    # Hard ceiling on watch descriptors (the reader also holds socket fds).
    MAX_WATCHES = 96
    VNODE_FLAGS = (select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND | select.KQ_NOTE_DELETE
                   | select.KQ_NOTE_RENAME | select.KQ_NOTE_ATTRIB | select.KQ_NOTE_LINK)

    def __init__(self, paths, stdin_fd=None):
        self.kqueue = select.kqueue()
        self.watches = {}
        self.stdin_fd = stdin_fd if stdin_fd is not None and stdin_fd >= 0 else None
        self._pending_source = False
        self._last_wake = time.monotonic() - self.MIN_WAKE_INTERVAL
        if self.stdin_fd is not None:
            self.kqueue.control(
                [select.kevent(self.stdin_fd, select.KQ_FILTER_READ, select.KQ_EV_ADD)], 0, 0)
        self.update(paths)

    def __enter__(self):
        return self

    def __exit__(self, *exception):
        self.close()

    def update(self, paths):
        """Swap the watched set; all previous watch descriptors are closed first."""
        for fd in list(self.watches):
            self._drop(fd)
        self.watches = {}
        targets = {}
        for raw in paths:
            if len(self.watches) >= self.MAX_WATCHES:
                break
            try:
                path = Path(raw).resolve()
            except OSError:
                continue
            target = self._watch_target(path)
            if target is None or target in targets:
                continue
            fd = self._open_read_only(target)
            if fd is None:
                continue
            targets[target] = fd
            self.watches[fd] = target
        # EV_CLEAR: an unchanged source must not keep waking the loop.
        changes = [select.kevent(fd, select.KQ_FILTER_VNODE,
                                 select.KQ_EV_ADD | select.KQ_EV_CLEAR, self.VNODE_FLAGS)
                   for fd in self.watches]
        if changes:
            self.kqueue.control(changes, 0, 0)

    def wait(self, timeout):
        """Block until a watched source changes or hook input arrives."""
        deadline = None if timeout is None else time.monotonic() + max(0.0, timeout)
        while True:
            now = time.monotonic()
            if self._pending_source and now - self._last_wake >= self.MIN_WAKE_INTERVAL:
                self._last_wake = now
                self._pending_source = False
                return True
            if deadline is not None and now >= deadline:
                return False
            if self._pending_source:
                # Inside the coalescing window: hold the burst until it opens.
                limit = self._last_wake + self.MIN_WAKE_INTERVAL
                remaining = (limit - now) if deadline is None else (min(deadline, limit) - now)
            else:
                remaining = None if deadline is None else deadline - now
            try:
                events = self.kqueue.control(None, 16, remaining)
            except (OSError, ValueError):
                return False
            if not events:
                continue
            if any(event.filter == select.KQ_FILTER_READ for event in events):
                # Hook input is urgent: never coalesced, never deferred.
                return True
            self._pending_source = True

    def close(self):
        """Close every watch descriptor and the kqueue itself."""
        for fd in list(self.watches):
            try:
                os.close(fd)
            except OSError:
                pass
        self.watches = {}
        try:
            self.kqueue.close()
        except (OSError, ValueError):
            pass

    def _drop(self, fd):
        try:
            self.kqueue.control(
                [select.kevent(fd, select.KQ_FILTER_VNODE, select.KQ_EV_DELETE)], 0, 0)
        except (OSError, ValueError):
            pass
        try:
            os.close(fd)
        except OSError:
            pass

    @staticmethod
    def _watch_target(path):
        """The file itself, or its nearest existing ancestor directory."""
        if path.exists():
            return path
        for parent in path.parents:
            if parent.is_dir():
                return parent
        return None

    @staticmethod
    def _open_read_only(target):
        try:
            fd = os.open(target, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
            mode = os.fstat(fd).st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                os.close(fd)
                return None
            return fd
        except OSError:
            return None


def source_paths(codex_root, rows, permissions, opencode):
    """Everything whose change must wake the idle reader."""
    # No -shm watch: it is SQLite lock coordination, not logical source data,
    # and our own read-only opens can churn it into self-wakes.
    files = [codex_root / "state_5.sqlite",
             codex_root / "state_5.sqlite-wal",
             opencode.database,
             opencode.database.with_name(opencode.database.name + "-wal"),
             opencode.service_path]
    directories = [codex_root / "sessions", codex_root / "archived_sessions",
                   opencode.database.parent, opencode.service_path.parent]
    for row in rows:
        rollout = row[2] if len(row) > 2 else None
        if isinstance(rollout, str) and rollout:
            files.append(Path(rollout))
    for request in permissions.requests.values():
        path = request.get("_path")
        if isinstance(path, str) and path:
            files.append(Path(path))
    # Source parent directories: creation and replacement inside them wake the loop.
    for path in list(files):
        directories.append(path.parent)
    return files + directories


def emit(sock_path, requests, now):
    packet = {"coucou_kind": "attention", "action": "snapshot", "expires_at": now + LEASE,
              "requests": requests[:100]}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(1)
        client.connect(str(sock_path))
        client.sendall(json.dumps(packet, ensure_ascii=False).encode() + b"\n")
        return json_object(client.recv(4096).decode()).get("attention_protocol") == 1


class AttentionLoop:
    """The steady-state reader loop, extracted from main() so its contract is
    testable: hook hints are drained before each snapshot (a permission that
    just arrived on the pipe is emitted in the very same pass, with no
    filesystem event in between), and OpenCode state is refreshed from server
    memory at most every OPEN_REFRESH seconds while active viewed candidate
    sessions exist — permission.asked lives in memory, not SQLite. Idle means
    no active candidate sessions, nothing pending and no outstanding query:
    the loop then blocks on source events only.
    """

    OPEN_REFRESH = 3

    def __init__(self, codex, opencode, permissions, sock_path, hook_input=None, watcher=None, send=None):
        self.codex = codex
        self.opencode = opencode
        self.permissions = permissions
        self.sock_path = sock_path
        self.hook_input = hook_input
        self.watcher = watcher
        self.send = send or emit
        self.executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        self.future = None
        self.open_pending = []
        self.last_open_read = 0.0
        self.next_open_read = 0.0
        # Simple snapshot state: written and read on the loop thread only.
        self.active_candidates = 0
        self.requests = []
        self.rows = []

    def run_once(self, wait=False):
        """One pass; None when the hook pipe closed (the reader exits)."""
        if self.hook_input is not None and not self.hook_input.drain(0):
            return None
        now = time.time()
        requests = []
        status = {}
        rows = []
        try:
            rows = self.codex.sessions()
            pending = self.codex.snapshot(now, rows)
            requests.extend(pending)
            status["codex"] = {"ok": True, "pending": len(pending)}
        except (OSError, ValueError, sqlite3.Error, KeyError, TypeError):
            status["codex"] = {"ok": False}
        # Hook hints are verified against their own transcript, independently of
        # the index: an absent or locked catalog must not hide an exact
        # verified native request.
        hooked = []
        try:
            hooked = self.permissions.pending()
        except (OSError, ValueError, TypeError):
            pass
        requests.extend(hooked)
        status["codex"]["pending"] = status["codex"].get("pending", 0) + len(hooked)
        open_status, open_pending = self.collect_opencode(now, wait)
        if open_status is not None:
            status["opencode"] = open_status
        requests.extend(open_pending)
        self.rows = rows
        self.requests = requests
        return status, requests

    def collect_opencode(self, now, wait=False):
        """Refresh the OpenCode snapshot. The native pending GET stays the only
        authority; the SQLite index is only used to count active viewed
        candidate sessions, whose in-memory permissions can appear after an
        empty GET with no database change at all."""
        if self.future is None and (wait or now >= self.next_open_read):
            self.future = self.executor.submit(self.opencode.snapshot)
        status = None
        if self.future is not None and (wait or self.future.done()):
            try:
                self.open_pending = self.future.result()
                self.last_open_read = time.time()
                status = {"ok": True, "pending": len(self.open_pending)}
            except (OSError, ValueError, sqlite3.Error, KeyError, TypeError):
                self.open_pending = []
                status = {"ok": False}
            self.future = None
            self.next_open_read = now + self.OPEN_REFRESH
        try:
            self.active_candidates = len(self.opencode.sessions())
        except (OSError, ValueError, sqlite3.Error, KeyError, TypeError):
            self.active_candidates = 0
        pending = self.open_pending if time.time() - self.last_open_read < 8 else []
        return status, pending

    def emit(self, requests):
        self.send(self.sock_path, requests, time.time())

    def next_timeout(self):
        """How long the loop may sleep: an outstanding OpenCode query, a
        visible request (lease renewal), an active candidate session (its
        permissions live in memory), else a pure source-event idle block."""
        if self.future is not None:
            return .5
        if self.active_candidates:
            return self.OPEN_REFRESH
        if self.requests:
            return 8
        return None

    def sleep(self):
        if self.watcher is None:
            time.sleep(1)  # degraded fallback where kqueue is unavailable
            return
        # Refresh the watch set: this closes replaced/lost descriptors and
        # adopts files created since the last check.
        self.watcher.update(source_paths(self.codex.root, self.rows, self.permissions, self.opencode))
        self.watcher.wait(self.next_timeout())

    def shutdown(self):
        self.executor.shutdown(wait=False, cancel_futures=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--check", action="store_true", help="Read-only status counts; never sends UI events")
    parser.add_argument("--hooks-stdin", action="store_true")
    parser.add_argument("--include-child-sessions", action="store_true",
                        help="Also follow verified Codex Desktop subagent threads and viewed OpenCode child sessions")
    args = parser.parse_args()
    home = Path.home()
    codex = CodexReader(os.environ.get("CODEX_HOME", str(home / ".codex")),
                        include_children=args.include_child_sessions)
    opencode = LocalOpenCode(home / ".local/state/opencode/service.json",
                             home / ".local/share/opencode/opencode.db",
                             include_children=args.include_child_sessions)
    permissions = HumanPermissions(codex)
    hook_input = HookInput(sys.stdin.fileno(), permissions) if args.hooks_stdin else None
    watcher = None
    if not (args.once or args.check):
        try:
            watcher = SourceWatcher([], stdin_fd=hook_input.fd if hook_input else None)
        except (AttributeError, OSError, ValueError):
            watcher = None  # no kqueue: degrade to a slow scan instead of crashing
    loop = AttentionLoop(codex, opencode, permissions, args.socket, hook_input, watcher)
    try:
        while True:
            # Hints are drained at the top of every pass, before the snapshot:
            # a permission that just woke the loop is emitted immediately.
            result = loop.run_once(wait=args.once or args.check)
            if result is None:
                return
            status, requests = result
            if args.check:
                print(json.dumps(status))
                return
            try:
                loop.emit(requests)
            except (OSError, ValueError):
                pass
            if args.once:
                return
            loop.sleep()
    finally:
        loop.shutdown()


if __name__ == "__main__":
    main()
