// The GitLab panel: the "+N" and the colour of the sections (src/core/gitlab-panel.ts)
// and the panel itself (src/gitlab-panel/view.ts). What counts as a thread waiting
// for an answer is tested in Rust (src-tauri/src/gitlab_dash.rs).

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { calls, internals, sent } from "./tauri.mjs";
import { installFakeDom } from "./fakedom.mjs";
import {
  SECTION_ORDER, ageLabel, approvalsLabel, count, emptyState, itemIds, loadState, newCount, noteUrl, preview,
  receive, safeInstanceUrl, saveState, sectionTitle, sendError, shortProject, toggle, waiting,
} from "../src/core/gitlab-panel.ts";
import { PanelView } from "../src/gitlab-panel/view.ts";

installFakeDom();
globalThis.CSS = { escape: (s) => s };

const mr = (iid, over = {}) => ({
  id: `g/p!${iid}`, project: "g/p", projectId: 7, iid, title: `MR ${iid}`, url: `https://gitlab.com/g/p/-/merge_requests/${iid}`,
  isDraft: false, ci: "success", updatedAt: 0, approvals: null, unresolved: null, ...over,
});
const note = (id, body, isMe = false) => ({ id, author: isMe ? "Me" : "Bob", username: isMe ? "me" : "bob", body, createdAt: 0, isMe });
const thread = (id, last = 1, over = {}) => ({
  id, key: `${id}:${last}`, project: "g/p", projectId: 7, mrIid: 5, mrRef: "g/p!5", mrTitle: "Add thing",
  mrUrl: "https://gitlab.com/g/p/-/merge_requests/5", resolvable: true, position: null, lastAt: 0,
  notes: [note(1, "why this?", true), note(last, "because of **X**")], ...over,
});
const dash = (over = {}) => ({
  me: "me", baseUrl: "https://gitlab.com", canWrite: true, toReview: [], mine: [], approved: [], comments: [], fetchedAt: 1, ...over,
});

// ── The sections ──────────────────────────────────────────────────────────────

test("what asks for an action comes first, and has a colour while it waits", () => {
  assert.deepEqual(SECTION_ORDER, ["comments", "toReview", "mine", "approved"]);
  const d = dash({ comments: [thread("a")], toReview: [mr(1)], mine: [mr(2)], approved: [mr(3)] });
  assert.deepEqual(SECTION_ORDER.map((s) => waiting(d, s)), [true, true, false, false]);
  assert.deepEqual(SECTION_ORDER.map((s) => count(d, s)), [1, 1, 1, 1]);
  assert.ok(!waiting(dash(), "comments"), "nothing waits when empty");
  assert.equal(sectionTitle("comments"), "Comments waiting");
});

test("a thread is told apart by its last message, a merge request by its reference", () => {
  const d = dash({ comments: [thread("a", 4)], mine: [mr(2)] });
  assert.deepEqual(itemIds(d, "comments"), ["a:4"]);
  assert.deepEqual(itemIds(d, "mine"), ["g/p!2"]);
});

// ── "+N" ──────────────────────────────────────────────────────────────────────

test("the first data counts as seen: the badges start at nothing", () => {
  const d = dash({ comments: [thread("a")], toReview: [mr(1), mr(2)] });
  const state = receive(emptyState(), d);
  assert.ok(state.initialized);
  assert.deepEqual(SECTION_ORDER.map((s) => newCount(state, d, s)), [0, 0, 0, 0]);
  assert.equal(newCount(emptyState(), d, "toReview"), 0, "no badge before any data");
});

test("what arrives in a closed section is new until it is opened", () => {
  let state = receive(emptyState(), dash({ toReview: [mr(1)] }));
  const later = dash({ toReview: [mr(1), mr(2), mr(3)], comments: [thread("a")] });
  state = receive(state, later);
  assert.equal(newCount(state, later, "toReview"), 2);
  assert.equal(newCount(state, later, "comments"), 1);
  state = toggle(state, later, "toReview");
  assert.equal(newCount(state, later, "toReview"), 0, "opening clears it");
  assert.equal(newCount(state, later, "comments"), 1, "the others keep theirs");
  state = toggle(state, later, "toReview");
  assert.equal(state.open.toReview, false);
  assert.equal(newCount(state, later, "toReview"), 0, "closing it again keeps it seen");
});

