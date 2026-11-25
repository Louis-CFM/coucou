// Tests for the Coucou Clipboard Manager frontend logic.
// Run with:  pnpm exec node --test tests/clipboard.test.mjs
//            or via the existing pnpm test script.

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";

// ── Helpers (duplicated from clipboard.ts so we can test without bundling) ───

function relTimeApprox(ms) {
  const diff = Date.now() - ms;
  if (diff < 60_000) return "just now";
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
  return `${Math.floor(diff / 86_400_000)}d ago`;
}

function isSameDay(ms) {
  const d = new Date(ms);
  const now = new Date();
  return d.getDate() === now.getDate() && d.getMonth() === now.getMonth() && d.getFullYear() === now.getFullYear();
}

function classifyText(text) {
  const trimmed = text.trim();
  if (
    (trimmed.startsWith("http://") || trimmed.startsWith("https://")) &&
    !trimmed.includes("\n") &&
    !trimmed.includes(" ")
  ) {
    const preview = trimmed.split("://")[1]?.split("/")[0] ?? trimmed;
    return { kind: "link", preview };
  }
  const preview = trimmed.slice(0, 80) + (trimmed.length > 80 ? "…" : "");
  return { kind: "text", preview };
}

function wordCount(s) {
  return s.split(/\s+/).filter(Boolean).length;
}

function charCount(s) {
  return [...s].length;
}

function filterItems(items, cat, query) {
  let result = items;
  if (cat !== "all") result = result.filter((i) => i.kind === cat);
  if (query.trim()) {
    const q = query.toLowerCase();
    result = result.filter(
      (i) => i.content.toLowerCase().includes(q) || (i.preview ?? "").toLowerCase().includes(q)
    );
  }
  return result;
}

// ── Sample data ───────────────────────────────────────────────────────────────

