import assert from "node:assert/strict";
import { test } from "node:test";
import pi from "../pi/coucou.ts";
import omp from "../oh-my-pi/coucou.ts";
import { createRelay, relayCommand } from "../shared/relay.ts";
import { context, fixture, register } from "./helpers.mjs";

for (const [name, factory] of [["pi", pi], ["oh-my-pi", omp]]) {
  test(`${name}: isolated sessions, tool outcomes and metadata-only relay contract`, async t => {
    const f = await fixture(t);
    const emit = register(factory);
    assert.equal(await emit("session_start"), undefined);
    assert.equal(await emit("before_agent_start", { prompt: "SECRET", systemPrompt: "SECRET" }), undefined);
    const input = { toolName: "bash", args: { command: "SECRET" }, toolCallId: "t" };
    assert.equal(await emit("tool_execution_start", input), undefined);
    const result = { ...input, isError: true, result: { content: "SECRET" } };
    assert.equal(await emit("tool_execution_end", result), undefined);
    await emit("tool_execution_end", { ...result, isError: false });
    if (name === "pi") await emit("agent_settled", { aborted: false });
    else await emit("agent_end", { messages: [{ role: "assistant", stopReason: "stop", content: "SECRET" }] });
    if (name === "pi") {
      await emit("session_shutdown", { reason: "new" });
      // Pi rebinds a new extension runtime when replacing a session.
      const next = register(factory);
      await next("session_start", {}, context("two"));
      await next("session_shutdown");
    } else {
      await emit("session_switch", { reason: "new" }, context("two"));
      await emit("session_branch", { reason: "fork" }, context("three"));
      await emit("session_shutdown");
    }
    const records = await f.records();
    assert.ok(records.every(r => JSON.stringify(r).includes("SECRET") === false));
    assert.ok(records.every(r => JSON.stringify(r.args) === JSON.stringify(["--agent", name])));
    assert.deepEqual(records.slice(0, 7).map(r => r.payload.hook_event_name), [
      "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUseFailure", "PostToolUse", "Stop", "SessionEnd",
    ]);
    assert.deepEqual(records[2].payload, {
      session_id: `${name}:one`, cwd: "/project/example", hook_event_name: "PreToolUse",
      tool_name: "bash", coucou_agent: name,
    });
    assert.equal(records.at(-1).payload.session_id, `${name}:${name === "pi" ? "two" : "three"}`);
    assert.equal(records.at(-1).payload.hook_event_name, "SessionEnd");
    assert.deepEqual(input.args, { command: "SECRET" });
    assert.equal(result.isError, true);
  });
}

test("Pi: only settlement completes the run; final outcome and abort win", async t => {
  const f = await fixture(t);
  const emit = register(pi);
  await emit("session_start");
  await emit("agent_start");
  await emit("agent_end", { messages: [] });
  await emit("turn_end", {});
  await emit("agent_before_settle", { outcome: "error" });
  await emit("agent_settled", { aborted: false });
  await emit("agent_start");
  await emit("agent_before_settle", { outcome: "completed" });
  await emit("agent_settled", { aborted: false });
  await emit("agent_start");
  await emit("agent_before_settle", { outcome: "error" });
  await emit("agent_settled", { aborted: true });
  await emit("agent_start");
  await emit("agent_settled", { aborted: false });
  await emit("session_shutdown");
  assert.deepEqual((await f.records()).map(r => r.payload.hook_event_name), [
    "SessionStart", "StopFailure", "Stop", "Interrupt", "Stop", "SessionEnd",
  ]);
});

