// A remote host's edits (remote.rs): shown on the island, never opened here.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { emit } from "./tauri.mjs";

installFakeDom();
const { registerHookHandlers } = await import("../src/island/hooks.ts");
const { DEFAULT_SETTINGS, State } = await import("../src/core/state.ts");
const { buildDiffCard } = await import("../src/views/diff.ts");

const CLAUDE = "integration_claude";
registerHookHandlers({ alert() {}, setView() {}, reveal() {}, dropPin() {} });

// Hook events arm timers of their own: a mock clock lets them go.
beforeEach(() => mock.timers.enable({ apis: ["setTimeout", "setInterval"] }));
afterEach(() => mock.timers.reset());

const edit = (extra) =>
  emit("hook", {
    hook_event_name: "PostToolUse",
    session_id: "s1",
    tool_name: "Edit",
    tool_input: { file_path: "--install-extension=evil.ext", old_string: "a", new_string: "b" },
    ...extra,
  });

test("a remote host's diff has no ↗; a local one does", () => {
  State.tasks = [];
  State.settings = { ...DEFAULT_SETTINGS };
  State.loadIntegrationTasks();
  State.sessionDiffs.clear();
  emit("hook", { hook_event_name: "SessionStart", session_id: "s1", cwd: "/srv/api", coucou_remote: "devbox" });
  edit({ cwd: "/srv/api", coucou_remote: "devbox" });
  const [remote] = State.sessionDiffs.get(CLAUDE) ?? [];
  assert.equal(remote?.remote, true);
  // Only the head matters here: the card is drawn without its lines.
  const card = (diff) => buildDiffCard({ ...diff, hunks: [] }, { dismiss() {}, open() {} });
  assert.equal(card(remote).find(".icon-btn").length, 0);

  edit({ cwd: "/home/me/p" });
  const local = (State.sessionDiffs.get(CLAUDE) ?? []).at(-1);
  assert.ok(!local?.remote);
  assert.equal(card(local).find(".icon-btn").length, 1);
});