test("what arrives in an open section is seen at once", () => {
  let state = receive(emptyState(), dash());
  state = toggle(state, dash(), "comments");
  const later = dash({ comments: [thread("a")] });
  state = receive(state, later);
  assert.equal(newCount(state, later, "comments"), 0);
});

test("a new answer in a thread is new again", () => {
  let state = receive(emptyState(), dash({ comments: [thread("a", 2)] }));
  const later = dash({ comments: [thread("a", 5)] });
  state = receive(state, later);
  assert.equal(newCount(state, later, "comments"), 1);
});

test("the state is kept between launches, and a bad one is forgotten", () => {
  const store = new Map();
  const storage = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) };
  let state = receive(emptyState(), dash({ toReview: [mr(1)] }));
  state = toggle(state, dash({ toReview: [mr(1)] }), "mine");
  saveState(storage, state);
  assert.deepEqual(loadState(storage), state);
  store.set("gitlab-panel-state", "{not json");
  assert.deepEqual(loadState(storage), emptyState());
  store.set("gitlab-panel-state", JSON.stringify({ initialized: true, seen: { mine: [1, "x"] }, open: { mine: "yes" } }));
  const odd = loadState(storage);
  assert.deepEqual(odd.seen.mine, ["x"]);
  assert.equal(odd.open.mine, false);
  assert.deepEqual(loadState(undefined), emptyState(), "no storage at all");
  saveState({ getItem: () => null, setItem: () => { throw new Error("full"); } }, state);
});

// ── Words ─────────────────────────────────────────────────────────────────────

test("ages, approvals and previews", () => {
  const now = 10 * 86_400_000;
  assert.equal(ageLabel(0, now), "");
  assert.equal(ageLabel(now - 30_000, now), "just now");
  assert.equal(ageLabel(now - 5 * 60_000, now), "5m");
  assert.equal(ageLabel(now - 3 * 3_600_000, now), "3h");
  assert.equal(ageLabel(now - 2 * 86_400_000, now), "2d");
  assert.equal(approvalsLabel(null), null);
  assert.equal(approvalsLabel({ given: 1, required: 2 }), "1/2");
  assert.equal(approvalsLabel({ given: 1, required: 0 }), "✓ 1");
  assert.equal(approvalsLabel({ given: 0, required: 0 }), null);
  assert.equal(shortProject("group/sub/proj"), "proj");
  assert.equal(preview(thread("a", 2, { notes: [note(1, "line one\n\n  line   two")] })), "line one line two");
  assert.equal(preview(thread("a", 2, { notes: [note(1, "x".repeat(200))] }), 10), "xxxxxxxxx…");
  assert.equal(noteUrl(thread("a", 9)), "https://gitlab.com/g/p/-/merge_requests/5#note_9");
});

test("each failure has its own words, and an empty reply none", () => {
  assert.match(sendError("forbidden"), /api scope/);
  assert.match(sendError("network"), /kept/);
  assert.match(sendError("not_found"), /no longer exists/);
  assert.equal(sendError("empty"), "");
  assert.match(sendError("error"), /refused/);
});

test("links open only on the instance the data came from", () => {
  const base = "https://git.corp.fr";
  assert.equal(safeInstanceUrl("https://git.corp.fr/a/-/merge_requests/1", base), "https://git.corp.fr/a/-/merge_requests/1");
  assert.equal(safeInstanceUrl("https://evil.example/x", base), null);
  assert.equal(safeInstanceUrl("javascript:alert(1)", base), null);
  assert.equal(safeInstanceUrl("https://x", "not a url"), null);
});

// ── The panel itself ──────────────────────────────────────────────────────────

let root;
let view;

/** Answers the commands a test cares about; everything else answers nothing. */
function answer(replies) {
  const original = internals.invoke;
  internals.invoke = async (cmd, args) => {
    if (cmd in replies) {
      calls.push([cmd, args]);
      return typeof replies[cmd] === "function" ? replies[cmd](args) : replies[cmd];
    }
    return original(cmd, args);
  };
  return () => (internals.invoke = original);
}

const sections = () => root.find(".gp-sec");
const headOf = (i) => sections()[i].find(".gp-sec-head")[0];
const badges = () => root.find(".gp-new").map((e) => e.textContent);

beforeEach(() => {
  // The last test's timers must not keep the run waiting.
  view?.closed();
  calls.length = 0;
  root = document.createElement("div");
  view = new PanelView(root);
});

