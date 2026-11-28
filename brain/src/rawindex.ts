/**
 * Level 1 — Raw text FTS index.
 *
 * Stores every human + Claude message from:
 *   - Claude.ai conversations export (conversations.json / .zip)
 *   - Claude Code sessions (.jsonl files)
 *
 * No LLM. One FTS row per message → search lands at the right message.
 * Secrets are masked at index time (via readSession / formatConversationAsSessionCondensed).
 *
 * DB: ~/CoucouBrain/.state/raw.db
 *   - raw_messages  (FTS5 virtual table)
 *   - raw_manifest  (regular table, tracks what's been indexed + hash)
 */
import Database from "better-sqlite3";
import fs from "node:fs";
import path from "node:path";
import { expandHome, projectNameFromClaudePath } from "./utils.js";
import type { BrainConfig } from "./config.js";
import {
  collectClaudeExport,
  formatConversationAsSessionCondensed,
  readSession,
  discoverSessions,
} from "./collect.js";
import { buildFtsQuery } from "./fts.js";

// ── Query builder (relaxed — single word OK) ──────────────────────────────────

/**
 * Like buildFtsQuery but allows single-word queries (min 3 chars).
 * Used for interactive `brain search`, not hook injection.
 */
function buildSearchQuery(text: string): string | null {
  // Try the standard builder first (2+ significant words)
  const standard = buildFtsQuery(text);
  if (standard) return standard;

  // Fallback: single significant word (≥ 3 chars, not a stopword)
  const word = text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]/gu, "")
    .trim();
  if (word.length >= 3) {
    const clean = word.replace(/["()+\-:*^~{}]/g, "");
    if (clean.length >= 3) return clean + "*";
  }
  return null;
}

// ── Types ─────────────────────────────────────────────────────────────────────

export interface RawSearchResult {
  convId: string;
  convTitle: string;
  convDate: string;
  /** claude.ai/chat/<uuid> for desktop, empty for sessions */
  convLink: string;
  msgIndex: number;
  role: "human" | "claude";
  source: "desktop" | "session";
  /** project slug for sessions, empty for desktop */
  project: string;
  /** First 220 chars of matching message */
  excerpt: string;
  score: number;
  /** Total messages in this conversation that match the query */
  nbMentions: number;
}

// ── Paths ─────────────────────────────────────────────────────────────────────

export function rawDbPath(config: BrainConfig): string {
  return path.join(expandHome(config.brainPath), ".state", "raw.db");
}

// ── DB helpers ────────────────────────────────────────────────────────────────

function openRawDb(dbPath: string, readonly = false): Database.Database {
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const db = new Database(dbPath, readonly ? { readonly: true } : undefined);
  db.exec("PRAGMA journal_mode=WAL");

  if (!readonly) {
    db.exec(`
      CREATE VIRTUAL TABLE IF NOT EXISTS raw_messages USING fts5(
        conv_id    UNINDEXED,
        conv_title UNINDEXED,
        conv_date  UNINDEXED,
        conv_link  UNINDEXED,
        msg_index  UNINDEXED,
        role       UNINDEXED,
        source     UNINDEXED,
        project    UNINDEXED,
        text,
        tokenize='unicode61 remove_diacritics 1'
      );

      CREATE TABLE IF NOT EXISTS raw_manifest (
        conv_id    TEXT PRIMARY KEY,
        conv_hash  TEXT NOT NULL,
        source     TEXT NOT NULL,
        indexed_at TEXT NOT NULL
      );
    `);
  }

  return db;
}

// ── Rebuild (full, from scratch) ──────────────────────────────────────────────

export interface RebuildRawStats {
  conversations: number;
  sessions: number;
  messages: number;
  durationMs: number;
}

export function rebuildRawIndex(
  config: BrainConfig,
  opts: {
    claudeExportPath?: string;
    onProgress?: (msg: string) => void;
  } = {}
): RebuildRawStats {
  const dbPath = rawDbPath(config);
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });

  // Wipe and recreate
  if (fs.existsSync(dbPath)) fs.unlinkSync(dbPath);
  const t0 = Date.now();
  const db = openRawDb(dbPath);

  const insertMsg = db.prepare(`
    INSERT INTO raw_messages (conv_id, conv_title, conv_date, conv_link, msg_index, role, source, project, text)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const insertManifest = db.prepare(`
    INSERT OR REPLACE INTO raw_manifest (conv_id, conv_hash, source, indexed_at) VALUES (?, ?, ?, ?)
  `);

  let convCount = 0;
  let sessionCount = 0;
  let msgCount = 0;
  const now = new Date().toISOString();

  // ── Claude.ai conversations ─────────────────────────────────────────────────
  const exportPath =
    opts.claudeExportPath ??
    (config as BrainConfig & { claudeExportPath?: string }).claudeExportPath;

  if (exportPath) {
    const resolved = expandHome(exportPath);
    if (fs.existsSync(resolved)) {
      opts.onProgress?.("  Chargement de l'export Claude.ai…");
      try {
        const conversations = collectClaudeExport(exportPath);
        opts.onProgress?.(`  ${conversations.length} conversations trouvées`);

        db.transaction(() => {
          for (const conv of conversations) {
            const condensed = formatConversationAsSessionCondensed(conv);
            const link = `https://claude.ai/chat/${conv.uuid}`;

            for (let i = 0; i < condensed.messages.length; i++) {
              const msg = condensed.messages[i]!;
              const text = msg.text.trim();
              if (!text) continue;
              insertMsg.run(
                conv.uuid,
                condensed.projectNameHint,
                condensed.date,
                link,
                i,
                msg.role,
                "desktop",
                "",
                text
              );
              msgCount++;
            }
            insertManifest.run(conv.uuid, condensed.hash, "desktop", now);
            convCount++;
          }
        })();
      } catch (e) {
        opts.onProgress?.(`  ⚠️  Export Claude.ai ignoré : ${(e as Error).message.slice(0, 120)}`);
      }
    } else {
      opts.onProgress?.(`  ⚠️  claudeExportPath introuvable : ${resolved}`);
    }
  }

  // ── Claude Code sessions ────────────────────────────────────────────────────
  opts.onProgress?.("  Découverte des sessions Claude Code…");
  // Include active sessions (raw index, no LLM) but exclude brain-internal ones
  const discovered = discoverSessions(config, { includeSubagents: false });
  // Filter only non-active for stability; active sessions are still open
  const toIndex = discovered.filter((s) => !s.isActive);

  opts.onProgress?.(`  ${toIndex.length} sessions à indexer (${discovered.filter(s => s.isActive).length} actives ignorées)`);

  db.transaction(() => {
    for (const disc of toIndex) {
      try {
        const condensed = readSession(disc.jsonlPath);
        const projectName = projectNameFromClaudePath(disc.projectPath);

        for (let i = 0; i < condensed.messages.length; i++) {
          const msg = condensed.messages[i]!;
          const text = msg.text.trim();
          if (!text) continue;
          insertMsg.run(
            disc.id,
            condensed.projectNameHint || projectName,
            condensed.date,
            "", // no public link for local sessions
            i,
            msg.role,
            "session",
            projectName,
            text
          );
          msgCount++;
        }
        insertManifest.run(disc.id, disc.hash, "session", now);
        sessionCount++;
      } catch {
        // skip unreadable sessions silently
      }
    }
  })();

  // Optimize FTS
  db.exec("INSERT INTO raw_messages(raw_messages) VALUES('optimize')");
  db.close();

  return {
    conversations: convCount,
    sessions: sessionCount,
    messages: msgCount,
    durationMs: Date.now() - t0,
  };
}

