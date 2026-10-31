// The notch's Clipboard: what each item is, the filters, the order (src/core/clipboard.ts).

import { test } from "node:test";
import assert from "node:assert/strict";
import { ago, fileName, linkHost, look, matches, ordered } from "../src/core/clipboard.ts";

let next = 1;
const item = (over = {}) => ({ id: next++, kind: "text", text: "", chars: 0, files: [], app: null, at: 0, pinned: false, ...over });

test("a text is a link, a colour, code or just text", () => {
  assert.equal(look(item({ text: "https://github.com/Louis-CFM/coucou" })), "link");
  assert.equal(look(item({ text: "www.example.com/page" })), "link");
  assert.equal(look(item({ text: "see https://x.dev for more" })), "text", "a sentence with a link in it stays text");
  assert.equal(look(item({ text: "#25D366" })), "color");
  assert.equal(look(item({ text: "rgb(52, 211, 153)" })), "color");
  assert.equal(look(item({ text: "const a = 1;\nconsole.log(a);" })), "code");
  assert.equal(look(item({ text: "fn main() {\n    println!(\"hi\");\n}" })), "code");
  assert.equal(look(item({ text: "Shopping list:\nmilk\neggs" })), "text");
  assert.equal(look(item({ kind: "image" })), "image");
  assert.equal(look(item({ kind: "files", files: ["C:\\a.txt"] })), "files");
});

test("the filters", () => {
  const link = item({ text: "https://a.dev" });
  const code = item({ text: "let x = 1;\nlet y = 2;" });
  const image = item({ kind: "image" });
  const files = item({ kind: "files", files: ["C:\\a.txt"] });
  assert.ok(matches(code, "text") && !matches(code, "links"), "code counts as text");
  assert.ok(matches(link, "links") && !matches(link, "text"));
  assert.ok(matches(image, "images") && matches(files, "files"));
  assert.ok([link, code, image, files].every((i) => matches(i, "all")));
});

test("pinned first, then the newest", () => {
  const old = item({ text: "old", at: 1 });
  const fresh = item({ text: "fresh", at: 9 });
  const pinned = item({ text: "pinned", at: 0, pinned: true });
  assert.deepEqual(ordered([old, fresh, pinned], "all").map((i) => i.text), ["pinned", "fresh", "old"]);
  assert.deepEqual(ordered([old, item({ kind: "image", at: 5 })], "images").length, 1);
});

test("a link's site and a file's name for the card", () => {
  assert.equal(linkHost("https://www.github.com/x/y"), "github.com");
  assert.equal(linkHost("www.example.com/page"), "example.com");
  assert.equal(fileName("C:\\Users\\me\\Desktop\\report.pdf"), "report.pdf");
  assert.equal(fileName("/home/me/notes.md"), "notes.md");
});

test("how long ago, in the language shown", () => {
  const now = 10_000_000;
  assert.match(ago(now - 5_000, now, "en"), /now/i);
  assert.match(ago(now - 5 * 60_000, now, "en"), /5\s?m/);
  assert.match(ago(now - 3 * 3_600_000, now, "en"), /3\s?h/);
  assert.notEqual(ago(now - 5 * 60_000, now, "fr"), ago(now - 5 * 60_000, now, "en"), "the language's own words");
});
