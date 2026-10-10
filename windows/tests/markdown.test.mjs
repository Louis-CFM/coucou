// Markdown in the chat's answers (src/views/markdown.ts): the block parser
// follows ChatMarkdown.swift, inline syntax is parsed to a tree, and rendering
// builds DOM nodes from text only — never HTML — with http(s)-only links.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { calls, sent } from "./tauri.mjs";

const dom = installFakeDom();
const { parseMarkdown, parseInline, renderMarkdown, safeWebUrl } = await import("../src/views/markdown.ts");

beforeEach(() => {
  calls.length = 0;
});

// ── Blocks ────────────────────────────────────────────────────────────────────

test("headings need a space after the hashes", () => {
  assert.deepEqual(parseMarkdown("# Title\n## Sub\n####### Deep"), [
    { kind: "heading", level: 1, text: "Title" },
    { kind: "heading", level: 2, text: "Sub" },
    { kind: "heading", level: 6, text: "Deep" },
  ]);
  assert.deepEqual(parseMarkdown("#hashtag"), [{ kind: "paragraph", text: "#hashtag" }]);
});

test("a fenced code block keeps its lines as they are, language apart", () => {
  const md = "Before\n```python\nprint('hi')\n  indented\n\n# not a heading\n```\nAfter";
  assert.deepEqual(parseMarkdown(md), [
    { kind: "paragraph", text: "Before" },
    { kind: "code", lang: "python", code: "print('hi')\n  indented\n\n# not a heading" },
    { kind: "paragraph", text: "After" },
  ]);
  // An unclosed fence runs to the end, as while an answer is still streaming.
  assert.deepEqual(parseMarkdown("```\nlet x"), [{ kind: "code", lang: "", code: "let x" }]);
});

test("lists keep their markers and nesting", () => {
  assert.deepEqual(parseMarkdown("- one\n* two\n  + nested\n1. first\n12. twelfth"), [
    { kind: "item", prefix: "•", text: "one", indent: 0 },
    { kind: "item", prefix: "•", text: "two", indent: 0 },
    { kind: "item", prefix: "•", text: "nested", indent: 1 },
    { kind: "item", prefix: "1.", text: "first", indent: 0 },
    { kind: "item", prefix: "12.", text: "twelfth", indent: 0 },
  ]);
});

test("quotes, rules and paragraphs that stop at the next block", () => {
  assert.deepEqual(parseMarkdown("> quoted\n>\n---\nline one\nline two\n- item\n\npara"), [
    { kind: "quote", text: "quoted" },
    { kind: "quote", text: "" },
    { kind: "rule" },
    { kind: "paragraph", text: "line one\nline two" },
    { kind: "item", prefix: "•", text: "item", indent: 0 },
    { kind: "paragraph", text: "para" },
  ]);
  assert.deepEqual(parseMarkdown("a\r\nb"), [{ kind: "paragraph", text: "a\nb" }]);
  assert.deepEqual(parseMarkdown(""), []);
});

// ── Inline ────────────────────────────────────────────────────────────────────

test("inline code, bold, italic and links nest as a tree", () => {
  assert.deepEqual(parseInline("Use `npm ci` **now**, *really* or __not__ _ever_."), [
    { kind: "text", text: "Use " },
    { kind: "code", text: "npm ci" },
    { kind: "text", text: " " },
    { kind: "strong", children: [{ kind: "text", text: "now" }] },
    { kind: "text", text: ", " },
    { kind: "em", children: [{ kind: "text", text: "really" }] },
    { kind: "text", text: " or " },
    { kind: "strong", children: [{ kind: "text", text: "not" }] },
    { kind: "text", text: " " },
    { kind: "em", children: [{ kind: "text", text: "ever" }] },
    { kind: "text", text: "." },
  ]);
  assert.deepEqual(parseInline("[**Docs**](https://example.com/a?b=1)"), [
    { kind: "link", url: "https://example.com/a?b=1", children: [{ kind: "strong", children: [{ kind: "text", text: "Docs" }] }] },
  ]);
});

test("snake_case words and code spans are not italics", () => {
  assert.deepEqual(parseInline("call my_long_name now"), [{ kind: "text", text: "call my_long_name now" }]);
  assert.deepEqual(parseInline("`a *b* c`"), [{ kind: "code", text: "a *b* c" }]);
  assert.deepEqual(parseInline("2 * 3 * 4"), [{ kind: "text", text: "2 * 3 * 4" }]);
});

test("only http and https addresses become links", () => {
  assert.equal(safeWebUrl("https://example.com"), "https://example.com/");
  assert.equal(safeWebUrl("http://localhost:3000/x"), "http://localhost:3000/x");
  for (const bad of ["javascript:alert(1)", "JaVaScRiPt:alert(1)", "file:///etc/passwd", "data:text/html,<b>x</b>", "vbscript:x", "/relative", "mailto:a@b.c", "not a url"]) {
    assert.equal(safeWebUrl(bad), null, bad);
  }
  assert.deepEqual(parseInline("[click](javascript:alert(1))"), [
    { kind: "link", url: null, children: [{ kind: "text", text: "click" }] },
    { kind: "text", text: ")" },
  ]);
});

// ── Rendering ─────────────────────────────────────────────────────────────────

test("markup in an answer is shown as text, never parsed", () => {
  const root = dom.root();
  const evil = '<img src=x onerror="alert(1)"> **<script>alert(2)</script>**\n```\n<b>code</b>\n```';
  renderMarkdown(root, evil); // fakedom throws if anything touches innerHTML
  assert.equal(root.find("IMG").length, 0);
  assert.equal(root.find("SCRIPT").length, 0);
  assert.equal(root.find("B").length, 0);
  assert.match(root.textContent, /<img src=x onerror="alert\(1\)">/);
  assert.equal(root.find("STRONG")[0].textContent, "<script>alert(2)</script>");
  assert.equal(root.find("PRE")[0].textContent, "<b>code</b>");
});

test("each block becomes its own element", () => {
  const root = dom.root();
  renderMarkdown(root, "## Answer\n\nHere:\n\n- **item 1**\n- item 2\n\n> note\n\n---\n\n```js\nx()\n```");
  const classes = root.children.map((c) => c.className);
  assert.deepEqual(classes, ["md-h md-h1", "md-p", "md-item", "md-item", "md-quote", "md-rule", "md-pre"]);
  assert.equal(root.find(".md-bullet")[0].textContent, "•");
  assert.equal(root.find(".md-copy").length, 1);
  // Rendering again replaces, it never appends.
  renderMarkdown(root, "plain");
  assert.equal(root.children.length, 1);
});

test("a web link opens through Rust; anything else is plain text", () => {
  const root = dom.root();
  renderMarkdown(root, "See [the docs](https://example.com/docs) or [this](file:///etc/passwd).");
  const links = root.find("A");
  assert.equal(links.length, 1);
  assert.equal(links[0].getAttribute("href"), "https://example.com/docs");
  const event = links[0].fire("click");
  assert.equal(event.defaultPrevented, true);
  assert.deepEqual(sent("open_url"), [{ url: "https://example.com/docs" }]);
  assert.match(root.textContent, /or this\.$/);
});
