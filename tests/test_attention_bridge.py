import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location("bridge", Path(__file__).resolve().parents[1] / "NotchBuddy/Resources/attention_bridge.py")
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
SID = "01a14345-b5dc-7ed3-855a-c7d8e5e3115f"
STAMP = "2026-10-16T07:00:00Z"
NOW = b.iso_time(STAMP) + 10


def record(kind, **payload):
    return {"type": kind, "timestamp": STAMP, "payload": payload}


def call(key="call_1", async_=True, questions=None):
    return record("response_item", type="function_call", name="request_user_input_async" if async_ else "request_user_input",
                  call_id=key, arguments=json.dumps({"questions": questions or [{"title": "Choose one?", "question": "Choose one?"}]}))


def output(key="call_1", **value):
    return record("response_item", type="function_call_output", call_id=key, output=json.dumps(value))


def reply(key="call_1", index=0):
    text = "<send_user_message_question_reply>\n" + json.dumps([{"questionItemId": json.dumps(["request_user_input_async", key, index]), "answer": "A"}]) + "\n</send_user_message_question_reply>"
    return record("response_item", type="message", role="user", content=[{"type": "input_text", "text": text}])


def meta(**changes):
    value = dict(id=SID, session_id=SID, thread_source="user", originator="Codex Desktop", source="vscode")
    value.update(changes)
    return record("session_meta", **value)


PARENT = "5f6e7d8c-9a0b-4c1d-8e2f-3a4b5c6d7e8f"


def spawn(child=SID, parent=PARENT, **changes):
    """The real subagent thread_spawn metadata shape."""
    value = dict(id=child, session_id=parent, thread_source="subagent", originator="Codex Desktop",
                 parent_thread_id=parent,
                 source={"subagent": {"thread_spawn": {"parent_thread_id": parent}}})
    value.update(changes)
    return record("session_meta", **value)


class QuietOpenCode:
    """Test double: no candidate sessions, no pending permissions."""
    def sessions(self, include_children=None):
        return []

    def snapshot(self):
        return []


class QuestionsTests(unittest.TestCase):
    def setUp(self):
        self.q = b.CodexQuestions(SID, "Human chat")
        self.q.feed(record("turn_context", turn_id="turn1", approvals_reviewer="user"))

    def test_accepted_then_answered(self):
        self.q.feed(call())
        self.assertEqual(self.q.pending(NOW), [])
        self.q.feed(output(accepted=True))
        self.assertEqual(len(self.q.pending(NOW)), 1)
        self.q.feed(reply())
        self.assertEqual(self.q.pending(NOW), [])

    def test_failed_question_is_not_a_reminder(self):
        self.q.feed(call())
        self.q.feed(output(accepted=False))
        self.assertEqual(self.q.pending(NOW), [])

    def test_partial_replies_and_call_identity(self):
        self.q.feed(call(questions=[{"title": "First"}, {"title": "Second"}]))
        self.q.feed(output(accepted=True))
        self.q.feed(call("call_2"))
        self.q.feed(output("call_2", accepted=True))
        self.q.feed(reply(index=0))
        pending = self.q.pending(NOW)
        self.assertEqual(pending[0]["reason"], "Second")
        self.assertEqual(len(pending), 2)
        self.q.feed(reply(index=1))
        self.assertEqual(self.q.pending(NOW)[0]["id"], "question:call_2")

    def test_blocking_result_and_cancel(self):
        self.q.feed(call(async_=False))
        self.assertEqual(len(self.q.pending(NOW)), 1)
        self.q.feed(output(answers={"choice": "A"}))
        self.assertEqual(self.q.pending(NOW), [])
        self.q.feed(call("call_2"))
        self.q.feed(output("call_2", accepted=True))
        self.q.feed(record("event_msg", type="turn_aborted", turn_id="turn1"))
        self.assertEqual(self.q.pending(NOW), [])

    def test_async_question_survives_task_finish_and_age(self):
        self.q.feed(call())
        self.q.feed(output(accepted=True))
        self.q.feed(record("event_msg", type="task_complete", turn_id="turn1"))
        self.assertEqual(len(self.q.pending(NOW + 2 * 86400)), 1)

    def test_malformed_reply_and_tool_text_cannot_resolve(self):
        self.q.feed(call())
        self.q.feed(output(accepted=True))
        bad = reply()
        bad["payload"]["content"][0]["text"] = "<send_user_message_question_reply>{broken}</send_user_message_question_reply>"
        self.q.feed(bad)
        not_user = reply(); not_user["payload"]["role"] = "assistant"
        self.q.feed(not_user)
        self.assertEqual(len(self.q.pending(NOW)), 1)

    def test_normal_user_reply_supersedes_but_context_update_does_not(self):
        self.q.feed(call())
        self.q.feed(output(accepted=True))
        self.q.feed(record("response_item", role="user", content=[{"text": "# AGENTS.md instructions for /project"}]))
        self.assertEqual(len(self.q.pending(NOW)), 1)
        self.q.feed(record("response_item", role="user", content=[{"text": "完成，請繼續"}]))
        self.assertEqual(self.q.pending(NOW), [])

    def test_root_proof(self):
        self.assertTrue(b.human_codex_root(meta()["payload"], SID))
        for changes in ({"parent_thread_id": "parent"}, {"thread_source": "guardian_review"},
                        {"source": {"subagent": {}}}, {"id": str(uuid.uuid4())},
                        {"session_id": None}, {"originator": "codex_exec"}, {"agent_id": "child"}):
            self.assertFalse(b.human_codex_root(meta(**changes)["payload"], SID), changes)


class TranscriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "sessions").mkdir()
        self.path = self.root / "sessions/rollout.jsonl"
        self.reader = b.CodexReader(self.root)
        self.write([meta(), record("turn_context", turn_id="turn1", approvals_reviewer="user")])

    def tearDown(self):
        self.temp.cleanup()

    def write(self, records, append=False):
        with self.path.open("a" if append else "w") as stream:
            for item in records:
                stream.write(json.dumps(item) + "\n")

    def read(self):
        return self.reader.read(SID, "Human chat", str(self.path))

    def test_partial_write_restart_and_reply(self):
        self.write([call()], append=True)
        data = json.dumps(output(accepted=True)) + "\n"
        with self.path.open("a") as stream: stream.write(data[:30])
        self.assertEqual(self.read().pending(NOW), [])
        with self.path.open("a") as stream: stream.write(data[30:])
        self.assertEqual(len(self.read().pending(NOW)), 1)
        self.reader = b.CodexReader(self.root)
        self.write([reply()], append=True)
        self.assertEqual(self.read().pending(NOW), [])

    def test_truncate_and_outside_path(self):
        self.write([call(), output(accepted=True)], append=True)
        self.assertEqual(len(self.read().pending(NOW)), 1)
        self.write([meta()])
        self.assertEqual(self.read().pending(NOW), [])
        outside = self.root / "outside.jsonl"
        outside.write_text(json.dumps(meta()) + "\n")
        self.assertIsNone(self.reader.read(SID, "Human", str(outside)))

    def test_desktop_catalog_with_real_index_flag(self):
        # Desktop 0.162 stores has_user_event=0 even for the currently human-owned chat.
        with sqlite3.connect(self.root / "state_5.sqlite") as db:
            db.execute("CREATE TABLE threads(id,title,rollout_path,archived,thread_source,originator,updated_at,has_user_event)")
            db.execute("INSERT INTO threads VALUES(?,?,?,0,'user','Codex Desktop',1,0)", (SID, "Human", str(self.path)))
        self.write([call(), output(accepted=True)], append=True)
        self.assertEqual(len(self.reader.snapshot(NOW)), 1)
        self.write([reply()], append=True)
        self.assertEqual(self.reader.snapshot(NOW), [])

    def hook(self, **changes):
        value = dict(coucou_agent="codex", session_id=SID, transcript_path=str(self.path), turn_id="turn1",
                     hook_event_name="PermissionRequest", tool_name="exec_command", tool_input={"command": "true", "justification": "Run a local check"})
        value.update(changes)
        return value

    def test_permission_proof_and_correlated_resolution(self):
        h = b.HumanPermissions(self.reader)
        h.receive(self.hook())
        self.assertEqual(len(h.pending()), 1)
        h.receive(self.hook(hook_event_name="PostToolUse", tool_input={"command": "other"}))
        self.assertEqual(len(h.pending()), 1)
        h.receive(self.hook(hook_event_name="PostToolUse"))
        self.assertEqual(h.pending(), [])
        for change in ({"turn_id": "other"}, {"agent_id": "child"}, {"tool_name": "mcp__server__tool"}):
            h.receive(self.hook(**change))
            self.assertEqual(h.pending(), [])
        self.write([record("turn_context", turn_id="turn1", approvals_reviewer="auto_review")], append=True)
        h.receive(self.hook())
        self.assertEqual(h.pending(), [])

    def test_permission_removed_on_native_tool_result_and_turn_end(self):
        h = b.HumanPermissions(self.reader)
        self.write([record("response_item", type="function_call", call_id="native", name="exec_command",
                           arguments=json.dumps(self.hook()["tool_input"]))], append=True)
        h.receive(self.hook())
        self.assertEqual(len(h.pending()), 1)
        self.write([output("native", exit_code=0)], append=True)
        self.assertEqual(h.pending(), [])
        h.receive(self.hook(tool_input={"command": "second"}))
        self.assertEqual(len(h.pending()), 1)
        self.write([record("event_msg", type="task_complete", turn_id="turn1")], append=True)
        self.assertEqual(h.pending(), [])

    def test_pipe_acknowledgement_never_answers(self):
        h = b.HumanPermissions(self.reader)
        read_fd, write_fd = os.pipe()
        try:
            pipe = b.HookInput(read_fd, h)
            os.write(write_fd, json.dumps(self.hook()).encode() + b"\n")
            self.assertTrue(pipe.drain(0))
            self.assertEqual(len(h.pending()), 1)
            os.close(write_fd); write_fd = -1
            self.assertFalse(pipe.drain(0))
        finally:
            os.close(read_fd)
            if write_fd >= 0: os.close(write_fd)

    def test_include_child_scope(self):
        child = self.root / "sessions/child.jsonl"
        child.write_text(json.dumps(spawn()) + "\n"
                         + json.dumps(record("turn_context", turn_id="turn1", approvals_reviewer="user")) + "\n")
        # Default scope: verified Desktop roots only, spawn chains rejected.
        self.assertIsNone(self.reader.read(SID, "Child", str(child)))
        strict = b.HumanPermissions(self.reader)
        strict.receive(self.hook(transcript_path=str(child)))
        self.assertEqual(strict.pending(), [])
        # Include-child scope: the real thread_spawn chain verifies.
        wide = b.CodexReader(self.root, include_children=True)
        self.assertIsNotNone(wide.read(SID, "Child", str(child)))
        guardian = self.root / "sessions/guardian.jsonl"
        guardian.write_text(json.dumps(meta(thread_source="guardian_review")) + "\n")
        self.assertIsNone(wide.read(SID, "Guardian", str(guardian)))
        wide_permissions = b.HumanPermissions(wide)
        wide_permissions.receive(self.hook(transcript_path=str(child)))
        self.assertEqual(len(wide_permissions.pending()), 1)

    def test_child_originator_must_be_desktop_even_with_catalog_row(self):
        # A non-Desktop originator is rejected at the transcript level too:
        # the catalog query alone does not guard HumanPermissions' direct reads.
        foreign = self.root / "sessions/foreign.jsonl"
        foreign.write_text(json.dumps(spawn(originator="codex_exec")) + "\n"
                           + json.dumps(record("turn_context", turn_id="turn1", approvals_reviewer="user")) + "\n")
        wide = b.CodexReader(self.root, include_children=True)
        self.assertIsNone(wide.read(SID, "Foreign", str(foreign)))
        permissions = b.HumanPermissions(wide)
        permissions.receive(self.hook(transcript_path=str(foreign)))
        self.assertEqual(permissions.pending(), [])

    def test_index_subagent_rows_only_in_include_mode(self):
        child_id = "7a8b9c0d-1e2f-4a3b-8c9d-0e1f2a3b4c5d"
        child = self.root / "sessions/child.jsonl"
        child.write_text(json.dumps(spawn(child=child_id)) + "\n")
        with sqlite3.connect(self.root / "state_5.sqlite") as db:
            db.execute("CREATE TABLE threads(id,title,rollout_path,archived,thread_source,originator,updated_at,has_user_event)")
            db.execute("INSERT INTO threads VALUES(?,?,?,0,'user','Codex Desktop',1,0)", (SID, "Human", str(self.path)))
            db.execute("INSERT INTO threads VALUES(?,?,?,0,'subagent','Codex Desktop',2,0)", (child_id, "Child", str(child)))
            db.execute("INSERT INTO threads VALUES(?,?,?,0,'memory','Codex Desktop',3,0)", ("m" * 36, "Memory", str(self.path)))
            db.execute("INSERT INTO threads VALUES(?,?,?,0,'guardian_review','Codex Desktop',4,0)", ("g" * 36, "Guardian", str(self.path)))
        self.assertEqual([row[0] for row in self.reader.sessions()], [SID])
        wide = b.CodexReader(self.root, include_children=True)
        self.assertEqual([row[0] for row in wide.sessions()], [child_id, SID])

    def test_source_loss_prunes_reader_state(self):
        with sqlite3.connect(self.root / "state_5.sqlite") as db:
            db.execute("CREATE TABLE threads(id,title,rollout_path,archived,thread_source,originator,updated_at,has_user_event)")
            db.execute("INSERT INTO threads VALUES(?,?,?,0,'user','Codex Desktop',1,0)", (SID, "Human", str(self.path)))
        self.write([call(), output(accepted=True)], append=True)
        self.assertEqual(len(self.reader.snapshot(NOW)), 1)
        self.path.unlink()
        self.assertEqual(self.reader.snapshot(NOW), [])
        self.assertEqual(self.reader.readers, {})


