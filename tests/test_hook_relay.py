"""Exercise the Python relays embedded in the Swift source, with fixture sockets.

No user config or real Coucou socket is opened. The same tests run on Windows
and macOS; the socket factory supplies only an explicit, disposable fake peer.
"""
import io
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "NotchBuddy/Sources/App/HookServer.swift").read_text(encoding="utf-8")
SCRIPTS = dict(re.findall(r'private let (nbHookPython\w*) = """\n(.*?)\n"""', SOURCE, re.S))
WRAPPER = re.search(r'private let nbHookShellWrapper = """\n(.*?)\n"""', SOURCE, re.S).group(1)


class Peer:
    def __init__(self, answer=b"", absent=False):
        self.answer = answer
        self.absent = absent
        self.sent = []
        self.timeouts = []
        self.paths = []

    def settimeout(self, seconds): self.timeouts.append(seconds)
    def connect(self, path):
        self.paths.append(path)
        if self.absent: raise FileNotFoundError("fixture peer is closed")
    def sendall(self, data): self.sent.append(json.loads(data))
    def recv(self, _):
        answer, self.answer = self.answer, b""
        return answer
    def close(self): pass


def run_script(script, payload, provider="codex", answer=b"", absent=False):
    # Swift's \n escape needs one decoding pass to become Python's \n literal.
    script = script.replace("\\\\", "\\")
    stdout = io.StringIO()
    peer = Peer(answer, absent)
    raw = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
    fake_sys = types.SimpleNamespace(stdin=types.SimpleNamespace(buffer=io.BytesIO(raw)),
                                    stdout=stdout, argv=["nb-hook"] + (["--codex"] if provider == "codex" else []),
                                    exit=lambda code=0: (_ for _ in ()).throw(SystemExit(code)))
    import sys
    with patch.dict(sys.modules, {"sys": fake_sys}), patch("socket.socket", return_value=peer), patch("socket.AF_UNIX", 1, create=True):
        try: exec(compile(script, "nb-hook", "exec"), {})
        except SystemExit as exit: assert exit.code == 0
    return stdout.getvalue(), peer


