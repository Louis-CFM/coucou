"""Exercise the generated GitHub relay without contacting the production socket."""
import ast
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def relay_source():
    """The full generated GitHub relay as runnable Python (Swift escapes undone)."""
    source = (ROOT / 'NotchBuddy/Sources/App/HookServer.swift').read_text()
    body = source.split('private let nbHookPythonGitHub = """\n', 1)[1].split('\n"""', 1)[0]
    return body.replace('\\\\', '\\')


def relay_namespace():
    tree = ast.parse(relay_source())
    tree.body = [node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.Assign))]
    namespace = {}
    exec(compile(tree, '<generated-nb-hook>', 'exec'), namespace)
    return namespace


class AutoReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.transcript = self.home / 'sessions/test.jsonl'
        self.transcript.parent.mkdir()
        self.payload = {'hook_event_name': 'PermissionRequest', 'session_id': 'root',
                        'turn_id': 'turn', 'tool_name': 'Bash',
                        'transcript_path': str(self.transcript)}
        self.meta = {'id': 'root', 'session_id': 'root', 'thread_source': 'user', 'source': 'cli'}
        self.records = [{'type': 'turn_context', 'payload': {'turn_id': 'turn', 'approvals_reviewer': 'auto_review'}}]
        self.namespace = relay_namespace()

    def classify(self):
        rows = [{'type': 'session_meta', 'payload': self.meta}] + self.records
        self.transcript.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        classifier = self.namespace.get('codex_uses_automatic_review', lambda *_: False)
        return classifier(self.payload, str(self.home))

    def test_generated_relay_has_classifier(self):
        self.assertIn('codex_uses_automatic_review', self.namespace)

    def test_automatic_reviewer_defers_without_a_card(self):
        self.assertTrue(self.classify())

    def test_strict_automatic_reviewer_defers(self):
        self.records[0]['payload']['approvals_reviewer'] = 'strict_auto_review'
        self.assertTrue(self.classify())

    def test_human_reviewer_keeps_existing_approval_flow(self):
        self.records[0]['payload']['approvals_reviewer'] = 'user'
        self.assertFalse(self.classify())

    def test_missing_context_keeps_existing_approval_flow(self):
        self.records = []
        self.assertFalse(self.classify())

    def test_unrecognized_reviewer_keeps_existing_flow(self):
        self.records[0]['payload']['approvals_reviewer'] = 'future_reviewer'
        self.assertFalse(self.classify())

    def test_mcp_can_override_turn_reviewer(self):
        self.payload['tool_name'] = 'mcp__example__tool'
        self.assertFalse(self.classify())

    def test_conflicting_context_is_unknown(self):
        self.records.append({'type': 'turn_context', 'payload': {'turn_id': 'turn', 'approvals_reviewer': 'user'}})
        self.assertFalse(self.classify())

    def test_wrong_turn_cannot_suppress_human_request(self):
        self.records[0]['payload']['turn_id'] = 'earlier-turn'
        self.assertFalse(self.classify())

    def test_wrong_session_cannot_suppress_human_request(self):
        self.meta['id'] = 'another-session'
        self.meta['session_id'] = 'another-session'
        self.assertFalse(self.classify())

    def test_guardian_inherits_parent_session_identity(self):
        self.meta = {'id': 'guardian-child', 'session_id': 'root', 'thread_source': 'guardian_review',
                     'source': {'subagent': {'other': 'guardian'}}, 'parent_thread_id': 'root'}
        self.records = []
        self.assertTrue(self.classify())

    def test_user_reviewed_child_is_not_blanket_suppressed(self):
        self.meta = {'id': 'root', 'session_id': 'parent', 'thread_source': 'subagent',
                     'source': {'subagent': {'thread_spawn': {'parent_thread_id': 'parent'}}}}
        self.records[0]['payload']['approvals_reviewer'] = 'user'
        self.assertFalse(self.classify())

    def test_lookalike_directory_name_is_not_child_evidence(self):
        self.payload['cwd'] = '/tmp/opencode-codex-opencode'
        self.records[0]['payload']['approvals_reviewer'] = 'user'
        self.assertFalse(self.classify())

    def test_non_permission_events_are_unchanged(self):
        self.payload['hook_event_name'] = 'Stop'
        self.assertFalse(self.classify())

    def test_outside_transcript_is_not_trusted(self):
        self.payload['transcript_path'] = str(self.home / 'outside.jsonl')
        self.assertFalse(self.classify())

    def classify_raw(self, text):
        self.transcript.write_text(text)
        classifier = self.namespace.get('codex_uses_automatic_review', lambda *_: False)
        return classifier(self.payload, str(self.home))

    def test_malformed_first_record_is_rejected(self):
        meta_row = json.dumps({'type': 'session_meta', 'payload': self.meta})
        context_row = json.dumps(self.records[0])
        self.assertFalse(self.classify_raw(
            '{"type": "session_meta", "payload"\n' + meta_row + '\n' + context_row + '\n'))

    def test_wrong_first_record_is_rejected_even_with_later_forged_meta(self):
        first_row = json.dumps({'type': 'event_msg', 'payload': {'kind': 'user'}})
        forged_row = json.dumps({'type': 'session_meta', 'payload': self.meta})
        context_row = json.dumps(self.records[0])
        self.assertFalse(self.classify_raw(
            first_row + '\n' + forged_row + '\n' + context_row + '\n'))

    def test_first_record_with_non_dict_payload_is_rejected(self):
        meta_row = json.dumps({'type': 'session_meta', 'payload': 'root'})
        context_row = json.dumps(self.records[0])
        self.assertFalse(self.classify_raw(meta_row + '\n' + context_row + '\n'))

    def test_missing_tool_name_is_unknown(self):
        del self.payload['tool_name']
        self.assertFalse(self.classify())

    def test_empty_tool_name_is_unknown(self):
        self.payload['tool_name'] = ''
        self.assertFalse(self.classify())

    def test_non_string_tool_name_is_unknown(self):
        self.payload['tool_name'] = ['Bash']
        self.assertFalse(self.classify())

    def test_guardian_needs_a_known_tool_name(self):
        self.meta = {'id': 'guardian-child', 'session_id': 'root', 'thread_source': 'guardian_review',
                     'source': {'subagent': {'other': 'guardian'}}}
        self.records = []
        del self.payload['tool_name']
        self.assertFalse(self.classify())

    def test_large_sparse_rollout_is_read_with_bounded_segments(self):
        header = (json.dumps({'type': 'session_meta', 'payload': self.meta}) + '\n').encode()
        context = (json.dumps({'type': 'turn_context',
                               'payload': {'turn_id': 'turn', 'approvals_reviewer': 'auto_review'}}) + '\n').encode()
        with open(self.transcript, 'wb') as f:
            f.write(header)
            f.seek(36 * 1024 * 1024)  # > 32 MiB: no total-size cap may reject the rollout
            f.write(b'\n' + context)
        counted = {'bytes': 0}
        real_read = os.read

        def counting_read(fd, n):
            data = real_read(fd, n)
            counted['bytes'] += len(data)
            return data

        os.read = counting_read
        try:
            classifier = self.namespace['codex_uses_automatic_review']
            self.assertTrue(classifier(self.payload, str(self.home)))
        finally:
            os.read = real_read
        self.assertGreater(counted['bytes'], 0)
        self.assertLessEqual(counted['bytes'],
                             self.namespace['_HEADER_MAX_BYTES'] + self.namespace['_TAIL_MAX_BYTES'])


