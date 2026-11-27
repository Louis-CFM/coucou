#!/usr/bin/env node
/**
 * brain-prompt.js — Claude Code UserPromptSubmit hook
 *
 * Performs FTS5 search on the user's message and injects up to 5 relevant
 * elements (~1000 tokens) as additionalContext.
 *
 * Constraints:
 *   - Total elapsed time < 300 ms (guarded by hard timeout)
 *   - Never injects mesures (financial data)
 *   - Never re-injects an element already seen in this session
 *   - Cross-project elements only if score is strong enough
 *   - Only injects if ≥ 2 significant query tokens match
 *
 * Guards:
 *   COUCOU_BRAIN_INTERNAL=1 → silent exit
 *   BRAIN_OFF=1 → silent exit
 *   pause flag → silent exit
 */
'use strict';

if (process.env.COUCOU_BRAIN_INTERNAL || process.env.BRAIN_OFF) {
  process.exit(0);
}

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');

// ── Hard timeout: never block a session for > 280 ms ─────────────────────────
const HARD_TIMEOUT = 280;
const deadline = setTimeout(() => {
  log('WARN', 'timeout — no injection');
  process.stdout.write('');
  process.exit(0);
}, HARD_TIMEOUT);
deadline.unref();

// ── Config ────────────────────────────────────────────────────────────────────
const HOOKS_DIR = __dirname;
const BRAIN_DIR = path.join(HOOKS_DIR, '..');

function loadBrainConfig() {
  const base = JSON.parse(fs.readFileSync(path.join(BRAIN_DIR, 'brain.config.json'), 'utf8'));
  const localPath = path.join(BRAIN_DIR, 'brain.config.local.json');
  const local = fs.existsSync(localPath) ? JSON.parse(fs.readFileSync(localPath, 'utf8')) : {};
  return { ...base, ...local };
}

function expandHome(p) {
  if (p.startsWith('~/')) return path.join(os.homedir(), p.slice(2));
  return p;
}