// ── Incremental update ────────────────────────────────────────────────────────

/**
 * Index only sessions not yet in the manifest (or whose hash changed).
 * Does NOT re-index Claude.ai conversations (they require the export file).
 */
export function incrementalUpdateRaw(
  config: BrainConfig,
  opts: { onProgress?: (msg: string) => void } = {}
): { added: number; messages: number; durationMs: number } {
  const dbPath = rawDbPath(config);
  if (!fs.existsSync(dbPath)) {
    const r = rebuildRawIndex(config, opts);
    return { added: r.sessions, messages: r.messages, durationMs: r.durationMs };
  }

  const t0 = Date.now();
  const db = openRawDb(dbPath);

  const insertMsg = db.prepare(`
    INSERT INTO raw_messages (conv_id, conv_title, conv_date, conv_link, msg_index, role, source, project, text)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const upsertManifest = db.prepare(`
    INSERT OR REPLACE INTO raw_manifest (conv_id, conv_hash, source, indexed_at) VALUES (?, ?, ?, ?)
  `);
  const deleteOld = db.prepare("DELETE FROM raw_messages WHERE conv_id = ?");
  const getManifest = db.prepare("SELECT conv_hash FROM raw_manifest WHERE conv_id = ?");

  let added = 0;
  let msgCount = 0;
  const now = new Date().toISOString();

  const discovered = discoverSessions(config, { includeSubagents: false });
  const toCheck = discovered.filter((s) => !s.isActive);

  db.transaction(() => {
    for (const disc of toCheck) {
      const existing = getManifest.get(disc.id) as { conv_hash: string } | undefined;
      if (existing?.conv_hash === disc.hash) continue; // up to date

      try {
        const condensed = readSession(disc.jsonlPath);
        const projectName = projectNameFromClaudePath(disc.projectPath);

        if (existing) deleteOld.run(disc.id);

        for (let i = 0; i < condensed.messages.length; i++) {
          const msg = condensed.messages[i]!;
          const text = msg.text.trim();
          if (!text) continue;
          insertMsg.run(
            disc.id,
            condensed.projectNameHint || projectName,
            condensed.date,
            "",
            i,
            msg.role,
            "session",
            projectName,
            text
          );
          msgCount++;
        }
        upsertManifest.run(disc.id, disc.hash, "session", now);
        added++;
      } catch {
        // skip
      }
    }
  })();

  if (added > 0) {
    db.exec("INSERT INTO raw_messages(raw_messages) VALUES('optimize')");
  }
  db.close();

  return { added, messages: msgCount, durationMs: Date.now() - t0 };
}

// ── Search ────────────────────────────────────────────────────────────────────

export interface RawSearchResponse {
  results: RawSearchResult[];
  /** Total distinct conversations matching the query (no threshold). */
  total: number;
}

/**
 * Search the raw FTS index.
 *
 * FTS5 auxiliary functions (bm25) cannot be used in GROUP BY or window
 * functions. We instead fetch all matching rows in one pass, deduplicate
 * by conv_id in JS (best-scoring message wins), then sort and paginate.
 *
 * No BM25 threshold — every conversation containing a query term is returned.
 * `total` is the count of distinct matching conversations (before pagination).
 */
export function searchRaw(
  config: BrainConfig,
  query: string,
  limit = 10,
  offset = 0,
  sourceFilter?: "desktop" | "session"
): RawSearchResponse {
  const dbPath = rawDbPath(config);
  if (!fs.existsSync(dbPath)) return { results: [], total: 0 };

  const ftsQuery = buildSearchQuery(query);
  if (!ftsQuery) return { results: [], total: 0 };

  let db: Database.Database | null = null;
  try {
    db = new Database(dbPath, { readonly: true });

    type Row = {
      conv_id: string;
      conv_title: string;
      conv_date: string;
      conv_link: string;
      source: string;
      project: string;
      text: string;
      msg_index: number;
      role: string;
      score: number;
    };

    // Single pass: all matching rows, ordered by score (best first).
    // bm25() returns negative values; more negative = better match.
    const allRows = db
      .prepare(
        `SELECT conv_id, conv_title, conv_date, conv_link, source, project,
                text, msg_index, role,
                bm25(raw_messages) as score
         FROM raw_messages
         WHERE raw_messages MATCH ?
         ORDER BY bm25(raw_messages) ASC`
      )
      .all(ftsQuery) as Row[];

    // Apply optional source filter
    const rows = sourceFilter
      ? allRows.filter((r) => r.source === sourceFilter)
      : allRows;

    // Count matching messages per conversation (after source filter)
    const mentionsByConv = new Map<string, number>();
    for (const row of rows) {
      mentionsByConv.set(row.conv_id, (mentionsByConv.get(row.conv_id) ?? 0) + 1);
    }

    // Deduplicate: keep best-scoring message per conversation (first seen = best).
    const bestByConv = new Map<string, Row>();
    for (const row of rows) {
      if (!bestByConv.has(row.conv_id)) {
        bestByConv.set(row.conv_id, row);
      }
    }

    const all = [...bestByConv.values()]; // already sorted best-first
    const total = all.length;
    const page = all.slice(offset, offset + limit);

    const results: RawSearchResult[] = page.map((row) => ({
      convId: row.conv_id,
      convTitle: row.conv_title,
      convDate: row.conv_date,
      convLink: row.conv_link,
      msgIndex: row.msg_index,
      role: row.role as "human" | "claude",
      source: row.source as "desktop" | "session",
      project: row.project,
      excerpt: row.text.slice(0, 220).replace(/\n+/g, " "),
      score: row.score,
      nbMentions: mentionsByConv.get(row.conv_id) ?? 1,
    }));

    return { results, total };
  } catch {
    return { results: [], total: 0 };
  } finally {
    db?.close();
  }
}

// ── Stats ─────────────────────────────────────────────────────────────────────

export interface RawIndexStats {
  conversations: number;
  sessions: number;
  messages: number;
}

// ── Conversation messages ─────────────────────────────────────────────────────

export interface ConversationDetail {
  id: string;
  titre: string;
  source: "desktop" | "session";
  date: string;
  lien: string;
  projet: string;
  messages: { role: "human" | "claude"; text: string }[];
}

/**
 * Fetch all messages for a conversation from the raw FTS index.
 * Returns null if the conversation is not indexed.
 */
export function getConversationMessages(
  config: BrainConfig,
  convId: string
): ConversationDetail | null {
  const dbPath = rawDbPath(config);
  if (!fs.existsSync(dbPath)) return null;

  let db: Database.Database | null = null;
  try {
    db = new Database(dbPath, { readonly: true });

    type MsgRow = {
      msg_index: number;
      role: string;
      text: string;
      conv_title: string;
      conv_date: string;
      conv_link: string;
      source: string;
      project: string;
    };

    const rows = db
      .prepare(
        `SELECT msg_index, role, text, conv_title, conv_date, conv_link, source, project
         FROM raw_messages
         WHERE conv_id = ?
         ORDER BY msg_index`
      )
      .all(convId) as MsgRow[];

    if (rows.length === 0) return null;

    const first = rows[0]!;
    return {
      id: convId,
      titre: first.conv_title,
      source: first.source as "desktop" | "session",
      date: first.conv_date,
      lien: first.conv_link,
      projet: first.project,
      messages: rows.map((r) => ({
        role: r.role as "human" | "claude",
        text: r.text,
      })),
    };
  } catch {
    return null;
  } finally {
    db?.close();
  }
}

// ── All conversations (for graph/recurrences) ─────────────────────────────────

export interface ConversationSummary {
  convId: string;
  convTitle: string;
  convDate: string;
  convLink: string;
  source: "desktop" | "session";
  project: string;
}

/**
 * Return all indexed conversations (one entry per distinct conv_id).
 * Used by graph and recurrences commands — no FTS query needed.
 */
export function getAllConversations(config: BrainConfig): ConversationSummary[] {
  const dbPath = rawDbPath(config);
  if (!fs.existsSync(dbPath)) return [];

  let db: Database.Database | null = null;
  try {
    db = new Database(dbPath, { readonly: true });

    type Row = {
      conv_id: string;
      conv_title: string;
      conv_date: string;
      conv_link: string;
      source: string;
      project: string;
    };

    // Full scan — one representative row per conv_id (msg_index = 0 = first message)
    const rows = db
      .prepare(
        `SELECT conv_id, conv_title, conv_date, conv_link, source, project
         FROM raw_messages
         WHERE msg_index = 0
         ORDER BY conv_date DESC`
      )
      .all() as Row[];

    return rows.map((r) => ({
      convId: r.conv_id,
      convTitle: r.conv_title,
      convDate: r.conv_date,
      convLink: r.conv_link,
      source: r.source as "desktop" | "session",
      project: r.project,
    }));
  } catch {
    return [];
  } finally {
    db?.close();
  }
}

// ── Stats ─────────────────────────────────────────────────────────────────────

export function getRawStats(config: BrainConfig): RawIndexStats | null {
  const dbPath = rawDbPath(config);
  if (!fs.existsSync(dbPath)) return null;

  let db: Database.Database | null = null;
  try {
    db = new Database(dbPath, { readonly: true });
    const conversations = (
      db
        .prepare("SELECT COUNT(*) as n FROM raw_manifest WHERE source = 'desktop'")
        .get() as { n: number }
    ).n;
    const sessions = (
      db
        .prepare("SELECT COUNT(*) as n FROM raw_manifest WHERE source = 'session'")
        .get() as { n: number }
    ).n;
    const messages = (
      db.prepare("SELECT COUNT(*) as n FROM raw_messages").get() as { n: number }
    ).n;
    return { conversations, sessions, messages };
  } catch {
    return null;
  } finally {
    db?.close();
  }
}
