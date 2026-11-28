/**
 * Raw FTS index tests.
 *
 * Covers:
 * 1. Secret masking — indexed text must never contain the raw secret.
 * 2. Hook isolation — brain-prompt.js only reads fts.db, never raw.db.
 * 3. Session exclusion — sessions from ~/CoucouBrain/ path are skipped.
 * 4. Search deduplication — single-word query returns at most one result per conversation.
 */
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import Database from "better-sqlite3";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { rebuildRawIndex, searchRaw, rawDbPath } from "../src/rawindex.js";
import type { BrainConfig } from "../src/config.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Create a temp brain config.
 * IMPORTANT: use a prefix without hyphens so the encoded project path
 * round-trips correctly through decodeClaudeProjectPath (hyphens → slashes).
 */
function tmpConfig(): { config: BrainConfig; dir: string } {
  // "rawtest" has no hyphens → encodes/decodes cleanly to /tmp/rawtestXXXXXX
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rawtest"));
  const config: BrainConfig = {
    brainPath: dir,
    claudeProjectsPath: path.join(dir, "fake-claude-projects"),
    repoPaths: [],
    chunkModel: "claude-haiku-4-5-20251001",
    mergeModel: "claude-opus-4-6",
    maxChunkTokens: 100000,
    language: "fr",
    repoAliases: {},
    // 0 → no active-session guard; test files are always < 30 min old
    activeSessionMinutes: 0,
  };
  fs.mkdirSync(config.claudeProjectsPath!, { recursive: true });
  return { config, dir };
}

/** Write a minimal JSONL session file so readSession() can parse it. */
function writeSession(
  claudeProjectsPath: string,
  projectSlug: string,
  sessionId: string,
  messages: Array<{ role: "human" | "assistant"; text: string }>
): void {
  const projDir = path.join(claudeProjectsPath, projectSlug);
  fs.mkdirSync(projDir, { recursive: true });
  const lines = messages.map((m) =>
    JSON.stringify({
      type: m.role === "human" ? "user" : "assistant",
      message: {
        role: m.role,
        content: [{ type: "text", text: m.text }],
      },
    })
  );
  fs.writeFileSync(path.join(projDir, `${sessionId}.jsonl`), lines.join("\n") + "\n", "utf8");
}

