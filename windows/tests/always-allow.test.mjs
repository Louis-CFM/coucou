// Claude Code's permission card offers "Always allow" when Claude Code
// suggests a rule to remember (src/island/hooks.ts alwaysOffer): the button
// names that rule, and only Claude Code's cards get it.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit } from "./tauri.mjs";
import { alwaysOffer, registerHookHandlers } from "../src/island/hooks.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

const island = {
  alert: () => {},
  setView: () => {},
  reveal: () => {},
  dropPin: () => {},
};
registerHookHandlers(island);

const hook = (payload) => emit("hook", payload);

beforeEach(() => {
  mock.timers.enable({ apis: ["setTimeout"] });
  calls.length = 0;
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.view = "overview";
  State.paused = false;
  State.isPinned = false;
  State.pendingApproval = null;
  State.settings = { ...DEFAULT_SETTINGS };
  State.loadIntegrationTasks();
});

afterEach(() => {
  mock.timers.runAll();
  mock.timers.reset();
});

const ask = (id, extra = {}) =>
  hook({
    hook_event_name: "PermissionRequest",
    request_id: id,
    session_id: "s1",
    cwd: "C:\\p\\proj",
    tool_name: "Bash",
    tool_input: { command: "npm test" },
    ...extra,
  });

const RULE = [
  { type: "addRules", rules: [{ toolName: "Bash", ruleContent: "npm test:*" }], behavior: "allow", destination: "localSettings" },
];

test("Claude Code's suggestion names the Always button", () => {
  assert.deepEqual(alwaysOffer(RULE), {
    label: "Always allow Bash(npm test:*)",
    detail: "Allow, and let Claude Code remember Bash(npm test:*) in .claude/settings.local.json.",
  });
  assert.equal(
    alwaysOffer([{ type: "addRules", rules: [{ toolName: "WebFetch" }], behavior: "allow", destination: "userSettings" }]).label,
    "Always allow WebFetch",
  );
  assert.equal(alwaysOffer([{ type: "setMode", mode: "acceptEdits", destination: "session" }]).label, "Allow edits this session");
  assert.equal(
    alwaysOffer([{ type: "addDirectories", directories: ["C:\\work\\other"], destination: "session" }]).label,
    "Allow files in other this session",
  );
  // Something it can't read still offers the button, in plain words.
  assert.equal(alwaysOffer([{ type: "somethingNew", destination: "projectSettings" }]).label, "Always allow");
  // A long list is cut, never the button stretched.
  const many = [{ type: "addRules", rules: Array.from({ length: 6 }, (_, i) => ({ toolName: "Bash", ruleContent: `make target-${i}:*` })), behavior: "allow", destination: "localSettings" }];
  assert.ok(alwaysOffer(many).label.length <= "Always allow ".length + 48);
  assert.ok(alwaysOffer(many).label.endsWith("…"));
});

test("nothing offered, nothing to show", () => {
  for (const raw of [undefined, null, [], "addRules", {}, [null, 3]]) {
    const offer = alwaysOffer(raw);
    assert.ok(offer === null || offer.label === "Always allow", JSON.stringify(raw));
  }
  assert.equal(alwaysOffer(undefined), null);
  assert.equal(alwaysOffer([]), null);
});

test("a request with suggestions gets Always allow, one without is upstream's card", () => {
  ask("r1", { permission_suggestions: RULE });
  assert.equal(State.pendingApproval.always.label, "Always allow Bash(npm test:*)");
  // Without suggestions the card is exactly upstream's.
  State.pendingApproval = null;
  ask("r2");
  assert.ok(!("always" in State.pendingApproval));
});

test("no other agent's card offers Always allow", () => {
  ask("r1", { coucou_agent: "codex", permission_suggestions: RULE });
  assert.equal(State.pendingApproval?.pillId, "agent_codex");
  assert.ok(!("always" in State.pendingApproval));
});
