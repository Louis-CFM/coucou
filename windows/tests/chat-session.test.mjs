import assert from "node:assert/strict";
import { after, beforeEach, test } from "node:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const windowsRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const temporary = await mkdtemp(join(tmpdir(), "coucou-chat-session-test-"));
const bundledEntry = join(temporary, "chat-session-entry.mjs");
const bridgeState = { calls: [], failSave: false, failReset: false };
globalThis.__coucouChatSessionTest = bridgeState;

await build({
  entryPoints: [resolve(windowsRoot, "tests/chat-session-entry.ts")],
  bundle: true,
  format: "esm",
  platform: "node",
  target: "node20",
  outfile: bundledEntry,
  logLevel: "silent",
  plugins: [{
    name: "mock-chat-session-bridge",
    setup(buildApi) {
      buildApi.onResolve({ filter: /\.\/bridge$/ }, () => ({ path: "bridge", namespace: "coucou-chat-session-test" }));
      buildApi.onLoad({ filter: /.*/, namespace: "coucou-chat-session-test" }, () => ({
        loader: "js",
        contents: `
          export const Bridge = {
            async saveSettings(settings) {
              globalThis.__coucouChatSessionTest.calls.push(["saveSettings", settings.chatProvider, settings.codexModel]);
              if (globalThis.__coucouChatSessionTest.failSave) throw new Error("settings write failed");
            },
            async chatReset(provider, model) {
              globalThis.__coucouChatSessionTest.calls.push(["chatReset", provider, model]);
              if (globalThis.__coucouChatSessionTest.failReset) throw new Error("backend reset failed");
            },
          };
        `,
      }));
    },
  }],
});

const {
  DEFAULT_SETTINGS,
  State,
  initializeChatSession,
  reconcileChatSession,
  waitForChatSessionReady,
} = await import(pathToFileURL(bundledEntry).href);

const originalConsoleError = console.error;
beforeEach(async () => {
  await waitForChatSessionReady().catch(() => {});
  State.settings = { ...DEFAULT_SETTINGS };
  State.chatGeneration = 0;
  bridgeState.calls.length = 0;
  bridgeState.failSave = false;
  bridgeState.failReset = false;
  initializeChatSession();
});
after(async () => {
  console.error = originalConsoleError;
  delete globalThis.__coucouChatSessionTest;
  await rm(temporary, { recursive: true, force: true });
});

test("settings persistence failure does not retry per frame and retries on explicit submit", async () => {
  console.error = () => {};
  bridgeState.failSave = true;
  State.settings = { ...State.settings, chatProvider: "codex" };
  reconcileChatSession(true);

  await assert.rejects(waitForChatSessionReady(), /settings write failed/);
  assert.deepEqual(bridgeState.calls, [["saveSettings", "codex", ""]]);

  bridgeState.calls.length = 0;
  bridgeState.failSave = false;
  reconcileChatSession();
  await assert.rejects(waitForChatSessionReady(), /settings write failed/);
  assert.deepEqual(bridgeState.calls, []);

  reconcileChatSession(false, true);
  await waitForChatSessionReady();
  assert.deepEqual(bridgeState.calls, [
    ["saveSettings", "codex", ""],
    ["chatReset", "codex", ""],
  ]);
});

test("backend reset failure propagates and a later config transition can recover", async () => {
  console.error = () => {};
  bridgeState.failReset = true;
  State.settings = { ...State.settings, chatProvider: "codex" };
  reconcileChatSession(true);

  await assert.rejects(waitForChatSessionReady(), /backend reset failed/);
  assert.deepEqual(bridgeState.calls, [
    ["saveSettings", "codex", ""],
    ["chatReset", "codex", ""],
  ]);

  bridgeState.calls.length = 0;
  bridgeState.failReset = false;
  State.settings = { ...State.settings, codexModel: "gpt-5-codex" };
  reconcileChatSession(true);
  await waitForChatSessionReady();
  assert.deepEqual(bridgeState.calls, [
    ["saveSettings", "codex", "gpt-5-codex"],
    ["chatReset", "codex", "gpt-5-codex"],
  ]);
});
