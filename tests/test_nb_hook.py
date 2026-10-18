#!/usr/bin/env python3
# Runs the Mac's nb-hook.py (the template in HookServer.swift) against a fake
# Coucou on a Unix socket: what the agent reads on stdout, and how long it waits.
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT = os.path.join(ROOT, 'NotchBuddy', 'Sources', 'App', 'HookServer.swift')


def relay_source(socket_path):
    with open(SWIFT, encoding='utf-8') as f:
        text = f.read().replace('\r\n', '\n')
    m = re.search(r'private let nbHookPythonTemplate = """\n(.*?)\n"""', text, re.S)
    assert m, 'nbHookPythonTemplate not found in HookServer.swift'
    # A Swift multi-line literal writes each backslash twice.
    return m.group(1).replace('\\\\', '\\').replace('__COUCOU_SOCKET__', socket_path)


class FakeApp:
    # One connection: reads the event line, then calls respond(conn, event).
    # The connection stays open until close(), like an app that holds a card.
    def __init__(self, path, respond):
        self.respond = respond
        self.event = None
        self.conn = None
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(4)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        self.conn, _ = self.server.accept()
        data = b''
        while b'\n' not in data:
            chunk = self.conn.recv(1 << 20)
            if not chunk:
                break
            data += chunk
        self.event = json.loads(data.split(b'\n', 1)[0])
        try:
            self.respond(self.conn, self.event)
        except OSError:
            pass

    def close(self):
        if self.conn:
            self.conn.close()
        self.server.close()