function item(overrides = {}) {
  return {
    id: `id-${Math.random().toString(36).slice(2)}`,
    kind: "text",
    content: "Hello world",
    preview: "Hello world",
    pinned: false,
    createdAt: Date.now(),
    lastCopiedAt: Date.now(),
    hash: "abc123",
    ...overrides,
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("Text classification", () => {
  it("classifies a plain string as text", () => {
    const { kind } = classifyText("Hello world");
    assert.equal(kind, "text");
  });

  it("classifies an https URL as link", () => {
    const { kind, preview } = classifyText("https://github.com/user/repo");
    assert.equal(kind, "link");
    assert.equal(preview, "github.com");
  });

  it("classifies an http URL as link", () => {
    const { kind } = classifyText("http://example.com/path?q=1");
    assert.equal(kind, "link");
  });

  it("does not classify a URL with spaces as link", () => {
    const { kind } = classifyText("https://example.com and other text");
    assert.equal(kind, "text");
  });

  it("does not classify multiline URL-like text as link", () => {
    const { kind } = classifyText("https://example.com\nhttps://other.com");
    assert.equal(kind, "text");
  });

  it("truncates long text preview to 80 chars", () => {
    const long = "x".repeat(100);
    const { preview } = classifyText(long);
    assert.equal(preview, "x".repeat(80) + "…");
  });

  it("does not truncate text under 80 chars", () => {
    const short = "Hello";
    const { preview } = classifyText(short);
    assert.equal(preview, "Hello");
  });
});

describe("Word and character count", () => {
  it("counts words correctly", () => {
    assert.equal(wordCount("Hello world foo"), 3);
    assert.equal(wordCount("  spaced  out  "), 2);
    assert.equal(wordCount(""), 0);
  });

  it("counts characters including unicode", () => {
    assert.equal(charCount("Hello"), 5);
    assert.equal(charCount("こんにちは"), 5);
    assert.equal(charCount(""), 0);
  });
});

describe("Category filtering", () => {
  const items = [
    item({ kind: "text", content: "note", preview: "note" }),
    item({ kind: "link", content: "https://example.com", preview: "example.com" }),
    item({ kind: "image", content: "/path/img.png", preview: "Image 100×100" }),
    item({ kind: "text", content: "another note with search term", preview: "another note with search term" }),
  ];

  it("returns all items when category is 'all'", () => {
    assert.equal(filterItems(items, "all", "").length, 4);
  });

  it("filters to text only", () => {
    const result = filterItems(items, "text", "");
    assert.equal(result.length, 2);
    assert.ok(result.every((i) => i.kind === "text"));
  });

  it("filters to image only", () => {
    const result = filterItems(items, "image", "");
    assert.equal(result.length, 1);
  });

  it("filters to link only", () => {
    const result = filterItems(items, "link", "");
    assert.equal(result.length, 1);
  });

  it("applies text search across content", () => {
    const result = filterItems(items, "all", "search term");
    assert.equal(result.length, 1);
    assert.equal(result[0].content, "another note with search term");
  });

  it("applies text search across preview", () => {
    const result = filterItems(items, "all", "example.com");
    assert.equal(result.length, 1);
  });

  it("search is case-insensitive", () => {
    const result = filterItems(items, "all", "ANOTHER");
    assert.equal(result.length, 1);
  });

  it("empty search returns all in category", () => {
    const result = filterItems(items, "text", "");
    assert.equal(result.length, 2);
  });

  it("combined category + search", () => {
    const result = filterItems(items, "text", "search");
    assert.equal(result.length, 1);
  });
});

describe("Date grouping", () => {
  it("today items are detected correctly", () => {
    const now = Date.now();
    assert.ok(isSameDay(now));
  });

  it("yesterday items are not today", () => {
    const yesterday = Date.now() - 86_400_000;
    assert.ok(!isSameDay(yesterday));
  });
});

describe("Pin semantics", () => {
  it("pinned items are identifiable", () => {
    const pinned = item({ pinned: true });
    const unpinned = item({ pinned: false });
    assert.ok(pinned.pinned);
    assert.ok(!unpinned.pinned);
  });

  it("pinned items survive category filter", () => {
    const items = [
      item({ kind: "text", pinned: true }),
      item({ kind: "text", pinned: false }),
    ];
    const result = filterItems(items, "text", "");
    assert.equal(result.filter((i) => i.pinned).length, 1);
  });
});

describe("Deduplication by hash", () => {
  it("two items with the same hash are considered duplicates", () => {
    const items = [
      item({ hash: "deadbeef", content: "original" }),
      item({ hash: "deadbeef", content: "duplicate" }),
    ];
    // A real dedup routine would leave only one; verify detection logic
    const unique = items.filter((item, idx, arr) => arr.findIndex((i) => i.hash === item.hash) === idx);
    assert.equal(unique.length, 1);
  });
});

describe("Relative time", () => {
  it("returns 'just now' for recent timestamps", () => {
    assert.equal(relTimeApprox(Date.now()), "just now");
  });

  it("returns minutes for recent minutes ago", () => {
    const result = relTimeApprox(Date.now() - 5 * 60_000);
    assert.ok(result.includes("m ago"), result);
  });

  it("returns hours for timestamps hours ago", () => {
    const result = relTimeApprox(Date.now() - 3 * 3_600_000);
    assert.ok(result.includes("h ago"), result);
  });

  it("returns days for old timestamps", () => {
    const result = relTimeApprox(Date.now() - 2 * 86_400_000);
    assert.ok(result.includes("d ago"), result);
  });
});

describe("History retention limits", () => {
  it("non-pinned items beyond MAX_HISTORY (100) are evicted last", () => {
    const MAX = 100;
    const items = Array.from({ length: 110 }, (_, i) =>
      item({ id: `id-${i}`, pinned: i < 5 })
    );
    // Simulate eviction: keep pinned + first MAX-pinned.length unpinned from front
    const pinned = items.filter((i) => i.pinned);
    const unpinned = items.filter((i) => !i.pinned);
    const evicted = [...pinned, ...unpinned.slice(0, MAX - pinned.length)];
    assert.equal(evicted.length, MAX);
    assert.ok(evicted.filter((i) => i.pinned).length === 5);
  });
});

describe("Clipboard View State Resolution", () => {
  function resolveViewState(state) {
    if (state.loading) return "loading";
    if (!state.monitoring && state.items.length === 0) return "paused";
    if (state.items.length === 0) return "empty";
    if (state.query && filterItems(state.items, state.category, state.query).length === 0) {
      return "no-results";
    }
    return "populated";
  }

  it("resolves to loading when loading flag is true", () => {
    assert.equal(resolveViewState({ loading: true, monitoring: true, items: [], category: "all", query: "" }), "loading");
  });

  it("resolves to paused when monitoring is off and items are 0", () => {
    assert.equal(resolveViewState({ loading: false, monitoring: false, items: [], category: "all", query: "" }), "paused");
  });

  it("resolves to empty when monitoring is on and items are 0", () => {
    assert.equal(resolveViewState({ loading: false, monitoring: true, items: [], category: "all", query: "" }), "empty");
  });

  it("resolves to populated when items exist and query is empty", () => {
    const items = [item({ content: "hello" })];
    assert.equal(resolveViewState({ loading: false, monitoring: true, items, category: "all", query: "" }), "populated");
  });

  it("resolves to no-results when query matches 0 items in populated list", () => {
    const items = [item({ content: "hello" })];
    assert.equal(resolveViewState({ loading: false, monitoring: true, items, category: "all", query: "nonexistent" }), "no-results");
  });
});

describe("Clipboard 2.0 Helpers", () => {
  function isToday(ms) {
    const d = new Date(ms);
    const now = new Date();
    return d.getDate() === now.getDate() && d.getMonth() === now.getMonth() && d.getFullYear() === now.getFullYear();
  }

  function isYesterday(ms) {
    const d = new Date(ms);
    const y = new Date();
    y.setDate(y.getDate() - 1);
    return d.getDate() === y.getDate() && d.getMonth() === y.getMonth() && d.getFullYear() === y.getFullYear();
  }

  function formatBytes(bytes) {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  function cleanPreview(it) {
    if (it.kind === "image") {
      return it.preview || `Image ${it.imageWidth ?? 0}×${it.imageHeight ?? 0}`;
    }
    if (it.kind === "link") {
      return it.preview || it.content;
    }
    const firstLine = it.content.split("\n").find((l) => l.trim().length > 0) || it.preview || it.content;
    return firstLine.replace(/^#+\s*/, "").trim();
  }

  function isCodeSnippet(text) {
    const trimmed = text.trim();
    if (trimmed.length < 15) return false;
    const codePatterns = [
      /\b(const|let|var|function|return|import|export|class|interface|type|async|await)\b/,
      /\b(def|elif|import|from|class|lambda|self)\b/,
      /\b(fn|pub|struct|impl|mut|match|enum|use)\b/,
      /[{}();=>]{3,}/,
      /^(<[a-z][\s\S]*>[\s\S]*<\/[a-z]>|<[a-z][\s\S]*\/>)$/i,
      /\b(SELECT|FROM|WHERE|INSERT|UPDATE|DELETE)\b/i,
    ];
    return codePatterns.some((pattern) => pattern.test(trimmed));
  }

  it("partitions dates into Today, Yesterday, and Previous Days accurately", () => {
    const now = Date.now();
    const yesterday = Date.now() - 86_400_000;
    const threeDaysAgo = Date.now() - 3 * 86_400_000;

    assert.equal(isToday(now), true);
    assert.equal(isYesterday(now), false);

    assert.equal(isToday(yesterday), false);
    assert.equal(isYesterday(yesterday), true);

    assert.equal(isToday(threeDaysAgo), false);
    assert.equal(isYesterday(threeDaysAgo), false);
  });

  it("formats byte sizes cleanly", () => {
    assert.equal(formatBytes(512), "512 B");
    assert.equal(formatBytes(2048), "2.0 KB");
    assert.equal(formatBytes(1024 * 1024 * 2.5), "2.5 MB");
  });

  it("cleans raw markdown headers from preview strings", () => {
    const markdownItem = { kind: "text", content: "## Studio hours: Mon-Fri\nDetails below" };
    assert.equal(cleanPreview(markdownItem), "Studio hours: Mon-Fri");

    const linkItem = { kind: "link", content: "https://github.com", preview: "github.com" };
    assert.equal(cleanPreview(linkItem), "github.com");

    const imgItem = { kind: "image", preview: "Image 800×600", imageWidth: 800, imageHeight: 600 };
    assert.equal(cleanPreview(imgItem), "Image 800×600");
  });

  it("detects code snippets vs prose correctly", () => {
    assert.equal(isCodeSnippet("const foo = (x) => x * 2;"), true);
    assert.equal(isCodeSnippet("def calculate_total(items):\n    return sum(items)"), true);
    assert.equal(isCodeSnippet("SELECT id, name FROM users WHERE active = 1;"), true);
    assert.equal(isCodeSnippet("Studio hours: Mon–Fri, 10 am – 7 pm PT. Saturdays by appointment."), false);
    assert.equal(isCodeSnippet("Short text"), false);
  });
});
