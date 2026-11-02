// The island's permission card answers the request it shows, never one that
// replaced it between two frames. Run with `npm test`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";

installFakeDom();
document.addEventListener = () => {};
window.addEventListener = () => {};
const { buildViews } = await import("../src/views/views.ts");
const { State } = await import("../src/core/state.ts");

const request = (requestId) => ({ requestId, sessionId: "s", pillId: "claude", tool: "Bash", command: `echo ${requestId}` });

test("Allow answers the request drawn, not one that replaced it before the next sync", (t) => {
  let now = 0;
  t.mock.method(performance, "now", () => now);
  t.after(() => (State.pendingApproval = null));
  const decided = [];
  const actions = new Proxy({ decide: (d, id) => decided.push([d, id]) }, { get: (o, k) => o[k] ?? (() => {}) });
  const card = buildViews(actions, () => {}).get("approval");
  State.pendingApproval = request("A");
  card.sync();
  const [deny, allow] = card.el.find("BUTTON");
  now = 1000;
  // A expired and B is waiting, but the card still shows A.
  State.pendingApproval = request("B");
  allow.fire("click");
  deny.fire("click");
  assert.deepEqual(decided, [["allow", "A"], ["deny", "A"]]);
});
