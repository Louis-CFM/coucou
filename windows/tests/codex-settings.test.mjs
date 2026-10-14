import { test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { internals, calls, sent } from "./tauri.mjs";
installFakeDom();
const { codexChatSection } = await import("../src/settings/codex-chat.ts");
const { DEFAULT_SETTINGS } = await import("../src/core/state.ts");
const { visibleProviders } = await import("../src/core/providers.ts");
const flush = () => new Promise(resolve => setTimeout(resolve, 0));

test("removal and reinstall hide/restore Codex and retain the user's model controls", async () => {
  calls.length = 0;
  let settings = { ...DEFAULT_SETTINGS, chatProvider: "codex", chatModels: { codex: "gpt-test" },
    codexReasoningEffort: "high", codexServiceTier: "priority" };
  internals.invoke = async (cmd, args) => {
    calls.push([cmd, args]);
    assert.equal(cmd, "codex_chat_set_enabled");
    return { ...settings, codexChatEnabled: args.enabled, chatProvider: args.enabled ? "codex" : "anthropic" };
  };
  const section = codexChatSection(() => settings, s => settings = s);
  let button = section.el.find("button")[0];
  assert.equal(button.textContent, "Uninstall");
  button.fire("click");
  assert.equal(section.el.find("button")[0].disabled, true);
  await flush();
  assert.equal(settings.codexChatEnabled, false);
  assert.equal(visibleProviders(settings).some(p => p.id === "codex"), false);
  assert.equal(section.el.find("button")[0].textContent, "Install");
  section.el.find("button")[0].fire("click");
  await flush();
  assert.equal(settings.codexChatEnabled, true);
  assert.equal(settings.chatProvider, "codex");
  assert.equal(settings.chatModels.codex, "gpt-test");
  assert.equal(settings.codexReasoningEffort, "high");
  assert.equal(settings.codexServiceTier, "priority");
  assert.deepEqual(sent("codex_chat_set_enabled"), [{ enabled: false }, { enabled: true }]);
  assert.equal(visibleProviders(settings).some(p => p.id === "codex"), true);
});

test("failed persistence keeps the integration installed and allows a retry", async () => {
  let settings = { ...DEFAULT_SETTINGS };
  internals.invoke = async () => { throw new Error("disk is read-only"); };
  const section = codexChatSection(() => settings, s => settings = s);
  section.el.find("button")[0].fire("click");
  await flush();
  assert.equal(settings.codexChatEnabled, true);
  assert.equal(section.el.find("button")[0].textContent, "Uninstall");
  assert.equal(section.el.find("button")[0].disabled, false);
  assert.match(section.el.querySelector(".notice.err").textContent, /disk is read-only/);
});