test("four sections, folded, with their counts", () => {
  view.setDashboard(dash({ comments: [thread("a")], toReview: [mr(1), mr(2)], mine: [mr(3)] }));
  assert.equal(sections().length, 4);
  assert.deepEqual(sections().map((s) => s.find(".gp-sec-title")[0].textContent),
    ["Comments waiting", "To review", "My MRs", "Approved"]);
  assert.deepEqual(sections().map((s) => s.find(".gp-count")[0].textContent), ["1", "2", "1", "0"]);
  assert.equal(root.find(".gp-row").length, 0, "nothing is open on the first launch");
  assert.ok(sections()[0].classList.contains("waiting"));
  assert.ok(!sections()[2].classList.contains("waiting"));
  assert.deepEqual(badges(), [], "the first data is already seen");
});

test("a section opens to its merge requests, and its +N goes", () => {
  view.setDashboard(dash());
  view.setDashboard(dash({ toReview: [mr(1, { isDraft: true, ci: "failure" }), mr(2)] }));
  assert.deepEqual(badges(), ["+2"]);
  headOf(1).fire("click");
  assert.deepEqual(badges(), []);
  const rows = root.find(".gp-row");
  assert.equal(rows.length, 2);
  assert.match(rows[0].textContent, /MR 1/);
  assert.match(rows[0].textContent, /Draft/);
  assert.match(rows[0].textContent, /!1/);
  rows[1].fire("click");
  assert.deepEqual(sent("open_url"), [{ url: "https://gitlab.com/g/p/-/merge_requests/2" }]);
});

test("my merge requests show their approvals and open threads", () => {
  view.setDashboard(dash({ mine: [mr(1, { approvals: { given: 1, required: 2 }, unresolved: 3 })] }));
  headOf(2).fire("click");
  const text = root.find(".gp-row")[0].textContent;
  assert.match(text, /1\/2/);
  assert.match(text, /3/);
});

test("a link to another host does not open", () => {
  view.setDashboard(dash({ toReview: [mr(1, { url: "https://evil.example/x" })] }));
  headOf(1).fire("click");
  root.find(".gp-row")[0].fire("click");
  assert.deepEqual(sent("open_url"), []);
});

test("a thread opens in place with its messages and a reply box", () => {
  view.setDashboard(dash({ comments: [thread("a")] }));
  headOf(0).fire("click");
  root.find(".gp-row")[0].fire("click");
  assert.equal(root.find(".gp-note").length, 2);
  assert.match(root.find(".gp-detail")[0].textContent, /g\/p!5/);
  assert.ok(root.find(".gp-note").some((n) => n.classList.contains("me")));
  assert.equal(root.find("TEXTAREA").length, 1);
  assert.deepEqual(root.find(".gp-btn").map((b) => b.textContent), ["Send", "Resolve"]);
});

test("a read-only token explains itself instead of offering a reply", () => {
  view.setDashboard(dash({ canWrite: false, comments: [thread("a")] }));
  headOf(0).fire("click");
  root.find(".gp-row")[0].fire("click");
  assert.equal(root.find("TEXTAREA").length, 0);
  assert.match(root.find(".gp-hint")[0].textContent, /api scope/);
});

test("a code comment shows the lines it is about", async () => {
  const restore = answer({
    gitlab_snippet: [{ number: 41, text: "let a = 1;", target: false }, { number: 42, text: "let b = 2;", target: true }],
  });
  const position = { file: "src/a.rs", line: 42, side: "new", sha: "H" };
  view.setDashboard(dash({ comments: [thread("a", 1, { position })] }));
  headOf(0).fire("click");
  root.find(".gp-row")[0].fire("click");
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(sent("gitlab_snippet"), [{ projectId: 7, file: "src/a.rs", sha: "H", line: 42 }]);
  assert.match(root.find(".gp-code-file")[0].textContent, /src\/a\.rs:42/);
  assert.equal(root.find(".gp-code-line").length, 2);
  assert.ok(root.find(".gp-code-line")[1].classList.contains("target"));
  restore();
});