class Relay(unittest.TestCase):
    PERMISSION = {'hook_event_name': 'PermissionRequest', 'tool_name': 'Bash', 'tool_input': {'command': 'ls'}}

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.sock = os.path.join(self.tmp, 'nb.sock')
        self.script = os.path.join(self.tmp, 'nb-hook.py')
        with open(self.script, 'w', encoding='utf-8') as f:
            f.write(relay_source(self.sock))
        self.app = None

    def tearDown(self):
        if self.app:
            self.app.close()

    def serve(self, respond):
        self.app = FakeApp(self.sock, respond)
        return self.app

    def run_relay(self, payload, *args):
        started = time.monotonic()
        proc = subprocess.run([sys.executable, self.script, *args],
                              input=json.dumps(payload).encode(), capture_output=True, timeout=30)
        return proc.stdout.decode().strip(), time.monotonic() - started

    def received(self):
        self.app.thread.join(5)
        return self.app.event

    # ── the relay, as before ─────────────────────────────────────────────────

    def test_no_app_never_holds_the_agent(self):
        out, took = self.run_relay(self.PERMISSION)
        self.assertEqual(out, '')
        self.assertLess(took, 2.0)

    def test_events_reach_the_app(self):
        self.serve(lambda conn, event: None)
        out, _ = self.run_relay({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash',
                                 'tool_input': {'command': 'ls'}})
        self.assertEqual(out, '')
        self.assertEqual(self.received()['tool_name'], 'Bash')

    def test_an_allow_from_the_app_is_the_documented_decision(self):
        self.serve(lambda conn, event: conn.sendall(b'{"permissionDecision":"allow"}\n'))
        out, _ = self.run_relay(self.PERMISSION)
        self.assertEqual(json.loads(out)['hookSpecificOutput']['decision']['behavior'], 'allow')

    # ── the ack ──────────────────────────────────────────────────────────────

    def test_the_relay_asks_for_an_ack(self):
        self.serve(lambda conn, event: conn.sendall(b'{"permissionDecision":"ask"}\n'))
        self.run_relay(self.PERMISSION)
        self.assertEqual(self.received().get('coucou_ack'), 1)

    def test_an_app_that_never_shows_the_card_costs_the_agent_under_two_seconds(self):
        self.serve(lambda conn, event: None)  # reads the event, never answers, keeps the connection
        out, took = self.run_relay(self.PERMISSION)
        self.assertEqual(out, '')
        self.assertLess(took, 2.5)

    def test_after_the_ack_the_relay_waits_for_the_click(self):
        def respond(conn, event):
            conn.sendall(b'{"ack":true}\n')
            time.sleep(2.0)  # longer than the ack budget: a human deciding
            conn.sendall(b'{"permissionDecision":"deny"}\n')
        self.serve(respond)
        out, took = self.run_relay(self.PERMISSION)
        self.assertEqual(json.loads(out)['hookSpecificOutput']['decision']['behavior'], 'deny')
        self.assertGreater(took, 1.9)

    def test_an_immediate_answer_without_ack_still_counts(self):
        self.serve(lambda conn, event: conn.sendall(b'{"permissionDecision":"allow"}\n'))
        out, _ = self.run_relay(self.PERMISSION)
        self.assertEqual(json.loads(out)['hookSpecificOutput']['decision']['behavior'], 'allow')

    def test_a_question_waits_for_its_answer_after_the_ack(self):
        question = {'hook_event_name': 'PreToolUse', 'tool_name': 'AskUserQuestion',
                    'tool_input': {'questions': [{'question': 'Which?', 'options': [{'label': 'A'}, {'label': 'B'}]}]}}

        def respond(conn, event):
            conn.sendall(b'{"ack":true}\n')
            time.sleep(2.0)
            conn.sendall(b'{"permissionDecision":"answer","answers":{"Which?":"B"}}\n')
        self.serve(respond)
        out, _ = self.run_relay(question, '--ask')
        self.assertEqual(json.loads(out)['hookSpecificOutput']['updatedInput']['answers'], {'Which?': 'B'})

    # ── the caps ─────────────────────────────────────────────────────────────

    def test_a_huge_tool_input_is_capped_on_its_way_to_the_app(self):
        self.serve(lambda conn, event: None)
        self.run_relay({'hook_event_name': 'PreToolUse', 'tool_name': 'Write',
                        'tool_input': {'file_path': '/p/a.txt', 'content': 'é' * 1_500_000}})
        content = self.received()['tool_input']['content']
        self.assertLessEqual(len(content.encode('utf-8')), 2000 + 3)
        self.assertTrue(content.endswith('…'))

    def test_a_finished_edit_keeps_its_text_for_the_live_diff(self):
        self.serve(lambda conn, event: None)
        big = 'line\n' * 4_000  # 20 KB
        self.run_relay({'hook_event_name': 'PostToolUse', 'tool_name': 'Edit',
                        'tool_input': {'file_path': '/p/a.ts', 'old_string': big, 'new_string': 'x'}})
        event = self.received()
        self.assertEqual(event['tool_input']['old_string'], big)
        self.assertNotIn('coucou_diff_truncated', event)

    def test_an_edit_past_the_diff_budget_is_cut_and_flagged(self):
        self.serve(lambda conn, event: None)
        self.run_relay({'hook_event_name': 'PostToolUse', 'tool_name': 'Write',
                        'tool_input': {'file_path': '/p/big.txt', 'content': 'x' * 300_000}})
        event = self.received()
        self.assertLessEqual(len(event['tool_input']['content'].encode('utf-8')), 256 * 1024 + 3)
        self.assertTrue(event['coucou_diff_truncated'])

    def test_the_question_and_the_final_answer_are_kept_whole(self):
        self.serve(lambda conn, event: None)
        self.run_relay({'hook_event_name': 'Stop', 'last_assistant_message': 'w' * 50_000})
        self.assertEqual(len(self.received()['last_assistant_message']), 50_000)

        self.app.close()
        os.unlink(self.sock)  # a closed Unix socket leaves its file behind
        long_q = 'q' * 3000

        def respond(conn, event):
            conn.sendall(b'{"ack":true}\n')
            conn.sendall(json.dumps({'permissionDecision': 'answer', 'answers': {long_q: 'A'}}).encode() + b'\n')
        self.serve(respond)
        question = {'hook_event_name': 'PreToolUse', 'tool_name': 'AskUserQuestion',
                    'tool_input': {'questions': [{'question': long_q, 'options': [{'label': 'A'}, {'label': 'B'}]}]}}
        out, _ = self.run_relay(question, '--ask')
        self.assertEqual(len(self.received()['tool_input']['questions'][0]['question']), 3000)
        self.assertEqual(json.loads(out)['hookSpecificOutput']['updatedInput']['questions'][0]['question'], long_q)


if __name__ == '__main__':
    unittest.main(verbosity=2)
