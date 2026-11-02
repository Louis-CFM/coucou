// The overview's diff card opens full size: its expand control asks for the
// island's "diff" view, which shows every hunk with its line numbers, and Back
// finds the small card still open. Run with `npm test`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";

installFakeDom();
document.addEventListener = () => {};
window.addEventListener = () => {};
const { buildViews } = await import("../src/views/views.ts");
const { State } = await import("../src/core/state.ts");
const { fromEdit } = await import("../src/core/diff.ts");

/** One row as text: "old|new|sign|text", or the separator's own text. */
const row = (r) => (r.children.length ? r.children.map((c) => c.textContent).join("|") : r.textContent);

test("the diff card expands to the diff view: every hunk, a separator between them, line numbers", (t) => {
  const before = Array.from({ length: 20 }, (_, i) => `line ${i + 1}`);
  const after = before.map((l, i) => (i === 1 || i === 17 ? `${l} changed` : l));
  const path = "C:\\src\\app\\main.ts";
  State.tasks = [{ id: "claude", name: "Claude Code", color: "#F5A524", state: "working", stepIndex: 0, steps: [], source: "claudeCode", isIntegration: false }];
  State.focusId = "claude";
  State.mode = "expanded";
  State.view = "overview";
  State.appendSessionDiff("claude", fromEdit(before.join("\n"), after.join("\n"), path));
  t.after(() => {
    State.clearSessionDiffs("claude");
    State.tasks = [];
    State.focusId = null;
    State.mode = "hidden";
    State.view = "overview";
  });

  const asked = [];
  const actions = new Proxy({ setView: (v) => asked.push(v) }, { get: (o, k) => o[k] ?? (() => {}) });
  const views = buildViews(actions, () => {});
  const overview = views.get("overview");
  overview.sync(); // the first sync settles the focused pill (and closes any diff)
  overview.command("toggleDiff"); // Ctrl+E: the focused pill's latest edit, in the small card
  overview.sync();
  // The small card itself keeps its plain rows.
  assert.equal(overview.el.find(".diff-line").length, 13);
  assert.equal(overview.el.find(".num").length, 0);
  assert.equal(overview.el.find(".diff-gap").length, 0);

  overview.el.find(".diff-expand")[0].fire("click");
  overview.el.find(".diff-lines")[0].fire("click");
  assert.deepEqual(asked, ["diff", "diff"]);

  State.view = "diff";
  State.notify();
  const full = views.get("diff");
  full.sync();
  assert.equal(full.el.find(".diff-back")[0].getAttribute("title"), path);
  assert.deepEqual(full.el.find(".diff-lines")[0].children.map(row), [
    "1|1| |line 1",
    "2||−|line 2",
    "|2|+|line 2 changed",
    "3|3| |line 3",
    "4|4| |line 4",
    "5|5| |line 5",
    "⋯",
    "15|15| |line 15",
    "16|16| |line 16",
    "17|17| |line 17",
    "18||−|line 18",
    "|18|+|line 18 changed",
    "19|19| |line 19",
    "20|20| |line 20",
  ]);

  // Back: the overview, with the small card still on the same diff.
  full.el.find(".diff-back")[0].fire("click");
  assert.equal(asked.at(-1), "overview");
  State.view = "overview";
  State.notify();
  overview.sync();
  assert.equal(overview.el.find(".diff-card").length, 1);

  // A diff dropped while it is open full size closes the view.
  State.view = "diff";
  State.clearSessionDiffs("claude");
  full.sync();
  assert.equal(asked.at(-1), "overview");
});
