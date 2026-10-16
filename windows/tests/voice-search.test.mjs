import { test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { voicePage } from "../src/hub/pages/voice.ts";

installFakeDom();

test("voice search stays on Anthropic until the user explicitly selects Parallel", async () => {
  const prefs = { voice: false, voiceOutput: "off", voiceSearch: "anthropic" };
  const status = { prefs, models: { parakeet: { state: "missing" } }, hasClaudeKey: false };
  let writes = 0;
  const page = document.createElement("div");
  const ctx = {
    status,
    refresh: async () => status,
    hero: () => document.createElement("div"),
    setPrefs: async (change) => { writes++; change(prefs); },
    navigate: () => {},
  };
  await voicePage(page, ctx);
  assert.equal(writes, 0);
  const options = page.find("button");
  assert.ok(options.find((b) => b.textContent === "Anthropic").classList.contains("on"));
  assert.ok(!options.find((b) => b.textContent === "Parallel").classList.contains("on"));
  assert.match(page.textContent, /send web search queries to Parallel/);
  assert.match(page.textContent, /anonymous rate limits/);
  // The view's segmented control uses querySelectorAll in a real webview.
  for (const group of page.find(".hub-segmented")) group.querySelectorAll = (tag) => group.find(tag);
  options.find((b) => b.textContent === "Parallel").fire("click");
  await Promise.resolve();
  assert.equal(writes, 1);
  assert.equal(prefs.voiceSearch, "parallel");
  assert.equal(prefs.voice, false);
  options.find((b) => b.textContent === "Off").fire("click");
  await Promise.resolve();
  assert.equal(prefs.voiceSearch, "off");
});
