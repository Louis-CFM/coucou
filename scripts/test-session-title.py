#!/usr/bin/env python3
"""Check the title the nb-hook relays give a session, read from its transcript.

Both relays come out of HookServer.swift and send one event each to a stand-in socket:
the /rename title (custom-title) wins, else the title Claude Code gave the session
(ai-title, all VS Code sessions have), else none (the pill takes the folder). Only real
entries count, not a line that only mentions one, and a title up to 256 KB back is found.
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


def swift_literal(source, name):
    match = re.search(rf'^private let {name} = """\n(.*?)^"""$', source, re.S | re.M)
    if not match:
        sys.exit(f"{name} not found in {SOURCE.name}")
    return match.group(1).replace("\\\\", "\\")


def line(entry):
    return json.dumps(entry, ensure_ascii=False, separators=(",", ":"))


def transcript(*entries, pad=0):
    first = line({"type": "user", "cwd": "/srv/project", "message": {"role": "user", "content": "hi"}})
    filler = [line({"type": "assistant", "message": {"content": "x" * 900}})] * (pad // 1000)
    return "\n".join([first, *entries[:1], *filler, *entries[1:]]) + "\n"


CUSTOM = line({"type": "custom-title", "customTitle": "Renamed by me", "sessionId": "s"})
AI = line({"type": "ai-title", "aiTitle": "Title from Claude", "sessionId": "s"})
AI_OLD = line({"type": "ai-title", "aiTitle": "Older title", "sessionId": "s"})
# Lines that are about titles without being one: a search for "custom-title", and a tool
# call carrying a title entry as data. The relay once stopped at the first of these.
QUOTE = "\n".join([
    line({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "Grep", "input": {"pattern": "custom-title"}}]}}),
    line({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "Write", "input": {"entry": {"type": "custom-title", "customTitle": "not me"}}}]}}),
])

CASES = [
    ("the /rename title wins", transcript(AI_OLD, CUSTOM, AI), "Renamed by me"),
    ("else the title Claude Code gave", transcript(AI_OLD, AI), "Title from Claude"),
    ("a line that mentions a title is not one", transcript(CUSTOM, QUOTE), "Renamed by me"),
    ("nor for the title Claude Code gave", transcript(AI, QUOTE), "Title from Claude"),
    ("a title 200 KB back is found", transcript(AI, pad=200_000), "Title from Claude"),
    ("no title: the pill takes the folder", transcript(QUOTE), None),
]


def main():
    source = SOURCE.read_text(encoding="utf-8")
    wrapper = swift_literal(source, "nbHookShellWrapper")
    python3 = shutil.which("python3")
    work = Path(tempfile.mkdtemp(prefix="nbt", dir="/tmp"))
    try:
        for variant, sock_rel in SOCKETS.items():
            print(f"-- {variant}")
            home = work / variant
            hook = home / "hook"
            hook.mkdir(parents=True)
            (hook / "nb-hook").write_text(wrapper)
            (hook / "nb-hook.py").write_text(swift_literal(source, variant))
            sock_path = home / sock_rel
            sock_path.parent.mkdir(parents=True)
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(sock_path))
            server.listen(4)
            for label, text, expected in CASES:
                path = home / "transcript.jsonl"
                path.write_text(text, encoding="utf-8")
                event = {"hook_event_name": "SessionStart", "session_id": "s", "cwd": "/srv/project/sub",
                         "transcript_path": str(path)}
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
                got = received.get("session_title")
                if got != expected or received.get("session_root") != "/srv/project":
                    sys.exit(f"FAIL: {label}: title {got!r}, root {received.get('session_root')!r}")
                print(f"ok  {label}")
            server.close()
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("session titles: all checks passed")


if __name__ == "__main__":
    main()
