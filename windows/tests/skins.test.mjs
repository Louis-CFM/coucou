// Skins: the formula language, the file checks, the four outfits
// recovered from the first wardrobe, and how the wardrobe takes them in.

import { test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";

installFakeDom();

const {
  compileFormula, parseSkin, drawSkin, drawSkinIcon, setUserSkins, skinFor, skinSelections,
  isSkinSelection, skinLabel, onSkinsChange,
} = await import("../src/mochi/skins.ts");
const { parseOutfit, outfitLabel, wardrobeHeader } = await import("../src/mochi/wardrobe.ts");
const { setLanguage } = await import("../src/i18n/i18n.ts");

/** A canvas that only records what it was asked to draw. */
function recorder() {
  const calls = [];
  const target = { globalAlpha: 1 };
  const ctx = new Proxy(target, {
    get(t, key) {
      if (key in t) return t[key];
      if (key === "createLinearGradient") return () => ({ addColorStop() {} });
      return (...args) => void calls.push([String(key), ...args]);
    },
    set(t, key, value) {
      t[key] = value;
      return true;
    },
  });
  return { ctx, calls };
}

const HEAD = { R: 28, rx: 28 * 1.14, ry: 28 * 0.88, yaw: 0 };
const STATE = { presence: 1, morph: 0 };

// ── Formulas ──────────────────────────────────────────────────────────────────

test("formulas: arithmetic, precedence, variables and functions", () => {
  const env = { R: 10, xs: 0.5 };
  assert.equal(compileFormula("1 + 2 * 3")({}), 7);
  assert.equal(compileFormula("(1 + 2) * 3")({}), 9);
  assert.equal(compileFormula("-R + R*0.5")(env), -5);
  assert.equal(compileFormula("floor(R*xs/ 2)")(env), 2);
  assert.equal(compileFormula("max(1, min(R, 4))")(env), 4);
  assert.equal(compileFormula("2 - -3")({}), 5);
});

test("formulas: anything that is not plain arithmetic is refused", () => {
  for (const bad of ["1 +", "alert(1)", "R.constructor", "a b", "1; 2", "constructor", "((1)", "x".repeat(300)]) {
    assert.throws(() => compileFormula(bad)({ R: 1 }), undefined, bad.slice(0, 20));
  }
});

// ── Files ─────────────────────────────────────────────────────────────────────

const minimal = (over = {}) => ({
  id: "mine",
  name: "Mine",
  shapes: [{ type: "rect", x: 0, y: 0, w: 4, h: 4, fill: "#fff" }],
  ...over,
});

test("a good file parses; a bad one is refused, whatever is wrong with it", () => {
  assert.equal(parseSkin(minimal())?.id, "mine");
  const bad = [
    null, "text", {}, minimal({ id: "no spaces" }), minimal({ id: "../x" }), minimal({ name: "" }),
    minimal({ shapes: "no" }), minimal({ shapes: [{ type: "mystery" }] }),
    minimal({ shapes: [{ type: "rect", x: "1 +", y: 0, w: 1, h: 1 }] }),
    minimal({ shapes: [{ type: "rect", x: 0, y: 0, w: 1, h: 1, fill: "url(http://x)" }] }),
    minimal({ shapes: Array.from({ length: 200 }, () => ({ type: "rect", x: 0, y: 0, w: 1, h: 1 })) }),
    minimal({ shapes: [{ type: "poly", points: [[0, 0], [1, 1]] }] }),
  ];
  for (const raw of bad) assert.equal(parseSkin(raw), null, JSON.stringify(raw)?.slice(0, 60));
});

test("a file in another language's clothes: names by language, hat by default", () => {
  const skin = parseSkin(minimal({ names: { it: "Mia", fr: "" } }));
  assert.deepEqual(skin.names, { it: "Mia" });
  assert.equal(skin.kind, "hat");
  assert.equal(skin.layer, "front");
});

// ── The four recovered outfits ────────────────────────────────────────────────

const RECOVERED = ["topHat", "cap", "heartsHeadband", "strawHat"];

test("the four outfits recovered from the first wardrobe are in the collection", () => {
  for (const id of RECOVERED) {
    assert.ok(skinFor(`skin:${id}`), id);
    assert.ok(skinSelections().includes(`skin:${id}`), id);
  }
});

test("every skin file shipped with the app parses (a broken one is dropped silently)", async () => {
  const { BUNDLED_SKINS } = await import("../src/mochi/skin-files/index");
  assert.ok(BUNDLED_SKINS.length >= 26);
  for (const raw of BUNDLED_SKINS) assert.ok(parseSkin(raw), `${raw?.id} does not parse`);
  assert.equal(new Set(BUNDLED_SKINS.map((s) => s.id)).size, BUNDLED_SKINS.length, "duplicate ids");
});

test("every shipped skin draws every layer at several turns without throwing", async () => {
  const { BUNDLED_SKINS } = await import("../src/mochi/skin-files/index");
  for (const raw of BUNDLED_SKINS) {
    const skin = parseSkin(raw);
    for (const yaw of [0, 0.9, -0.9, 1.3, -1.3]) {
      for (const layer of ["behind", "body", "front"]) {
        const rec = recorder();
        drawSkin(rec.ctx, skin, { ...HEAD, yaw }, STATE, layer);
      }
    }
    const rec = recorder();
    drawSkinIcon(rec.ctx, 34, skin);
  }
});

test("a skin's body colours are read, and a bad colour refuses the file", () => {
  assert.deepEqual(parseSkin(minimal({ body: ["#fff", "rgb(1,2,3)"] })).body, ["#fff", "rgb(1,2,3)"]);
  assert.equal(parseSkin(minimal({ body: ["#fff", "red"] })), null);
  assert.equal(parseSkin(minimal({})).body, null);
});

test("a skin gives the halo and the tint their colour, except in the states that must show", async () => {
  const { glowColor, stateTintScale } = await import("../src/mochi/skin-outfits");
  const { botGlowColor } = await import("../src/core/layout");
  // The plain Mochi and the built-in outfits keep the state's colour and the full tint.
  assert.equal(glowColor("working", "none"), botGlowColor("working"));
  assert.equal(glowColor("idle", "witchHat"), botGlowColor("idle"));
  assert.equal(stateTintScale("working", "none"), 1);
  // A skin with its own colour: its halo at rest and at work…
  assert.equal(glowColor("idle", "skin:watermelon"), "#22C55E");
  assert.equal(glowColor("working", "skin:watermelon"), "#22C55E");
  assert.equal(glowColor("finished", "skin:watermelon"), "#22C55E");
  // …but an error, a rate limit and an approval stay red or amber.
  for (const s of ["error", "ratelimit", "approval"]) {
    assert.equal(glowColor(s, "skin:watermelon"), botGlowColor(s), s);
    assert.equal(stateTintScale(s, "skin:watermelon"), 1, s);
  }
  // A recoloured body takes only a little of the state's tint; a skin that only adds things takes all.
  assert.equal(stateTintScale("working", "skin:watermelon"), 0.3);
  assert.equal(stateTintScale("working", "skin:cap"), 1);
  assert.equal(glowColor("working", "skin:cap"), botGlowColor("working"));
  // A skin file with a glow that is not a colour is refused; none is fine.
  assert.equal(parseSkin(minimal({ glow: "#0f0" })).glow, "#0f0");
  assert.equal(parseSkin(minimal({ glow: "green" })), null);
  assert.equal(parseSkin(minimal({})).glow, null);
});

test("face features follow the eyes when Mochi looks down, and a skin can limit how far the eyes travel", async () => {
  const { outfitLookRange } = await import("../src/mochi/skin-outfits");
  assert.equal(outfitLookRange("none"), 1);
  assert.equal(outfitLookRange("skin:cap"), 1);
  for (const id of ["robot", "scarf", "mustache"]) assert.equal(outfitLookRange(`skin:${id}`), 0.5, id);
  for (const id of ["dog", "bear"]) assert.equal(outfitLookRange(`skin:${id}`), 0.4, id); // their muzzle needs more room
  assert.equal(parseSkin(minimal({ lookRange: 5 })).lookRange, 1);
  assert.equal(parseSkin(minimal({ lookRange: 0 })).lookRange, 0.1);

  // The dog's nose is a "follow" shape: its drawing is moved down when the head looks down
  // (negative pitch is down, as the island feeds it), and not at rest.
  const dog = skinFor("skin:dog");
  const moved = (pitch) => {
    const rec = recorder();
    drawSkin(rec.ctx, dog, { ...HEAD, pitch }, STATE, "front");
    return rec.calls.filter(([name]) => name === "translate").map(([, ...a]) => a[1]).filter((y) => y !== 0 && y !== undefined);
  };
  assert.ok(moved(-0.25).some((y) => y > 0), "the nose does not move down");
  assert.ok(moved(0.25).some((y) => y < 0), "the nose does not move up");
  assert.equal(moved(0).length, 0, "the nose moves although the head looks straight ahead");
});

test("the non-hat skins (scarf, bow tie, cape, wings, blush, moustache, headphones) draw at every turn", () => {
  for (const id of ["scarf", "bowTie", "cape", "angelWings", "blush", "mustache", "headphones"]) {
    const skin = skinFor(`skin:${id}`);
    assert.ok(skin && skin.kind === "face", id);
    for (const yaw of [0, 0.9, -0.9, 1.2, -1.2]) {
      const rec = recorder();
      drawSkin(rec.ctx, skin, { ...HEAD, yaw }, STATE, "front");
      drawSkin(rec.ctx, skin, { ...HEAD, yaw }, STATE, "behind");
      assert.ok(rec.calls.some(([name]) => name === "fill" || name === "stroke"), `${id} at yaw ${yaw}`);
    }
  }
});

test("each recovered outfit draws in front; the brimmed ones also behind the head", () => {
  const BRIMMED = new Set(["topHat", "strawHat"]); // the back half of the brim passes behind the head
  for (const id of RECOVERED) {
    const skin = skinFor(`skin:${id}`);
    const front = recorder();
    drawSkin(front.ctx, skin, HEAD, STATE, "front");
    assert.ok(front.calls.some(([name]) => name === "fill"), `${id} fills something`);
    const behind = recorder();
    drawSkin(behind.ctx, skin, HEAD, STATE, "behind");
    const drawsBehind = behind.calls.some(([name]) => name === "fill" || name === "stroke");
    assert.equal(drawsBehind, BRIMMED.has(id), id);
  }
});

test("head(u): the height of Mochi's head, 1 in the middle and 0 at the sides", () => {
  assert.equal(compileFormula("head(0)")({}), 1);
  assert.equal(compileFormula("head(1)")({}), 0);
  assert.equal(compileFormula("head(-1)")({}), 0);
  const h = (u) => compileFormula(`head(${u})`)({});
  assert.ok(h(0.3) > h(0.6) && h(0.6) > h(0.9), "falls towards the sides");
  assert.ok(h(0.5) > 0.9, "the top of the head is nearly flat");
});

test("a band follows its curves: one point per step, on both edges", () => {
  const skin = parseSkin({
    id: "b", name: "B",
    shapes: [{ type: "band", steps: 10, x: "u*10", top: "-5-head(u)", bottom: "0", fill: "#fff" }],
  });
  const { ctx, calls } = recorder();
  drawSkin(ctx, skin, HEAD, STATE, "front");
  const points = calls.filter(([name]) => name === "moveTo" || name === "lineTo");
  assert.equal(points.length, 2 * (10 + 1), "11 points along the top and 11 back along the bottom");
  assert.equal(calls.filter(([name]) => name === "closePath").length, 1);
});

test("a skin sits on the head, and keeps the head's width when it turns", () => {
  const widthOf = (id, yaw) => {
    const { ctx, calls } = recorder();
    drawSkin(ctx, skinFor(`skin:${id}`), { ...HEAD, yaw }, STATE, "front");
    const xs = calls.filter(([name]) => name === "moveTo" || name === "lineTo").map(([, x]) => x);
    return Math.max(...xs) - Math.min(...xs);
  };
  for (const id of ["cap", "heartsHeadband", "strawHat", "topHat"]) {
    const straight = widthOf(id, 0);
    const turned = widthOf(id, 0.9);
    assert.ok(straight > HEAD.rx, `${id} is at least as wide as the head's half width`);
    assert.ok(Math.abs(turned - straight) / straight < 0.12, `${id}: ${straight} → ${turned}`);
  }
});

test("the ends of a hat stay on the head's outline however the head turns", () => {
  // The body's silhouette never moves; a hat whose ends slid sideways would show a step
  // against it (the cap's dome used to stop short of the head on one side).
  const ends = (id, yaw) => {
    const { ctx, calls } = recorder();
    drawSkin(ctx, skinFor(`skin:${id}`), { ...HEAD, yaw }, STATE, "front");
    const xs = calls.filter(([name]) => name === "moveTo" || name === "lineTo").map(([, x]) => x);
    return [Math.min(...xs), Math.max(...xs)];
  };
  for (const id of ["cap", "heartsHeadband", "strawHat", "topHat"]) {
    const [l0, r0] = ends(id, 0);
    for (const yaw of [0.9, -0.9, 1.2]) {
      const [l, r] = ends(id, yaw);
      assert.ok(Math.abs(l - l0) < 1 && Math.abs(r - r0) < 1, `${id} at yaw ${yaw}: ${l0}..${r0} → ${l}..${r}`);
    }
  }
  // The cap's dome reaches the head's own edge, not a little inside it.
  const [left, right] = ends("cap", 0.9);
  assert.ok(left <= -HEAD.rx * 0.95 && right >= HEAD.rx * 0.95, `${left}..${right} against ±${HEAD.rx}`);
});

test("a hat's lowest edge overlaps the head, so it sits on it rather than above it", () => {
  const lowest = (id) => {
    const { ctx, calls } = recorder();
    drawSkin(ctx, skinFor(`skin:${id}`), HEAD, STATE, "front");
    return Math.max(...calls.filter(([name]) => name === "lineTo" || name === "moveTo").map(([, , y]) => y));
  };
  // The head's top is at y = -ry; a hat that sits on it reaches clearly below that line.
  for (const id of ["cap", "strawHat", "topHat", "heartsHeadband"]) {
    assert.ok(lowest(id) > -HEAD.ry + HEAD.R * 0.10, `${id} reaches into the head`);
  }
});

test("a detail on the head turns with it, and goes out of sight behind it (when)", () => {
  const hearts = (yaw) => {
    const { ctx, calls } = recorder();
    drawSkin(ctx, skinFor("skin:heartsHeadband"), { ...HEAD, yaw }, STATE, "front");
    return calls.filter(([name]) => name === "bezierCurveTo").length / 2; // two curves a heart
  };
  assert.equal(hearts(0), 2, "both hearts face front");
  assert.equal(hearts(2.3), 0, "turned far enough, both are behind the head");

  const visorX = (yaw) => {
    const { ctx, calls } = recorder();
    drawSkin(ctx, skinFor("skin:cap"), { ...HEAD, yaw }, STATE, "front");
    const visor = calls.filter(([name]) => name === "ellipse")[0];
    return visor[1];
  };
  assert.ok(visorX(0.8) > visorX(0) && visorX(0) > visorX(-0.8), "the visor swings the way the head turns");

  const noWhen = parseSkin({ id: "w", name: "W", shapes: [{ type: "rect", when: "0-1", x: 0, y: 0, w: 1, h: 1, fill: "#fff" }] });
  const none = recorder();
  drawSkin(none.ctx, noWhen, HEAD, STATE, "front");
  assert.equal(none.calls.filter(([name]) => name === "fill").length, 0, "when <= 0: not drawn");
});

test("too small, or not yet on, or Mochi a mailbox: nothing is drawn", () => {
  const skin = skinFor("skin:topHat");
  for (const [head, state] of [
    [{ ...HEAD, R: 3 }, STATE],
    [HEAD, { presence: 0, morph: 0 }],
    [HEAD, { presence: 1, morph: 1 }],
  ]) {
    const { ctx, calls } = recorder();
    drawSkin(ctx, skin, head, state, "front");
    assert.equal(calls.length, 0);
  }
});

test("a formula that cannot be computed draws nothing and does not throw", () => {
  const skin = parseSkin(minimal({ shapes: [{ type: "rect", x: "nope", y: 0, w: 1, h: 1, fill: "#fff" }] }));
  const { ctx } = recorder();
  assert.doesNotThrow(() => drawSkin(ctx, skin, HEAD, STATE, "front"));
});

test("the wardrobe icon draws a Mochi wearing it", () => {
  const { ctx, calls } = recorder();
  drawSkinIcon(ctx, 28, skinFor("skin:cap"));
  assert.ok(calls.filter(([name]) => name === "fill").length >= 3);
  // Mochi's body + two eyes are 3 fills: the cap adds its own (it was missing at R = 10).
  assert.ok(calls.filter(([name]) => name === "fill").length >= 6);
});

test("a skin shows at the size of the compact pill (R about 10), not only when the island is open", () => {
  for (const R of [10, 12, 29]) {
    const { ctx, calls } = recorder();
    drawSkin(ctx, skinFor("skin:topHat"), { R, rx: R * 1.14, ry: R * 0.88, yaw: 0 }, STATE, "front");
    assert.ok(calls.some(([name]) => name === "fill"), `R = ${R}`);
  }
});

// ── The wardrobe ──────────────────────────────────────────────────────────────

test("a stored skin is kept; one that does not exist reads as auto", () => {
  assert.equal(parseOutfit("skin:topHat"), "skin:topHat");
  assert.equal(parseOutfit("skin:no-such-skin"), "auto");
  assert.equal(parseOutfit("topHat"), "auto"); // the Mac's removed raw value is still not a choice
  assert.equal(parseOutfit("witchHat"), "witchHat");
  assert.equal(isSkinSelection("skin:cap"), true);
  assert.equal(isSkinSelection("witchHat"), false);
});

test("skins are named in the language of the page, else in English", () => {
  assert.equal(skinLabel("skin:topHat"), "Top hat");
  setUserSkins([minimal({ id: "party", name: "Party", names: { fr: "Fête" } })]);
  setLanguage("fr");
  try {
    assert.equal(skinLabel("skin:party"), "Fête");
    assert.equal(outfitLabel("skin:party"), "Fête");
    assert.match(wardrobeHeader("skin:party", "auto", new Date(2026, 5, 1)), /Fête/);
    assert.equal(skinLabel("skin:topHat"), "Top hat", "no French name: English");
  } finally {
    setLanguage("en");
    setUserSkins([]);
  }
  assert.equal(outfitLabel("witchHat"), "Witch hat"); // a built-in outfit is as before
});

test("the user's folder adds skins, a file of theirs wins over a shipped one, and listeners hear", () => {
  let heard = 0;
  const off = onSkinsChange(() => heard++);
  setUserSkins([
    minimal({ id: "party", name: "Party" }),
    minimal({ id: "topHat", name: "My top hat" }),
    { broken: true },
  ]);
  assert.equal(heard, 1);
  assert.ok(skinSelections().includes("skin:party"));
  assert.equal(skinFor("skin:topHat").name, "My top hat");
  setUserSkins([minimal({ id: "party", name: "Party" }), minimal({ id: "topHat", name: "My top hat" })]);
  assert.equal(heard, 1, "the same set again says nothing");

  setUserSkins([]);
  off();
  assert.equal(heard, 2);
  assert.equal(skinFor("skin:party"), undefined);
  assert.equal(skinFor("skin:topHat").name, "Top hat", "the shipped one is back");
  assert.equal(parseOutfit("skin:party"), "auto", "a removed file is no longer a choice");
});
