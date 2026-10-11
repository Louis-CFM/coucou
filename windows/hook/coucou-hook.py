#!/usr/bin/env python3
# coucou-hook for a macOS host behind a Linux Coucou's SSH tunnel (remote.rs):
# main.rs, normalize.rs and reply.rs for Claude Code, in Python. Never blocks
# Claude Code, never prints a decision nobody clicked.
import json, os, re, socket, stat, struct, sys, threading, time

CONNECT_TIMEOUT = 0.3
ANSWERED_POLL = 0.2
ANSWERED_KEEP = 3600
FIRE_AND_FORGET_BUDGET = 2.0
DECISION_BUDGET = 110.0
DROPPED_FIELDS = ("tool_response", "tool_output", "transcript_path")
MAX_FIELD_LEN = 2000
DIFF_TOOLS = ("Edit", "MultiEdit", "Write")
DIFF_FIELDS = ("old_string", "new_string", "content")
MAX_DIFF_FIELD_LEN = 256 * 1024
MAX_DIFF_TOTAL = 512 * 1024


def cut(s, limit):
    """`s` within `limit` UTF-8 bytes plus an ellipsis, and whether it was cut."""
    raw = s.encode("utf-8")
    if len(raw) <= limit:
        return s, False
    return raw[:limit].decode("utf-8", "ignore") + "…", True


def truncate(value):
    if isinstance(value, str):
        return cut(value, MAX_FIELD_LEN)[0]
    if isinstance(value, list):
        return [truncate(v) for v in value]
    if isinstance(value, dict):
        return {k: truncate(v) for k, v in value.items()}
    return value


def cap_diff(value, state):
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            if isinstance(v, str) and k in DIFF_FIELDS:
                v, was_cut = cut(v, min(MAX_DIFF_FIELD_LEN, state["budget"]))
                state["cut"] = state["cut"] or was_cut
                state["budget"] = max(0, state["budget"] - len(v.encode("utf-8")))
                out[k] = v
            else:
                out[k] = cap_diff(v, state)
        return out
    if isinstance(value, list):
        return [cap_diff(v, state) for v in value]
    if isinstance(value, str):
        return cut(value, MAX_FIELD_LEN)[0]
    return value


def term_editor(env):
    if env.get("CURSOR_TRACE_ID"):
        return "cursor"
    helper = env.get("VSCODE_GIT_ASKPASS_NODE", "")
    exe = helper.replace("\\", "/").rsplit("/", 1)[-1].lower()
    return "cursor" if exe.startswith("cursor") else None


def answer_key(payload):
    """answered.rs key: the tool_use_id, else FNV-1a of session, tool and input."""
    tid = payload.get("tool_use_id")
    if isinstance(tid, str) and tid and len(tid) <= 128 and re.fullmatch(r"[A-Za-z0-9_-]+", tid):
        return tid
    text = "%s\n%s\n%s" % (
        payload.get("session_id") if isinstance(payload.get("session_id"), str) else "",
        payload.get("tool_name") if isinstance(payload.get("tool_name"), str) else "",
        json.dumps(payload.get("tool_input"), sort_keys=True, separators=(",", ":"), ensure_ascii=False))
    h = 0xcbf29ce484222325
    for b in text.encode("utf-8"):
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return "h%016x" % h


def answered_dir():
    return os.path.join(os.environ.get("HOME", ""), ".coucou", "answered")


def mark_answered(key):
    d = answered_dir()
    try:
        os.makedirs(d, exist_ok=True)
        os.chmod(d, 0o700)
        tmp = os.path.join(d, ".%s.%d" % (key, os.getpid()))
        open(tmp, "w").close()
        os.replace(tmp, os.path.join(d, key))
        now = time.time()
        for name in os.listdir(d):
            p = os.path.join(d, name)
            if now - os.path.getmtime(p) > ANSWERED_KEEP:
                os.remove(p)
    except OSError:
        pass


def prepare(raw, arg_event, env, cwd):
    """(line, event name, AskUserQuestion input, answered key) to forward, or None."""
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    try:
        payload = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(payload, dict):
        return None
    if env.get("CLAUDE_CODE_ENTRYPOINT") == "claude-desktop":
        payload["coucou_agent"] = "claude-desktop"
    if "term_editor" not in payload and term_editor(env):
        payload["term_editor"] = term_editor(env)
    name = payload.get("hook_event_name") or arg_event
    if name == "Stop" and payload.get("status") == "error":
        name = "StopFailure"
    key = answer_key(payload)
    asks = name == "PreToolUse" and payload.get("tool_name") == "AskUserQuestion"
    payload["hook_event_name"] = "PermissionRequest" if asks else name
    for field in DROPPED_FIELDS:
        payload.pop(field, None)
    if not payload.get("cwd") and cwd:
        payload["cwd"] = cwd
    for field, var in (("term_program", "TERM_PROGRAM"), ("wt_session", "WT_SESSION"),
                     ("term_session_id", "TERM_SESSION_ID"), ("vscode_pid", "VSCODE_PID"),
                     ("session_pid", "CLAUDE_CODE_SSE_PORT")):
        payload.setdefault(field, env.get(var, ""))
    question = payload.get("tool_input") if payload.get("tool_name") == "AskUserQuestion" else None
    keeps_diff = name == "PostToolUse" and payload.get("tool_name") in DIFF_TOOLS
    tool_input = payload.pop("tool_input", None) if keeps_diff else None
    payload = truncate(payload)
    if tool_input is not None:
        state = {"budget": MAX_DIFF_TOTAL, "cut": False}
        payload["tool_input"] = cap_diff(tool_input, state)
        if state["cut"]:
            payload["coucou_diff_truncated"] = True
    return json.dumps(payload, ensure_ascii=False) + "\n", name, question, key