test("Send answers in the thread, which leaves; a failure keeps the draft", async () => {
  view.setDashboard(dash({ comments: [thread("a")] }));
  headOf(0).fire("click");
  root.find(".gp-row")[0].fire("click");
  const box = root.find("TEXTAREA")[0];
  box.value = "  thanks, done  ";

  let restore = answer({ gitlab_reply: { ok: false, error: "network" } });
  root.find(".gp-btn")[0].fire("click");
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(sent("gitlab_reply"), [{ projectId: 7, mrIid: 5, discussion: "a", body: "thanks, done" }]);
  assert.match(root.find(".gp-error")[0].textContent, /kept/);
  assert.equal(root.find("TEXTAREA")[0], box, "the same box, with its text");
  assert.equal(box.value, "  thanks, done  ");
  restore();

  calls.length = 0;
  restore = answer({ gitlab_reply: { ok: true, error: null } });
  root.find(".gp-btn")[0].fire("click");
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(sent("gitlab_reply").length, 1);
  assert.equal(root.find("TEXTAREA").length, 0, "the thread closed");
  restore();
});

test("an empty reply is not sent", async () => {
  view.setDashboard(dash({ comments: [thread("a")] }));
  headOf(0).fire("click");
  root.find(".gp-row")[0].fire("click");
  root.find(".gp-btn")[0].fire("click");
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(sent("gitlab_reply"), []);
});

test("a resolved thread stays, dimmed, to be opened again", async () => {
  view.setDashboard(dash({ comments: [thread("a")] }));
  headOf(0).fire("click");
  root.find(".gp-row")[0].fire("click");

  let restore = answer({ gitlab_resolve: { ok: true, error: null } });
  root.find(".gp-btn")[1].fire("click");
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(sent("gitlab_resolve"), [{ projectId: 7, mrIid: 5, discussion: "a", resolved: true }]);
  // Rust drops it from the list at once; the panel keeps it for a moment.
  view.setDashboard(dash({ comments: [] }));
  assert.equal(root.find(".gp-thread").length, 1);
  assert.ok(root.find(".gp-thread")[0].classList.contains("done"));
  assert.deepEqual(root.find(".gp-btn").map((b) => b.textContent), ["Reopen"]);
  restore();

  calls.length = 0;
  restore = answer({ gitlab_resolve: { ok: true, error: null } });
  root.find(".gp-btn")[0].fire("click");
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(sent("gitlab_resolve"), [{ projectId: 7, mrIid: 5, discussion: "a", resolved: false }]);
  assert.equal(root.find(".gp-thread").length, 0, "back to the list's own answer");
  restore();
});

test("closing the panel forgets the threads that were only kept for a moment", async () => {
  view.setDashboard(dash({ comments: [thread("a")] }));
  headOf(0).fire("click");
  root.find(".gp-row")[0].fire("click");
  const restore = answer({ gitlab_resolve: { ok: true, error: null } });
  root.find(".gp-btn")[1].fire("click");
  await new Promise((r) => setTimeout(r, 0));
  view.setDashboard(dash({ comments: [] }));
  assert.equal(root.find(".gp-thread").length, 1);
  view.closed();
  assert.equal(root.find(".gp-thread").length, 0);
  restore();
});

test("the window follows the content's height", () => {
  const inner = root.children[0];
  inner.offsetHeight = 321.4;
  view.setDashboard(dash());
  assert.deepEqual(sent("gitlab_panel_resize"), [{ height: 324 }], "the content and the card's border");
  view.render();
  assert.equal(sent("gitlab_panel_resize").length, 1, "only when it changes");
});

test("the header folds the panel or closes it", () => {
  view.setDashboard(dash());
  const [fold, close] = root.find(".gp-x");
  fold.fire("click");
  assert.deepEqual(sent("gitlab_panel_mode"), [{ expanded: false }]);
  assert.equal(sent("gitlab_panel_close").length, 0);
  view.setMode(true);
  root.find(".gp-x")[1].fire("click");
  assert.equal(close === undefined, false);
  assert.equal(sent("gitlab_panel_close").length, 1);
});

test("an avatar carries the initials of a person and a colour that is theirs", async () => {
  const { initials, avatarHue } = await import("../src/core/gitlab-panel.ts");
  assert.equal(initials("Jane Doe"), "JD");
  assert.equal(initials("bob"), "B");
  assert.equal(initials("anne-marie.dupont"), "AD");
  assert.equal(initials("  "), "?");
  assert.equal(initials("élodie"), "É");
  assert.equal(avatarHue("bob"), avatarHue("bob"));
  assert.notEqual(avatarHue("bob"), avatarHue("alice"));
  assert.ok(avatarHue("anyone") >= 0 && avatarHue("anyone") < 360);
});

// ── Folded: the slim bar ──────────────────────────────────────────────────────

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const tiles = () => root.find(".gp-pill");

