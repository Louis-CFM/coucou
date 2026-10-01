"""Exercise the Python relays embedded in the Swift source, with fixture sockets.

No user config or real Coucou socket is opened. The same tests run on Windows
and macOS; the socket factory supplies only an explicit, disposable fake peer.
"""
import io
import json
import pathlib
import re
import types
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "NotchBuddy/Sources/App/HookServer.swift").read_text(encoding="utf-8")
SCRIPTS = dict(re.findall(r'private let (nbHookScript\w*) = """\n(.*?)\n"""', SOURCE, re.S))


class Peer:
    def __init__(self, answer=b"", absent=False):
        self.answer = answer
        self.absent = absent
        self.sent = []
        self.timeouts = []

    def settimeout(self, seconds): self.timeouts.append(seconds)
    def connect(self, path):
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
        self.assertEqual(set(SCRIPTS), {"nbHookScript", "nbHookScriptAppStore"})
        for script in SCRIPTS.values(): compile(script.replace("\\\\", "\\"), "nb-hook", "exec")

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