class ChildScopeTests(unittest.TestCase):
    """--include-child-sessions accepts only the real thread_spawn chain."""

    def test_real_spawn_chain_verifies_in_include_mode_only(self):
        payload = spawn()["payload"]
        self.assertFalse(b.verified_desktop_thread(payload, SID), "default scope follows roots only")
        self.assertTrue(b.verified_desktop_thread(payload, SID, True))

    def test_broken_or_foreign_spawn_chains_are_rejected(self):
        other = str(uuid.uuid4())
        for changes in ({"thread_source": "guardian_review"},
                        {"thread_source": "memory"},
                        {"thread_source": "codex_exec"},
                        {"thread_source": "user", "session_id": SID, "source": "vscode"},
                        {"originator": "codex_exec"},
                        {"session_id": SID},
                        {"session_id": "not-a-uuid"},
                        {"parent_thread_id": other},
                        {"source": {"subagent": {"thread_spawn": {"parent_thread_id": other}}}},
                        {"source": {"subagent": {}}},
                        {"source": {"subagent": "text"}},
                        {"source": "vscode"},
                        {"id": other}):
            payload = spawn(**changes)["payload"]
            self.assertFalse(b.verified_desktop_thread(payload, SID, True), changes)
            self.assertFalse(b.verified_desktop_thread(payload, SID), changes)

    def test_root_metadata_stays_strict_in_both_modes(self):
        self.assertTrue(b.verified_desktop_thread(meta()["payload"], SID, True))
        for changes in ({"parent_thread_id": PARENT}, {"agent_id": "child"}, {"agent_type": "subagent"},
                        {"originator": "codex_exec"}, {"source": "unknown_client"},
                        {"source": {"subagent": {"thread_spawn": {"parent_thread_id": PARENT}}}}):
            payload = meta(**changes)["payload"]
            self.assertFalse(b.verified_desktop_thread(payload, SID), changes)
            self.assertFalse(b.verified_desktop_thread(payload, SID, True), changes)


