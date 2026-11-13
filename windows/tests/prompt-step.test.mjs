// A session's prompt as its step line (src/island/hooks.ts promptStep): text
// Claude Code injects (a background task's notification, system reminders,
// slash-command echoes) never shows as raw tags.

import { test } from "node:test";
import assert from "node:assert/strict";
import { promptStep } from "../src/island/hooks.ts";

test("injected prompts show as their summary or command, never as raw tags", () => {
  const note = '<task-notification>\n<task-id>bq1</task-id>\n<status>completed</status>\n<summary>Agent "Add skins" finished</summary>\n</task-notification>';
  assert.equal(promptStep(note), 'Agent "Add skins" finished');
  assert.equal(promptStep("<task-notification><task-id>x</task-id></task-notification>"), null);
  assert.equal(promptStep("<command-name>/compact</command-name>\n<command-message>compact</command-message>"), "/compact");
  assert.equal(promptStep("<system-reminder>noise</system-reminder>"), null);
  assert.equal(promptStep("fix the <b>bug</b> please"), "fix the bug please");
  assert.equal(promptStep("x".repeat(80)).length, 60);
});
