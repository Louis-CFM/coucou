#!/usr/bin/env python3
"""Check the reply the nb-hook relays read from a Cursor Agent transcript on Stop.

Cursor's agent runs the Claude Code hooks, but its stop payload carries no
last_assistant_message. Both relays come out of HookServer.swift and send one event each
to a stand-in socket: a Stop whose transcript is under ~/.cursor gets the turn's last
reply, joined from its text parts. A turn that only ran tools has none (not the previous
turn's), a payload that already has one keeps it, and other events and transcripts
outside ~/.cursor are left alone.
"""
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "NotchBuddy/Sources/App/HookServer.swift"
SOCKETS = {
    "nbHookPythonGitHub": "Library/Application Support/NotchBuddy/nb.sock",
    "nbHookPythonAppStore": "Library/Containers/fr.louisraille.Coucou/Data/nb.sock",
}
CURSOR_TRANSCRIPT = ".cursor/projects/p/agent-transcripts/c/c.jsonl"


def swift_literal(source, name):
    match = re.search(rf'^private let {name} = """\n(.*?)^"""$', source, re.S | re.M)
    if not match:
        sys.exit(f"{name} not found in {SOURCE.name}")
    return match.group(1).replace("\\\\", "\\")


def line(entry):
    return json.dumps(entry, ensure_ascii=False, separators=(",", ":"))


def user(text):
    return line({"role": "user", "message": {"content": [{"type": "text", "text": text}]}})


def assistant(*parts):
    return line({"role": "assistant", "message": {"content": list(parts)}})


def text(value):
    return {"type": "text", "text": value}


TOOL = {"type": "tool_use", "name": "Shell", "input": {"command": "ls"}}
ENDED = line({"type": "turn_ended", "status": "success"})


def transcript(*entries):
    return "\n".join(entries) + "\n"


TWO_TURNS = transcript(user("first"), assistant(text("Old reply.")), ENDED,
                       user("second"), assistant(TOOL), assistant(text("Done:"), text("all green.")), ENDED)

# (label, event overrides, transcript location, transcript text, expected last_assistant_message)
CASES = [
    ("the turn's last reply, its text parts joined", {}, CURSOR_TRANSCRIPT, TWO_TURNS, "Done: all green."),
    ("a turn that only ran tools has no reply",
     {}, CURSOR_TRANSCRIPT,
     transcript(user("first"), assistant(text("Old reply.")), ENDED, user("second"), assistant(TOOL), ENDED), None),
    ("a prompt that mentions the assistant is not a reply",
     {}, CURSOR_TRANSCRIPT, transcript(assistant(text("Old reply.")), user('say "assistant"')), None),
    ("a reply already in the payload is kept",
     {"last_assistant_message": "From the agent"}, CURSOR_TRANSCRIPT, TWO_TURNS, "From the agent"),
    ("only on Stop", {"hook_event_name": "UserPromptSubmit"}, CURSOR_TRANSCRIPT, TWO_TURNS, None),
    ("a transcript outside ~/.cursor is not read", {}, "elsewhere/c.jsonl", TWO_TURNS, None),
]


def main():
    source = SOURCE.read_text(encoding="utf-8")
    python3 = shutil.which("python3")
    work = Path(tempfile.mkdtemp(prefix="nbc", dir="/tmp"))
    try:
        for variant, sock_rel in SOCKETS.items():
            print(f"-- {variant}")
            home = work / variant
            hook = home / "hook"
            hook.mkdir(parents=True)
            (hook / "nb-hook.py").write_text(swift_literal(source, variant))
            sock_path = home / sock_rel
            sock_path.parent.mkdir(parents=True)
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(sock_path))
            server.listen(4)
            for label, overrides, location, content, expected in CASES:
                path = home / location
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
                event = {"hook_event_name": "stop", "conversation_id": "c", "cwd": "/srv/project",
                         "transcript_path": str(path), "cursor_version": "3.30.14", **overrides}
                received = {}

                def serve():
                    conn, _ = server.accept()
                    with conn:
                        data = b""
                        while b"\n" not in data:
                            chunk = conn.recv(65536)
                            if not chunk:
                                break
                            data += chunk
                        received.update(json.loads(data))
                t = threading.Thread(target=serve, daemon=True)
                t.start()
                # Straight to the relay with this python3: the wrapper's own checks are not the point here.
                subprocess.run([python3, str(hook / "nb-hook.py")], input=json.dumps(event), text=True,
                               env={"HOME": str(home), "PATH": os.environ.get("PATH", "")}, timeout=10, check=True)
                t.join(5)
                if not received:
                    sys.exit(f"FAIL: {label}: nothing reached the socket")
                got = received.get("last_assistant_message")
                if got != expected:
                    sys.exit(f"FAIL: {label}: last_assistant_message {got!r}, expected {expected!r}")
                print(f"ok  {label}")
            server.close()
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("cursor final message: all checks passed")


if __name__ == "__main__":
    main()