/** Encode an absolute path to a Claude project directory name (inverse of decodeClaudeProjectPath). */
function encodeProjectPath(absPath: string): string {
  return "-" + absPath.slice(1).replace(/\//g, "-");
}

// ── 1. Secret masking ─────────────────────────────────────────────────────────

describe("secret masking in raw index", () => {
  let dir: string;
  let config: BrainConfig;

  beforeEach(() => {
    ({ config, dir } = tmpConfig());
  });

  afterEach(() => {
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch {}
  });

  it("Anthropic API key (sk-ant-…) is masked — not stored in raw.db", () => {
    // Key constructed at runtime — never hardcoded in repo
    const keyBody = "A".repeat(20) + "-" + "B".repeat(15) + "-" + "C".repeat(10) + "AA";
    const fakeKey = "sk-ant-api03-" + keyBody;

    writeSession(config.claudeProjectsPath!, "-proj-secret-test", "sess-secret-01", [
      { role: "human", text: `Use this key: ${fakeKey}` },
      { role: "assistant", text: "Got it, using that key." },
    ]);

    rebuildRawIndex(config);

    const db = new Database(rawDbPath(config), { readonly: true });
    const rows = db.prepare("SELECT text FROM raw_messages").all() as Array<{ text: string }>;
    db.close();

    expect(rows.length).toBeGreaterThan(0);
    const allText = rows.map((r) => r.text).join("\n");
    expect(allText, "Raw secret must not appear in index").not.toContain(fakeKey);
    // mask.ts replaces with [MASQUÉ:<type>]
    expect(allText, "Masked placeholder must be present").toContain("[MASQUÉ:api-key-anthropic]");
  });

  it("ENV-style secret (KEY=value) is masked", () => {
    const secretValue = "MYSECRET" + Math.random().toString(36).slice(2).toUpperCase();
    writeSession(config.claudeProjectsPath!, "-proj-env-test", "sess-env-01", [
      { role: "human", text: `Config:\nAPI_SECRET=${secretValue}\nHelp me debug.` },
    ]);

    rebuildRawIndex(config);

    const db = new Database(rawDbPath(config), { readonly: true });
    const rows = db.prepare("SELECT text FROM raw_messages").all() as Array<{ text: string }>;
    db.close();

    const allText = rows.map((r) => r.text).join("\n");
    expect(allText, "Raw secret value must not appear in index").not.toContain(secretValue);
  });
});

// ── 2. Hook isolation ─────────────────────────────────────────────────────────

describe("hook isolation — brain-prompt.js never reads raw.db", () => {
  it("brain-prompt.js references fts_elements (LLM index), not raw_messages", () => {
    const src = fs.readFileSync(
      path.join(__dirname, "..", "hooks", "brain-prompt.js"),
      "utf8"
    );
    expect(src, "Hook must query fts_elements table").toContain("fts_elements");
    expect(src, "Hook must not access raw_messages table").not.toContain("raw_messages");
    expect(src, "Hook must not open raw.db").not.toContain("raw.db");
  });

  it("brain-session-start.js does not reference raw.db", () => {
    const src = fs.readFileSync(
      path.join(__dirname, "..", "hooks", "brain-session-start.js"),
      "utf8"
    );
    expect(src, "Session-start hook must not access raw.db").not.toContain("raw.db");
    expect(src, "Session-start hook must not access raw_messages").not.toContain("raw_messages");
  });
});

// ── 3. Session exclusion from brainPath ───────────────────────────────────────

describe("session exclusion from brainPath", () => {
  let dir: string;
  let config: BrainConfig;

  beforeEach(() => {
    ({ config, dir } = tmpConfig());
  });

  afterEach(() => {
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch {}
  });

  it("sessions with decoded project path inside brainPath are NOT indexed", () => {
    // Session inside brainPath — encodes the brainPath itself as project dir
    // e.g. brainPath = /tmp/rawtestXXX → encoded = -tmp-rawtestXXX
    const brainEncoded = encodeProjectPath(dir);
    writeSession(config.claudeProjectsPath!, brainEncoded, "sess-brain-internal", [
      { role: "human", text: "Internal brain digestion — should be excluded." },
    ]);

    // Normal session outside brainPath
    writeSession(config.claudeProjectsPath!, "-proj-normal", "sess-normal", [
      { role: "human", text: "Normal user session — should be indexed." },
    ]);

    rebuildRawIndex(config);

    const db = new Database(rawDbPath(config), { readonly: true });
    const rows = db
      .prepare("SELECT conv_id FROM raw_messages")
      .all() as Array<{ conv_id: string }>;
    db.close();

    const ids = rows.map((r) => r.conv_id);
    expect(ids, "Normal session should be indexed").toContain("sess-normal");
    expect(ids, "Brain-internal session must be excluded").not.toContain("sess-brain-internal");
  });
});

// ── 4. Search: total count + deduplication + pagination ──────────────────────

describe("search total, deduplication, pagination", () => {
  let dir: string;
  let config: BrainConfig;

  beforeEach(() => {
    ({ config, dir } = tmpConfig());
  });

  afterEach(() => {
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch {}
  });

  it("total equals SQL COUNT(DISTINCT conv_id)", () => {
    for (let i = 1; i <= 5; i++) {
      writeSession(config.claudeProjectsPath!, `-proj-${i}`, `sess-${i}`, [
        { role: "human", text: `unique keyword xqztest session ${i} configuration deployment` },
      ]);
    }
    // 2 noise sessions without the keyword
    for (let i = 6; i <= 7; i++) {
      writeSession(config.claudeProjectsPath!, `-proj-${i}`, `sess-${i}`, [
        { role: "human", text: `unrelated deployment configuration plan ${i}` },
      ]);
    }

    rebuildRawIndex(config);

    const dbPath = rawDbPath(config);
    const db = new Database(dbPath, { readonly: true });
    const sqlCount = (db
      .prepare("SELECT COUNT(DISTINCT conv_id) as n FROM raw_messages WHERE raw_messages MATCH 'xqztest*'")
      .get() as { n: number }).n;
    db.close();

    const { total } = searchRaw(config, "xqztest", 10);
    expect(total, "searchRaw total must match SQL COUNT(DISTINCT conv_id)").toBe(sqlCount);
    expect(total).toBe(5);
  });

  it("each conversation appears at most once (GROUP BY in SQL)", () => {
    // Each session has 10 messages mentioning the keyword → test SQL GROUP BY
    for (let i = 1; i <= 3; i++) {
      const msgs = Array.from({ length: 10 }, (_, j) => ({
        role: (j % 2 === 0 ? "human" : "assistant") as "human" | "assistant",
        text: `groupbytest session ${i} message ${j} widget`,
      }));
      writeSession(config.claudeProjectsPath!, `-proj-grp-${i}`, `sess-grp-${i}`, msgs);
    }

    rebuildRawIndex(config);

    const { results } = searchRaw(config, "groupbytest widget", 10);
    const ids = results.map((r) => r.convId);
    expect(new Set(ids).size, "Each conversation appears once").toBe(ids.length);
    expect(results.length).toBe(3);
  });

  it("--offset paginates correctly", () => {
    for (let i = 1; i <= 5; i++) {
      writeSession(config.claudeProjectsPath!, `-proj-page-${i}`, `sess-page-${i}`, [
        { role: "human", text: `paginatetest topic configuration session ${i}` },
      ]);
    }
    // 3 noise sessions
    for (let i = 6; i <= 8; i++) {
      writeSession(config.claudeProjectsPath!, `-proj-noise-${i}`, `sess-noise-${i}`, [
        { role: "human", text: `unrelated deployment plan ${i}` },
      ]);
    }

    rebuildRawIndex(config);

    const page1 = searchRaw(config, "paginatetest", 3, 0);
    const page2 = searchRaw(config, "paginatetest", 3, 3);

    expect(page1.total).toBe(5);
    expect(page2.total).toBe(5);
    expect(page1.results.length).toBe(3);
    expect(page2.results.length).toBe(2);

    // No overlap between pages
    const ids1 = new Set(page1.results.map((r) => r.convId));
    const ids2 = page2.results.map((r) => r.convId);
    for (const id of ids2) {
      expect(ids1.has(id), `${id} should not appear in page 1`).toBe(false);
    }
  });
});
