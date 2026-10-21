import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { calls, internals } from "./tauri.mjs";

installFakeDom();
const { codexChatSection } = await import("../src/settings/codex.ts");
const invoke = internals.invoke;
let status;
internals.invoke = async (cmd, args) => {
  const fallback = await invoke(cmd, args);
  if (cmd === "codex_chat_status") {
    if (status instanceof Error) throw status;
    return status;
  }
  return fallback;
};
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
beforeEach(() => { calls.length = 0; });

test("Codex settings require a ChatGPT login before enabling chat", async () => {
  status = { installed: true, connected: false, plan: null };
  let picked = false;
  const section = codexChatSection(() => { picked = true; });
  await flush();
  const [refresh, use] = section.find("BUTTON");
  assert.match(section.textContent, /codex login/);
  assert.ok(use.disabled);
  status = { installed: true, connected: true, plan: "plus" };
  refresh.fire("click");
  await flush();
  assert.ok(!use.disabled);
  assert.match(section.textContent, /Connected · plus/);
  use.fire("click");
  assert.ok(picked);
  assert.ok(calls.every(([cmd]) => cmd === "codex_chat_status"));
});

test("missing CLI and status failures keep Use in chat disabled", async () => {
  for (const result of [{ installed: false, connected: false, plan: null }, new Error("Codex closed the connection.")]) {
    status = result;
    const section = codexChatSection(() => assert.fail("must not select a disconnected provider"));
    await flush();
    assert.ok(section.find("BUTTON")[1].disabled);
    assert.match(section.textContent, result instanceof Error ? /closed the connection/ : /Install Codex CLI/);
  }
});
