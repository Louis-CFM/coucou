"""Exercise the generated Hermes callback without launching Coucou or calling a model."""

import json
import queue
import re
import subprocess
import threading
import unittest
from pathlib import Path
from unittest.mock import patch


class HermesPluginTest(unittest.TestCase):
    def setUp(self):
        source = (Path(__file__).resolve().parents[1] / "src-tauri/src/agents.rs").read_text(encoding="utf-8")
        template = re.search(r'const HERMES_PLUGIN: &str = r#"(.*?)"#;', source, re.S)
        self.assertIsNotNone(template)
        self.hook = r"C:\Coucou\bin\coucou-hook.exe"
        plugin = template.group(1).replace("{HOOK}", json.dumps(self.hook))
        scope = {"__name__": "coucou_hermes_test"}
        exec(compile(plugin, "<generated Hermes plugin>", "exec"), scope)
        self.callbacks = {}
        scope["register"](self)
        self.events = queue.Queue()

    def register_hook(self, name, callback):
        self.callbacks[name] = callback

    def fire(self, name, **kwargs):
        events = self.events

        class FakeStdin:
            def __init__(self):
                self.data = b""

            def write(self, data):
                self.data += data

            def close(self):
                pass

        class FakePopen:
            def __init__(self, argv, **options):
                self.argv = argv
                self.options = options
                self.stdin = FakeStdin()

            def wait(self, timeout):
                events.put((self.argv, self.options, json.loads(self.stdin.data)))
                return 0

        with patch.object(subprocess, "Popen", FakePopen):
            self.callbacks[name](**kwargs)
            argv, options, payload = events.get(timeout=2)
        self.assertEqual(argv, [self.hook, "--agent", "hermes"])
        self.assertEqual(options["stdin"], subprocess.PIPE)
        return payload

    def test_session_start_and_resumed_turn_use_the_relay_without_prompt(self):
        self.assertIn("on_session_start", self.callbacks)
        self.assertIn("pre_llm_call", self.callbacks)
        self.assertEqual(
            self.fire("on_session_start", session_id="20261008_123456_abcdef", platform="cli"),
            {"hook_event_name": "SessionStart", "session_id": "20261008_123456_abcdef", "platform": "cli"},
        )
        turn = self.fire(
            "pre_llm_call", session_id="20261008_123456_abcdef",
            turn_id="20261008_123456_abcdef:task:abcd1234", user_message="SECRET_SENTINEL",
        )
        self.assertEqual(turn, {
            "hook_event_name": "UserPromptSubmit", "session_id": "20261008_123456_abcdef",
            "turn_id": "20261008_123456_abcdef:task:abcd1234",
        })
        self.assertNotIn("SECRET_SENTINEL", json.dumps(turn))

    def test_monitoring_and_permission_observers_remain_registered(self):
        for name in ("on_session_end", "post_llm_call", "pre_tool_call", "post_tool_call", "pre_approval_request"):
            self.assertIn(name, self.callbacks)
        answer = self.fire("post_llm_call", session_id="s", response="Synthetic answer")
        self.assertEqual(answer["hook_event_name"], "Stop")

    def test_missing_relay_warns_once_and_does_not_block_hermes(self):
        class InlineThread:
            def __init__(self, target, daemon):
                self.target = target

            def start(self):
                self.target()

        with patch.object(threading, "Thread", InlineThread), patch.object(subprocess, "Popen", side_effect=FileNotFoundError):
            with self.assertLogs("coucou_hermes_test", level="WARNING") as log:
                self.callbacks["on_session_start"](session_id="s", platform="cli")
                self.callbacks["pre_llm_call"](session_id="s", turn_id="t", user_message="SECRET_SENTINEL")
        self.assertEqual(len(log.output), 1)
        self.assertIn("FileNotFoundError", log.output[0])
        self.assertNotIn("SECRET_SENTINEL", log.output[0])


if __name__ == "__main__":
    unittest.main()
