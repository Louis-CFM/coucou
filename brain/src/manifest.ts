/**
 * SQLite manifest — tracks which sessions and repos have been processed.
 * Lives in ~/CoucouBrain/.state/manifest.db (not tracked by git).
 */
import Database from "better-sqlite3";
import path from "node:path";
import fs from "node:fs";
import { expandHome } from "./utils.js";

export type ItemStatus = "pending" | "done" | "failed";

export interface SessionEntry {
  id: string;           // session UUID (from filename)
  project_path: string; // e.g. "-Users-louis-Developer-coucou"
  jsonl_path: string;   // absolute path to .jsonl
  hash: string;         // sha256 of file contents (detect modifications)
  status: ItemStatus;
  processed_at: string | null;
  record_id: string | null;    // ID of the generated record page
  projects: string;    // JSON array of project slugs
}

export interface RepoEntry {
  path: string;         // absolute path to repo
  last_commit: string;  // HEAD commit hash
  status: ItemStatus;
  processed_at: string | null;
  project_page_id: string | null; // ID of the generated project page
}

export class Manifest {
  private db: Database.Database;

  constructor(brainPath: string) {
    const statePath = path.join(expandHome(brainPath), ".state");
    fs.mkdirSync(statePath, { recursive: true });
    const dbPath = path.join(statePath, "manifest.db");
    this.db = new Database(dbPath);
    this.migrate();
  }

  private migrate(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        project_path TEXT NOT NULL,
        jsonl_path TEXT NOT NULL,
        hash TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        processed_at TEXT,
        record_id TEXT,
        projects TEXT NOT NULL DEFAULT '[]'
      );

      CREATE TABLE IF NOT EXISTS repos (
        path TEXT PRIMARY KEY,
        last_commit TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        processed_at TEXT,
        project_page_id TEXT
      );

      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    `);

    // Schema version for future migrations
    const existing = this.db
      .prepare("SELECT value FROM meta WHERE key = 'schema_version'")
      .get() as { value: string } | undefined;
    if (!existing) {
      this.db
        .prepare("INSERT INTO meta (key, value) VALUES ('schema_version', '1')")
        .run();
    }
  }

  // ── Sessions ────────────────────────────────────────────────────────────────

  upsertSession(entry: Omit<SessionEntry, "status" | "processed_at" | "record_id" | "projects"> & Partial<SessionEntry>): void {
    const existing = this.getSession(entry.id);
    if (existing) {
      // If hash changed, reset to pending so it gets re-processed
      if (existing.hash !== entry.hash && existing.status === "done") {
        this.db.prepare(`
          UPDATE sessions SET hash = ?, status = 'pending', processed_at = NULL, record_id = NULL
          WHERE id = ?
        `).run(entry.hash, entry.id);
      }
    } else {
      this.db.prepare(`
        INSERT INTO sessions (id, project_path, jsonl_path, hash, status, processed_at, record_id, projects)
        VALUES (?, ?, ?, ?, 'pending', NULL, NULL, '[]')
      `).run(entry.id, entry.project_path, entry.jsonl_path, entry.hash);
    }
  }

  getSession(id: string): SessionEntry | undefined {
    return this.db.prepare("SELECT * FROM sessions WHERE id = ?").get(id) as SessionEntry | undefined;
  }

  getPendingSessions(): SessionEntry[] {
    return this.db
      .prepare("SELECT * FROM sessions WHERE status IN ('pending', 'failed') ORDER BY jsonl_path ASC")
      .all() as SessionEntry[];
  }

  markSessionDone(id: string, recordId: string, projects: string[]): void {
    this.db.prepare(`
      UPDATE sessions SET status = 'done', processed_at = ?, record_id = ?, projects = ?
      WHERE id = ?
    `).run(new Date().toISOString(), recordId, JSON.stringify(projects), id);
  }

  markSessionFailed(id: string): void {
    this.db.prepare(`
      UPDATE sessions SET status = 'failed', processed_at = ? WHERE id = ?
    `).run(new Date().toISOString(), id);
  }

  getAllSessions(): SessionEntry[] {
    return this.db.prepare("SELECT * FROM sessions ORDER BY jsonl_path ASC").all() as SessionEntry[];
  }

  resetSessionToPending(id: string): void {
    this.db.prepare(
      "UPDATE sessions SET status = 'pending', processed_at = NULL WHERE id = ?"
    ).run(id);
  }

  // ── Repos ───────────────────────────────────────────────────────────────────

  upsertRepo(entry: Omit<RepoEntry, "status" | "processed_at" | "project_page_id">): void {
    const existing = this.getRepo(entry.path);
    if (existing) {
      if (existing.last_commit !== entry.last_commit && existing.status === "done") {
        this.db.prepare(`
          UPDATE repos SET last_commit = ?, status = 'pending', processed_at = NULL WHERE path = ?
        `).run(entry.last_commit, entry.path);
      }
    } else {
      this.db.prepare(`
        INSERT INTO repos (path, last_commit, status, processed_at, project_page_id)
        VALUES (?, ?, 'pending', NULL, NULL)
      `).run(entry.path, entry.last_commit);
    }
  }

  getRepo(repoPath: string): RepoEntry | undefined {
    return this.db.prepare("SELECT * FROM repos WHERE path = ?").get(repoPath) as RepoEntry | undefined;
  }

  getPendingRepos(): RepoEntry[] {
    return this.db
      .prepare("SELECT * FROM repos WHERE status IN ('pending', 'failed') ORDER BY path ASC")
      .all() as RepoEntry[];
  }

  markRepoDone(repoPath: string, projectPageId: string): void {
    this.db.prepare(`
      UPDATE repos SET status = 'done', processed_at = ?, project_page_id = ? WHERE path = ?
    `).run(new Date().toISOString(), projectPageId, repoPath);
  }

  markRepoFailed(repoPath: string): void {
    this.db.prepare(`
      UPDATE repos SET status = 'failed', processed_at = ? WHERE path = ?
    `).run(new Date().toISOString(), repoPath);
  }

  close(): void {
    this.db.close();
  }
}
