// The page's pixel density (src/core/dpr.ts): the island window, moved to a display with another
// scale, redraws its canvases, once per change.

import { afterEach, test } from "node:test";
import assert from "node:assert/strict";
import { watchDpr } from "../src/core/dpr.ts";

/** A fake matchMedia: every query returns a list that can be fired by hand. */
function fakeMedia() {
  const lists = [];
  globalThis.matchMedia = (query) => {
    const listeners = new Set();
    const list = {
      query,
      listeners,
      addEventListener: (type, fn) => type === "change" && listeners.add(fn),
      removeEventListener: (type, fn) => type === "change" && listeners.delete(fn),
      fire: () => [...listeners].forEach((fn) => fn()),
    };
    lists.push(list);
    return list;
  };
  return lists;
}

afterEach(() => {
  delete globalThis.matchMedia;
  globalThis.devicePixelRatio = 1;
});

test("watchDpr listens for the density the page has now", () => {
  globalThis.devicePixelRatio = 1;
  const lists = fakeMedia();
  watchDpr(() => {});
  assert.equal(lists.length, 1);
  assert.equal(lists[0].query, "(resolution: 1dppx)");
  assert.equal(lists[0].listeners.size, 1);
});

test("a change calls back once and listens for the new density instead", () => {
  globalThis.devicePixelRatio = 1;
  const lists = fakeMedia();
  let calls = 0;
  watchDpr(() => calls++);
  globalThis.devicePixelRatio = 1.5;
  lists[0].fire();
  assert.equal(calls, 1);
  assert.equal(lists.length, 2);
  assert.equal(lists[1].query, "(resolution: 1.5dppx)");
  assert.equal(lists[0].listeners.size, 0, "the old list is let go");
  assert.equal(lists[1].listeners.size, 1);
});

test("stop() lets go of the last list", () => {
  globalThis.devicePixelRatio = 1;
  const lists = fakeMedia();
  const stop = watchDpr(() => {});
  globalThis.devicePixelRatio = 2;
  lists[0].fire();
  stop();
  assert.equal(lists.at(-1).listeners.size, 0);
  assert.ok(lists.every((l) => l.listeners.size === 0));
});

test("without matchMedia (Node, an old webview) nothing happens and nothing throws", () => {
  delete globalThis.matchMedia;
  let calls = 0;
  const stop = watchDpr(() => calls++);
  assert.doesNotThrow(stop);
  assert.equal(calls, 0);
});
