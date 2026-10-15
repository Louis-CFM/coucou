#!/usr/bin/env python3
"""MCP/socket fixtures only; never reads real hooks, login, or model state."""

import importlib.util
import json
import os
from pathlib import Path
import queue
import selectors
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "NotchBuddy/Resources/CodexDesktopPlugin"
SERVER = PLUGIN / "server.py"
spec = importlib.util.spec_from_file_location("coucou_plugin", SERVER)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FakeCoucou:
    def __init__(self, root):
        self.path = str(Path(root) / "nb.sock")
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen()
        self.listener.settimeout(0.1)
        self.requests = queue.Queue()
        self.connections = []
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while not self.stop.is_set():
            try:
                client, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self.connections.append(client)
            data = bytearray()
            client.settimeout(2)
            try:
                while b"\n" not in data:
                    chunk = client.recv(4096)
                    if not chunk:
                        break
                    data.extend(chunk)
                self.requests.put((client, json.loads(data.split(b"\n", 1)[0])))
            except (OSError, ValueError):
                client.close()

    def request(self):
        return self.requests.get(timeout=2)

    def reply(self, client, value):
        data = value if isinstance(value, bytes) else json.dumps(value).encode() + b"\n"
        client.sendall(data)

    def close(self):
        self.stop.set()
        self.listener.close()
        self.thread.join(timeout=1)
        for client in self.connections:
            client.close()


