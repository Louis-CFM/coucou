/**
 * FTS5 full-text search index over brain elements.
 * Lives in ~/CoucouBrain/.state/fts.db — rebuilt after each ingest or rebuild.
 *
 * Design decisions:
 * - Single FTS5 virtual table (no content table, rebuilt from scratch on each run)
 * - `texte` is the only indexed column; metadata is UNINDEXED
 * - `is_correction=1` elements sort first regardless of score
 * - Elements from the current project get a manual boost via ORDER BY
 * - bm25() returns negative values: more negative = better match
 */
import Database from "better-sqlite3";
import fs from "node:fs";
import path from "node:path";
import matter from "gray-matter";
import { expandHome } from "./utils.js";
import type { BrainConfig } from "./config.js";
import type { StoredElement } from "./elements.js";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface SearchResult {
  id: string;
  kind: string;
  texte: string;
  statut: string | null;
  provenance: string | null;
  domaine: string | null;
  scope: string | null;
  projets: string[];
  date: string;
  sourceProject: string;
  isCorrection: boolean;
  score: number;
}

export interface SearchOptions {
  project?: string;      // current project slug (for boost)
  kinds?: string[];      // filter to these kinds
  limit?: number;        // max results (default 8)
  threshold?: number;    // bm25 threshold (default -1.0, more negative = stricter)
  excludeIds?: string[]; // IDs to skip (already-seen in this session)
  excludeMesures?: boolean; // never return any mesures
  excludeFinancialMesures?: boolean; // never return financial mesures (CA, revenues, €/$)
}

// ── Paths ─────────────────────────────────────────────────────────────────────

function ftsDbPath(config: BrainConfig): string {
  return path.join(expandHome(config.brainPath), ".state", "fts.db");
}

function brainBase(config: BrainConfig): string {
  return expandHome(config.brainPath);
}

// ── Corrections parser ────────────────────────────────────────────────────────

export interface CorrectionSection {
  scope: string;   // "global" or project slug
  text: string;    // full section Markdown text
}

