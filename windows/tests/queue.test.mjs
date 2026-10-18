// The approval wait line (src/island/queue.ts) — a port of ApprovalQueueTests.swift.

import { test } from "node:test";
import assert from "node:assert/strict";
import { ApprovalQueue, approvalInputKey } from "../src/island/queue.ts";

let seq = 0;
const entry = (
  session = "s1",
  pill = "integration_claude",
  tool = "Bash",
  key = "{}",
  requestId = "",
) => ({
  id: `e${++seq}`,
  requestId: requestId || `r${seq}`,
  sessionId: session,
  pillId: pill,
  tool,
  command: `cmd${seq}`,
  inputKey: key,
});

test("FIFO: the head is the oldest, removing it promotes the next", () => {
  const q = new ApprovalQueue();
  const a = entry(), b = entry(), c = entry();
  for (const e of [a, b, c]) assert.equal(q.enqueue(e), "accepted");
  assert.equal(q.count, 3);
  assert.equal(q.head, a);
  assert.equal(q.position(a.id), 1);
  assert.equal(q.position(c.id), 3);
  assert.equal(q.remove(a.id), a);
  assert.equal(q.head, b);
  assert.equal(q.count, 2);
});

test("a non-head removal leaves the others untouched", () => {
  const q = new ApprovalQueue();
  const a = entry(), b = entry(), c = entry();
  for (const e of [a, b, c]) q.enqueue(e);
  q.remove(a.id);
  assert.equal(q.remove(c.id), c);
  assert.equal(q.head, b);
  assert.equal(q.count, 1);
  assert.equal(q.remove(c.id), undefined); // already gone: no-op
  assert.equal(q.remove(b.id), b);
  assert.ok(q.isEmpty);
  assert.equal(q.head, undefined);
});

test("cap: the newest is rejected, the queue unchanged — room again after a removal", () => {
  const q = new ApprovalQueue();
  const all = Array.from({ length: ApprovalQueue.maxPending }, () => entry());
  for (const e of all) assert.equal(q.enqueue(e), "accepted");
  assert.equal(q.enqueue(entry()), "rejectedFull");
  assert.deepEqual([...q.entries], all);
  q.remove(all[0].id);
  assert.equal(q.enqueue(entry()), "accepted");
});

test("event matching is per request: session + pill, plus tool and input for PostToolUse", () => {
  const q = new ApprovalQueue();
  const s1 = entry("s1", "integration_claude", "Bash", '{"command":"ls"}');
  const s2 = entry("s2", "integration_claude", "Bash", '{"command":"ls"}');
  const cur = entry("s1", "agent_cursor", "Bash", '{"command":"ls"}');
  for (const e of [s1, s2, cur]) q.enqueue(e);

  assert.deepEqual(
    q.resolved("PostToolUse", "s1", "integration_claude", "Bash", '{"command":"ls"}'),
    [s1],
  );
  // Same session and tool, different input: not resolved.
  assert.deepEqual(
    q.resolved("PostToolUse", "s1", "integration_claude", "Bash", '{"command":"pwd"}'),
    [],
  );
  // Same session and input, different tool: not resolved.
  assert.deepEqual(
    q.resolved("PostToolUse", "s1", "integration_claude", "Read", '{"command":"ls"}'),
    [],
  );
  assert.deepEqual(q.resolved("Stop", "s2", "integration_claude", "", ""), [s2]);
  assert.deepEqual(q.resolved("Stop", "s1", "agent_cursor", "", ""), [cur]);
  assert.deepEqual(q.resolved("Stop", "other", "integration_claude", "", ""), []);
  // PreToolUse never resolves a request.
  assert.deepEqual(
    q.resolved("PreToolUse", "s1", "integration_claude", "Bash", '{"command":"ls"}'),
    [],
  );

  assert.ok(q.hasMixedSources);
  assert.ok(q.hasEntries("agent_cursor"));
  assert.ok(!q.hasEntries("agent_codex"));

  const same = new ApprovalQueue();
  same.enqueue(entry());
  same.enqueue(entry("s1", "integration_claude", "Edit"));
  assert.ok(!same.hasMixedSources);
});

test("a question resolves on session + pill + tool alone", () => {
  const q = new ApprovalQueue();
  const ask = { ...entry("s1", "integration_claude", "AskUserQuestion", '{"questions":[]}'), questions: [] };
  const perm = entry("s1", "integration_claude", "Bash", '{"command":"ls"}');
  q.enqueue(ask);
  q.enqueue(perm);
  // The terminal's PostToolUse for an answered ask can come without its input.
  assert.deepEqual(q.resolved("PostToolUse", "s1", "integration_claude", "AskUserQuestion", ""), [ask]);
  // …but the permission still wants its exact input.
  assert.deepEqual(q.resolved("PostToolUse", "s1", "integration_claude", "Bash", ""), []);
});

test("approvalInputKey: sorted keys, empty input is the empty string", () => {
  assert.equal(approvalInputKey({}), "");
  assert.equal(approvalInputKey({ b: 2, a: { d: 1, c: 2 } }), '{"a":{"c":2,"d":1},"b":2}');
  assert.equal(approvalInputKey({ command: "ls" }), '{"command":"ls"}');
});