test("OMP: retries and background work stay busy; terminal errors and aborts differ", async t => {
  const f = await fixture(t);
  const emit = register(omp);
  await emit("session_start");
  await emit("agent_start");
  const messages = [{ role: "assistant", stopReason: "error" }];
  await emit("message_end", { message: messages[0] });
  await emit("agent_end", { willContinue: true, messages });
  await emit("agent_end", { willContinue: true, awaitingAsyncWork: true, messages });
  await emit("agent_end", { awaitingAsyncWork: true, messages });
  // The failed assistant may have been pruned from the active history by recovery.
  await emit("agent_end", { messages: [] });
  await emit("agent_start");
  await emit("agent_end", { messages });
  await emit("message_end", { message: { role: "assistant", stopReason: "stop" } });
  await emit("agent_end", { messages: [...messages, { role: "assistant", stopReason: "stop" }] });
  await emit("message_end", { message: { role: "assistant", stopReason: "aborted" } });
  await emit("agent_end", { messages: [] });
  await emit("session_shutdown");
  assert.deepEqual((await f.records()).map(r => r.payload.hook_event_name), [
    "SessionStart", "UserPromptSubmit", "StopFailure", "UserPromptSubmit", "Stop", "Stop", "Interrupt", "SessionEnd",
  ]);
});

test("rebound OMP factories keep child sessions separate", async t => {
  const f = await fixture(t);
  const first = register(omp);
  const second = register(omp);
  await first("session_start", {}, context("parent"));
  await second("session_start", {}, context("child"));
  await first("session_shutdown");
  await second("session_shutdown");
  const events = (await f.records()).map(r => r.payload);
  for (const id of ["parent", "child"]) {
    assert.deepEqual(events.filter(e => e.session_id === `oh-my-pi:${id}`).map(e => e.hook_event_name), ["SessionStart", "SessionEnd"]);
  }
});

test("missing, crashing and stalled relays never reject or hold an event handler", async t => {
  const f = await fixture(t);
  for (const mode of ["missing", "stalled"]) {
    process.env.COUCOU_HOOK_PATH = mode === "missing" ? `${f.dir}/missing` : f.hook;
    if (mode === "stalled") process.env.COUCOU_TEST_STALL = "1";
    const emit = register(pi);
    const started = performance.now();
    assert.equal(await emit("session_start"), undefined);
    assert.ok(performance.now() - started < 100);
    await assert.doesNotReject(() => emit("session_shutdown"));
    if (mode === "stalled") assert.ok(performance.now() - started >= 400);
    assert.ok(performance.now() - started < 1800);
  }
});

test("bounded overload retains the newest state and closes within its deadline", async t => {
  const f = await fixture(t);
  process.env.COUCOU_TEST_STALL = "1";
  const relay = createRelay("pi");
  const session = { session_id: "pi:load", cwd: f.dir };
  for (let i = 0; i < 10000; i++) relay.send(session, { hook_event_name: "PreToolUse", tool_name: String(i) });
  delete process.env.COUCOU_TEST_STALL;
  relay.send(session, { hook_event_name: "Stop" });
  const started = performance.now();
  await relay.close();
  assert.ok(performance.now() - started < 1600);
  assert.ok((await f.records()).length <= 33);
  assert.equal((await f.records()).at(-1).payload.hook_event_name, "Stop");
});

test("relay discovery uses installed paths, explicit overrides and no shell interpolation", () => {
  assert.deepEqual(relayCommand("darwin", {}, "/home/test"), {
    command: "/bin/sh", args: ["/home/test/Library/Application Support/NotchBuddy/nb-hook"],
  });
  assert.deepEqual(relayCommand("linux", { XDG_DATA_HOME: "/data" }, "/home/test"), {
    command: "/data/coucou/bin/coucou-hook", args: [],
  });
  assert.deepEqual(relayCommand("darwin", { COUCOU_HOOK_PATH: "/tmp/a ' $x; command" }), {
    command: "/bin/sh", args: ["/tmp/a ' $x; command"],
  });
  assert.equal(relayCommand("linux", { COUCOU_HOOK_PATH: "relative" }), undefined);
  assert.equal(relayCommand("win32", {}), undefined);
  assert.deepEqual(relayCommand("win32", { LOCALAPPDATA: "C:\\Users\\test\\AppData\\Local" }), {
    command: "C:\\Users\\test\\AppData\\Local\\Coucou\\bin\\coucou-hook.exe", args: [],
  });
  assert.equal(relayCommand("freebsd", {}), undefined);
});