export function parseCorrections(config: BrainConfig): CorrectionSection[] {
  const filePath = path.join(brainBase(config), "corrections.md");
  if (!fs.existsSync(filePath)) return [];

  const raw = fs.readFileSync(filePath, "utf8");
  // Strip YAML frontmatter
  const { content } = matter(raw);

  const sections: CorrectionSection[] = [];
  let currentScope: string | null = null;
  let currentLines: string[] = [];

  for (const line of content.split("\n")) {
    const headingMatch = line.match(/^##\s+(.+)$/);
    if (headingMatch) {
      if (currentScope !== null && currentLines.some((l) => l.trim())) {
        sections.push({ scope: currentScope, text: currentLines.join("\n").trim() });
      }
      currentScope = headingMatch[1].trim().toLowerCase().replace(/\s+/g, "-");
      currentLines = [];
    } else if (currentScope !== null) {
      currentLines.push(line);
    }
  }
  if (currentScope !== null && currentLines.some((l) => l.trim())) {
    sections.push({ scope: currentScope, text: currentLines.join("\n").trim() });
  }

  return sections;
}

/** Append a correction entry to corrections.md under the given scope section. */
export function appendCorrection(config: BrainConfig, text: string, scope: string = "global"): void {
  const filePath = path.join(brainBase(config), "corrections.md");

  if (!fs.existsSync(filePath)) {
    // Bootstrap the file
    const header = [
      "---",
      "id: corrections",
      "type: reference",
      'title: "Corrections manuelles"',
      "project: []",
      "created: " + new Date().toISOString().slice(0, 10),
      "updated: " + new Date().toISOString().slice(0, 10),
      "sources: []",
      "links: []",
      "group: Reference",
      "---",
      "",
      "Corrections manuelles — jamais écrasées par l'ingestion.",
      "Chaque entrée corrige ou remplace un élément produit par le modèle.",
      "",
    ].join("\n");
    fs.writeFileSync(filePath, header, "utf8");
  }

  let raw = fs.readFileSync(filePath, "utf8");

  // Update `updated:` in frontmatter
  raw = raw.replace(/^updated:.*$/m, `updated: ${new Date().toISOString().slice(0, 10)}`);

  const sectionHeader = `## ${scope}`;
  const entry = `\n- ${text}`;

  if (raw.includes(sectionHeader)) {
    // Find the section and append before the next ## heading or EOF
    const sectionStart = raw.indexOf(sectionHeader);
    // Find next ## heading after this one
    const nextHeading = raw.indexOf("\n## ", sectionStart + sectionHeader.length);
    if (nextHeading === -1) {
      raw = raw.trimEnd() + entry + "\n";
    } else {
      raw = raw.slice(0, nextHeading) + entry + "\n" + raw.slice(nextHeading);
    }
  } else {
    // Create new section at end
    raw = raw.trimEnd() + `\n\n${sectionHeader}${entry}\n`;
  }

  fs.writeFileSync(filePath, raw, "utf8");
}

// ── Rebuild ───────────────────────────────────────────────────────────────────

interface FtsRow {
  elem_id: string;
  kind: string;
  texte: string;
  keywords_text: string;
  statut: string;
  provenance: string;
  domaine: string;
  scope: string;
  projets_text: string;
  date_str: string;
  source_project: string;
  is_correction: number;
  is_financial: number;
}

/** Rebuild the FTS index from all state files and corrections.md. */
export function rebuildFts(config: BrainConfig): { elements: number; corrections: number } {
  const dbPath = ftsDbPath(config);
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });

  const db = new Database(dbPath);

  try {
    db.exec("PRAGMA journal_mode=WAL");

    // Drop and recreate FTS table (simplest rebuild strategy)
    db.exec(`
      DROP TABLE IF EXISTS fts_elements;
      CREATE VIRTUAL TABLE fts_elements USING fts5(
        elem_id UNINDEXED,
        kind UNINDEXED,
        statut UNINDEXED,
        provenance UNINDEXED,
        domaine UNINDEXED,
        scope UNINDEXED,
        projets_text UNINDEXED,
        date_str UNINDEXED,
        source_project UNINDEXED,
        is_correction UNINDEXED,
        is_financial UNINDEXED,
        texte,
        keywords_text,
        tokenize='unicode61 remove_diacritics 1'
      );
    `);

    const insert = db.prepare(`
      INSERT INTO fts_elements
        (elem_id, kind, statut, provenance, domaine, scope, projets_text, date_str, source_project, is_correction, is_financial, texte, keywords_text)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    const insertMany = db.transaction((rows: FtsRow[]) => {
      for (const row of rows) {
        insert.run(
          row.elem_id, row.kind, row.statut, row.provenance, row.domaine,
          row.scope, row.projets_text, row.date_str, row.source_project,
          row.is_correction, row.is_financial, row.texte, row.keywords_text
        );
      }
    });

    // ── Index project elements ──────────────────────────────────────────────
    const stateDir = path.join(brainBase(config), ".state", "proj");
    let elementCount = 0;

    if (fs.existsSync(stateDir)) {
      for (const f of fs.readdirSync(stateDir)) {
        if (!f.endsWith(".json")) continue;
        try {
          const state = JSON.parse(fs.readFileSync(path.join(stateDir, f), "utf8")) as {
            id: string;
            elements: StoredElement[];
          };
          const projectId = state.id;
          const rows: FtsRow[] = state.elements.map((e) => ({
            elem_id: e.id,
            kind: e.kind,
            texte: e.texte,
            keywords_text: (e.keywords ?? []).join(" "),
            statut: e.statut ?? "",
            provenance: e.provenance ?? "",
            domaine: e.domaine ?? "",
            scope: e.scope ?? "projet",
            projets_text: (e.projets ?? []).join(" "),
            date_str: e.date,
            source_project: projectId,
            is_correction: 0,
            is_financial: e.financial ? 1 : 0,
          }));
          if (rows.length > 0) {
            insertMany(rows);
            elementCount += rows.length;
          }
        } catch {
          // skip corrupt state file
        }
      }
    }

    // ── Index corrections ─────────────────────────────────────────────────
    const corrections = parseCorrections(config);
    const corrRows: FtsRow[] = corrections.map((sec, i) => ({
      elem_id: `corr_${sec.scope}_${i}`,
      kind: "correction",
      texte: sec.text,
      keywords_text: "",
      statut: "",
      provenance: "",
      domaine: "",
      scope: sec.scope,
      projets_text: sec.scope === "global" ? "" : sec.scope,
      date_str: "",
      source_project: `corrections:${sec.scope}`,
      is_correction: 1,
      is_financial: 0,
    }));
    if (corrRows.length > 0) {
      insertMany(corrRows);
    }

    // ── Optimize ────────────────────────────────────────────────────────────
    db.exec("INSERT INTO fts_elements(fts_elements) VALUES('optimize')");

    return { elements: elementCount, corrections: corrections.length };
  } finally {
    db.close();
  }
}

// ── Search ────────────────────────────────────────────────────────────────────

/** FR + EN stopwords — only 3-char-and-shorter words are stripped by length anyway,
 *  but we also strip common longer ones that are semantically empty. */
const STOPWORDS = new Set([
  // FR — mots-outils et mots-questions
  "avec", "dans", "pour", "plus", "sous", "tout", "tous", "bien", "même", "mais",
  "donc", "alors", "ainsi", "aussi", "comme", "quand", "dont", "cette", "quel",
  "quelle", "quels", "quelles", "être", "avoir", "faire", "votre", "notre",
  "leurs", "leur", "cette", "ceci", "cela", "voici", "voilà", "depuis", "vers",
  "sans", "entre", "après", "avant", "selon", "étant", "ayant", "fait", "faits",
  "nouveau", "nouvelle", "nouvelles", "nouveaux", "premier", "première",
  // FR question words — common but semantically empty for brain search
  "comment", "pourquoi", "combien", "quand", "lequel", "laquelle", "lesquels",
  "toujours", "jamais", "souvent", "maintenant", "encore", "peut", "doit",
  "faut", "faire", "refaire", "mettre", "prendre", "donner", "passer",
  // EN
  "with", "from", "that", "this", "have", "will", "about", "been", "which",
  "when", "what", "your", "their", "there", "these", "those", "them", "then",
  "than", "just", "also", "into", "some", "make", "need", "each", "here",
  "after", "before", "between", "without", "should", "would", "could", "must",
  "back", "both", "however", "because", "other", "another",
]);

/** Build a safe FTS5 query from free text.
 *  Returns null if no significant tokens (hook should inject nothing). */
export function buildFtsQuery(text: string): string | null {
  const words = text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, " ")  // keep unicode letters+numbers
    .split(/\s+/)
    .filter((w) => w.length >= 4 && !STOPWORDS.has(w))
    .map((w) => {
      // Strip any remaining FTS5 special chars inside words
      const clean = w.replace(/["()+\-:*^~{}]/g, "");
      return clean.length >= 4 ? clean + "*" : null;
    })
    .filter((w): w is string => w !== null);

  if (words.length < 2) return null;

  // Deduplicate
  const unique = [...new Set(words)].slice(0, 8);
  // Use OR logic: finds docs matching any term, BM25 ranks multi-term matches first.
  // AND would miss corrections that only partially overlap with the user's prompt.
  return unique.join(" OR ");
}

/** Search the FTS index. Returns [] if db not found or query invalid. */
export function searchFts(config: BrainConfig, query: string, opts: SearchOptions = {}): SearchResult[] {
  const dbPath = ftsDbPath(config);
  if (!fs.existsSync(dbPath)) return [];

  const ftsQuery = buildFtsQuery(query);
  if (!ftsQuery) return [];

  const limit = opts.limit ?? 8;
  const threshold = opts.threshold ?? -0.5;
  const excludeIds = new Set(opts.excludeIds ?? []);

  let db: Database.Database | null = null;
  try {
    db = new Database(dbPath, { readonly: true });

    // Build WHERE clause extras
    const conditions: string[] = ["fts_elements MATCH ?"];
    const params: (string | number)[] = [ftsQuery];

    if (opts.kinds && opts.kinds.length > 0) {
      conditions.push(`kind IN (${opts.kinds.map(() => "?").join(",")})`);
      params.push(...opts.kinds);
    }
    if (opts.excludeMesures) {
      conditions.push("kind != 'mesure'");
    }
    if (opts.excludeFinancialMesures) {
      conditions.push("(kind != 'mesure' OR is_financial = 0)");
    }

    const sql = `
      SELECT elem_id, kind, statut, provenance, domaine, scope, projets_text,
             date_str, source_project, is_correction, texte,
             bm25(fts_elements) as score
      FROM fts_elements
      WHERE ${conditions.join(" AND ")}
        AND bm25(fts_elements) < ?
      ORDER BY
        is_correction DESC,
        CASE WHEN source_project = ? THEN 0
             WHEN projets_text LIKE ? THEN 0
             ELSE 1 END ASC,
        CASE WHEN scope = 'transverse' THEN 0 ELSE 1 END ASC,
        bm25(fts_elements) ASC
      LIMIT ?
    `;

    const projectId = opts.project ? `proj_${opts.project}` : "";
    const projectLike = opts.project ? `%${opts.project}%` : "";

    const rows = db.prepare(sql).all(
      ...params, threshold, projectId, projectLike, limit * 3  // overfetch to filter
    ) as Array<FtsRow & { score: number }>;

    const results: SearchResult[] = [];
    for (const row of rows) {
      if (excludeIds.has(row.elem_id)) continue;
      // Cross-project elements need a stronger match (score more negative)
      const isCurrentProject = row.source_project === projectId || row.projets_text.includes(opts.project ?? "NEVER_MATCH");
      const isGlobal = row.scope === "transverse" || row.source_project.startsWith("corrections:");
      if (!isCurrentProject && !isGlobal && row.score > -2.0) continue;

      results.push({
        id: row.elem_id,
        kind: row.kind,
        texte: row.texte,
        statut: row.statut || null,
        provenance: row.provenance || null,
        domaine: row.domaine || null,
        scope: row.scope || null,
        projets: row.projets_text ? row.projets_text.split(" ").filter(Boolean) : [],
        date: row.date_str,
        sourceProject: row.source_project,
        isCorrection: row.is_correction === 1,
        score: row.score,
      });

      if (results.length >= limit) break;
    }

    return results;
  } catch {
    return [];
  } finally {
    db?.close();
  }
}

/** Render a SearchResult as a compact Markdown line for hook injection. */
export function renderSearchResult(r: SearchResult): string {
  if (r.isCorrection) {
    const scope = r.sourceProject.replace("corrections:", "");
    return `[CORRECTION:${scope}] ${r.texte}`;
  }

  const warn = (r.statut === "❌" || r.statut === "⚠️") ? ` ${r.statut}` : "";
  const stat = r.statut && r.statut !== "❌" && r.statut !== "⚠️" ? ` ${r.statut}` : "";
  const kind = r.kind;
  const proj = r.sourceProject.replace(/^proj_/, "");

  if (r.statut === "❌") {
    return `[${kind}${warn}] [${proj}] ${r.texte}${r.statut === "❌" ? " ← NE PAS REFAIRE" : ""}`;
  }
  return `[${kind}${stat}${warn}] [${proj}] ${r.texte}`;
}

// ── Hooks config writer ───────────────────────────────────────────────────────

/** Write ~/.claude/brain-hooks.json with paths hooks need to run without subprocess. */
export function writeHooksConfig(config: BrainConfig): void {
  const claudeDir = process.env.CLAUDE_CONFIG_DIR ??
    (process.env.HOME ? `${process.env.HOME}/.claude` : null);
  if (!claudeDir) return;

  const hooksConfig = {
    brainPath: expandHome(config.brainPath),
    ftsDbPath: ftsDbPath(config),
    hooksDir: new URL("../../hooks", import.meta.url).pathname,
    updatedAt: new Date().toISOString(),
  };

  const configPath = `${claudeDir}/brain-hooks.json`;
  try {
    fs.writeFileSync(configPath, JSON.stringify(hooksConfig, null, 2), "utf8");
  } catch {
    // Non-fatal
  }
}
