import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { join } from "node:path";
import { context, register } from "./helpers.mjs";
import pi from "../pi/coucou.ts";
import omp from "../oh-my-pi/coucou.ts";

test("both extensions reach a Unix socket through Coucou's actual Python relay", async t => {
  // A short path also fits Darwin's 104-byte sockaddr_un limit.
  const dir = await mkdtemp("/tmp/coucou-relay-");
  const previous = process.env.COUCOU_HOOK_PATH;
  const received = [];
  const peers = new Set();
  const server = createServer(socket => {
    peers.add(socket);
    socket.on("close", () => peers.delete(socket));
    socket.on("error", () => {});
    let buffer = "";
    socket.on("data", chunk => {
      buffer += chunk.toString();
      if (!buffer.endsWith("\n")) return;
      received.push(JSON.parse(buffer));
      socket.end('{"ok":true}\n');
    });
  });
  t.after(async () => {
    if (previous === undefined) delete process.env.COUCOU_HOOK_PATH;
    else process.env.COUCOU_HOOK_PATH = previous;
    for (const peer of peers) peer.destroy();
    await new Promise(resolve => server.close(resolve));
    await rm(dir, { recursive: true, force: true });
  });
  const source = await readFile(new URL("../../NotchBuddy/Sources/App/HookServer.swift", import.meta.url), "utf8");
  const match = source.match(/private let nbHookPythonGitHub = """\n([\s\S]*?)\n"""/);
  assert.ok(match, "the shipping relay source must be found");
  // Decode Swift's escaped backslashes. Replace only socket discovery to keep
  // the test off the real app; all normalization and JSON framing stay intact.
  const socketPath = join(dir, "nb.sock");
  const relay = match[1].replaceAll("\\\\", "\\")
    .replace("'~/Library/Application Support/NotchBuddy/nb.sock'", JSON.stringify(socketPath));
  assert.ok(relay.includes(JSON.stringify(socketPath)));
  await writeFile(join(dir, "nb-hook.py"), relay);
  const hook = join(dir, "nb-hook");
  await writeFile(hook, '#!/bin/sh\nexec python3 "$(dirname "$0")/nb-hook.py" "$@"\n', { mode: 0o700 });
  process.env.COUCOU_HOOK_PATH = hook;
  await new Promise((resolve, reject) => { server.once("error", reject); server.listen(socketPath, resolve); });
  for (const [agent, factory] of [["pi", pi], ["oh-my-pi", omp]]) {
    const emit = register(factory);
    await emit("session_start", {}, context("real-relay"));
    await emit("before_agent_start", { prompt: "SECRET" }, context("real-relay"));
    if (agent === "pi") await emit("agent_settled", { aborted: false }, context("real-relay"));
    else await emit("agent_end", { messages: [{ role: "assistant", timestamp: 1, stopReason: "stop" }] }, context("real-relay"));
    await emit("session_shutdown");
    assert.deepEqual(received.filter(e => e.coucou_agent === agent).map(e => e.hook_event_name), [
      "SessionStart", "UserPromptSubmit", "Stop", "SessionEnd",
    ]);
  }
  assert.ok(received.every(e => e.session_id === `${e.coucou_agent}:real-relay`));
  assert.equal(JSON.stringify(received).includes("SECRET"), false);
});