function toSlug(name) {
  return String(name).toLowerCase()
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

// ── Logging ───────────────────────────────────────────────────────────────────
let brainBase = null;

function log(level, message, extra) {
  if (!brainBase) return;
  // BRAIN_LOG_FILE overrides destination (used by tests to avoid polluting hooks.log)
  const logFile = process.env.BRAIN_LOG_FILE ||
    path.join(brainBase, '.state', 'logs', 'hooks.log');
  if (logFile === '/dev/null') return;
  try {
    fs.mkdirSync(path.dirname(logFile), { recursive: true });
    const line = `${new Date().toISOString().slice(0, 19)}Z [prompt] ${level} ${message}${extra ? ' | ' + JSON.stringify(extra) : ''}`;
    fs.appendFileSync(logFile, line + '\n', 'utf8');
  } catch {}
}

// ── Stopwords ─────────────────────────────────────────────────────────────────
const STOPWORDS = new Set([
  // FR — mots-outils et mots-questions
  'avec','dans','pour','plus','sous','tout','tous','bien','même','mais','donc',
  'alors','ainsi','aussi','comme','quand','dont','cette','quel','quelle','quels',
  'quelles','être','avoir','faire','votre','notre','leurs','leur','cette','ceci',
  'cela','voici','voilà','depuis','vers','sans','entre','après','avant','selon',
  'étant','ayant','fait','faits','nouveau','nouvelle','nouvelles','nouveaux','premier','première',
  // FR question words — common but semantically empty for brain search
  'comment','pourquoi','combien','quand','lequel','laquelle','lesquels',
  'toujours','jamais','souvent','maintenant','encore','peut','doit',
  'faut','faire','refaire','mettre','prendre','donner','passer',
  // EN
  'with','from','that','this','have','will','about','been','which','when','what',
  'your','their','there','these','those','them','then','than','just','also','into',
  'some','make','need','each','here','after','before','between','without','should',
  'would','could','must','back','both','however','because','other','another',
]);

// ── FTS query builder ─────────────────────────────────────────────────────────

/** Extract significant terms from user text (no * suffix, deduped). */
function extractTerms(text) {
  return [...new Set(
    text
      .toLowerCase()
      .replace(/[^\p{L}\p{N}\s]/gu, ' ')
      .split(/\s+/)
      .filter(w => w.length >= 4 && !STOPWORDS.has(w))
      .map(w => w.replace(/["()+\-:*^~{}]/g, ''))
      .filter(w => w.length >= 4)
  )].slice(0, 8);
}

/** Build FTS5 OR query (prefix). Returns null if fewer than 2 significant terms. */
function buildFtsQuery(text) {
  const terms = extractTerms(text);
  if (terms.length < 2) return null;
  return terms.map(t => t + '*').join(' OR ');
}

/** Count how many query terms appear (as substrings) in a row's texte+keywords. */
function countTermMatches(terms, row) {
  const haystack = ((row.texte || '') + ' ' + (row.keywords_text || '')).toLowerCase();
  return terms.filter(t => haystack.includes(t)).length;
}

// ── Session seen-IDs tracking ─────────────────────────────────────────────────
function getSeenPath(sessionId) {
  if (!brainBase || !sessionId || sessionId === 'unknown') return null;
  return path.join(brainBase, '.state', 'sessions', `${sessionId}.json`);
}

function loadSeen(sessionId) {
  const p = getSeenPath(sessionId);
  if (!p || !fs.existsSync(p)) return new Set();
  try {
    return new Set(JSON.parse(fs.readFileSync(p, 'utf8')));
  } catch { return new Set(); }
}

function saveSeen(sessionId, ids) {
  const p = getSeenPath(sessionId);
  if (!p) return;
  try {
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, JSON.stringify([...ids]), 'utf8');
  } catch {}
}

function cleanupOldSeenFiles() {
  if (!brainBase) return;
  const sessionsDir = path.join(brainBase, '.state', 'sessions');
  if (!fs.existsSync(sessionsDir)) return;
  try {
    const cutoff = Date.now() - 86400000; // 24h
    for (const f of fs.readdirSync(sessionsDir)) {
      const fp = path.join(sessionsDir, f);
      try {
        if (fs.statSync(fp).mtimeMs < cutoff) fs.unlinkSync(fp);
      } catch {}
    }
  } catch {}
}

// ── Project detection from CWD ────────────────────────────────────────────────
function detectProjectSlug(cwd, stateDir) {
  let repoName = path.basename(cwd);
  let remoteUrl = null;
  try {
    const r = spawnSync('git', ['-C', cwd, 'remote', 'get-url', 'origin'], {
      encoding: 'utf8', timeout: 500,
    });
    if (r.status === 0) {
      remoteUrl = r.stdout.trim();
      repoName = remoteUrl.replace(/\.git$/, '').split(/[\/:]/).pop() || repoName;
    }
  } catch {}

  const slugFromName = toSlug(repoName);
  const slugFromCwd = toSlug(path.basename(cwd));

  if (!fs.existsSync(stateDir)) return slugFromCwd;

  for (const f of fs.readdirSync(stateDir)) {
    if (!f.endsWith('.json') || f === 'lessons.json' || f === 'louis.json') continue;
    try {
      const st = JSON.parse(fs.readFileSync(path.join(stateDir, f), 'utf8'));
      if (remoteUrl && st.remote && st.remote === remoteUrl) {
        return st.id.replace(/^proj_/, '');
      }
      if (st.id === `proj_${slugFromName}` || st.id === `proj_${slugFromCwd}`) {
        return st.id.replace(/^proj_/, '');
      }
    } catch {}
  }

  return slugFromName;
}

// ── Injection dedup ───────────────────────────────────────────────────────────
function injTokenSet(text) {
  return new Set(
    text.toLowerCase()
      .replace(/[^\p{L}\p{N}\s]/gu, ' ')
      .split(/\s+/)
      .filter(w => w.length >= 3)
  );
}
function injJaccard(a, b) {
  const setA = injTokenSet(a);
  const setB = injTokenSet(b);
  if (setA.size === 0 && setB.size === 0) return 1;
  let n = 0;
  for (const t of setA) if (setB.has(t)) n++;
  return n / (setA.size + setB.size - n);
}
/** Remove near-duplicates (Jaccard >= 0.6) from a sorted result list. */
function dedupResults(results) {
  const kept = [];
  for (const r of results) {
    const dup = kept.some(k => {
      // ❌ same project → tighter dedup (0.40) to avoid injecting two versions of the same failure
      const threshold =
        k.statut === '❌' && r.statut === '❌' && k.source_project === r.source_project
          ? 0.40
          : 0.5;
      return injJaccard(k.texte, r.texte) >= threshold;
    });
    if (!dup) kept.push(r);
  }
  return kept;
}

// ── Render result ─────────────────────────────────────────────────────────────
function renderResult(r) {
  if (r.isCorrection) {
    const scope = r.sourceProject.replace('corrections:', '');
    return `[CORRECTION:${scope}]\n${r.texte}`;
  }
  const warn = (r.statut === '❌' || r.statut === '⚠️') ? ` ${r.statut}` : '';
  const notRedo = r.statut === '❌' ? ' ← NE PAS REFAIRE' : '';
  const proj = r.sourceProject.replace(/^proj_/, '');
  return `[${r.kind}${warn}][${proj}]${notRedo}\n${r.texte}`;
}

// ── Main ──────────────────────────────────────────────────────────────────────
const startTime = Date.now();
let input = '';
process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', () => {
  try {
    run(input);
  } catch (e) {
    log('ERROR', e.message);
    process.exit(0);
  }
});

function run(rawInput) {
  let data = {};
  try { data = JSON.parse(rawInput); } catch {}

  const prompt = data.prompt || '';
  const sessionId = data.session_id || 'unknown';
  const cwd = data.cwd || process.env.PWD || process.cwd();

  // ── Guard 2: prompt contains internal marker (digest subprocess) ─────────────
  if (prompt.includes('<!-- coucou-brain-internal -->')) { process.exit(0); }

  if (!prompt || prompt.length < 8) { process.exit(0); }

  // ── Guard: skip internal hook/task messages ───────────────────────────────────
  // Mirrors the same filter as collect.ts to avoid wasted FTS work on system messages.
  const trimmedPrompt = prompt.trim();
  if (
    trimmedPrompt.includes('<task-notification>') ||
    trimmedPrompt.includes('<system-reminder>') ||
    trimmedPrompt.includes('<parameter>') ||
    /^<[a-z][-a-z]*>/.test(trimmedPrompt) ||
    /^toolu_[A-Za-z0-9]{10,}$/.test(trimmedPrompt)
  ) { process.exit(0); }

  let config;
  try { config = loadBrainConfig(); } catch { process.exit(0); }

  brainBase = expandHome(config.brainPath);

  // ── Guard 3: cwd is inside brainPath (digestion dir, security tests…) ─────────
  if (cwd && (cwd + path.sep).startsWith(brainBase + path.sep)) { process.exit(0); }

  // Check pause flag
  if (fs.existsSync(path.join(brainBase, '.state', 'paused'))) {
    process.exit(0);
  }

  // Build FTS query — exit early if not enough significant tokens
  const terms = extractTerms(prompt);
  const ftsQuery = terms.length >= 2 ? terms.map(t => t + '*').join(' OR ') : null;
  if (!ftsQuery) {
    log('INFO', 'no sig tokens', { prompt: prompt.slice(0, 50) });
    process.exit(0);
  }
  // Minimum term overlap required (at least half, minimum 2)
  const minMatches = Math.max(2, Math.ceil(terms.length / 2));

  // Load FTS DB
  const ftsDbPath = path.join(brainBase, '.state', 'fts.db');
  if (!fs.existsSync(ftsDbPath)) { process.exit(0); }

  let Database;
  try {
    Database = require('better-sqlite3');
  } catch { process.exit(0); }

  let db;
  try {
    db = new Database(ftsDbPath, { readonly: true });
  } catch { process.exit(0); }

  // Detect project
  const stateDir = path.join(brainBase, '.state', 'proj');
  const projectSlug = detectProjectSlug(cwd, stateDir);
  const projectId = `proj_${projectSlug}`;

  // Load seen IDs for this session
  const seen = loadSeen(sessionId);
  cleanupOldSeenFiles();

  try {
    // Main query: top 30 elements by BM25
    const sql = `
      SELECT elem_id, kind, statut, provenance, domaine, scope,
             projets_text, date_str, source_project, is_correction, texte,
             keywords_text, bm25(fts_elements) as score
      FROM fts_elements
      WHERE fts_elements MATCH ?
        AND (kind != 'mesure' OR is_financial = 0)
      ORDER BY
        is_correction DESC,
        CASE WHEN source_project = ? OR projets_text LIKE ? THEN 0 ELSE 1 END ASC,
        CASE WHEN scope = 'transverse' THEN 0 ELSE 1 END ASC,
        bm25(fts_elements) ASC
      LIMIT 30
    `;
    // Priority query: ❌ and préférence from current project — always included regardless of BM25 rank
    const sqlPriority = `
      SELECT elem_id, kind, statut, provenance, domaine, scope,
             projets_text, date_str, source_project, is_correction, texte,
             keywords_text, bm25(fts_elements) as score
      FROM fts_elements
      WHERE fts_elements MATCH ?
        AND (statut = '❌' OR kind = 'préférence')
        AND (source_project = ? OR projets_text LIKE ?)
        AND (kind != 'mesure' OR is_financial = 0)
      ORDER BY bm25(fts_elements) ASC
      LIMIT 10
    `;

    const projectLike = `%${projectSlug}%`;
    const stmt = db.prepare(sql);
    const stmtPrio = db.prepare(sqlPriority);
    const mainRows = stmt.all(ftsQuery, projectId, projectLike);
    const prioRows = stmtPrio.all(ftsQuery, projectId, projectLike);
    db.close();

    // Merge: priority rows first (deduped by elem_id), then main rows
    const seen_ids = new Set(prioRows.map(r => r.elem_id));
    const rows = [...prioRows, ...mainRows.filter(r => !seen_ids.has(r.elem_id))];

    // Filter: term overlap + BM25 (type-aware) + cross-project threshold + exclude seen
    const candidates = [];
    for (const row of rows) {
      if (seen.has(row.elem_id)) continue;

      const isCurrentProject =
        row.source_project === projectId ||
        row.projets_text.includes(projectSlug);
      const isGlobal =
        row.scope === 'transverse' ||
        row.source_project.startsWith('corrections:global');
      const isProjectCorr = row.is_correction &&
        row.source_project === `corrections:${projectSlug}`;

      // ❌/préférence get priority via SQL (already in rows from priority query),
      // but same term-overlap and BM25 thresholds as other elements — no minMatches reduction
      const matchCount = countTermMatches(terms, row);
      if (matchCount < minMatches) continue;

      // Same-project / global: BM25 must be meaningful
      if ((isCurrentProject || isGlobal || isProjectCorr) && row.score > -0.5) continue;
      // Cross-project: require strong BM25 + extra term overlap
      if (!isCurrentProject && !isGlobal && !isProjectCorr) {
        if (row.score > -6.0) continue;
        // Cross-project also needs ≥ 75% of terms
        if (matchCount < Math.max(minMatches + 1, Math.ceil(terms.length * 0.75))) continue;
      }

      candidates.push({ ...row, matchCount });
    }

    // Re-rank: corrections first, then ❌/préférence, then matchCount DESC, then bm25 ASC
    candidates.sort((a, b) => {
      if (b.is_correction !== a.is_correction) return b.is_correction - a.is_correction;
      const aHP = (a.statut === '❌' || a.kind === 'préférence') ? 1 : 0;
      const bHP = (b.statut === '❌' || b.kind === 'préférence') ? 1 : 0;
      if (bHP !== aHP) return bHP - aHP;
      if (b.matchCount !== a.matchCount) return b.matchCount - a.matchCount;
      return a.score - b.score;
    });

    const results = dedupResults(candidates).slice(0, 3);

    if (results.length === 0) {
      log('INFO', 'no results above threshold', { query: ftsQuery, project: projectSlug });
      process.exit(0);
    }

    // Format injection (max ~1000 tokens = ~4000 chars)
    const lines = results.map(r => renderResult({
      id: r.elem_id,
      kind: r.kind,
      texte: r.texte,
      statut: r.statut || null,
      sourceProject: r.source_project,
      scope: r.scope,
      isCorrection: r.is_correction === 1,
    }));

    const context = `Mémoire CoucouBrain [${projectSlug}] :\n\n` + lines.join('\n\n');

    // Clamp to ~4000 chars (~1000 tokens)
    const clamped = context.length > 4000 ? context.slice(0, 3990) + '\n…' : context;

    // Save seen IDs
    const injectedIds = results.map(r => r.elem_id);
    for (const id of injectedIds) seen.add(id);
    saveSeen(sessionId, seen);

    const duration = Date.now() - startTime;
    log('INFO', 'injected', {
      project: projectSlug,
      session: sessionId,
      ids: injectedIds,
      scores: results.map(r => ({ id: r.elem_id, matches: `${r.matchCount}/${terms.length}`, bm25: r.score.toFixed(2) })),
      tokens: Math.round(clamped.length / 4),
      ms: duration,
      query: ftsQuery,
    });

    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'UserPromptSubmit',
        additionalContext: clamped,
      },
    }));

  } catch (e) {
    try { db?.close(); } catch {}
    log('ERROR', e.message, { query: ftsQuery });
    process.exit(0);
  }
}