def answers_fit(question, answers):
    items = question.get("questions") if isinstance(question, dict) else None
    if not isinstance(items, list) or not items or len(items) != len(answers):
        return False
    for item in items:
        text = item.get("question") if isinstance(item, dict) else None
        if not isinstance(text, str):
            return False
        labels = [o.get("label") for o in item.get("options") or [] if isinstance(o, dict) and isinstance(o.get("label"), str)]
        pick = answers.get(text)
        if item.get("multiSelect") is True:
            if not isinstance(pick, list):
                return False
            picks = [p for p in pick if isinstance(p, str)]
            if not picks or len(set(picks)) != len(picks) or not all(p in labels for p in picks):
                return False
        elif not (isinstance(pick, str) and pick in labels):
            return False
    return True


def answered_input(decision, question):
    try:
        answers = json.loads(decision).get("answers")
    except (ValueError, AttributeError):
        return None
    if not isinstance(answers, dict) or not isinstance(question, dict) or not answers_fit(question, answers):
        return None
    return dict(question, answers=answers)


def decision_json(decision, question):
    if decision.lstrip().startswith("{"):
        updated = answered_input(decision, question)
        if updated is None:
            return None
        return json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                                  "decision": {"behavior": "allow", "updatedInput": updated}}},
                          separators=(",", ":"), ensure_ascii=False)
    word = decision.strip()
    if word in ("allow", "always"):
        behavior = '{"behavior":"allow"}'
    elif word == "deny":
        behavior = '{"behavior":"deny","message":"Denied from Coucou"}'
    else:
        return None
    return '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":%s}}' % behavior


def stdout(event, decision, question):
    """reply::stdout for Claude Code: only a clicked decision or picked answers print anything."""
    if decision is None:
        return None
    if event == "PreToolUse":
        updated = answered_input(decision, question)
        if updated is None:
            return None
        return json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
                                                  "updatedInput": updated}}, separators=(",", ":"), ensure_ascii=False)
    if event != "PermissionRequest":
        return None
    return decision_json(decision, question)


def private_dir(path):
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and st.st_mode & 0o077 == 0


def server_uid(sock):
    if hasattr(socket, "SO_PEERCRED"):
        return struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[1]
    # macOS: LOCAL_PEERCRED (SOL_LOCAL 0, option 1) gives struct xucred {u_int version; uid_t uid; ...}.
    return struct.unpack_from("II", sock.getsockopt(0, 1, 76))[1]


def talk(line, waits, path):
    if not path or not os.path.isabs(path) or not private_dir(os.path.dirname(path)):
        return None
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(path)
        if server_uid(sock) != os.getuid():
            return None
        sock.settimeout(None)
        sock.sendall(line.encode("utf-8"))
        if not waits:
            return None
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(1024)
            if not chunk:
                break
            buf += chunk
        answer = buf.decode("utf-8", "replace").strip()
        return answer or None
    except OSError:
        return None


def main():
    arg_event = next((a for a in sys.argv[1:] if not a.startswith("-")), "")
    raw = sys.stdin.buffer.read()
    try:
        cwd = os.getcwd()
    except OSError:
        cwd = ""
    event = prepare(raw, arg_event, os.environ, cwd)
    if event is None:
        return
    line, name, question, key = event
    waits = name == "PermissionRequest" or (name == "PreToolUse" and question is not None)
    result = []
    worker = threading.Thread(target=lambda: result.append(talk(line, waits, os.environ.get("COUCOU_SOCKET"))), daemon=True)
    worker.start()
    deadline = time.monotonic() + (DECISION_BUDGET if waits else FIRE_AND_FORGET_BUDGET)
    # Gives up as soon as another relay on this host has the answer (answered.rs).
    while worker.is_alive() and time.monotonic() < deadline:
        worker.join(ANSWERED_POLL)
        if waits and os.path.exists(os.path.join(answered_dir(), key)):
            break
    out = stdout(name, result[0] if result else None, question)
    if waits and out is not None:
        mark_answered(key)
    if out is not None:
        sys.stdout.write(out + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    os._exit(0)
