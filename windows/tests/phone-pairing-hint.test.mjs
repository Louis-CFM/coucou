// Settings → Android phone: what the pairing link says about itself after "Copy link".

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { installFakeDom } from "./fakedom.mjs";
import { copyLinkHint } from "../src/settings/phone.ts";

installFakeDom();

test("the hint about the copied link is there but hidden until the link is copied", () => {
  const hint = copyLinkHint();
  assert.equal(hint.hidden, true);
  const text = hint.textContent ?? "";
  assert.match(text, /pairing code/);
  assert.match(text, /Pair again/);
  assert.match(text, /old one stops working/);
});

test("copying the link shows the hint and keeps it after the button text goes back", () => {
  const src = readFileSync(new URL("../src/settings/phone.ts", import.meta.url), "utf8");
  const click = src.slice(src.indexOf('copy.addEventListener("click"'), src.indexOf("const repair"));
  assert.ok(click.includes("copied.hidden = false"), "the hint is shown by the click");
  assert.ok(!click.includes("copied.hidden = true"), "and not hidden again by the timer");
  assert.match(src, /\n\s*copied,\r?\n/, "it sits right under the link");
});
