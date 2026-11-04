#!/usr/bin/env python3
"""Run the nb-hook relay that HookServer.swift installs against a stand-in Coucou socket.

Covers the shell wrapper on this OS (macOS: python3 behind xcode-select; elsewhere: the
python3 in PATH, as on a server reached over SSH), the default socket path and the
COUCOU_SOCKET override, a permission round trip, an AskUserQuestion answer, VS Code
sessions on a remote machine, and that an unreachable socket never blocks the agent.
"""
import json
import os
from pathlib import Path
import queue
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "NotchBuddy/Sources/App/HookServer.swift"
DEFAULT_SOCKETS = {
    "nbHookPythonGitHub": "Library/Application Support/NotchBuddy/nb.sock",
    "nbHookPythonAppStore": "Library/Containers/fr.louisraille.Coucou/Data/nb.sock",
}


def swift_literal(source, name):
    """The text of `private let <name> = \"\"\" … \"\"\"` (the relay literals only escape backslashes)."""
    match = re.search(rf'^private let {name} = """\n(.*?)^"""$', source, re.S | re.M)
    if not match:
        sys.exit(f"{name} not found in {SOURCE.name}")
    body = match.group(1)
    other = set(re.findall(r"\\([^\\])", body.replace("\\\\", "")))
    if other:
        sys.exit(f"{name}: unexpected escapes {sorted(other)}, teach swift_literal() about them")
    return body.replace("\\\\", "\\")


class FakeCoucou:
    """Listens like the app: one JSON line per connection, answers blocking requests."""

    def __init__(self, path):
        self.path = path
        self.received = queue.Queue()
        self.reply = {}
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(8)
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                data = b""
                while b"\n" not in data:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                msg = json.loads(data)
                self.received.put(msg)
                blocking = (msg.get("hook_event_name") == "PermissionRequest"
                            or msg.get("coucou_kind") == "ask_user_question")
                try:
                    conn.sendall((json.dumps(self.reply if blocking else {"ok": True}) + "\n").encode())
                except OSError:
                    pass  # fire-and-forget: the relay already hung up

    def next(self):
        """The next message the relay sent, or {} when none arrived."""
        try:
            return self.received.get(timeout=5)
        except queue.Empty:
            return {}

    def close(self):
        self.server.close()
        os.unlink(self.path)


def run(hook_dir, payload, args=(), env=None, timeout=10):
    started = time.monotonic()
    proc = subprocess.run(["/bin/sh", str(hook_dir / "nb-hook"), *args], input=json.dumps(payload),
                          capture_output=True, text=True, env=env, timeout=timeout)
    assert proc.returncode == 0, proc
    return proc.stdout.strip(), time.monotonic() - started


def check(condition, message):
    if not condition:
        sys.exit(f"FAIL: {message}")
    print(f"ok  {message}")


def main():
    source = SOURCE.read_text(encoding="utf-8")
    wrapper = swift_literal(source, "nbHookShellWrapper")
    # Short paths: sun_path holds 104 bytes on macOS.
    work = Path(tempfile.mkdtemp(prefix="nb", dir="/tmp"))
    try:
        for variant, default_socket in DEFAULT_SOCKETS.items():
            print(f"-- {variant}")
            hook_dir = work / variant
            hook_dir.mkdir()
            (hook_dir / "nb-hook").write_text(wrapper)
            (hook_dir / "nb-hook.py").write_text(swift_literal(source, variant))
            home = work / f"home-{variant}"
            home.mkdir()
            base_env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home)}
            event = {"hook_event_name": "SessionStart", "session_id": "s1", "cwd": "/srv/project"}

            coucou = FakeCoucou(str(home / default_socket))
            out, _ = run(hook_dir, event, env=base_env)
            check(out == "" and coucou.next().get("hook_event_name") == "SessionStart",
                  "an event reaches the default socket")
            coucou.close()

            tunnel = str(work / f"{variant[-6:]}.sock")
            coucou = FakeCoucou(tunnel)
            env = dict(base_env, COUCOU_SOCKET=tunnel)
            run(hook_dir, event, env=env)
            check(coucou.next().get("session_id") == "s1", "COUCOU_SOCKET points the relay at another socket")

            coucou.reply = {"permissionDecision": "allow"}
            request = dict(event, hook_event_name="PermissionRequest", tool_name="Bash",
                           tool_input={"command": "ls"})
            out, _ = run(hook_dir, request, env=env)
            coucou.next()
            check(json.loads(out)["hookSpecificOutput"]["decision"]["behavior"] == "allow",
                  "a permission decision comes back to the agent")

            coucou.reply = {"permissionDecision": "answer", "answers": {"Which one?": "First"}}
            ask = dict(event, hook_event_name="PreToolUse", tool_name="AskUserQuestion",
                       tool_input={"questions": [{"question": "Which one?", "header": "Pick",
                                                  "options": [{"label": "First"}, {"label": "Second"}],
                                                  "multiSelect": False}]})
            out, _ = run(hook_dir, ask, args=("--ask",), env=env)
            coucou.next()
            check(json.loads(out)["hookSpecificOutput"]["updatedInput"]["answers"] == {"Which one?": "First"},
                  "an answer from the notch comes back to the agent")

            vscode = dict(env, CLAUDE_CODE_ENTRYPOINT="claude-vscode")
            run(hook_dir, event, env=vscode)
            check(coucou.next().get("term_program") == "vscode", "a remote VS Code session goes to the VS Code pill")
            coucou.reply = {"permissionDecision": "ask"}
            run(hook_dir, ask, args=("--ask",), env=vscode)
            check(coucou.next().get("term_program") == "vscode", "so does its question")
            run(hook_dir, event, env=dict(vscode, TERM_PROGRAM="iTerm.app"))
            check(coucou.next().get("term_program") == "iTerm.app", "a real TERM_PROGRAM is kept")
            run(hook_dir, event, env=dict(vscode, __CFBundleIdentifier="com.todesktop.230313mzl4w4u92"))
            check(coucou.next().get("term_program") == "", "an editor with a bundle ID is left to it")
            run(hook_dir, event, env=dict(env, CLAUDE_CODE_ENTRYPOINT="sdk-ts"))
            check(coucou.next().get("term_program") == "", "other entrypoints are not taken for VS Code")
            coucou.close()

            out, took = run(hook_dir, request, env=dict(env, COUCOU_SOCKET=str(work / "none.sock")))
            check(out == "" and took < 5, f"no Coucou: the permission request goes back at once ({took:.2f} s)")

            # No python3 (Linux) or no xcode-select (macOS) in PATH: the wrapper stays quiet.
            bare = work / f"bin-{variant}"
            bare.mkdir()
            for tool in ("dirname", "uname"):
                os.symlink(shutil.which(tool), bare / tool)
            bare_env = dict(env, PATH=str(bare))
            out, _ = run(hook_dir, event, env=bare_env)
            check(out == "", "without python3 the wrapper prints nothing")
            out, _ = run(hook_dir, request, args=("--agent", "copilot", "permissionRequest"), env=bare_env)
            check(out == '{"permissionDecision":"ask"}', "without python3 Copilot still gets its JSON")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("nb-hook relay: all checks passed")


if __name__ == "__main__":
    main()
