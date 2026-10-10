// Live diff engine (src/core/diff.ts) — port of tests/DiffEngineTests.swift,
// plus the tool-input glue (buildFileDiff) HookServer.swift does on macOS.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  DIFF_MAX_LINES, buildFileDiff, fileName, fromEdit, fromNew, isDiffStep, lastTextStep,
  makeDiffStep, parseDiffStep, toOneLine,
} from "../src/core/diff.ts";

const allLines = (d) => d.hunks.flatMap((h) => h.lines);

test("fromEdit — additions", () => {
  const d = fromEdit("", "hello\nworld\n", "/a/b.swift");
  assert.equal(d.added, 2);
  assert.equal(d.removed, 0);
  assert.equal(d.tooLarge, false);
  assert.equal(d.hunks.length, 1);
  assert.equal(fileName(d.path), "b.swift");
});

test("fromEdit — removals", () => {
  const d = fromEdit("hello\nworld\n", "", "/x.py");
  assert.equal(d.added, 0);
  assert.equal(d.removed, 2);
  assert.equal(d.hunks.length, 1);
});

test("fromEdit — replacement keeps context lines", () => {
  const d = fromEdit("foo\nbar\nbaz\n", "foo\nqux\nbaz\n", "/f.ts");
  assert.equal(d.added, 1);
  assert.equal(d.removed, 1);
  assert.ok(d.hunks[0].lines.some((l) => l.kind === "context"));
  assert.deepEqual(
    d.hunks[0].lines.map((l) => [l.kind, l.text, l.origLine, l.newLine]),
    [
      ["context", "foo", 1, 1],
      ["removed", "bar", 2, -1],
      ["added", "qux", -1, 2],
      ["context", "baz", 3, 3],
    ],
  );
});

test("fromNew — new file, every line added", () => {
  const d = fromNew("line1\nline2\nline3\n", "/new.rs");
  assert.equal(d.added, 3);
  assert.equal(d.removed, 0);
  assert.equal(d.isNewFile, true);
  assert.ok(allLines(d).every((l) => l.kind === "added"));
});

test("fromEdit — two separate edits of a MultiEdit", () => {
  const d1 = fromEdit("aaa\n", "bbb\n", "/m.kt");
  const d2 = fromEdit("ccc\n", "ddd\n", "/m.kt");
  assert.deepEqual([d1.added, d1.removed, d2.added, d2.removed], [1, 1, 1, 1]);
});

test("tooLarge past 200 KB: counts only, no hunks", () => {
  const d = fromEdit("x".repeat(150 * 1024), "y".repeat(60 * 1024), "/big.swift");
  assert.equal(d.tooLarge, true);
  assert.deepEqual(d.hunks, []);
  assert.equal(d.added, 1);
  assert.equal(d.removed, 1);
});

test("the 200 KB guard counts UTF-8 bytes, not characters", () => {
  const d = fromEdit("é".repeat(60 * 1024), "è".repeat(60 * 1024), "/accents.txt");
  assert.equal(d.tooLarge, true);
});

test("CRLF is normalised", () => {
  const d = fromEdit("a\r\nb\r\n", "a\r\nc\r\n", "/win.txt");
  assert.equal(d.added, 1);
  assert.equal(d.removed, 1);
});

test("no trailing newline", () => {
  const d = fromEdit("hello", "hello\nworld", "/t.txt");
  assert.equal(d.added, 1);
  assert.equal(d.removed, 0);
});

test("3 lines of context around a change", () => {
  const lines = Array.from({ length: 10 }, (_, i) => `line${i + 1}`);
  const changed = lines.map((l, i) => (i === 4 ? "changed" : l));
  const d = fromEdit(`${lines.join("\n")}\n`, `${changed.join("\n")}\n`, "/ctx.swift");
  assert.equal(d.added, 1);
  assert.equal(d.removed, 1);
  assert.equal(d.hunks.length, 1);
  const context = d.hunks[0].lines.filter((l) => l.kind === "context");
  assert.equal(context.length, 6);
  assert.equal(d.hunks[0].origStart, 2);
  assert.equal(d.hunks[0].newStart, 2);
});

test("distant changes make separate hunks", () => {
  const lines = Array.from({ length: 30 }, (_, i) => `l${i}`);
  const changed = lines.map((l, i) => (i === 2 || i === 25 ? `${l}!` : l));
  const d = fromEdit(lines.join("\n"), changed.join("\n"), "/two.ts");
  assert.equal(d.hunks.length, 2);
  assert.equal(d.added, 2);
  assert.equal(d.removed, 2);
});

test("m·n > 1 000 000 → tooLarge before the quadratic table", () => {
  const many = Array.from({ length: 1001 }, (_, i) => `line${i}`).join("\n");
  const d = fromEdit(many, `${many}\nextra`, "/big.swift");
  assert.equal(d.tooLarge, true);
  assert.deepEqual(d.hunks, []);
});

test("fromNew — too large keeps the line count", () => {
  const d = fromNew("x\n".repeat(DIFF_MAX_LINES + 1), "/new.swift");
  assert.equal(d.tooLarge, true);
  assert.equal(d.isNewFile, true);
  assert.deepEqual(d.hunks, []);
  assert.ok(d.added > 0);
});

