// Windows and Linux additions: the pending
// card going the moment it is settled elsewhere, the Always allow offer, the
// live git push, and the pure parts of the chat's mic.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit, sent } from "./tauri.mjs";
import { alwaysOffer, promptStep, registerHookHandlers, settledElsewhere } from "../src/island/hooks.ts";
import { gitPushCommand, pushRepo } from "../src/island/integrations.ts";
import { isHallucination, wav } from "../src/views/dictation.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

const CLAUDE = "integration_claude";

let asked;
const island = {
  alert: (view) => asked.push(`alert:${view}`),
  setView: (view) => asked.push(`setView:${view}`),
  reveal: () => asked.push("reveal"),
  dropPin: () => asked.push("dropPin"),
  hold: (on) => asked.push(`hold:${on}`),
};
registerHookHandlers(island);

const hook = (payload) => emit("hook", payload);

beforeEach(() => {
  mock.timers.enable({ apis: ["setTimeout"] });
  asked = [];
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

// ── The card answered elsewhere ───────────────────────────────────────────────

test("the relay hanging up takes the card down at once, with nobody left to release", () => {
  ask("r1");
  assert.equal(State.pendingApproval?.requestId, "r1");
  emit("hook-resolved", "r1");
  assert.equal(State.pendingApproval, null);
  assert.deepEqual(sent("approval_decline"), []);
  assert.ok(asked.includes("dropPin"));
});

test("a hang-up for another request leaves the card alone", () => {
  ask("r1");
  emit("hook-resolved", "r0");
  assert.equal(State.pendingApproval?.requestId, "r1");
});

test("the very tool call running means it was allowed in the terminal", () => {
  ask("r1");
  hook({ hook_event_name: "PostToolUse", session_id: "s1", cwd: "C:\\p\\proj", tool_name: "Bash", tool_input: { command: "npm test" } });
  assert.equal(State.pendingApproval, null);
  // The relay may still be waiting: it is released.
  assert.deepEqual(sent("approval_decline"), [{ requestId: "r1" }]);
});

test("another call's result (a subagent alongside) or another session's never counts", () => {
  ask("r1");
  hook({ hook_event_name: "PostToolUse", session_id: "s1", cwd: "C:\\p\\proj", tool_name: "Read", tool_input: { file_path: "a.ts" } });
  hook({ hook_event_name: "PostToolUse", session_id: "s1", cwd: "C:\\p\\proj", tool_name: "Bash", tool_input: { command: "ls" } });
  hook({ hook_event_name: "PostToolUse", session_id: "s2", cwd: "C:\\p\\proj", tool_name: "Bash", tool_input: { command: "npm test" } });
  hook({ hook_event_name: "PreToolUse", session_id: "s1", cwd: "C:\\p\\proj", tool_name: "Bash", tool_input: { command: "npm test" } });
  assert.equal(State.pendingApproval?.requestId, "r1");
  assert.deepEqual(sent("approval_decline"), []);
});

test("settledElsewhere: the turn ending, or the same call's result or failure", () => {
  const pending = { requestId: "r", sessionId: "s", pillId: CLAUDE, tool: "Bash", command: "Bash · rm -rf build" };
  const input = { command: "rm -rf build" };
  for (const name of ["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt"]) {
    assert.ok(settledElsewhere(pending, name, CLAUDE, "s", undefined, undefined), name);
  }
  assert.ok(settledElsewhere(pending, "PostToolUse", CLAUDE, "s", "Bash", input));
  assert.ok(settledElsewhere(pending, "PostToolUseFailure", CLAUDE, "s", "Bash", input));
  assert.ok(!settledElsewhere(pending, "PostToolUse", CLAUDE, "s", "Bash", { command: "ls" }));
  assert.ok(!settledElsewhere(pending, "PreToolUse", CLAUDE, "s", "Bash", input));
  assert.ok(!settledElsewhere(pending, "Notification", CLAUDE, "s", undefined, undefined));
  assert.ok(!settledElsewhere(pending, "Stop", "agent_codex", "s", undefined, undefined));
  assert.ok(!settledElsewhere(pending, "Stop", CLAUDE, "other", undefined, undefined));
});

// ── Always allow ──────────────────────────────────────────────────────────────

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

// ── Live push ─────────────────────────────────────────────────────────────────

test("a git push is told apart, and where it pushes from", () => {
  assert.equal(gitPushCommand("Bash", { command: "git push origin main" }), "git push origin main");
  assert.equal(gitPushCommand("Bash", { command: "cd repo && git push" }), "cd repo && git push");
  assert.equal(gitPushCommand("Bash", { command: "git status; echo push" }), null);
  assert.equal(gitPushCommand("Read", { command: "git push" }), null);
  assert.equal(pushRepo("cd /home/me/coucou && git push", "/tmp"), "coucou");
  assert.equal(pushRepo('git -C "C:\\work\\bloom" push', "C:\\x"), "bloom");
  assert.equal(pushRepo("git push", "C:\\Users\\me\\proj\\"), "proj");
});

test("Claude Code's git push brings the GitHub card up, held, and lets it go after", () => {
  State.settings = { ...DEFAULT_SETTINGS, activeIntegrations: ["integration_github"] };
  State.loadIntegrationTasks();
  const push = { session_id: "s1", cwd: "C:\\p\\proj", tool_name: "Bash", tool_input: { command: "git push" } };
  hook({ hook_event_name: "PreToolUse", ...push });
  assert.deepEqual(State.githubPush?.state, "pushing");
  assert.equal(State.focusId, "integration_github");
  assert.deepEqual(asked, ["alert:overview", "hold:true"]);
  hook({ hook_event_name: "PostToolUse", ...push });
  assert.equal(State.githubPush?.state, "done");
  assert.deepEqual(sent("refresh_integration"), [{ id: "integration_github" }]);
  mock.timers.tick(8000);
  assert.equal(State.githubPush, null);
  assert.ok(asked.includes("hold:false"));
});

// ── The mic's pure parts ──────────────────────────────────────────────────────

test("Whisper's inventions on a breath are dropped, real short answers kept", () => {
  assert.ok(isHallucination("Thank you.", 400));
  assert.ok(isHallucination("Thanks for watching!", 5000));
  assert.ok(isHallucination("   ", 3000));
  assert.ok(!isHallucination("Thank you.", 2000));
  assert.ok(!isHallucination("Open the settings", 600));
});

test("a recording becomes a 16 kHz mono WAV", async () => {
  const blob = wav([new Float32Array(48_000).fill(0.5)], 48_000);
  assert.equal(blob.type, "audio/wav");
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const text = (a, b) => String.fromCharCode(...bytes.slice(a, b));
  assert.equal(text(0, 4), "RIFF");
  assert.equal(text(8, 12), "WAVE");
  const view = new DataView(bytes.buffer);
  assert.equal(view.getUint32(24, true), 16_000);
  // One second at 16 kHz, 16-bit: 32 000 bytes of samples.
  assert.equal(view.getUint32(40, true), 32_000);
  assert.equal(view.getInt16(44, true), Math.trunc(0.5 * 0x7fff));
});

test("injected prompts show as their summary or command, never as raw tags", () => {
  const note = '<task-notification>\n<task-id>bq1</task-id>\n<status>completed</status>\n<summary>Agent "Add skins" finished</summary>\n</task-notification>';
  assert.equal(promptStep(note), 'Agent "Add skins" finished');
  assert.equal(promptStep("<task-notification><task-id>x</task-id></task-notification>"), null);
  assert.equal(promptStep("<command-name>/compact</command-name>\n<command-message>compact</command-message>"), "/compact");
  assert.equal(promptStep("<system-reminder>noise</system-reminder>"), null);
  assert.equal(promptStep("fix the <b>bug</b> please"), "fix the bug please");
  assert.equal(promptStep("x".repeat(80)).length, 60);
});

// ── The desktop Mochi wears the dragged-out Mochi's own look ──────────────────

test("a coloured Mochi dragged out of the island wears its own look on the desktop", async () => {
  const { DesktopLink } = await import("../src/island/desktop.ts");
  const { MAIN_MOCHI } = await import("../src/mochi/wardrobe.ts");
  const pill = State.tasks.find((t) => t.isIntegration && t.id !== State.mainPillId);
  assert.ok(pill, "a declared coloured pill");
  State.settings.mochiLooks = { [MAIN_MOCHI]: { outfit: "pumpkin", shape: "" }, [pill.id]: { outfit: "robot", shape: "bean" } };
  const link = new DesktopLink({ reveal() {}, wardrobeFromDesktop() {}, dizzyFromDesktop() {} });
  const snapshot = () => sent("plugin:event|emit_to").map((a) => a.payload).at(-1);

  link.push();
  assert.equal(snapshot().outfit, "pumpkin", "the main Mochi by default");
  State.focusId = pill.id;
  link.pickUp(0, 0);
  link.push();
  assert.deepEqual([snapshot().outfit, snapshot().shape], ["robot", "bean"]);
});
