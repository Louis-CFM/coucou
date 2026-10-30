import { test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { PillSurface, hotRects, insideHot } from "../src/pill/surface.ts";

test("tooltip updates leave the hovered button mounted and its click intact", () => {
  const { root } = installFakeDom();
  const host = root();
  const surface = new PillSurface(host);
  const button = document.createElement("button");
  let clicks = 0;
  button.addEventListener("click", () => clicks++);
  surface.content("toolbar", () => button);
  // Any replacement of the toolbar's ancestors between down and up loses the click.
  host.replaceChildren = () => assert.fail("tooltip detached the capsule");
  surface.capsule.replaceChildren = () => assert.fail("tooltip replaced the hovered button");
  button.fire("pointerdown");
  surface.content("toolbar", () => assert.fail("rebuilt the same toolbar"));
  surface.bubble("dictate", () => document.createElement("span"));
  const tip = surface.bubbles.firstChild;
  surface.bubble("dictate", () => assert.fail("restarted the unchanged tooltip animation"));
  assert.equal(surface.bubbles.firstChild, tip);
  surface.bubble("", () => null);
  button.fire("pointerup");
  button.fire("click");
  assert.equal(clicks, 1);
  assert.equal(button.parentElement, surface.capsule);
  assert.equal(surface.capsule.parentElement, host);
});

test("state changes replace content without moving the capsule", () => {
  const { root } = installFakeDom();
  const host = root();
  const surface = new PillSurface(host);
  surface.content("resting", root);
  const resting = surface.capsule.firstChild;
  surface.content("toolbar", root);
  assert.notEqual(surface.capsule.firstChild, resting);
  assert.equal(host.children[1], surface.capsule);
});

test("bottom hover covers the expanded target before the size animation ends", () => {
  const rects = hotRects({ left: 238, top: 160, width: 44, height: 8 }, null, "bottom", 150, 34);
  assert.equal(insideHot(rects, 190, 140), true);
  assert.equal(insideHot(rects, 330, 140), true);
  assert.equal(insideHot(rects, 100, 140), false);
});

test("both side edges keep hover anchored through expansion and into the tooltip", () => {
  for (const edge of ["left", "right"]) {
    const x = edge === "left" ? 2 : 470;
    const bubble = { left: edge === "left" ? 44 : 210, top: 145, width: 226, height: 30 };
    const rects = hotRects({ left: x, top: 138, width: 8, height: 44 }, bubble, edge, 34, 150);
    assert.equal(insideHot(rects, edge === "left" ? 30 : 450, 100), true);
    assert.equal(insideHot(rects, edge === "left" ? 40 : 440, 160), true);
    assert.equal(insideHot(rects, bubble.left + 220, 160), true);
    assert.equal(insideHot(rects, 240, 10), false);
  }
});

test("long messages use their actual width instead of a fixed 200px click zone", () => {
  const rects = hotRects({ left: 60, top: 134, width: 400, height: 34 }, null, "bottom", 400, 34);
  assert.equal(insideHot(rects, 65, 145), true);
  assert.equal(insideHot(rects, 450, 145), true);
});
