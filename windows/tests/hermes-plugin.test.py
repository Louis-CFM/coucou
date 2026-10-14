"""Exercise the generated plugin through a real newline-JSON relay process."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "src-tauri/src/agents.rs"


class Request:
    command = "printf 'safe'"
    description = "Test command"
    timeout_seconds = 1
    allowed_choices = ("once", "deny")

    def respond(self, choice):
        return choice


class PluginTest(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text().split('const HERMES_PLUGIN: &str = r#"', 1)[1].split('"#;', 1)[0]
        self.plugin = types.ModuleType("coucou_test")
        exec(compile(source.replace("{HOOK}", repr(sys.executable)), str(SOURCE), "exec"), self.plugin.__dict__)
        self.transports = {}
        ctx = types.SimpleNamespace(
            register_hook=lambda *args: None,
            register_approval_transport=lambda name, fn: self.transports.update(approval=fn),
            register_clarify_transport=lambda name, fn: self.transports.update(clarify=fn),
        )
        self.plugin.register(ctx)
        self.plugin._current_session_id = "test-session"

    def relay(self, output, returncode=0):
        real_run = subprocess.run
        def run(args, **kwargs):
            # A real subprocess consumes and validates the plugin's exact wire frame.
            script = (
                "import json,sys; raw=sys.stdin.readline(); "
                "assert raw.endswith('\\n'); p=json.loads(raw); "
                "assert p['session_id']=='test-session'; "
                "assert p['hook_event_name'] in ('PermissionRequest','HermesClarify'); "
                f"sys.stdout.write({output!r}); sys.exit({returncode})"
            )
            return real_run([sys.executable, "-c", script], **kwargs)
        self.plugin.subprocess = types.SimpleNamespace(run=run)

    def test_allow_is_one_time_and_deny_stays_deny(self):
        for wire, expected in [("allow\n", "once"), ("deny\n", "deny")]:
            self.relay(wire)
            self.assertEqual(self.transports["approval"](Request()), expected)

    def test_missing_invalid_and_failed_relay_trigger_host_fallback(self):
        for wire, status in [("", 0), ("always", 0), ("session", 0), ("{\"choice\":\"allow\"}", 0), ("allow", 1)]:
            self.relay(wire, status)
            with self.assertRaises(RuntimeError):
                self.transports["approval"](Request())

    def test_disallowed_allow_never_grants_access(self):
        self.relay("allow")
        request = Request()
        request.allowed_choices = ("deny",)
        with self.assertRaises(RuntimeError):
            self.transports["approval"](request)

    def test_unavailable_and_timeout_trigger_host_fallback(self):
        for error in [FileNotFoundError(), subprocess.TimeoutExpired("relay", 1)]:
            def run(*args, **kwargs):
                raise error
            self.plugin.subprocess = types.SimpleNamespace(run=run)
            with self.assertRaises((FileNotFoundError, subprocess.TimeoutExpired)):
                self.transports["approval"](Request())

    def test_clarify_answers_and_missing_relay(self):
        self.relay(json.dumps({"answer": {"q0": "A"}}))
        self.assertEqual(self.transports["clarify"]([{"question": "Pick", "options": []}]),
                         {"answers": {"q0": "A"}, "outcome": "submitted"})
        self.relay("")
        self.assertIsNone(self.transports["clarify"]([{"question": "Pick"}]))

    def test_clarify_terminal_handoff_does_not_return_fabricated_answer(self):
        self.relay("")
        self.assertIsNone(self.transports["clarify"]([{"question": "Type in terminal"}]))

    def test_older_hermes_keeps_observer_hooks(self):
        hooks = []
        self.plugin.register(types.SimpleNamespace(register_hook=lambda name, fn: hooks.append(name)))
        self.assertIn("pre_approval_request", hooks)


if __name__ == "__main__":
    unittest.main()