class RelayTests(unittest.TestCase):
    def test_both_embedded_scripts_are_present_and_valid_python(self):
        self.assertEqual(set(SCRIPTS), {"nbHookPythonGitHub", "nbHookPythonAppStore"})
        for script in SCRIPTS.values(): compile(script.replace("\\\\", "\\"), "nb-hook", "exec")

    def test_installers_use_the_shell_wrapper_and_defined_python_variants(self):
        self.assertNotRegex(SOURCE, r'\bnbHookScript(?:AppStore)?\b')
        settings = (ROOT / "NotchBuddy/Sources/App/CodexSettingsView.swift").read_text(encoding="utf-8")
        self.assertIn('relayCommand: "/bin/sh \\(quoted) --codex"', settings)
        self.assertIn('getpwuid(getuid())', settings)
        installer = SOURCE.split('func installCodexRelay(directory: URL) throws {', 1)[1].split('// MARK:', 1)[0]
        for constant in ('nbHookShellWrapper', 'nbHookPythonGitHub', 'nbHookPythonAppStore'):
            self.assertIn(constant, installer)

    def test_each_build_uses_its_upstream_socket_path(self):
        paths = {
            "nbHookPythonGitHub": "~/Library/Application Support/NotchBuddy/nb.sock",
            "nbHookPythonAppStore": "~/Library/Containers/fr.louisraille.Coucou/Data/nb.sock",
        }
        for name, script in SCRIPTS.items():
            _, peer = run_script(script, {"hook_event_name": "PreToolUse"})
            self.assertEqual(peer.paths, [os.path.expanduser(paths[name])])

    def run_wrapper(self, relay, tools=True, arguments=()):
        shell = shutil.which("sh") or shutil.which("bash")
        if shell is None and os.name == "nt":
            candidate = pathlib.Path("C:/Program Files/Git/bin/bash.exe")
            shell = str(candidate) if candidate.exists() else None
        self.assertIsNotNone(shell, "a POSIX shell is required to exercise the embedded wrapper")
        with tempfile.TemporaryDirectory(prefix="coucou-wrapper-") as temporary:
            directory = pathlib.Path(temporary)
            # Only the interpreter is substituted; no production socket/config is used.
            interpreter = pathlib.Path(sys.executable).as_posix()
            wrapper = WRAPPER.replace("\\\\", "\\").replace("/usr/bin/python3", shlex.quote(interpreter))
            (directory / "nb-hook").write_text(wrapper, encoding="utf-8", newline="\n")
            (directory / "nb-hook.py").write_text(relay, encoding="utf-8", newline="\n")
            tools_probe = directory / "xcode-select"
            tools_probe.write_text("#!/bin/sh\nexit " + ("0" if tools else "1") + "\n", encoding="utf-8", newline="\n")
            tools_probe.chmod(0o755)
            env = dict(os.environ, PATH=directory.as_posix() + os.pathsep + os.environ.get("PATH", ""))
            return subprocess.run([shell, str(directory / "nb-hook"), *arguments], input='{"fixture":true}',
                                  capture_output=True, text=True, env=env, timeout=15)

    def test_shell_wrapper_forwards_provider_arguments_and_stdin(self):
        relay = "import json, sys\nprint(json.dumps({'args':sys.argv[1:], 'input':json.load(sys.stdin)}))\n"
        for arguments in ((), ("--codex",)):
            result = self.run_wrapper(relay, arguments=arguments)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stderr, "")
            self.assertEqual(json.loads(result.stdout), {"args": list(arguments), "input": {"fixture": True}})

    def test_shell_wrapper_is_silent_when_tools_or_relay_fail(self):
        for tools, relay in ((False, "print('must not run')\n"),
                             (True, "import sys\nprint('discard this')\nsys.exit(7)\n")):
            result = self.run_wrapper(relay, tools=tools, arguments=("--codex",))
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_provider_context_is_explicit_and_responses_are_not_forwarded(self):
        for script in SCRIPTS.values():
            out, peer = run_script(script, {"hook_event_name": "PreToolUse", "session_id": "fixture",
                                          "agent_provider": "claude", "tool_response": "large", "transcript_path": "private"})
            self.assertEqual(out, "")
            self.assertEqual(peer.sent[0]["agent_provider"], "codex")
            self.assertNotIn("tool_response", peer.sent[0])
            self.assertNotIn("transcript_path", peer.sent[0])
            self.assertEqual(peer.timeouts[0], 0.3)

    def test_codex_allow_deny_and_always_shapes(self):
        for script in SCRIPTS.values():
            for decision in ("allow", "deny", "always"):
                out, peer = run_script(script, {"hook_event_name": "PermissionRequest", "permission_suggestions": [{"type": "fixture"}]},
                                       answer=json.dumps({"permissionDecision": decision}).encode() + b"\n")
                result = json.loads(out)["hookSpecificOutput"]
                self.assertEqual(result["hookEventName"], "PermissionRequest")
                self.assertEqual(result["decision"]["behavior"], "deny" if decision == "deny" else "allow")
                self.assertNotIn("updatedPermissions", result["decision"])
                self.assertEqual(peer.timeouts[0], 0.3)
                self.assertGreater(peer.timeouts[1], 1)

    def test_legacy_claude_still_tags_claude_and_keeps_always_permissions(self):
        for script in SCRIPTS.values():
            out, peer = run_script(script, {"hook_event_name": "PermissionRequest", "permission_suggestions": [{"type": "fixture"}]},
                                   provider="claude", answer=b'{"permissionDecision":"always"}\n')
            self.assertEqual(peer.sent[0]["agent_provider"], "claude")
            self.assertEqual(json.loads(out)["hookSpecificOutput"]["decision"]["updatedPermissions"], [{"type": "fixture"}])

    def test_closed_app_or_no_decision_prints_nothing(self):
        for script in SCRIPTS.values():
            for absent, answer in ((True, b""), (False, b""), (False, b'{"permissionDecision":"ask"}\n'), (False, b"invalid\n")):
                out, _ = run_script(script, {"hook_event_name": "PermissionRequest"}, absent=absent, answer=answer)
                self.assertEqual(out, "")

    def test_empty_invalid_and_non_object_inputs_are_silent(self):
        for script in SCRIPTS.values():
            for payload in (b"", b"invalid", b"null", b"[]", b'"not-an-object"'):
                out, peer = run_script(script, payload)
                self.assertEqual(out, "")
                self.assertEqual(peer.sent, [])


if __name__ == "__main__": unittest.main()