test("folded, the panel is a bar: the logo and a tile per section with its +N and its glow", () => {
  view.setDashboard(dash({ comments: [thread("a")], toReview: [mr(1)] }));
  view.setMode(false);
  assert.ok(root.classList.contains("slim"));
  assert.equal(root.find(".gp-sec").length, 0, "no card, no lists");
  assert.equal(root.find(".gp-logo").length, 1);
  assert.equal(tiles().length, 4);
  assert.deepEqual(tiles().map((t) => t.classList.contains("waiting")), [true, true, false, false]);
  assert.deepEqual(root.find(".gp-pbadge").map((b) => b.textContent), [], "nothing new yet");
  view.setDashboard(dash({ comments: [thread("a")], toReview: [mr(1), mr(2), mr(3)] }));
  assert.deepEqual(root.find(".gp-pbadge").map((b) => b.textContent), ["+2"]);
  assert.match(tiles()[1].getAttribute("title"), /To review · 3/);
});

test("a tile unfolds the panel with its section open", () => {
  view.setDashboard(dash({ toReview: [mr(1)] }));
  view.setMode(false);
  calls.length = 0;
  tiles()[1].fire("click");
  assert.deepEqual(sent("gitlab_panel_mode"), [{ expanded: true }]);
  assert.ok(!root.classList.contains("slim"));
  assert.equal(root.find(".gp-row").length, 1, "the section is open");
});

test("hovering the bar unfolds it after a moment, leaving before that does not", async () => {
  view.hoverDelay = 10;
  view.setDashboard(dash());
  view.setMode(false);
  calls.length = 0;
  view.pointerEnter();
  view.pointerLeave();
  await wait(30);
  assert.deepEqual(sent("gitlab_panel_mode"), [], "gone before the delay");
  view.pointerEnter();
  await wait(30);
  assert.deepEqual(sent("gitlab_panel_mode"), [{ expanded: true }]);
  view.pointerLeave();
  view.setAutoClose(15);
});

test("the card folds once the pointer has been away for the island's delay", async () => {
  view.setDashboard(dash());
  view.setAutoClose(0.03);
  view.setMode(true);
  calls.length = 0;
  view.pointerEnter();
  await wait(60);
  assert.deepEqual(sent("gitlab_panel_mode"), [], "not while the pointer is on it");
  view.pointerLeave();
  await wait(80);
  assert.deepEqual(sent("gitlab_panel_mode"), [{ expanded: false }]);
  assert.ok(root.classList.contains("slim"));
  view.setAutoClose(15);
});

test("a reply being written is not lost to a fold", async () => {
  view.setDashboard(dash({ comments: [thread("a")] }));
  headOf(0).fire("click");
  root.find(".gp-row")[0].fire("click");
  root.find("TEXTAREA")[0].value = "half a sentence";
  view.setAutoClose(0.03);
  view.setMode(true);
  calls.length = 0;
  await wait(120);
  assert.deepEqual(sent("gitlab_panel_mode"), [], "the draft keeps it open");
  root.find("TEXTAREA")[0].value = "";
  await wait(80);
  assert.deepEqual(sent("gitlab_panel_mode"), [{ expanded: false }]);
  view.setAutoClose(15);
});

test("an auto-close delay of 0 never folds it", async () => {
  view.setDashboard(dash());
  view.setAutoClose(0);
  view.setMode(true);
  calls.length = 0;
  await wait(50);
  assert.deepEqual(sent("gitlab_panel_mode"), []);
  view.setAutoClose(15);
});

test("a new comment makes the folded bar pulse, and never unfolds it", () => {
  view.setDashboard(dash());
  view.setMode(false);
  calls.length = 0;
  view.setDashboard(dash({ comments: [thread("a")] }));
  assert.ok(tiles()[0].classList.contains("pulse"));
  assert.ok(!tiles()[1].classList.contains("pulse"));
  assert.deepEqual(sent("gitlab_panel_mode"), []);
  assert.ok(root.classList.contains("slim"));
});

test("it is only ever the card or the slim bar: nothing to drag", () => {
  view.setDashboard(dash());
  assert.equal(root.className, "");
  view.setMode(false);
  assert.equal(root.className, "slim");
  assert.equal(root.find(".gp-head").length, 0);
  assert.equal(root.find(".gp-slim")[0].listeners.get("mousedown"), undefined, "no drag on the bar");
  view.setMode(true);
  assert.equal(root.find(".gp-head")[0].listeners.get("mousedown"), undefined, "nor on the header");
});

test.after(() => view?.closed());