class MCP:
    def __init__(self, socket_path, timeout=1):
        # Inject fixture paths through the class, not a production environment override.
        launcher = "import runpy,sys; runpy.run_path(sys.argv[1])['Bridge'](sys.argv[2], float(sys.argv[3])).run()"
        self.process = subprocess.Popen([sys.executable, "-u", "-c", launcher, str(SERVER), socket_path, str(timeout)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.send(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                    "clientInfo": {"name": "fixture", "version": "1"}})
        assert self.read()["result"]["protocolVersion"] == "2025-11-25"
        self.notify("notifications/initialized", {})

    def send(self, ident, method, params=None):
        self.write({"jsonrpc": "2.0", "id": ident, "method": method, "params": params or {}})

    def notify(self, method, params):
        self.write({"jsonrpc": "2.0", "method": method, "params": params})

    def write(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b"\n")
        self.process.stdin.flush()

    def call(self, ident, arguments):
        self.send(ident, "tools/call", {"name": "ask_question", "arguments": arguments})

    def read(self):
        if not self.selector.select(timeout=3):
            raise AssertionError("MCP fixture response timed out")
        return json.loads(self.process.stdout.readline())

    def close(self):
        if self.process.stdout.closed:
            return b""
        if not self.process.stdin.closed:
            self.process.stdin.close()
        self.process.wait(timeout=3)
        remaining, diagnostics = self.process.stdout.read(), self.process.stderr.read()
        self.selector.close()
        self.process.stdout.close()
        self.process.stderr.close()
        assert self.process.returncode == 0, diagnostics.decode(errors="replace")
        assert not diagnostics, "Server wrote diagnostics"
        return remaining


class PluginTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="coucou-mcp-", dir="/tmp")
        self.coucou = FakeCoucou(self.temp.name)
        self.mcp = MCP(self.coucou.path)
        self.arguments = {"cwd": self.temp.name, "questions": [
            {"id": "choice", "question": "選哪個？", "options": [{"label": "A", "description": "First"}, {"label": "B"}]},
            {"id": "input", "question": "下一個指示？", "options": [], "isOther": True, "isSecret": True}]}

    def tearDown(self):
        self.mcp.close()
        self.coucou.close()
        self.temp.cleanup()

    def assert_error(self, response):
        self.assertTrue(response["result"]["isError"])
        self.assertIn("original Codex conversation", response["result"]["content"][0]["text"])
        self.assertNotIn("structuredContent", response["result"])

    def test_package_and_protocol(self):
        manifest = json.loads((PLUGIN / "plugin.json").read_text())
        mcp = json.loads((PLUGIN / "mcp.json").read_text())
        marketplace = json.loads((PLUGIN / ".agents/plugins/marketplace.json").read_text())
        self.assertEqual(manifest["name"], "coucou-desktop")
        self.assertTrue(manifest["$schema"].endswith("plugin.schema.json"))
        entry = mcp["mcpServers"]["coucou"]
        self.assertEqual(entry, {"type": "stdio", "command": "python3",
                                 "args": ["${PLUGIN_ROOT}/server.py"], "cwd": "${PLUGIN_ROOT}"})
        self.assertTrue((PLUGIN / "skills/coucou-question/SKILL.md").is_file())
        self.assertTrue((PLUGIN / "README.md").is_file())
        self.assertEqual(marketplace["name"], "coucou-local")
        plugin = marketplace["plugins"][0]
        self.assertEqual(plugin["name"], manifest["name"])
        self.assertEqual(plugin["source"], {"source": "local", "path": "./"})
        self.assertEqual((PLUGIN / plugin["source"]["path"]).resolve(), PLUGIN.resolve())
        self.assertEqual(plugin["policy"], {"installation": "AVAILABLE", "authentication": "ON_INSTALL"})
        self.assertEqual(plugin["category"], "Productivity")
        self.mcp.send(2, "tools/list")
        tools = self.mcp.read()["result"]["tools"]
        self.assertEqual([tool["name"] for tool in tools], ["ask_question"])
        self.mcp.send(3, "ping")
        self.assertEqual(self.mcp.read(), {"jsonrpc": "2.0", "id": 3, "result": {}})
        self.mcp.send(4, "unknown")
        self.assertEqual(self.mcp.read()["error"]["code"], -32601)

    def test_answers_return_to_call_and_unique_identity(self):
        sessions, requests = [], []
        for ident in (10, "second"):
            self.mcp.call(ident, self.arguments)
            client, payload = self.coucou.request()
            self.assertEqual(payload["coucou_kind"], "codex_mcp_question")
            self.assertEqual(payload["coucou_agent"], "codex")
            self.assertEqual(payload["originator"], "Codex Desktop")
            self.assertEqual(payload["cwd"], self.temp.name)
            self.assertFalse(set(payload) & {"thread_id", "turn_id", "coucou_managed"})
            self.assertTrue(payload["tool_input"]["questions"][0]["isOther"])
            sessions.append(payload["session_id"])
            requests.append(payload["request_id"])
            answers = {"choice": {"answers": ["B"]}, "input": {"answers": ["Continue 繁體中文"]}}
            self.coucou.reply(client, {"permissionDecision": "answer", "answers": answers})
            response = self.mcp.read()
            self.assertEqual(response["id"], ident)
            self.assertEqual(response["result"]["structuredContent"], {"answers": answers})
            self.assertEqual(json.loads(response["result"]["content"][0]["text"]), {"answers": answers})
            self.assertFalse(response["result"]["isError"])
        self.assertEqual(sessions[0], sessions[1])
        self.assertNotEqual(requests[0], requests[1])

    def test_invalid_shapes_never_reach_socket(self):
        invalid = [None, {}, {**self.arguments, "cwd": "."}, {**self.arguments, "cwd": "/absent-fixture-directory"},
                   {**self.arguments, "questions": []}, {**self.arguments, "questions": self.arguments["questions"] * 2},
                   {**self.arguments, "questions": [{"id": "q", "question": "x", "isOther": False}]},
                   {**self.arguments, "questions": [{"id": "q", "question": "x", "isSecret": "true"}]},
                   {**self.arguments, "questions": [{"id": "q", "question": "x", "options": [{"label": "a"}] * 10}]},
                   {**self.arguments, "questions": [{"id": "q", "question": "x", "options": [{"label": "a"}] * 2}]},
                   {**self.arguments, "questions": [{"id": "q", "question": "x" * 4097}]},
                   {**self.arguments, "extra": True}]
        for ident, arguments in enumerate(invalid, 10):
            self.mcp.call(ident, arguments)
            self.assert_error(self.mcp.read())
        self.assertTrue(self.coucou.requests.empty())

    def test_busy_cancel_stale_ids_and_new_call(self):
        self.mcp.call(10, self.arguments)
        first, _ = self.coucou.request()
        self.mcp.call(10, self.arguments)
        duplicate = self.mcp.read()
        self.assertIsNone(duplicate["id"])
        self.assertEqual(duplicate["error"]["code"], -32600)
        self.mcp.call(11, self.arguments)
        self.assert_error(self.mcp.read())
        self.mcp.notify("notifications/cancelled", {"requestId": 11})
        self.mcp.notify("notifications/cancelled", {"requestId": "10"})
        self.mcp.notify("notifications/cancelled", {"requestId": True})
        self.mcp.send(12, "ping")
        self.assertEqual(self.mcp.read()["id"], 12)
        self.mcp.notify("notifications/cancelled", {"requestId": 10})
        response = self.mcp.read()
        self.assertEqual(response["id"], 10)
        self.assert_error(response)
        self.assertEqual(first.recv(1), b"")
        self.mcp.call(13, self.arguments)
        second, _ = self.coucou.request()
        self.mcp.notify("notifications/cancelled", {"requestId": 10})
        answers = {"choice": {"answers": ["A"]}, "input": {"answers": ["New request"]}}
        self.coucou.reply(second, {"permissionDecision": "answer", "answers": answers})
        self.assertEqual(self.mcp.read()["result"]["structuredContent"], {"answers": answers})

    def test_invalid_or_stale_answers_fall_back(self):
        responses = [{"permissionDecision": "ask"}, {"permissionDecision": "answer", "answers": {}},
                     {"permissionDecision": "answer", "answers": {"old-question": {"answers": ["wrong"]}}},
                     {"permissionDecision": "answer", "answers": {"choice": "A", "input": {"answers": ["x"]}}},
                     {"permissionDecision": "answer", "answers": {"choice": {"answers": ["A"]}, "input": {"answers": []}}},
                     b'{"permissionDecision":"answer","permissionDecision":"ask"}\n',
                     b"not json\n", b"x" * (module.MAX_BYTES + 1) + b"\n"]
        for ident, value in enumerate(responses, 10):
            self.mcp.call(ident, self.arguments)
            client, _ = self.coucou.request()
            try:
                self.coucou.reply(client, value)
            except BrokenPipeError:
                pass
            self.assert_error(self.mcp.read())

    def test_timeout_disconnect_and_eof(self):
        self.mcp.close()
        self.mcp = MCP(self.coucou.path, timeout=0.15)
        self.mcp.call(10, self.arguments)
        first, _ = self.coucou.request()
        self.assert_error(self.mcp.read())
        self.assertEqual(first.recv(1), b"")
        self.mcp.call(11, self.arguments)
        second, _ = self.coucou.request()
        second.close()
        self.assert_error(self.mcp.read())
        self.mcp.call(12, self.arguments)
        third, _ = self.coucou.request()
        self.assertEqual(self.mcp.close(), b"")
        self.assertEqual(third.recv(1), b"")

    def test_missing_socket_and_closed_choice_fail_without_answers(self):
        self.mcp.close()
        self.mcp = MCP(str(Path(self.temp.name) / "missing.sock"))
        self.mcp.call(10, self.arguments)
        self.assert_error(self.mcp.read())
        self.assertTrue(self.coucou.requests.empty())
        self.mcp.close()
        self.mcp = MCP(self.coucou.path)
        arguments = {"cwd": self.temp.name, "questions": [
            {"id": "choice", "question": "Choose", "isOther": False, "options": [{"label": "A"}]}]}
        self.mcp.call(11, arguments)
        client, _ = self.coucou.request()
        self.coucou.reply(client, {"permissionDecision": "answer", "answers": {"choice": {"answers": ["B"]}}})
        self.assert_error(self.mcp.read())

    def test_invalid_json_and_input_size_bound(self):
        self.mcp.process.stdin.write(b"not json\n")
        self.mcp.process.stdin.flush()
        self.assertEqual(self.mcp.read()["error"]["code"], -32700)
        self.mcp.process.stdin.write(b"[" * 1500 + b"0" + b"]" * 1500 + b"\n")
        self.mcp.process.stdin.flush()
        self.assertIn(self.mcp.read()["error"]["code"], {-32700, -32600})
        self.mcp.write({"jsonrpc": "2.0", "id": True, "method": "ping"})
        self.assertEqual(self.mcp.read()["error"]["code"], -32600)
        self.mcp.process.stdin.write(b"x" * (module.MAX_BYTES + 1) + b"\n")
        self.mcp.process.stdin.flush()
        self.assertEqual(self.mcp.read()["error"]["code"], -32700)
        self.assertEqual(self.mcp.close(), b"")


if __name__ == "__main__":
    unittest.main()
