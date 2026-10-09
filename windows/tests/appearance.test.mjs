import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { Island } from "../src/island/island.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";
import { UploadCanvas } from "../src/upload/canvas.ts";
import { UploadSeq, USC } from "../src/upload/sequence.ts";

beforeEach(() => { State.settings = { ...DEFAULT_SETTINGS }; UploadSeq.deactivate(); });

function host() {
  const properties = new Map();
  return {
    root: { dataset: {}, style: {
      setProperty: (key, value) => properties.set(key, value),
      removeProperty: (key) => properties.delete(key),
    } },
    fsm: {}, properties,
  };
}

test("Original and Dark Frosted restore after either click-through method", () => {
  const island = host();
  for (const appearance of ["original", "windowsDarkFrosted"]) {
    for (const method of ["holdCtrl", "ctrlAltD"]) {
      State.settings.islandAppearance = appearance;
      State.settings.clickThroughShortcut = method;
      Island.prototype.applySettings.call(island);
      Island.prototype.setClickThrough.call(island, true);
      assert.equal(island.root.dataset.appearance, appearance);
      assert.equal(island.root.dataset.clickThrough, "true");
      Island.prototype.setClickThrough.call(island, false);
      assert.equal(island.root.dataset.appearance, appearance);
      assert.equal(island.root.dataset.clickThrough, "false");
    }
  }
});

test("a system accent updates its CSS token; unavailable accent uses the charcoal CSS fallback", () => {
  const island = host();
  Island.prototype.setAccentColor.call(island, [255, 220, 12]);
  assert.equal(island.properties.get("--windows-accent"), "255, 220, 12");
  Island.prototype.setAccentColor.call(island, [0, 120, 215]);
  assert.equal(island.properties.get("--windows-accent"), "0, 120, 215");
  Island.prototype.setAccentColor.call(island, null);
  assert.ok(!island.properties.has("--windows-accent"));
});

test("drag, upload and attachment choice preserve the Frosted surface instead of painting black", (t) => {
  let now = 1000;
  t.mock.method(performance, "now", () => now);
  const fills = [];
  const context = new Proxy({
    fillRect(x, y, w, h) { fills.push({ color: this.fillStyle, x, y, w, h }); },
    measureText: (text) => ({ width: text.length * 6 }),
    createLinearGradient: () => ({ addColorStop() {} }),
    createRadialGradient: () => ({ addColorStop() {} }),
  }, { get: (object, key) => key in object ? object[key] : () => {} });
  const previousDocument = globalThis.document;
  globalThis.document = { createElement: () => ({
    style: {}, append() {}, addEventListener() {}, getContext: () => context,
  }) };
  t.after(() => { globalThis.document = previousDocument; });
  const canvas = new UploadCanvas({ ask() {}, cancel() {} });
  UploadSeq.enterZone(280, 100);
  const frames = [UploadSeq.frame()];
  UploadSeq.performDrop(2.4);
  now += 1800;
  frames.push(UploadSeq.frame());
  now += 4000;
  frames.push(UploadSeq.frame());
  for (const appearance of ["original", "windowsDarkFrosted"]) {
    State.settings.islandAppearance = appearance;
    for (const frame of frames) {
      fills.length = 0;
      canvas.draw(frame, now / 1000);
      const wholeIsland = fills.filter(({ x, y, w, h }) => x === 0 && y === 0 && w === USC.W && h === USC.ISL_H);
      assert.equal(wholeIsland.length, appearance === "original" ? 1 : 0);
      assert.equal(State.settings.islandAppearance, appearance);
      assert.ok(fills.some(({ w, h }) => w === USC.CARD_W && h === USC.CARD_H));
    }
  }
});