test("makeDiffStep / parseDiffStep round-trip", () => {
  const s = makeDiffStep("foo.swift", 3, 1, 7);
  assert.ok(isDiffStep(s));
  assert.deepEqual(parseDiffStep(s), { filename: "foo.swift", added: 3, removed: 1, diffId: 7 });
  assert.equal(parseDiffStep(makeDiffStep("bar.ts", 0, 2, 42))?.diffId, 42);
  assert.equal(isDiffStep("Edit foo.swift"), false);
  assert.equal(parseDiffStep("Edit foo.swift"), null);
  assert.equal(parseDiffStep("\uE001no-tab"), null);
  assert.equal(parseDiffStep("\uE001f\t1:2"), null);
  assert.equal(parseDiffStep("\uE001f\t1:2:x"), null);
});

test("lastTextStep skips diff markers", () => {
  assert.equal(lastTextStep(["Reads · a.ts", makeDiffStep("a.ts", 1, 0, 1)]), "Reads · a.ts");
  assert.equal(lastTextStep([makeDiffStep("a.ts", 1, 0, 1)]), undefined);
  assert.equal(lastTextStep([]), undefined);
});

test("toOneLine", () => {
  assert.equal(toOneLine("line one\nline two\nline three"), "line one line two line three");
  assert.equal(toOneLine("**hello** world"), "hello world");
  assert.equal(toOneLine("## My Title\nsome text"), "My Title some text");
  assert.equal(toOneLine(""), "");
  assert.ok(toOneLine("x ".repeat(200), 10).length <= 10);
  assert.equal(toOneLine("First para.\n\nSecond para."), "First para.");
  assert.equal(
    toOneLine("Done. Single commit 450a657 on github-pulse.\n\n---\n\nFiles touched (7)…"),
    "Done. Single commit 450a657 on github-pulse.",
  );
  assert.equal(toOneLine("Summary line.\n***\nMore details."), "Summary line.");
  assert.equal(toOneLine("Result:\n| Col1 | Col2 |\n|---|---|\n| A | B |"), "Result:");
  assert.equal(toOneLine("- item one\n- item two"), "item one item two");
  assert.equal(toOneLine("* first\n* second"), "first second");
  assert.equal(toOneLine("1. step one\n2. step two"), "step one step two");
  assert.equal(toOneLine("\n\nActual content."), "Actual content.");
  // Windows line endings split paragraphs too.
  assert.equal(toOneLine("Fixed `it`.\r\n\r\nDetails"), "Fixed it.");
});

test("buildFileDiff — Edit", () => {
  const d = buildFileDiff("Edit", { file_path: "C:\\p\\a.ts", old_string: "a\nb", new_string: "a\nc\nd" });
  assert.equal(fileName(d.path), "a.ts");
  assert.deepEqual([d.added, d.removed, d.isNewFile], [2, 1, false]);
  // Nothing changed, nothing given, or not a string: no diff.
  assert.equal(buildFileDiff("Edit", { file_path: "/a", old_string: "x", new_string: "x" }), null);
  assert.equal(buildFileDiff("Edit", { file_path: "/a", old_string: "", new_string: "" }), null);
  assert.equal(buildFileDiff("Edit", { old_string: "x", new_string: "y" }), null);
  assert.equal(buildFileDiff("Edit", { file_path: "/a", old_string: 1, new_string: "y" }), null);
});

test("buildFileDiff — MultiEdit sums its edits", () => {
  const d = buildFileDiff("MultiEdit", {
    file_path: "/p/m.kt",
    edits: [
      { old_string: "aaa", new_string: "bbb" },
      { old_string: "ccc", new_string: "ddd\neee" },
      { old_string: 3 },
      null,
    ],
  });
  assert.deepEqual([d.added, d.removed, d.hunks.length], [3, 2, 2]);
  assert.equal(buildFileDiff("MultiEdit", { file_path: "/p/m.kt", edits: [] }), null);
  assert.equal(buildFileDiff("MultiEdit", { file_path: "/p/m.kt" }), null);
});

test("buildFileDiff — Write and other tools", () => {
  const d = buildFileDiff("Write", { file_path: "/p/n.md", content: "# Hi\n\nThere\n" });
  assert.deepEqual([d.added, d.removed, d.isNewFile], [3, 0, true]);
  assert.equal(buildFileDiff("Write", { file_path: "/p/n.md", content: "" }), null);
  assert.equal(buildFileDiff("Bash", { command: "ls" }), null);
  assert.equal(buildFileDiff("Read", { file_path: "/p/n.md" }), null);
});

test("buildFileDiff — Antigravity replace_file_content and write_to_file", () => {
  const d1 = buildFileDiff("replace_file_content", {
    file_path: "C:\\p\\a.ts",
    old_string: "a\nb",
    new_string: "a\nc\nd",
  });
  assert.equal(fileName(d1.path), "a.ts");
  assert.deepEqual([d1.added, d1.removed, d1.isNewFile], [2, 1, false]);

  // Raw Antigravity field names
  const d2 = buildFileDiff("replace_file_content", {
    TargetFile: "/p/b.rs",
    TargetContent: "fn old() {}",
    ReplacementContent: "fn new() {\n  println!();\n}",
  });
  assert.equal(fileName(d2.path), "b.rs");
  assert.deepEqual([d2.added, d2.removed, d2.isNewFile], [3, 1, false]);

  const d3 = buildFileDiff("write_to_file", {
    TargetFile: "/p/new.txt",
    CodeContent: "hello\nworld\n",
  });
  assert.equal(fileName(d3.path), "new.txt");
  assert.deepEqual([d3.added, d3.removed, d3.isNewFile], [2, 0, true]);
});