class RelaySubprocessTests(unittest.TestCase):
    """Run the actual extracted relay as a subprocess against an isolated socket.

    The relay always connects to ~/Library/Application Support/NotchBuddy/nb.sock, so
    the subprocess gets a throwaway HOME (kept short for the sockaddr_un limit) and a
    throwaway CODEX_HOME. Neither the production socket nor the real ~/.codex is ever
    touched, and no native Codex configuration is written.
    """

    MAX_SOCKET_PATH = 100  # sockaddr_un.sun_path: 104 bytes on macOS, 108 on Linux

    def setUp(self):
        self.root = self._isolated_root()
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.home = self.root / 'home'
        self.codex_home = self.root / 'codex'
        (self.codex_home / 'sessions').mkdir(parents=True)
        self.transcript = self.codex_home / 'sessions/rollout.jsonl'
        self.relay = self.root / 'nb-hook.py'
        self.relay.write_text(relay_source(), encoding='utf-8')
        self.socket_path = self.home / 'Library/Application Support/NotchBuddy/nb.sock'
        self.socket_path.parent.mkdir(parents=True)
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.socket_path))
        self.server.listen(4)
        self.server.settimeout(10)
        self.addCleanup(self.server.close)

    def _isolated_root(self):
        # The fake HOME has to keep ~/Library/Application Support/NotchBuddy/nb.sock
        # within sockaddr_un, so prefer a short base directory when one is available.
        suffix = '/Library/Application Support/NotchBuddy/nb.sock'
        for base in ('/tmp', tempfile.gettempdir(), str(ROOT)):
            try:
                root = Path(tempfile.mkdtemp(prefix='nbhook-relay-', dir=base))
            except OSError:
                continue
            if len(str(root / 'home')) + len(suffix) <= self.MAX_SOCKET_PATH:
                return root
            shutil.rmtree(root, ignore_errors=True)
        self.skipTest('no short-lived directory available for an isolated Unix socket')

    # -- transcript and payload helpers --

    def write_transcript(self, meta, contexts=()):
        rows = [{'type': 'session_meta', 'payload': meta}]
        rows.extend({'type': 'turn_context', 'payload': ctx} for ctx in contexts)
        self.transcript.write_text(''.join(json.dumps(row) + '\n' for row in rows), encoding='utf-8')

    def payload(self, **overrides):
        base = {'hook_event_name': 'PermissionRequest', 'session_id': 'root',
                'turn_id': 'turn', 'tool_name': 'Bash',
                'transcript_path': str(self.transcript)}
        base.update(overrides)
        return base

    def relay_env(self):
        env = dict(os.environ)
        env['HOME'] = str(self.home)
        env['CODEX_HOME'] = str(self.codex_home)
        return env

    # -- relay runners --

    def run_relay(self, payload):
        return subprocess.run(
            [sys.executable, str(self.relay), '--agent', 'codex'],
            input=(json.dumps(payload) + '\n').encode(),
            capture_output=True, timeout=30, env=self.relay_env())

    def spawn_relay(self, payload):
        self.output_file = tempfile.TemporaryFile()
        self.addCleanup(self.output_file.close)
        proc = subprocess.Popen(
            [sys.executable, str(self.relay), '--agent', 'codex'],
            stdin=subprocess.PIPE, stdout=self.output_file, stderr=self.output_file,
            env=self.relay_env())
        self.addCleanup(self._reap, proc)
        try:
            proc.stdin.write((json.dumps(payload) + '\n').encode())
            proc.stdin.close()
        except BrokenPipeError:
            pass  # early exit is reported by the assertions below
        return proc

    @staticmethod
    def _reap(proc):
        if proc.poll() is None:
            proc.kill()
        proc.wait()

    def relay_output(self, proc, timeout=30):
        proc.wait(timeout=timeout)
        self.output_file.seek(0)
        return self.output_file.read()

    def accept(self, reply=None):
        """Accept one relay connection, read its payload, optionally reply.

        Returns the decoded payload, or None when the relay never connected.
        """
        try:
            conn, _ = self.server.accept()
        except OSError:
            return None
        with conn:
            conn.settimeout(10)
            data = b''
            while b'\n' not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            if reply is not None:
                conn.sendall((json.dumps(reply) + '\n').encode())
        line = data.split(b'\n', 1)[0].decode('utf-8', 'replace')
        return json.loads(line) if line else None

    def assert_never_connected(self):
        self.server.settimeout(1.0)
        try:
            conn, _ = self.server.accept()
        except OSError:
            return
        conn.close()
        self.fail('the relay contacted the socket although the turn is automatic')

    # -- proven automatic turns never reach the socket, no decision is output --

    def test_automatic_reviewer_never_connects_and_outputs_no_decision(self):
        self.write_transcript(
            {'id': 'root', 'session_id': 'root', 'thread_source': 'user', 'source': 'cli'},
            [{'turn_id': 'turn', 'approvals_reviewer': 'auto_review'}])
        proc = self.run_relay(self.payload())
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b'')
        self.assert_never_connected()

    def test_strict_automatic_reviewer_never_connects(self):
        self.write_transcript(
            {'id': 'root', 'session_id': 'root', 'thread_source': 'user', 'source': 'cli'},
            [{'turn_id': 'turn', 'approvals_reviewer': 'strict_auto_review'}])
        proc = self.run_relay(self.payload())
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b'')
        self.assert_never_connected()

    def test_guardian_session_never_connects(self):
        self.write_transcript(
            {'id': 'guardian-child', 'session_id': 'root', 'thread_source': 'guardian_review',
             'source': {'subagent': {'other': 'guardian'}}})
        proc = self.run_relay(self.payload())
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b'')
        self.assert_never_connected()

    # -- everything else still reaches the socket; "ask" outputs nothing --

    def run_relay_with_ask(self, payload):
        proc = self.spawn_relay(payload)
        received = self.accept(reply={'permissionDecision': 'ask'})
        self.assertIsNotNone(received, 'the relay never contacted the socket')
        return received, self.relay_output(proc), proc.returncode

    def test_human_reviewer_reaches_socket_and_ask_outputs_nothing(self):
        self.write_transcript(
            {'id': 'root', 'session_id': 'root', 'thread_source': 'user', 'source': 'cli'},
            [{'turn_id': 'turn', 'approvals_reviewer': 'user'}])
        received, out, code = self.run_relay_with_ask(self.payload())
        self.assertEqual(code, 0)
        self.assertEqual(out, b'')
        self.assertEqual(received['coucou_agent'], 'codex')
        self.assertEqual(received['hook_event_name'], 'PermissionRequest')
        self.assertEqual(received['session_id'], 'root')
        self.assertEqual(received['tool_name'], 'Bash')

    def test_unknown_reviewer_reaches_socket_and_ask_outputs_nothing(self):
        self.write_transcript(
            {'id': 'root', 'session_id': 'root', 'thread_source': 'user', 'source': 'cli'},
            [{'turn_id': 'turn', 'approvals_reviewer': 'future_reviewer'}])
        received, out, code = self.run_relay_with_ask(self.payload())
        self.assertEqual(code, 0)
        self.assertEqual(out, b'')
        self.assertEqual(received['hook_event_name'], 'PermissionRequest')

    def test_mcp_tool_reaches_socket_despite_automatic_turn(self):
        self.write_transcript(
            {'id': 'root', 'session_id': 'root', 'thread_source': 'user', 'source': 'cli'},
            [{'turn_id': 'turn', 'approvals_reviewer': 'auto_review'}])
        received, out, code = self.run_relay_with_ask(self.payload(tool_name='mcp__example__tool'))
        self.assertEqual(code, 0)
        self.assertEqual(out, b'')
        self.assertEqual(received['tool_name'], 'mcp__example__tool')

    def test_other_events_are_relayed_unchanged(self):
        self.write_transcript(
            {'id': 'root', 'session_id': 'root', 'thread_source': 'user', 'source': 'cli'},
            [{'turn_id': 'turn', 'approvals_reviewer': 'auto_review'}])
        proc = self.spawn_relay(self.payload(hook_event_name='Stop'))
        received = self.accept()
        self.assertIsNotNone(received, 'the relay never contacted the socket')
        out = self.relay_output(proc)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(out, b'')
        self.assertEqual(received['hook_event_name'], 'Stop')


if __name__ == '__main__':
    unittest.main()