class LoopContractTests(unittest.TestCase):
    """The reader loop drains hints before snapshotting, so a hint that just
    woke it is emitted in the same pass — with no filesystem write in between."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "sessions").mkdir()
        self.path = self.root / "sessions/rollout.jsonl"
        self.reader = b.CodexReader(self.root)
        self.permissions = b.HumanPermissions(self.reader)
        self.write([meta(), record("turn_context", turn_id="turn1", approvals_reviewer="user")])

    def tearDown(self):
        self.temp.cleanup()

    def write(self, records, append=False):
        with self.path.open("a" if append else "w") as stream:
            for item in records:
                stream.write(json.dumps(item) + "\n")

    def hook(self, **changes):
        value = dict(coucou_agent="codex", session_id=SID, transcript_path=str(self.path), turn_id="turn1",
                     hook_event_name="PermissionRequest", tool_name="exec_command",
                     tool_input={"command": "true", "justification": "Run a local check"})
        value.update(changes)
        return value

    def test_hint_wakes_loop_and_emits_without_file_write(self):
        read_fd, write_fd = os.pipe()
        watcher = b.SourceWatcher([], stdin_fd=read_fd)
        loop = b.AttentionLoop(self.reader, QuietOpenCode(), self.permissions, "/dev/null",
                               b.HookInput(read_fd, self.permissions), watcher,
                               send=lambda sock, requests, now: sent.append(requests) or True)
        sent = []
        try:
            self.assertEqual(loop.run_once()[1], [])
            # The only thing that changes is the hint on the pipe.
            os.write(write_fd, json.dumps(self.hook()).encode() + b"\n")
            self.assertTrue(watcher.wait(1), "the hint alone must wake the idle loop")
            result = loop.run_once()
            self.assertIsNotNone(result)
            status, requests = result
            self.assertEqual(len(requests), 1)
            self.assertEqual(requests[0]["kind"], "permission")
            self.assertIn("Run a local check", requests[0]["reason"])
            loop.emit(requests)
            self.assertEqual(sent, [requests])
        finally:
            watcher.close()
            loop.shutdown()
            os.close(read_fd)
            os.close(write_fd)

    def test_absent_index_does_not_hide_verified_hook_request(self):
        # The fixture has a verified transcript and hint but no Codex index:
        # the hint must still reconcile and be emitted.
        read_fd, write_fd = os.pipe()
        loop = b.AttentionLoop(self.reader, QuietOpenCode(), self.permissions, "/dev/null",
                               b.HookInput(read_fd, self.permissions))
        try:
            os.write(write_fd, json.dumps(self.hook()).encode() + b"\n")
            status, requests = loop.run_once()
            self.assertIs(status["codex"]["ok"], False)
            self.assertEqual(len(requests), 1)
            self.assertEqual(requests[0]["kind"], "permission")
        finally:
            loop.shutdown()
            os.close(read_fd)
            os.close(write_fd)

    def test_locked_index_does_not_hide_verified_hook_request(self):
        index = sqlite3.connect(self.root / "state_5.sqlite", timeout=.3)
        index.execute("CREATE TABLE threads(id,title,rollout_path,archived,thread_source,originator,updated_at,has_user_event)")
        index.execute("INSERT INTO threads VALUES(?,?,?,0,'user','Codex Desktop',1,0)", (SID, "Human", str(self.path)))
        index.commit()
        index.execute("BEGIN EXCLUSIVE")
        read_fd, write_fd = os.pipe()
        loop = b.AttentionLoop(self.reader, QuietOpenCode(), self.permissions, "/dev/null",
                               b.HookInput(read_fd, self.permissions))
        try:
            os.write(write_fd, json.dumps(self.hook()).encode() + b"\n")
            status, requests = loop.run_once()
            self.assertIs(status["codex"]["ok"], False, "the locked index must report failure")
            self.assertEqual(len(requests), 1, "a locked index must not hide the verified hook request")
            self.assertEqual(requests[0]["kind"], "permission")
        finally:
            loop.shutdown()
            index.rollback()
            index.close()
            os.close(read_fd)
            os.close(write_fd)

    def test_loop_exits_on_hook_pipe_eof(self):
        read_fd, write_fd = os.pipe()
        loop = b.AttentionLoop(self.reader, QuietOpenCode(), self.permissions, "/dev/null",
                               b.HookInput(read_fd, self.permissions))
        try:
            self.assertIsNotNone(loop.run_once())
            os.close(write_fd)
            write_fd = -1
            self.assertIsNone(loop.run_once())
        finally:
            loop.shutdown()
            os.close(read_fd)
            if write_fd >= 0: os.close(write_fd)


class OpenCodeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.database = root / "opencode.db"
        self.service = root / "service.json"
        self.client = b.LocalOpenCode(self.service, self.database)
        with sqlite3.connect(self.database) as db:
            db.execute("CREATE TABLE session_v2(id,title,parent_id,time_viewed,time_archived,time_updated,time_suspended)")
            db.executemany("INSERT INTO session_v2 VALUES(?,?,?,?,?,?,?)", [
                ("ses_Human", "Human", None, 1, None, 6, 1),
                ("ses_Child", "Child", "ses_Human", 1, None, 5, 1),
                ("ses_Worker", "Worker", None, None, None, 4, 1),
                ("ses_Archive", "Archive", None, 1, 1, 3, 1),
                ("ses_Idle", "Idle", None, 1, None, 2, None)])

    def tearDown(self): self.temp.cleanup()

    def test_only_active_viewed_roots(self):
        self.assertEqual(self.client.sessions(), [("ses_Human", "Human")])

    def test_include_child_viewed_sessions_only(self):
        # Include mode drops only the parent-null restriction; viewed, unarchived
        # and active stay mandatory.
        self.assertEqual(self.client.sessions(include_children=True),
                         [("ses_Human", "Human"), ("ses_Child", "Child")])
        wide = b.LocalOpenCode(self.service, self.database, include_children=True)
        body = {"data": [{"id": "per_Child", "sessionID": "ses_Child", "action": "bash"}]}
        with patch.object(wide, "get", return_value=body) as get:
            pending = wide.snapshot()
            self.assertEqual([item["session_id"] for item in pending], ["ses_Child"])
            get.assert_any_call("/api/session/ses_Child/permission")

    def test_pending_truth_and_resolution(self):
        body = {"data": [{"id": "per_One", "sessionID": "ses_Human", "action": "bash", "resources": ["npm test"]},
                         {"id": "per_Child", "sessionID": "ses_Child", "action": "bash"},
                         {"id": "malformed", "sessionID": "ses_Human"}]}
        with patch.object(self.client, "get", return_value=body) as get:
            pending = self.client.snapshot()
            self.assertEqual(len(pending), 1)
            self.assertIn("npm test", pending[0]["reason"])
            get.assert_called_once_with("/api/session/ses_Human/permission")
        with patch.object(self.client, "get", return_value={"data": []}):
            self.assertEqual(self.client.snapshot(), [])
        with patch.object(self.client, "get", return_value=[]):
            self.assertEqual(self.client.snapshot(), [])

    def test_credentials_stay_local_and_requests_are_get_only(self):
        self.service.write_text(json.dumps({"url": "http://127.0.0.1:1234", "password": uuid.uuid4().hex}))
        captured = []
        class Opener:
            def open(self, request, timeout):
                captured.append(request)
                return io.BytesIO(b'{"data":[]}')
        with patch.object(b.urllib.request, "build_opener", return_value=Opener()) as build:
            self.assertEqual(self.client.get("/api/session/ses_Human/permission"), {"data": []})
            self.assertEqual(captured[0].get_method(), "GET")
            self.assertTrue(captured[0].get_header("Authorization").startswith("Basic "))
            proxy, redirects = build.call_args.args
            self.assertEqual(proxy.proxies, {})
            self.assertIsNone(redirects.redirect_request(None, None, None, None, None, None))
        for url in ["https://example.com", "http://127.0.0.1@other.test", "http://localhost/path", "http://localhost/?query=1"]:
            self.service.write_text(json.dumps({"url": url, "password": uuid.uuid4().hex}))
            with self.assertRaises(ValueError): self.client.get("/api/session/ses_Human/permission")


class MemoryPendingTests(unittest.TestCase):
    """OpenCode permission.asked lives in server memory, not SQLite."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.database = self.root / "opencode.db"
        self.service = self.root / "service.json"
        with sqlite3.connect(self.database) as db:
            db.execute("CREATE TABLE session_v2(id,title,parent_id,time_viewed,time_archived,time_updated,time_suspended)")
            db.execute("INSERT INTO session_v2 VALUES('ses_A','Main',NULL,1,NULL,1,1)")

    def tearDown(self): self.temp.cleanup()

    def test_memory_only_permission_without_db_change(self):
        client = b.LocalOpenCode(self.service, self.database)
        reader = b.CodexReader(self.root)  # no Codex index here: the OpenCode side is under test
        responses = [{"data": []},
                     {"data": [{"id": "per_New", "sessionID": "ses_A", "action": "bash"}]}]
        calls = []
        def fake_get(route):
            calls.append(route)
            return responses[min(len(calls) - 1, 1)]
        with patch.object(client, "get", side_effect=fake_get):
            loop = b.AttentionLoop(reader, client, b.HumanPermissions(reader), "/dev/null")
            try:
                status, requests = loop.run_once(wait=True)
                self.assertEqual(requests, [])
                self.assertEqual(loop.active_candidates, 1)
                # An active viewed session keeps the loop re-querying even with
                # nothing pending yet.
                self.assertEqual(loop.next_timeout(), b.AttentionLoop.OPEN_REFRESH)
                # Nothing wrote to the database between the two queries: the new
                # permission appears purely from the in-memory server list.
                status, requests = loop.run_once(wait=True)
                self.assertEqual([item["id"] for item in requests], ["per_New"])
                self.assertEqual(len(calls), 2)
                # A visible request switches to lease-renewal cadence.
                self.assertEqual(loop.next_timeout(), b.AttentionLoop.OPEN_REFRESH,
                                 "a visible card must not slow discovery of another native permission")
            finally:
                loop.shutdown()

    def test_no_active_sessions_blocks_on_sources_only(self):
        quiet_db = self.root / "quiet.db"
        with sqlite3.connect(quiet_db) as db:
            db.execute("CREATE TABLE session_v2(id,title,parent_id,time_viewed,time_archived,time_updated,time_suspended)")
        reader = b.CodexReader(self.root)
        loop = b.AttentionLoop(reader, b.LocalOpenCode(self.service, quiet_db),
                               b.HumanPermissions(reader), "/dev/null")
        try:
            loop.run_once(wait=True)
            self.assertEqual(loop.active_candidates, 0)
            self.assertIsNone(loop.next_timeout(), "idle must mean no active sessions, no pending, no query")
        finally:
            loop.shutdown()


if __name__ == "__main__":
    unittest.main()
